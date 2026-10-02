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
    private(set) var state: VoiceCallState = .idle
    private(set) var partialTranscript = ""
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
    @ObservationIgnored private var bargeInRunStart: TimeInterval?
    @ObservationIgnored private var isHeld = false

    // Reply
    @ObservationIgnored private var shaper = SpeechTextShaper()
    /// False once the reply is abandoned (barge-in, hold) or not yet sent.
    @ObservationIgnored private var replyActive = false
    @ObservationIgnored private var replyStarted = false
    @ObservationIgnored private var runSeenStreaming = false
    @ObservationIgnored private var runFinished = false
    @ObservationIgnored private var lastIsStreaming = false
    @ObservationIgnored private var thinkingSince: TimeInterval?
    @ObservationIgnored private var cueOn = false

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
        tickInterval: Duration? = .milliseconds(250)
    ) {
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
        do {
            try await bridge.startCall()
            guard state == .connecting else { return }
            try await listener.start()
            guard state == .connecting else { return }
            state = .listening
            startTicker()
        } catch {
            startError = error as? VoiceCallStartError
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
        switch state {
        case .thinking:
            if !replyStarted, let thinkingSince, time - thinkingSince >= VoiceCallTiming.thinkingCueDelay,
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
        guard isHearing, !discardFinals else { return }
        partial = text
        publishTranscript()
        decideApprovalIfReady()
    }

    private func handleFinal(_ text: String) {
        guard isHearing, !discardFinals else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { finals.append(trimmed) }
        partial = ""
        publishTranscript()
        decideApprovalIfReady()
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
        case .awaitingApproval:
            if approvalListenStart != nil {
                observeTurn(isSpeech, at: time)
            } else if sustainedVoice(isSpeech, at: time) != nil {
                // Talking over the read-back answers it.
                speaker.stopNow()
                beginApprovalListening(speechFrom: bargeInRunStart ?? time, to: time)
            }
        case .speaking:
            if let start = sustainedVoice(isSpeech, at: time) {
                bargeIn(speechFrom: start, to: time)
            }
        default:
            bargeInRunStart = nil
        }
    }

    /// The start of a voice run once it has lasted long enough to be the user, not echo.
    private func sustainedVoice(_ isSpeech: Bool, at time: TimeInterval) -> TimeInterval? {
        guard isSpeech else {
            bargeInRunStart = nil
            return nil
        }
        let start = bargeInRunStart ?? time
        bargeInRunStart = start
        guard time - start >= VoiceCallTiming.bargeInSpeech - 0.0001 else { return nil }
        bargeInRunStart = nil
        return start
    }

    private func observeTurn(_ isSpeech: Bool, at time: TimeInterval) {
        switch turnDetector.observe(isSpeech: isSpeech, at: time) {
        case .speechStarted:
            discardFinals = false
        case .endOfTurn:
            if case .awaitingApproval = state {
                approvalTurnEnded = true
                decideApprovalIfReady()
            } else {
                submitTurn()
            }
        case nil:
            break
        }
    }

    /// Keeps the speech that interrupted, as the start of the next turn.
    private func restartTurn(speechFrom start: TimeInterval, to time: TimeInterval) {
        turnDetector.reset()
        _ = turnDetector.observe(isSpeech: true, at: start)
        _ = turnDetector.observe(isSpeech: true, at: time)
        discardFinals = false
        clearTranscript()
    }

    // MARK: - Turns

    private func submitTurn() {
        guard state == .listening else { return }
        let text = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state = .thinking
        discardFinals = true
        clearTranscript()
        shaper = SpeechTextShaper()
        replyActive = true
        replyStarted = false
        runSeenStreaming = false
        runFinished = false
        thinkingSince = now()
        lastChatTask = Task { [weak self, chat] in
            let sent = await chat.sendVoiceMessage(VoiceCallPhrases.voicePrefix + text)
            guard !sent, let self, self.replyActive, self.state == .thinking else { return }
            self.replyActive = false
            self.setCue(false)
            self.speaker.enqueue(VoiceCallPhrases.sendFailed)
            self.state = .speaking
            self.runFinished = true
        }
    }

    private func bargeIn(speechFrom start: TimeInterval, to time: TimeInterval) {
        speaker.stopNow()
        if replyActive, lastIsStreaming, !runFinished {
            lastChatTask = Task { [chat] in _ = await chat.cancelActiveStream() }
        }
        replyActive = false
        state = .listening
        restartTurn(speechFrom: start, to: time)
    }

    private func returnToListening() {
        state = .listening
        turnDetector.reset()
        clearTranscript()
        discardFinals = true
        bargeInRunStart = nil
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
        if self.currentTool != currentTool { self.currentTool = currentTool }
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
                speaker.enqueue(VoiceCallPhrases.reconnecting)
            }
            return
        }
        if state == .reconnecting {
            reconnectSince = nil
            state = replyStarted ? .speaking : .thinking
        }

        guard replyActive, !isHeld, pendingApproval == nil else { return }
        if let streamingText, !streamingText.isEmpty {
            speak(shaper.append(streamingText))
            if !replyStarted {
                replyStarted = true
                setCue(false)
                state = .speaking
            }
        }
        if runSeenStreaming, !isStreaming, !runFinished {
            runFinished = true
            speak(shaper.finish())
            if !speaker.isSpeaking { finishReply() }
        }
    }

    private func speak(_ sentences: [String]) {
        for sentence in sentences { speaker.enqueue(sentence) }
    }

    private func finishReply() {
        replyActive = false
        setCue(false)
        returnToListening()
    }

    private func handleSpeakerFinished() {
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
            beginApprovalListening(speechFrom: nil, to: now())
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
        speaker.enqueue(VoiceCallPhrases.approvalReadBack(action))
    }

    private func beginApprovalListening(speechFrom start: TimeInterval?, to time: TimeInterval) {
        approvalListenStart = time
        approvalTurnEnded = false
        if let start {
            restartTurn(speechFrom: start, to: time)
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
        speaker.enqueue(choice == .once ? VoiceCallPhrases.approved : VoiceCallPhrases.denied)
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
            bargeInRunStart = nil
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
