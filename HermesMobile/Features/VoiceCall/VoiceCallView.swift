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
    /// The running tool call in plain words, for the call screen.
    var toolActivity: VoiceCallToolActivity?

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
        let runningTool = liveToolCalls.last(where: { !$0.isCompleted })
        return VoiceCallChatSnapshot(
            streamingText: parts.isEmpty ? nil : parts.joined(separator: "\n"),
            isStreaming: activeStreamID != nil,
            approval: approval,
            isReconnecting: recovery == .reconnecting || recovery == .waitingForNetwork,
            currentTool: runningTool?.name,
            toolActivity: runningTool.map(VoiceCallToolActivity.of)
        )
    }

    /// The memories a run has used so far: the server's `context_sources` first, then what
    /// finished tool calls read. Kept out of `make`, which runs on every streamed token; the call
    /// screen reads it only when the run's sources or tool calls change.
    static func sources(context: [ContextSourcesStreamEvent.Source], toolCalls: [ToolCall]) -> [VoiceCallSource] {
        VoiceCallSources.merged(VoiceCallSources.from(context: context), VoiceCallSources.from(toolCalls: toolCalls))
    }
}

/// What a finished call hands back to whoever opened it.
struct VoiceCallSummary: Equatable {
    /// Milliseconds each turn waited for its first reply text. A turn that never
    /// got reply text records no sample.
    let turnMS: [Int]
}

/// The full-screen call with Atlas on one chat. It owns the call controller and
/// feeds it the chat's stream state; closing it leaves the chat on screen.
struct VoiceCallView: View {
    let chat: ChatViewModel
    let openingTurn: String?
    /// The turn times so far, each time a turn is timed (a voice mock saves them as it goes).
    let onTurnTimed: (([Int]) -> Void)?
    let onDismiss: (VoiceCallSummary) -> Void

    @State private var controller: VoiceCallController?
    @State private var startMessage: String?
    /// Turn times from calls before a reconnect; the summary covers every call on this screen.
    @State private var earlierTurnMS: [Int] = []
    /// The opening turn goes out on the first call only, never again after a reconnect.
    @State private var openingTurnSent = false
    /// The close paths overlap (a Close button, then its sheet's dismissal); report once.
    @State private var didReport = false
    @State private var levels = VoiceCallAudioLevels()
    /// When the call first started listening, for the call timer.
    @State private var connectedAt: Date?
    @AppStorage(VoiceCallSettings.usesServerVoiceKey) private var usesServerVoice = false
    /// The cloud's slot in screen coordinates; the full-screen starfield is centered on it.
    @State private var orbSlot: CGRect = .zero
    /// Whether the user has spoken yet and this turn's memories, for the starfield.
    @State private var scene = VoiceCallSceneTracker()
    @Environment(\.openURL) private var openURL

    init(chat: ChatViewModel, openingTurn: String? = nil, onTurnTimed: (([Int]) -> Void)? = nil,
         onDismiss: @escaping (VoiceCallSummary) -> Void) {
        self.chat = chat
        self.openingTurn = openingTurn
        self.onTurnTimed = onTurnTimed
        self.onDismiss = onDismiss
    }

    private var turnMS: [Int] { earlierTurnMS + (controller?.turnLatenciesMS ?? []) }

    /// Closes the screen, reporting how long each turn took to answer.
    private func onClose() {
        guard !didReport else { return }
        didReport = true
        // A call still saying why it ended hangs up now.
        controller?.end()
        onDismiss(VoiceCallSummary(turnMS: turnMS))
    }

    /// Starts a fresh call on the same chat, after a failure or a start that didn't connect.
    private func startOver() {
        controller?.end()
        earlierTurnMS = turnMS
        controller = nil
        connectedAt = nil
        Task { await startCall() }
    }

    var body: some View {
        presentations(callEvents(screen))
    }

    private var screen: some View {
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
    }

    /// Feeds the controller the chat's state and follows the call's lifetime.
    private func callEvents(_ content: some View) -> some View {
        content
            .task { await startCall() }
            .onChange(of: controller?.turnLatenciesMS ?? []) { _, _ in onTurnTimed?(turnMS) }
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
            .onChange(of: chat.liveToolCalls) { _, _ in absorbSources() }
            .onChange(of: chat.liveContextSources) { _, _ in absorbSources() }
            .onChange(of: controller?.partialTranscript ?? "") { _, partial in
                if !scene.heardUser, !partial.isEmpty { scene.heard(partial) }
            }
            .onChange(of: controller?.state) { old, state in
                if let old, let state { scene.stateChanged(from: old, to: state) }
                if state == .listening, connectedAt == nil {
                    connectedAt = .now
                    openingTurnSent = true
                }
            }
            // A call that ended on its own stays up to say why; one the user ended closes.
            .onChange(of: controller?.isFinished) { _, finished in
                if finished == true, controller?.startError == nil, controller?.failure == nil { onClose() }
            }
    }

    /// Feedback for each turn, and the sheet and alert a failed start shows.
    private func presentations(_ content: some View) -> some View {
        content
            .onChange(of: announcement) { _, announcement in
                guard let announcement else { return }
                AccessibilityNotification.Announcement(announcement).post()
            }
            .sensoryFeedback(trigger: controller?.lastSentTurn) { _, sent in
                sent == nil ? nil : .impact(weight: .light)
            }
            // Cutting Atlas off answers in the hand at once.
            .sensoryFeedback(trigger: controller?.interruptions ?? 0) { old, new in
                new > old ? .impact(weight: .light) : nil
            }
            .sheet(isPresented: permissionSheetBinding, onDismiss: { onClose() }) {
                permissionSheet
            }
            .alert(
                startMessage ?? "",
                isPresented: Binding(get: { startMessage != nil }, set: { if !$0 { startMessage = nil } })
            ) {
                Button("Retry") { startOver() }
                Button("Back to chat", role: .cancel) { onClose() }
            }
    }

    private var snapshot: VoiceCallChatSnapshot {
        VoiceCallChatSnapshot.of(chat)
    }

    /// Adds what the running reply has drawn on to this turn's memories.
    private func absorbSources() {
        let found = VoiceCallChatSnapshot.sources(context: chat.liveContextSources, toolCalls: chat.liveToolCalls)
        scene.absorb(found, isStreaming: chat.activeStreamID != nil)
    }

    private func startCall() async {
        guard controller == nil else { return }
        guard !chat.isViewingCachedData else {
            startMessage = String(localized: "Reconnect to the server to send a message.")
            return
        }
        VoiceCallDiagnostics.beginCall()
        let controller = VoiceCallController(
            listener: AppleSpeechListener(
                levels: levels,
                vocabulary: { [client = chat.client] in await client.voiceVocabulary() },
                log: VoiceCallDiagnostics.write
            ),
            speaker: makeSpeaker(),
            chat: chat,
            bridge: CallSystemBridge(),
            openingTurn: openingTurnSent ? nil : openingTurn,
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

    private var scenePhase: VoiceCallScenePhase {
        .base(state: state, heardUser: scene.heardUser, sourceCount: scene.sources.count)
    }

    /// The canvas under the starfield, which says whose turn it is and what Atlas drew on.
    private var background: some View {
        ZStack {
            Color.hxCanvas
            VoiceCallStarfield(
                levels: levels,
                phase: scenePhase,
                sources: scene.sources,
                focus: orbSlot,
                interruptions: controller?.interruptions ?? 0,
                replyStarts: scene.replyStarts
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(verbatim: CallSystemBridge.handle)
                .font(AppFont.headline(weight: .medium))
                .foregroundStyle(Color.hxTextPrimary)
            // The line keeps its height before the call connects, so the cloud never shifts.
            Group {
                if let connectedAt, !isEnded {
                    Text(timerInterval: connectedAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                } else {
                    Text(verbatim: " ").accessibilityHidden(true)
                }
            }
            .font(AppFont.footnote())
            .foregroundStyle(Color.hxTextSecondary)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .combine)
    }

    /// The cloud doubles as the one-tap shortcut: send now, take a turn back, or cut Atlas off.
    /// Under it, whose turn it is.
    private var orb: some View {
        let action = controller?.tapAction
        return VStack(spacing: 16) {
            ZStack {
                Button {
                    controller?.performTapAction()
                } label: {
                    // The starfield itself is drawn full screen behind everything, centered here.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 380, maxHeight: 380)
                        .contentShape(Circle().scale(0.7))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { orbSlot = $0 }
                }
                .buttonStyle(.plain)
                .disabled(action == nil)
                .accessibilityLabel(tapHint ?? "")
                .accessibilityHidden(action == nil)

                // Captions ride over the cloud; taps go through to it. VoiceOver reads them on their own.
                captions
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            }

            VoiceCallStatus(word: stateWord, activity: toolActivity, sources: shownSources, hint: tapHint)
        }
    }

    /// The memories Atlas is answering from, as chips while it speaks.
    private var shownSources: [VoiceCallSource] {
        state == .speaking ? scene.sources : []
    }

    private var tapHint: String? {
        switch controller?.tapAction {
        case .send: String(localized: "Tap to send")
        case .interrupt: String(localized: "Tap to interrupt")
        case .cancel: String(localized: "Tap to cancel")
        case nil: nil
        }
    }

    /// What Atlas is running, while it works on a reply.
    private var toolActivity: VoiceCallToolActivity? {
        guard controller?.currentTool != nil, state == .thinking || state == .speaking else { return nil }
        return snapshot.toolActivity
    }

    private var captions: some View {
        VoiceCallCaptions(
            sent: controller?.lastSentTurn,
            live: controller?.partialTranscript ?? "",
            reply: replyCaption,
            isReplying: [.thinking, .speaking, .reconnecting].contains(state)
        )
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// Atlas's reply to the latest turn, as it would be spoken (no markdown).
    private var replyCaption: String? {
        guard let text = snapshot.streamingText else { return nil }
        let sentences = SpeechTextShaper.sentences(in: text, final: true)
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    @ViewBuilder
    private var controls: some View {
        if let failure = controller?.failure {
            VoiceCallFailurePanel(
                reason: Self.reason(for: failure),
                onReconnect: startOver,
                onBack: onClose
            )
        } else {
            callControls
        }
    }

    private var callControls: some View {
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

    /// Whose turn it is, in one word under the cloud.
    private var stateWord: String {
        switch state {
        case .idle, .connecting: String(localized: "Connecting")
        case .listening: controller?.isMuted == true ? String(localized: "Muted") : String(localized: "Listening")
        case .thinking: String(localized: "Thinking")
        case .speaking: String(localized: "Speaking")
        case .awaitingApproval: String(localized: "Waiting for your approval")
        case .reconnecting: String(localized: "Reconnecting")
        case .ended: controller?.failure == nil ? String(localized: "Call ended") : String(localized: "Call dropped")
        }
    }

    /// What VoiceOver says as the turn changes: the state word, and why a call dropped.
    private var announcement: String? {
        guard controller != nil else { return nil }
        if let failure = controller?.failure {
            return stateWord + ". " + Self.reason(for: failure)
        }
        if state == .speaking, let found = scene.foundAnnouncement {
            return stateWord + ". " + found
        }
        return stateWord
    }

    static func reason(for failure: VoiceCallFailure) -> String {
        switch failure {
        case .connectionLost: String(localized: "Lost the connection to Atlas.")
        case .microphoneStopped: String(localized: "The microphone stopped working.")
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
                .font(AppFont.headline())
                .multilineTextAlignment(.center)
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            Button("Close") { onClose() }
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
