import SwiftUI

/// What a call needs from the chat's stream, read from `ChatViewModel`.
struct VoiceCallChatSnapshot: Equatable {
    var streamingText: String?
    var isStreaming: Bool
    var approval: ApprovalPromptState?
    var isReconnecting: Bool
    var currentTool: String?

    /// `replyMessageID` is the reply this turn streamed into, remembered so its
    /// final text can still be read after the stream ends.
    static func make(
        messages: [ChatMessage],
        streamingMessageID: String?,
        replyMessageID: String?,
        activeStreamID: String?,
        recovery: ActiveStreamRecoveryState,
        approval: ApprovalPromptState?,
        liveToolCalls: [ToolCall]
    ) -> VoiceCallChatSnapshot {
        let textID = streamingMessageID ?? replyMessageID
        let text = textID.flatMap { id in messages.last(where: { $0.id == id })?.content }
        return VoiceCallChatSnapshot(
            streamingText: text,
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
    @State private var replyMessageID: String?
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
            if let id = chat.streamingAssistantMessageID, replyMessageID != id { replyMessageID = id }
            controller?.chatDidUpdate(
                streamingText: snapshot.streamingText,
                isStreaming: snapshot.isStreaming,
                approval: snapshot.approval,
                isReconnecting: snapshot.isReconnecting,
                currentTool: snapshot.currentTool
            )
        }
        .onChange(of: controller?.state) { _, state in
            // A new turn: forget the previous reply so its text is never re-read.
            if state == .thinking, chat.streamingAssistantMessageID == nil { replyMessageID = nil }
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
        VoiceCallChatSnapshot.make(
            messages: chat.messages,
            streamingMessageID: chat.streamingAssistantMessageID,
            replyMessageID: replyMessageID,
            activeStreamID: chat.activeStreamID,
            recovery: chat.activeStreamRecoveryState,
            approval: chat.approvalPrompt,
            liveToolCalls: chat.liveToolCalls
        )
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
            bridge: CallSystemBridge()
        )
        self.controller = controller
        await controller.start()
        if case .recognitionUnavailable(let language) = controller.startError {
            let name = Locale.current.localizedString(forIdentifier: language) ?? language
            startMessage = String(localized: "On-device speech recognition for \(name) isn't installed.")
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

    private var transcript: some View {
        Text(controller?.partialTranscript ?? "")
            .font(.title3)
            .multilineTextAlignment(.center)
            .lineLimit(6)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(controller?.partialTranscript ?? "")
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
