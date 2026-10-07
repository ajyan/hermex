import Foundation
import Observation
import UIKit

enum VoiceCallState: Equatable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case awaitingApproval(String)
    case reconnecting
    case ended(String?)
}

/// Spoken lines. English only: recognition and the approve phrases are English.
enum VoiceCallPhrases {
    static let voicePrefix = "[voice] "
    static let reconnecting = "Lost connection, reconnecting."
    static let connectionLost = "Call ended, connection lost"
    static let sendFailed = "I couldn't reach Atlas."
    static let approved = "Approved."
    static let denied = "Denied."
    static let didntCatch = "I didn't catch that."

    /// `text` without a call's leading `[voice] ` tag, for display.
    static func withoutVoiceTag(_ text: String) -> String {
        if text == voicePrefix.trimmingCharacters(in: .whitespaces) { return "" }
        guard text.hasPrefix(voicePrefix) else { return text }
        return String(text.dropFirst(voicePrefix.count))
    }

    static func approvalReadBack(_ action: String) -> String {
        "Atlas wants to \(action). Say approve, or deny."
    }
}

/// One voice call's state machine and the sole owner of its lifetime. The chat
/// it drives owns the stream; the view pushes stream state in through
/// `chatDidUpdate`, so reconnect and replay stay in `ChatStreamCoordinator`.
@MainActor
@Observable
final class VoiceCallController {
    private(set) var state: VoiceCallState = .idle {
        didSet {
            guard state != oldValue else { return }
            log("state \(oldValue) -> \(state)")
            if state == .listening { listeningSince = now() }
        }
    }
    private(set) var partialTranscript = ""
    /// What the user last said, kept on screen until their next words are recognized.
    private(set) var lastSentTurn: String?
    private(set) var currentTool: String?
    private(set) var isMuted = false
    private(set) var startError: VoiceCallStartError?
    /// True once the system call is gone: the call screen can close.
    private(set) var isFinished = false

    @ObservationIgnored private let listener: SpeechListening
    @ObservationIgnored private let speaker: SpeechSpeaking
    @ObservationIgnored private let chat: VoiceCallChatDriving
    @ObservationIgnored private let bridge: CallSystemBridging
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let suppressThinkingCue: @MainActor () -> Bool
    @ObservationIgnored private let tickInterval: Duration?
    /// Diagnostics sink (Debug builds write it to a file on the device).
    @ObservationIgnored private let log: (String) -> Void

    /// The latest chat call (send, cancel, respond) and listener restart; tests await them.
    @ObservationIgnored private(set) var lastChatTask: Task<Void, Never>?
    @ObservationIgnored private(set) var lastListenerTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    // Listening
    @ObservationIgnored private var turnDetector = TurnDetector()
    @ObservationIgnored private var finals: [String] = []
    @ObservationIgnored private var partial = ""
    /// Finals that arrive after a turn was sent (or while Atlas talks) belong to
    /// speech already handled; drop them until the next speech starts.
    @ObservationIgnored private var discardFinals = false
    /// Words Atlas has said this reply; hearing them back is echo, not the user.
    @ObservationIgnored private var spokenWords: Set<String> = []
    /// A turn has ended with only a partial transcript; waiting briefly for the final one.
    @ObservationIgnored private var awaitingFinalSince: TimeInterval?
    @ObservationIgnored private var isHeld = false
    /// When the current turn's first speech was heard, so the log can show how long it took to send.
    @ObservationIgnored private var turnStartedAt: TimeInterval?
    /// When the transcript last changed, for ending a turn the level meter never heard.
    @ObservationIgnored private var transcriptChangedAt: TimeInterval?
    /// When `listening` began, for the no-speech prompt.
    @ObservationIgnored private var listeningSince: TimeInterval?

    // Reply
    @ObservationIgnored private var shaper = SpeechTextShaper()
    /// False once the reply is abandoned (barge-in, hold) or not yet sent.
    @ObservationIgnored private var replyActive = false
    @ObservationIgnored private var replyStarted = false
    @ObservationIgnored private var runSeenStreaming = false
    @ObservationIgnored private var runFinished = false
    @ObservationIgnored private var runFinishedAt: TimeInterval?
    @ObservationIgnored private var lastIsStreaming = false
    @ObservationIgnored private var thinkingSince: TimeInterval?
    @ObservationIgnored private var cueOn = false
    /// When the current turn was sent, so the log can time the reply against it.
    @ObservationIgnored private var sentAt: TimeInterval?
    /// When `tick` last ran; a long gap means the main thread stalled.
    @ObservationIgnored private var lastTickAt: TimeInterval?

    // Approval
    @ObservationIgnored private var pendingApproval: ApprovalPromptState?
    @ObservationIgnored private var handledApprovalIDs: Set<String> = []
    @ObservationIgnored private var approvalListenStart: TimeInterval?
    @ObservationIgnored private var approvalTurnEnded = false

    // Reconnect
    @ObservationIgnored private var reconnectSince: TimeInterval?

    init(
        listener: SpeechListening,
        speaker: SpeechSpeaking,
        chat: VoiceCallChatDriving,
        bridge: CallSystemBridging,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        suppressThinkingCue: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled },
        tickInterval: Duration? = .milliseconds(250),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.log = log
        self.listener = listener
        self.speaker = speaker
        self.chat = chat
        self.bridge = bridge
        self.now = now
        self.suppressThinkingCue = suppressThinkingCue
        self.tickInterval = tickInterval

        listener.onPartial = { [weak self] in self?.handlePartial($0) }
        listener.onFinal = { [weak self] in self?.handleFinal($0) }
        listener.onVoiceActivity = { [weak self] in self?.handleVoiceActivity($0, at: $1) }
        speaker.onFinishedQueue = { [weak self] in self?.handleSpeakerFinished() }
        bridge.onEnded = { [weak self] in self?.tearDown(endSystemCall: false, message: nil) }
        bridge.onMuteChanged = { [weak self] in self?.handleMuteChanged($0) }
        bridge.onHoldChanged = { [weak self] in self?.handleHoldChanged($0) }
    }

    // MARK: - Lifetime

    func start() async {
        guard state == .idle else { return }
        state = .connecting
        connectingSince = now()
        startTicker()
        do {
            try await bridge.startCall()
            log("system call connected \(since(connectingSince))")
            guard state == .connecting else { return }
            try await listener.start()
            log("listener started \(since(connectingSince))")
            guard state == .connecting else { return }
            state = .listening
        } catch {
            log("start failed: \(error)")
            if startError == nil { startError = error as? VoiceCallStartError }
            tearDown(endSystemCall: true, message: nil)
        }
    }

    /// Ends the call. A run still streaming is left to finish on the server.
    func end() {
        tearDown(endSystemCall: true, message: nil)
    }

    func setMuted(_ muted: Bool) {
        bridge.setMuted(muted)
    }

    enum TapAction: Equatable {
        /// Send what the user has said without waiting for the pause.
        case send
        /// Cut Atlas off and listen, as talking over it would.
        case interrupt
    }

    /// What tapping the call visual does right now, if anything.
    var tapAction: TapAction? {
        guard !isHeld else { return nil }
        switch state {
        case .listening where !partialTranscript.isEmpty: return .send
        case .speaking: return .interrupt
        default: return nil
        }
    }

    func performTapAction() {
        switch tapAction {
        case .send:
            log("tap: send")
            submitTurn()
        case .interrupt:
            log("tap: interrupt")
            speaker.stopNow()
            if replyActive, lastIsStreaming, !runFinished {
                lastChatTask = Task { [chat] in _ = await chat.cancelActiveStream() }
            }
            replyActive = false
            setCue(false)
            returnToListening()
        case nil:
            break
        }
    }

    private var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    private func tearDown(endSystemCall: Bool, message: String?) {
        guard !isEnded else { return }
        state = .ended(message)
        ticker?.cancel()
        ticker = nil
        listener.stop()
        setCue(false)
        replyActive = false
        partialTranscript = ""
        if let message {
            // Say why, then hang up once it has been said.
            speaker.stopNow()
            speaker.enqueue(message + ".")
            pendingSystemEnd = endSystemCall
            isFinished = !endSystemCall
        } else {
            speaker.stopNow()
            if endSystemCall { bridge.endCall() }
            isFinished = true
        }
    }

    @ObservationIgnored private var pendingSystemEnd = false
    @ObservationIgnored private var connectingSince: TimeInterval?

    private func startTicker() {
        guard let tickInterval else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// Time-based transitions: the thinking cue, the approval timeout, and giving up on a reconnect.
    func tick() {
        let time = now()
        // Only the live ticker's gaps mean anything; tests drive `tick` by hand.
        if tickInterval != nil, let lastTickAt, time - lastTickAt > 0.75 {
            log(String(format: "main thread stalled: %.2fs between ticks", time - lastTickAt))
        }
        lastTickAt = time
        switch state {
        case .listening:
            if let awaitingFinalSince, time - awaitingFinalSince >= VoiceCallTiming.finalTranscriptWait {
                log("final transcript never came; sending the partial")
                submitTurn()
            } else if !isMuted, !isHeld {
                if awaitingFinalSince == nil, partial.isEmpty, !finals.isEmpty, let transcriptChangedAt,
                   time - transcriptChangedAt >= VoiceCallTiming.finalTranscriptSettle {
                    log("turn ended by settled final transcript")
                    submitTurn()
                } else if awaitingFinalSince == nil, !turnDetector.isInTurn, !partialTranscript.isEmpty,
                   let transcriptChangedAt, time - transcriptChangedAt >= VoiceCallTiming.transcriptStallEnd {
                    log("turn ended by transcript stall")
                    submitTurn()
                } else if partialTranscript.isEmpty, let listeningSince,
                          time - listeningSince >= VoiceCallTiming.noSpeechTimeout {
                    announceNoSpeech()
                }
            }
        case .connecting:
            if let connectingSince, time - connectingSince >= VoiceCallTiming.connectTimeout {
                startError = .callDidNotConnect
                tearDown(endSystemCall: true, message: nil)
            }
        case .thinking:
            if runFinished, !replyStarted, let runFinishedAt, time - runFinishedAt >= VoiceCallTiming.noReplyTextGrace {
                log("run finished with no reply text; giving up")
                finishReply()
            } else if !replyStarted, let thinkingSince, time - thinkingSince >= VoiceCallTiming.thinkingCueDelay,
               !suppressThinkingCue() {
                setCue(true)
            }
        case .awaitingApproval:
            if let approvalListenStart, time - approvalListenStart >= VoiceCallTiming.approvalListenTimeout {
                respondToApproval(.deny)
            }
        case .reconnecting:
            if let reconnectSince, time - reconnectSince >= VoiceCallTiming.reconnectGiveUp {
                tearDown(endSystemCall: true, message: VoiceCallPhrases.connectionLost)
            }
        default:
            break
        }
    }

    // MARK: - Listener

    private func handlePartial(_ text: String) {
        if checkTalkOver(text) { return }
        guard isHearing, !discardFinals else { return }
        if partialTranscript.isEmpty {
            let afterSpeech = turnStartedAt.map { String(format: " (%.2fs after speech started)", now() - $0) } ?? ""
            log("first words: \"\(text)\"\(afterSpeech)")
        }
        partial = text
        transcriptChangedAt = now()
        publishTranscript()
        if !partialTranscript.isEmpty { lastSentTurn = nil }
        decideApprovalIfReady()
    }

    private func handleFinal(_ text: String) {
        if checkTalkOver(text) { return }
        guard isHearing, !discardFinals else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        log("final: \"\(trimmed)\"\(awaitingFinalSince.map { String(format: " (%.2fs after end of turn)", now() - $0) } ?? "")")
        if !trimmed.isEmpty { finals.append(trimmed) }
        partial = ""
        transcriptChangedAt = now()
        publishTranscript()
        if !partialTranscript.isEmpty { lastSentTurn = nil }
        decideApprovalIfReady()
        if state == .listening, awaitingFinalSince != nil { submitTurn() }
    }

    /// While Atlas talks, the mic also hears Atlas. Only words Atlas isn't saying
    /// (enough of them, or "stop"/"wait") mean the user is talking over it.
    /// Returns true when `heard` was consumed as talk-over (or echo).
    private func checkTalkOver(_ heard: String) -> Bool {
        guard !isMuted, !isHeld else { return false }
        let isReadBack: Bool
        switch state {
        case .speaking: isReadBack = false
        case .awaitingApproval where approvalListenStart == nil: isReadBack = true
        default: return false
        }
        let novel = Self.words(in: heard).filter { !spokenWords.contains($0) }
        guard novel.count >= VoiceCallTiming.bargeInNovelWords || novel.contains(where: Self.stopWords.contains) else {
            log("echo ignored: \"\(heard)\"")
            return true
        }
        log("talk-over: \"\(heard)\" novel=\(novel)")
        speaker.stopNow()
        if isReadBack {
            beginApprovalListening(seed: heard)
        } else {
            bargeIn(seed: heard)
        }
        return true
    }

    private static let stopWords: Set<String> = ["stop", "wait"]

    static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// True when speech is turned into a turn: listening, or answering an approval.
    private var isHearing: Bool {
        guard !isMuted, !isHeld else { return false }
        switch state {
        case .listening: return true
        case .awaitingApproval: return approvalListenStart != nil
        default: return false
        }
    }

    private func publishTranscript() {
        let text = (finals + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
        if partialTranscript != text { partialTranscript = text }
    }

    private func clearTranscript() {
        finals = []
        partial = ""
        publishTranscript()
    }

    private func handleVoiceActivity(_ isSpeech: Bool, at time: TimeInterval) {
        guard !isMuted, !isHeld else { return }
        switch state {
        case .listening:
            observeTurn(isSpeech, at: time)
        case .awaitingApproval where approvalListenStart != nil:
            observeTurn(isSpeech, at: time)
        default:
            break
        }
    }

    private func observeTurn(_ isSpeech: Bool, at time: TimeInterval) {
        switch turnDetector.observe(isSpeech: isSpeech, at: time) {
        case .speechStarted:
            turnStartedAt = time
            log("turn started")
            discardFinals = false
            awaitingFinalSince = nil
        case .endOfTurn:
            if case .awaitingApproval = state {
                approvalTurnEnded = true
                decideApprovalIfReady()
            } else if partial.isEmpty {
                log("end of turn (silence)")
                submitTurn()
            } else {
                // The recognizer is still finishing the last words; give it a moment.
                log("end of turn (silence); finalizing transcript")
                awaitingFinalSince = time
                listener.endTurn()
            }
        case nil:
            break
        }
    }

    /// Starts a turn already in progress, keeping the words that interrupted.
    private func restartTurn(seed: String) {
        lastSentTurn = nil
        awaitingFinalSince = nil
        let time = now()
        turnDetector.reset()
        _ = turnDetector.observe(isSpeech: true, at: time - VoiceCallTiming.minimumTurnSpeech)
        _ = turnDetector.observe(isSpeech: true, at: time)
        discardFinals = false
        finals = []
        partial = seed
        publishTranscript()
    }

    // MARK: - Turns

    private func submitTurn() {
        guard state == .listening else { return }
        awaitingFinalSince = nil
        let text = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state = .thinking
        spokenWords = []
        lastSentTurn = text
        discardFinals = true
        clearTranscript()
        shaper = SpeechTextShaper()
        replyActive = true
        replyStarted = false
        runSeenStreaming = false
        runFinished = false
        runFinishedAt = nil
        thinkingSince = now()
        let spokenFor = turnStartedAt.map { String(format: " (turn started %.1fs ago)", now() - $0) } ?? ""
        turnStartedAt = nil
        sentAt = now()
        log("send: \"\(text)\"\(spokenFor)")
        lastChatTask = Task { [weak self, chat] in
            let sent = await chat.sendVoiceMessage(VoiceCallPhrases.voicePrefix + text)
            self?.log("send \(sent ? "accepted" : "FAILED") \(self?.since(self?.sentAt) ?? "")")
            guard !sent, let self, self.replyActive, self.state == .thinking else { return }
            self.replyActive = false
            self.setCue(false)
            self.say(VoiceCallPhrases.sendFailed)
            self.state = .speaking
            self.runFinished = true
        }
    }

    /// Nothing was heard for a while: say so instead of sitting silent.
    private func announceNoSpeech() {
        log("no speech heard; prompting")
        listeningSince = nil
        spokenWords = []
        replyActive = false
        runFinished = true
        state = .speaking
        say(VoiceCallPhrases.didntCatch)
    }

    private func bargeIn(seed: String) {
        if replyActive, lastIsStreaming, !runFinished {
            lastChatTask = Task { [chat] in _ = await chat.cancelActiveStream() }
        }
        replyActive = false
        state = .listening
        restartTurn(seed: seed)
    }

    private func returnToListening() {
        state = .listening
        turnDetector.reset()
        clearTranscript()
        discardFinals = true
        awaitingFinalSince = nil
    }

    private func setCue(_ on: Bool) {
        guard cueOn != on else { return }
        cueOn = on
        speaker.setThinkingCue(on)
    }

    // MARK: - Chat

    func chatDidUpdate(
        streamingText: String?,
        isStreaming: Bool,
        approval: ApprovalPromptState?,
        isReconnecting: Bool,
        currentTool: String?
    ) {
        guard !isEnded, state != .idle, state != .connecting else { return }
        if self.currentTool != currentTool {
            if let currentTool { log("tool: \(currentTool) \(since(sentAt))") }
            self.currentTool = currentTool
        }
        if isStreaming != lastIsStreaming {
            log("stream \(isStreaming ? "open" : "closed") \(since(sentAt))")
        }
        lastIsStreaming = isStreaming
        if isStreaming { runSeenStreaming = true }

        if let approval {
            if pendingApproval == nil, !handledApprovalIDs.contains(approval.id) {
                beginApproval(approval)
            }
        } else if pendingApproval != nil {
            withdrawApproval()
        }

        if isReconnecting {
            if state != .reconnecting, replyActive, pendingApproval == nil {
                state = .reconnecting
                reconnectSince = now()
                say(VoiceCallPhrases.reconnecting)
            }
            return
        }
        if state == .reconnecting {
            reconnectSince = nil
            state = replyStarted ? .speaking : .thinking
        }

        guard replyActive, !isHeld, pendingApproval == nil else { return }
        if let streamingText, !streamingText.isEmpty {
            speak(shaper.append(streamingText, final: runFinished))
            if !replyStarted {
                log("first reply text \(since(sentAt))")
                replyStarted = true
                setCue(false)
                state = .speaking
            }
        }
        if runSeenStreaming, !isStreaming, !runFinished {
            log("run finished \(since(sentAt)); text=\"\(streamingText ?? "nil")\"")
            runFinished = true
            runFinishedAt = now()
            speak(shaper.finish())
        }
        // With no text yet, the reply may still land (the transcript refresh
        // after the run); `tick` gives up after a grace period.
        if runFinished, replyStarted, !speaker.isSpeaking { finishReply() }
    }

    /// "after 1.23s" since `start`, for the log.
    private func since(_ start: TimeInterval?) -> String {
        start.map { String(format: "after %.2fs", now() - $0) } ?? ""
    }

    private func speak(_ sentences: [String]) {
        for sentence in sentences { say(sentence) }
    }

    /// Everything the call speaks goes through here, so its words are known as echo.
    private func say(_ sentence: String) {
        log("say: \"\(sentence)\"")
        spokenWords.formUnion(Self.words(in: sentence))
        speaker.enqueue(sentence)
    }

    private func finishReply() {
        replyActive = false
        setCue(false)
        returnToListening()
    }

    private func handleSpeakerFinished() {
        log("speaker queue finished")
        if isEnded {
            if pendingSystemEnd {
                pendingSystemEnd = false
                bridge.endCall()
                isFinished = true
            }
            return
        }
        switch state {
        case .awaitingApproval where approvalListenStart == nil:
            beginApprovalListening(seed: nil)
        case .speaking where runFinished:
            finishReply()
        default:
            break
        }
    }

    // MARK: - Approval

    private func beginApproval(_ approval: ApprovalPromptState) {
        pendingApproval = approval
        approvalListenStart = nil
        approvalTurnEnded = false
        speaker.stopNow()
        setCue(false)
        let action = approval.pending.description ?? approval.pending.command ?? "run a command"
        state = .awaitingApproval(action)
        say(VoiceCallPhrases.approvalReadBack(action))
    }

    private func beginApprovalListening(seed: String?) {
        approvalListenStart = now()
        approvalTurnEnded = false
        if let seed {
            restartTurn(seed: seed)
        } else {
            turnDetector.reset()
            discardFinals = false
            clearTranscript()
        }
    }

    /// Decides once the turn has ended and every result is final; a pending partial waits.
    private func decideApprovalIfReady() {
        guard case .awaitingApproval = state, approvalTurnEnded, partial.isEmpty else { return }
        let answer = finals.joined(separator: " ")
        respondToApproval(VoiceApprovalMatcher.decide(answer) == .approve ? .once : .deny)
    }

    private func respondToApproval(_ choice: ApprovalChoice) {
        guard let approval = pendingApproval else { return }
        handledApprovalIDs.insert(approval.id)
        lastChatTask = Task { [chat] in _ = await chat.respondToApproval(choice) }
        say(choice == .once ? VoiceCallPhrases.approved : VoiceCallPhrases.denied)
        resumeAfterApproval()
    }

    /// The on-screen card answered first: drop the voice prompt.
    func approvalAnsweredOnScreen() {
        guard pendingApproval != nil else { return }
        speaker.stopNow()
        withdrawApproval()
    }

    private func withdrawApproval() {
        if let approval = pendingApproval { handledApprovalIDs.insert(approval.id) }
        resumeAfterApproval()
    }

    private func resumeAfterApproval() {
        pendingApproval = nil
        approvalListenStart = nil
        approvalTurnEnded = false
        turnDetector.reset()
        clearTranscript()
        discardFinals = true
        if replyActive {
            state = .thinking
            replyStarted = false
            thinkingSince = now()
        } else {
            returnToListening()
        }
    }

    // MARK: - System call controls

    private func handleMuteChanged(_ muted: Bool) {
        guard isMuted != muted, !isEnded else { return }
        isMuted = muted
        if muted {
            listener.stop()
            awaitingFinalSince = nil
            turnDetector.reset()
        } else {
            restartListener()
        }
    }

    private func handleHoldChanged(_ held: Bool) {
        guard isHeld != held, !isEnded else { return }
        isHeld = held
        if held {
            listener.stop()
            speaker.stopNow()
            setCue(false)
            replyActive = false
            pendingApproval = nil
            approvalListenStart = nil
        } else {
            returnToListening()
            if !isMuted { restartListener() }
        }
    }

    private func restartListener() {
        lastListenerTask = Task { [weak self, listener] in
            do {
                try await listener.start()
            } catch {
                self?.tearDown(endSystemCall: true, message: nil)
            }
        }
    }
}
