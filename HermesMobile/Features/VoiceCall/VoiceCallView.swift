import AVFoundation
import AVKit
import SwiftUI

/// Debug builds append call events to Documents/voice-call.log for on-device diagnosis.
/// Each line carries the wall time, seconds since the call began, and the audio route.
enum VoiceCallDiagnostics {
    #if DEBUG
    private static let queue = DispatchQueue(label: "voice-call.log", qos: .utility)
    nonisolated(unsafe) private static var callStart = ProcessInfo.processInfo.systemUptime
    #endif

    /// Starts a call's section of the log; later lines are timed from here.
    @MainActor static func beginCall() {
        #if DEBUG
        callStart = ProcessInfo.processInfo.systemUptime
        let device = UIDevice.current
        write("===== call begin: \(device.model) iOS \(device.systemVersion)")
        #endif
    }

    static func write(_ line: String) {
        #if DEBUG
        let elapsed = ProcessInfo.processInfo.systemUptime - callStart
        let date = Date()
        queue.async {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("voice-call.log")
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
                .joined(separator: ",")
            let stamp = date.formatted(.iso8601.time(includingFractionalSeconds: true))
            let data = Data(String(format: "%@ +%7.3f [%@] %@\n", stamp, elapsed, route, line).utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
        #endif
    }
}

/// What a call needs from the chat's stream, read from `ChatViewModel`.
struct VoiceCallChatSnapshot: Equatable {
    var streamingText: String?
    var isStreaming: Bool
    var approval: ApprovalPromptState?
    var isReconnecting: Bool
    var currentTool: String?

    @MainActor
    static func of(_ chat: ChatViewModel) -> VoiceCallChatSnapshot {
        make(
            messages: chat.messages,
            activeStreamID: chat.activeStreamID,
            recovery: chat.activeStreamRecoveryState,
            approval: chat.approvalPrompt,
            liveToolCalls: chat.liveToolCalls
        )
    }

    /// The reply is everything Atlas said after the latest user turn, joined in
    /// order. No message IDs: they change when a run finishes, and a reply split
    /// around tool calls spans several messages.
    static func make(
        messages: [ChatMessage],
        activeStreamID: String?,
        recovery: ActiveStreamRecoveryState,
        approval: ApprovalPromptState?,
        liveToolCalls: [ToolCall]
    ) -> VoiceCallChatSnapshot {
        let replyStart = (messages.lastIndex { $0.role == "user" }).map { $0 + 1 } ?? messages.endIndex
        let parts = messages[replyStart...]
            .filter { $0.role == "assistant" }
            .compactMap(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return VoiceCallChatSnapshot(
            streamingText: parts.isEmpty ? nil : parts.joined(separator: "\n"),
            isStreaming: activeStreamID != nil,
            approval: approval,
            isReconnecting: recovery == .reconnecting || recovery == .waitingForNetwork,
            currentTool: liveToolCalls.last(where: { !$0.isCompleted })?.name
        )
    }
}

/// The full-screen call with Atlas on one chat. It owns the call controller and
/// feeds it the chat's stream state; closing it leaves the chat on screen.
struct VoiceCallView: View {
    let chat: ChatViewModel
    let onClose: () -> Void

    @State private var controller: VoiceCallController?
    @State private var startMessage: String?
    @State private var levels = VoiceCallAudioLevels()
    /// When the call first started listening, for the call timer.
    @State private var connectedAt: Date?
    @AppStorage(VoiceCallSettings.usesServerVoiceKey) private var usesServerVoice = false
    /// The orb's slot in screen coordinates; the full-screen orb is centered on it.
    @State private var orbSlot: CGRect = .zero
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                orb
                Spacer(minLength: 12)
                controls
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if let prompt = chat.approvalPrompt {
                ApprovalRequestOverlay(
                    prompt: prompt,
                    isResponding: chat.isRespondingToApproval,
                    errorMessage: chat.approvalErrorMessage,
                    onChoice: { choice in
                        controller?.approvalAnsweredOnScreen()
                        Task { _ = await chat.respondToApproval(choice) }
                    },
                    onSkipAll: {
                        controller?.approvalAnsweredOnScreen()
                        Task { _ = await chat.skipApprovalsForCurrentSession() }
                    }
                )
            }
        }
        // A call is an immersive, dark surface in either appearance, like the Phone app.
        .preferredColorScheme(.dark)
        .task { await startCall() }
        // However the screen goes away, its system call goes with it; a call left
        // live blocks the next one from connecting.
        .onDisappear {
            guard let controller, !controller.isFinished else { return }
            VoiceCallDiagnostics.write("call screen closed without hanging up; ending the call")
            controller.end()
        }
        .onChange(of: snapshot) { _, snapshot in
            controller?.chatDidUpdate(
                streamingText: snapshot.streamingText,
                isStreaming: snapshot.isStreaming,
                approval: snapshot.approval,
                isReconnecting: snapshot.isReconnecting,
                currentTool: snapshot.currentTool
            )
        }
        .onChange(of: controller?.state) { _, state in
            if state == .listening, connectedAt == nil { connectedAt = .now }
        }
        .onChange(of: controller?.isFinished) { _, finished in
            if finished == true, controller?.startError == nil { onClose() }
        }
        .sensoryFeedback(trigger: controller?.lastSentTurn) { _, sent in
            sent == nil ? nil : .impact(weight: .light)
        }
        .sheet(isPresented: permissionSheetBinding, onDismiss: onClose) {
            permissionSheet
        }
        .alert(
            startMessage ?? "",
            isPresented: Binding(get: { startMessage != nil }, set: { if !$0 { startMessage = nil; onClose() } })
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    private var snapshot: VoiceCallChatSnapshot {
        VoiceCallChatSnapshot.of(chat)
    }

    private func startCall() async {
        guard controller == nil else { return }
        guard !chat.isViewingCachedData else {
            startMessage = String(localized: "Reconnect to the server to send a message.")
            return
        }
        VoiceCallDiagnostics.beginCall()
        let controller = VoiceCallController(
            listener: AppleSpeechListener(levels: levels, log: VoiceCallDiagnostics.write),
            speaker: makeSpeaker(),
            chat: chat,
            bridge: CallSystemBridge(),
            log: VoiceCallDiagnostics.write
        )
        self.controller = controller
        await controller.start()
        switch controller.startError {
        case .recognitionUnavailable(let language):
            let name = Locale.current.localizedString(forIdentifier: language) ?? language
            startMessage = String(localized: "On-device speech recognition for \(name) isn't installed.")
        case .callDidNotConnect:
            startMessage = String(localized: "The call couldn't connect. Try again.")
        case .permissionDenied, nil:
            break
        }
    }

    private func makeSpeaker() -> SpeechSpeaking {
        let apple = AppleSpeechSpeaker(levels: levels, log: VoiceCallDiagnostics.write)
        guard usesServerVoice else { return apple }
        VoiceCallDiagnostics.write("speaker: server voice (openai engine)")
        let client = chat.client
        return ServerSpeechSpeaker(
            synthesize: { text in try await client.synthesizeSpeech(text: text, voice: nil, engine: .openai) },
            fallback: apple,
            levels: levels,
            log: VoiceCallDiagnostics.write
        )
    }

    // MARK: - Pieces

    private var state: VoiceCallState { controller?.state ?? .idle }

    private var mood: VoiceCallOrbMood {
        switch state {
        case .idle, .connecting, .reconnecting: .connecting
        case .listening: controller?.isMuted == true ? .quiet : .listening
        case .thinking: .thinking
        case .speaking: .speaking
        case .awaitingApproval: .attention
        case .ended: .quiet
        }
    }

    /// Near-black under the breathing glow, which carries the speaker's color.
    private var background: some View {
        ZStack {
            Color(red: 0.02, green: 0.024, blue: 0.04)
            VoiceCallOrb(levels: levels, mood: mood, focus: orbSlot)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(verbatim: CallSystemBridge.handle)
                .font(.headline.weight(.medium))
            HStack(spacing: 6) {
                Text(stateLabel)
                if let connectedAt, !isEnded {
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(timerInterval: connectedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let tool = controller?.currentTool {
                Label(tool, systemImage: "wrench.and.screwdriver")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .adaptiveGlass(fallbackMaterial: .ultraThinMaterial, in: Capsule())
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller?.currentTool)
        .accessibilityElement(children: .combine)
    }

    /// The orb doubles as the one-tap shortcut: send now, or cut Atlas off.
    private var orb: some View {
        let action = controller?.tapAction
        return VStack(spacing: 12) {
            Button {
                controller?.performTapAction()
            } label: {
                // The orb itself is drawn full screen behind everything, centered here.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 380, maxHeight: 380)
                    .contentShape(Circle().scale(0.7))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { orbSlot = $0 }
            }
            .buttonStyle(.plain)
            // Captions ride over the orb; taps go through to it.
            .overlay {
                captions
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            }
            .disabled(action == nil)
            .accessibilityLabel(tapHint ?? "")
            .accessibilityHidden(action == nil)

            Text(tapHint ?? " ")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .opacity(tapHint == nil ? 0 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: tapHint)
                .accessibilityHidden(true)
        }
    }

    private var tapHint: LocalizedStringKey? {
        switch controller?.tapAction {
        case .send: "Tap to send"
        case .interrupt: "Tap to interrupt"
        case nil: controller?.isMuted == true ? "You're muted" : nil
        }
    }

    private var captions: some View {
        VoiceCallCaptions(
            sent: controller?.lastSentTurn,
            live: controller?.partialTranscript ?? "",
            reply: replyCaption,
            isReplying: [.thinking, .speaking, .reconnecting].contains(state)
        )
    }

    /// Atlas's reply to the latest turn, as it would be spoken (no markdown).
    private var replyCaption: String? {
        guard let text = snapshot.streamingText else { return nil }
        let sentences = SpeechTextShaper.sentences(in: text, final: true)
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private var controls: some View {
        let isMuted = controller?.isMuted ?? false
        return HStack(alignment: .top) {
            CallControl(title: "Audio") {
                CallAudioRoutePicker()
            }

            Spacer()

            CallControl(title: isMuted ? "Unmute" : "Mute", isOn: isMuted) {
                Button {
                    controller?.setMuted(!isMuted)
                } label: {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Circle())
                }
                .accessibilityLabel(isMuted ? LocalizedStringKey("Unmute") : "Mute")
            }

            Spacer()

            CallControl(title: "End", tint: .hxDanger) {
                Button {
                    if let controller { controller.end() } else { onClose() }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Circle())
                }
                .accessibilityLabel("End")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    private var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    private var stateLabel: LocalizedStringKey {
        switch state {
        case .idle, .connecting: "Connecting"
        case .listening: controller?.isMuted == true ? "Muted" : "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .awaitingApproval: "Waiting for your approval"
        case .reconnecting: "Reconnecting"
        case .ended: "Call ended"
        }
    }

    private var permissionSheetBinding: Binding<Bool> {
        Binding(
            get: { controller?.startError == .permissionDenied },
            set: { _ in }
        )
    }

    private var permissionSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.slash")
                .font(.largeTitle)
                .foregroundStyle(Color.hxWarning)
                .accessibilityHidden(true)
            Text("Atlas needs the microphone and speech recognition for calls")
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            Button("Close", action: onClose)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

/// One round call button with its caption underneath, Phone-app style.
private struct CallControl<Content: View>: View {
    let title: LocalizedStringKey
    var isOn = false
    var tint: Color?
    @ViewBuilder let content: Content

    /// The title is for VoiceOver; the round buttons speak for themselves on screen.
    var body: some View {
        button
            .accessibilityLabel(title)
            .frame(minWidth: 60)
    }

    /// Solid when it carries meaning (End, or a control that's on), glass otherwise.
    @ViewBuilder
    private var button: some View {
        let face = content
            .font(.title3)
            .foregroundStyle(isOn ? Color.black : Color.white)
            .frame(width: 60, height: 60)
        if let solid = tint ?? (isOn ? Color.white : nil) {
            face.background(solid, in: Circle())
        } else {
            face.adaptiveGlass(fallbackMaterial: .ultraThinMaterial, in: Circle())
        }
    }
}

/// The system audio route menu (speaker, receiver, AirPods) for the call.
private struct CallAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
