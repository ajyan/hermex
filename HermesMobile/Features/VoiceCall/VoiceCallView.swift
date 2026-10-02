import AVFoundation
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
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 24) {
                header
                Spacer(minLength: 0)
                transcript
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)

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
        .onChange(of: controller?.isFinished) { _, finished in
            if finished == true, controller?.startError == nil { onClose() }
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
            listener: AppleSpeechListener(),
            speaker: AppleSpeechSpeaker(),
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

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: stateSymbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(stateColor)
                .frame(height: 56)
                .accessibilityHidden(true)
            Text(verbatim: CallSystemBridge.handle)
                .font(.title.weight(.semibold))
            Text(stateLabel)
                .font(.subheadline)
                .foregroundStyle(Color.hxTextSecondary)
            if let tool = controller?.currentTool {
                Label(tool, systemImage: "wrench.and.screwdriver")
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.hxTextSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What the user is saying, or, once sent, what they said, dimmed.
    private var transcript: some View {
        let live = controller?.partialTranscript ?? ""
        let text = live.isEmpty ? (controller?.lastSentTurn ?? "") : live
        return Text(text)
            .font(.title3)
            .foregroundStyle(live.isEmpty ? Color.hxTextSecondary : Color.primary)
            .multilineTextAlignment(.center)
            .lineLimit(6)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(text)
    }

    private var controls: some View {
        HStack(spacing: 48) {
            let isMuted = controller?.isMuted ?? false
            Button {
                controller?.setMuted(!isMuted)
            } label: {
                Label(isMuted ? LocalizedStringKey("Unmute") : "Mute", systemImage: isMuted ? "mic.slash.fill" : "mic.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel(isMuted ? LocalizedStringKey("Unmute") : "Mute")

            Button {
                if let controller { controller.end() } else { onClose() }
            } label: {
                Label("End", systemImage: "phone.down.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.hxDanger, in: Circle())
            }
            .accessibilityLabel("End")
        }
        .buttonStyle(.plain)
    }

    private var stateLabel: LocalizedStringKey {
        switch controller?.state ?? .idle {
        case .idle, .connecting: "Connecting"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .awaitingApproval: "Waiting for your approval"
        case .reconnecting: "Reconnecting"
        case .ended: "Call ended"
        }
    }

    private var stateSymbol: String {
        switch controller?.state ?? .idle {
        case .idle, .connecting: "phone.connection"
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .awaitingApproval: "hand.raised.fill"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .ended: "phone.down"
        }
    }

    private var stateColor: Color {
        switch controller?.state ?? .idle {
        case .awaitingApproval: .hxWarning
        case .reconnecting, .ended: .hxTextSecondary
        default: .accentColor
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
