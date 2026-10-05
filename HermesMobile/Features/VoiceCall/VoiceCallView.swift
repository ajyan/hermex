import AVFoundation
import AVKit
import SwiftUI

/// Debug builds append call events to Documents/voice-call.log for on-device diagnosis.
enum VoiceCallDiagnostics {
    static func write(_ line: String) {
        #if DEBUG
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice-call.log")
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let data = Data("\(stamp) [\(route)] \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
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
                captions
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
        let controller = VoiceCallController(
            listener: AppleSpeechListener(levels: levels),
            speaker: AppleSpeechSpeaker(levels: levels),
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

    /// Near-black with a wash of the current speaker's color from the top.
    private var background: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [moodTint.opacity(0.32), .clear],
                center: .init(x: 0.5, y: 0.38),
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: mood)
    }

    private var moodTint: Color {
        switch mood {
        case .listening: Color(red: 0.2, green: 0.55, blue: 1.0)
        case .thinking, .speaking: Color(red: 0.6, green: 0.3, blue: 0.95)
        case .attention: Color(red: 1.0, green: 0.6, blue: 0.2)
        case .connecting, .quiet: Color(red: 0.4, green: 0.45, blue: 0.55)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(verbatim: CallSystemBridge.handle)
                .font(.largeTitle.weight(.semibold))
            HStack(spacing: 6) {
                Text(stateLabel)
                if let connectedAt, !isEnded {
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(timerInterval: connectedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
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
                VoiceCallOrb(levels: levels, mood: mood)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 340, maxHeight: 340)
                    .contentShape(Circle().scale(0.7))
            }
            .buttonStyle(.plain)
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

    /// Live captions for whoever is talking: the user's words while listening,
    /// Atlas's latest sentences while it answers, with the user's turn above.
    private var captions: some View {
        let live = controller?.partialTranscript ?? ""
        let sent = controller?.lastSentTurn
        let reply = atlasCaption
        return VStack(spacing: 10) {
            if let reply {
                if let sent {
                    Text(sent)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(reply)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .truncationMode(.head)
            } else if !live.isEmpty {
                Text(live)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .truncationMode(.head)
            } else if let sent {
                Text(sent)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.head)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .bottom)
        .padding(.bottom, 28)
    }

    /// The tail of what Atlas is saying, as it would be spoken (no markdown).
    private var atlasCaption: String? {
        switch state {
        case .thinking, .speaking, .reconnecting: break
        default: return nil
        }
        guard let text = snapshot.streamingText else { return nil }
        let sentences = SpeechTextShaper.sentences(in: text, final: true)
        guard !sentences.isEmpty else { return nil }
        return sentences.suffix(3).joined(separator: " ")
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
            Text("Hermex needs the microphone and speech recognition for calls")
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

    var body: some View {
        VStack(spacing: 8) {
            button
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 80)
    }

    /// Solid when it carries meaning (End, or a control that's on), glass otherwise.
    @ViewBuilder
    private var button: some View {
        let face = content
            .font(.title2)
            .foregroundStyle(isOn ? Color.black : Color.white)
            .frame(width: 72, height: 72)
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
