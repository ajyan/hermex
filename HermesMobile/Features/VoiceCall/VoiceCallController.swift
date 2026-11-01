import Foundation
import Observation

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

/// Why a call ended on its own, when it wasn't the user hanging up. The call screen stays up
/// to say so and offer a reconnect.
enum VoiceCallFailure: Equatable {
    /// The chat's stream dropped and didn't come back.
    case connectionLost
    /// The mic couldn't restart after a mute or hold.
    case microphoneStopped
}

/// Spoken lines. English only: recognition and the approve phrases are English.
enum VoiceCallPhrases {
    static let reconnecting = "Lost connection, reconnecting."
    static let connectionLost = "Call ended, connection lost"
    static let sendFailed = "I couldn't reach Atlas."
    static let approved = "Approved."
    static let denied = "Denied."
    static let hangingUpNoSpeech = "I haven't heard anything, so I'm hanging up"
    static let holdOn = "One moment."
    static let checking = "Let me check."
    static let stillWorking = "Still working on it."

    /// The tag before each spoken turn, carrying the phone's local time (`[voice 2:41 PM] `)
    /// so Atlas can answer "what time is it?" without a tool call.
    static func voicePrefix(at date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        // Plain spaces: the short style can use a narrow no-break space before AM/PM.
        let time = formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        return "[voice \(time)] "
    }

    /// A call's leading tag: `[voice 2:41 PM] `, or the legacy `[voice] ` in older history.
    nonisolated(unsafe) private static let voiceTag = #/^\[voice(?: [^\]]{1,20})?\] ?/#
    private static let voiceTagOpening = "[voice"
    /// The longest time a tag holds, matching `voiceTag`.
    private static let voiceTagTimeLimit = 20

    /// How many characters of `text` its leading call tag takes (with one trailing space),
    /// or nil when it has none. Display matches the app's own lowercase tag; speech also
    /// catches Atlas echoing it in another case.
    static func voiceTagLength(in text: Substring, ignoringCase: Bool = false) -> Int? {
        guard let match = text.prefixMatch(of: voiceTag.ignoresCase(ignoringCase)) else { return nil }
        return text.distance(from: match.range.lowerBound, to: match.range.upperBound)
    }

    /// Whether streaming `text` could still grow into a call tag (`[voi`, `[voice 2:4`).
    static func isPartialVoiceTag(_ text: Substring) -> Bool {
        let lowered = text.lowercased()
        guard lowered.hasPrefix("["), !lowered.contains("]") else { return false }
        if voiceTagOpening.hasPrefix(lowered) { return true }
        return lowered.hasPrefix(voiceTagOpening + " ") && lowered.count <= voiceTagOpening.count + 1 + voiceTagTimeLimit
    }

    /// `text` without a call's leading tag, for display.
    static func withoutVoiceTag(_ text: String) -> String {
        guard let length = voiceTagLength(in: text[...]) else { return text }
        return String(text.dropFirst(length))
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
            if state == .speaking { speakingSince = now() }
        }
    }
    private(set) var partialTranscript = ""
    /// What the user last said, kept on screen until their next words are recognized.
    private(set) var lastSentTurn: String?
    private(set) var currentTool: String?
    /// Milliseconds each sent turn waited for its first reply text, in call order.
    private(set) var turnLatenciesMS: [Int] = []
    private(set) var isMuted = false
    private(set) var startError: VoiceCallStartError?
    /// True once the system call is gone: the call screen can close.
    private(set) var isFinished = false
    /// Set when the call ended on its own; the screen shows it instead of closing.
    private(set) var failure: VoiceCallFailure?
    /// Counts the times the user cut Atlas off (talking over it, saying "stop", or a tap), so the
    /// call screen can answer each at once.
    private(set) var interruptions = 0

    @ObservationIgnored private let listener: SpeechListening
    @ObservationIgnored private let speaker: SpeechSpeaking
    @ObservationIgnored private let chat: VoiceCallChatDriving
    @ObservationIgnored private let bridge: CallSystemBridging
    @ObservationIgnored private let now: () -> TimeInterval
    /// Wall-clock time for the turn tag (`now` is uptime).
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let tickInterval: Duration?
    /// Diagnostics sink (Debug builds write it to a file on the device).
    @ObservationIgnored private let log: (String) -> Void
    /// Sent once as the call's first turn, so the other side speaks first.
    /// The opening turn until it is sent (held calls wait for the unhold).
    @ObservationIgnored private var pendingOpeningTurn: String?

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
    /// Words heard while Atlas worked on this reply (the room, or the user talking to
    /// someone else). The recognizer can deliver them late, once Atlas is already
    /// speaking; they are not the user talking over it.
    @ObservationIgnored private var ambientWords: Set<String> = []
    /// When `speaking` began, for the talk-over grace period.
    @ObservationIgnored private var speakingSince: TimeInterval?
    /// When the user said "wait" to take back a turn: it isn't sent again until they add
    /// to it or `VoiceCallTiming.waitForMore` passes.
    @ObservationIgnored private var waitingForMoreSince: TimeInterval?
    /// The transcript last held back for ending mid-thought, so the log says so once.
    @ObservationIgnored private var heldMidThought: String?
    /// A turn has ended with only a partial transcript; waiting briefly for the final one.
    @ObservationIgnored private var awaitingFinalSince: TimeInterval?
    @ObservationIgnored private var isHeld = false
    /// True from a listener start the call kept until the next stop.
    @ObservationIgnored private var listenerIsOn = false
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
    /// True from a send until the server accepts it. Until then the chat still shows the
    /// previous run (an earlier call's, say), whose text is not this turn's reply.
    @ObservationIgnored private var awaitingSendAcceptance = false
    /// Counts sends, so a slow acceptance can't clear a later turn's wait.
    @ObservationIgnored private var sendCount = 0
    @ObservationIgnored private var replyStarted = false
    /// Seconds into thinking when the next hold-on line is due, and how many were said this turn.
    @ObservationIgnored private var nextHoldOnAt = VoiceCallTiming.holdOnDelay
    @ObservationIgnored private var holdOnLinesSaid = 0
    /// True once this turn's first reply text was timed; an approval pause doesn't add a second sample.
    @ObservationIgnored private var latencyRecorded = false
    @ObservationIgnored private var runSeenStreaming = false
    @ObservationIgnored private var runFinished = false
    @ObservationIgnored private var runFinishedAt: TimeInterval?
    @ObservationIgnored private var lastIsStreaming = false
    @ObservationIgnored private var thinkingSince: TimeInterval?
    @ObservationIgnored private var cueOn = false
    /// When the current turn was sent, so the log can time the reply against it.
    @ObservationIgnored private var sentAt: TimeInterval?
    /// When the level meter first heard speech after the current turn was sent.
    @ObservationIgnored private var speechAfterSendAt: TimeInterval?
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
        openingTurn: String? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        clock: @escaping () -> Date = Date.init,
        tickInterval: Duration? = .milliseconds(250),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.log = log
        self.pendingOpeningTurn = openingTurn
        self.listener = listener
        self.speaker = speaker
        self.chat = chat
        self.bridge = bridge
        self.now = now
        self.clock = clock
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
        let startedAt = now()
        connectingSince = startedAt
        startTicker()
        do {
            try await bridge.startCall()
            log("system call connected \(since(startedAt))")
            guard state == .connecting else { return }
            // The connect timeout is for the system call; the listener's permission
            // prompts and speech download wait on the user, who can still end the call.
            connectingSince = nil
            try await listener.start()
            log("listener started \(since(startedAt))")
            listenerDidStart()
            guard state == .connecting else { return }
            state = .listening
            sendOpeningTurnIfReady()
        } catch {
            log("start failed: \(error)")
            if startError == nil { startError = error as? VoiceCallStartError }
            tearDown(endSystemCall: true, message: nil)
        }
    }

    /// Ends the call. A run still streaming is left to finish on the server. While the call
    /// is saying why it ended, this cuts that short and ends the system call now.
    func end() {
        if isEnded, pendingSystemEnd {
            pendingSystemEnd = false
            speaker.stopNow()
            bridge.endCall()
            isFinished = true
            return
        }
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
        /// Take back the turn Atlas is working on (misheard, or asked wrong) and listen.
        case cancel
    }

    /// What tapping the call visual does right now, if anything.
    var tapAction: TapAction? {
        guard !isHeld else { return nil }
        switch state {
        case .listening where !partialTranscript.isEmpty: return .send
        case .speaking: return .interrupt
        case .thinking where replyActive: return .cancel
        default: return nil
        }
    }

    func performTapAction() {
        switch tapAction {
        case .send:
            log("tap: send")
            submitTurn(tapped: true)
        case .interrupt:
            log("tap: interrupt")
            interruptions += 1
            speaker.stopNow()
            cancelRunIfStreaming()
            replyActive = false
            setCue(false)
            returnToListening()
        case .cancel:
            log("tap: cancel")
            interruptions += 1
            // The send may not be accepted yet; cancel the run it starts, not nothing.
            cancelPendingRun()
            lastSentTurn = nil
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
        stopListener()
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
                          time - listeningSince >= VoiceCallTiming.silentHangUp {
                    log("no words heard for \(Int(VoiceCallTiming.silentHangUp))s; hanging up")
                    tearDown(endSystemCall: true, message: VoiceCallPhrases.hangingUpNoSpeech)
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
            } else if !replyStarted, !runFinished, replyActive, !isHeld, let thinkingSince {
                let waited = time - thinkingSince
                if waited >= nextHoldOnAt {
                    // A long silence on a call reads as a dropped line; say it's still coming.
                    setCue(false)
                    say(holdOnLinesSaid == 0 ? VoiceCallPhrases.holdOn : VoiceCallPhrases.stillWorking)
                    holdOnLinesSaid += 1
                    nextHoldOnAt = waited + VoiceCallTiming.stillWorkingInterval
                } else if waited >= VoiceCallTiming.thinkingCueDelay, holdOnLinesSaid == 0, !speaker.isSpeaking {
                    // One cue per turn; once a hold-on line has been said, the voice reassures instead.
                    setCue(true)
                }
            }
        case .awaitingApproval:
            if let approvalListenStart, time - approvalListenStart >= VoiceCallTiming.approvalListenTimeout {
                respondToApproval(.deny)
            }
        case .reconnecting:
            if let reconnectSince, time - reconnectSince >= VoiceCallTiming.reconnectGiveUp {
                failure = .connectionLost
                tearDown(endSystemCall: true, message: VoiceCallPhrases.connectionLost)
            }
        default:
            break
        }
    }

    // MARK: - Listener

    private func handlePartial(_ text: String) {
        if checkTalkOver(text) || checkContinuation(text) { return }
        noteAmbient(text)
        guard isHearing, !discardFinals else { return }
        // A "wait" after words already heard is for the call, not part of the turn.
        let text = !finals.isEmpty && Self.command(in: text) != nil ? "" : text
        if partialTranscript.isEmpty {
            let afterSpeech = turnStartedAt.map { String(format: " (%.2fs after speech started)", now() - $0) } ?? ""
            log("first words: \"\(text)\"\(afterSpeech)")
        }
        partial = text
        transcriptChangedAt = now()
        if !text.isEmpty { waitingForMoreSince = nil }
        publishTranscript()
        if !partialTranscript.isEmpty { lastSentTurn = nil }
        decideApprovalIfReady()
    }

    private func handleFinal(_ text: String) {
        if checkTalkOver(text) || checkContinuation(text) { return }
        noteAmbient(text)
        guard isHearing, !discardFinals else { return }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finals.isEmpty, Self.command(in: trimmed) != nil { trimmed = "" }
        log("final: \"\(trimmed)\"\(awaitingFinalSince.map { String(format: " (%.2fs after end of turn)", now() - $0) } ?? "")")
        if !trimmed.isEmpty {
            finals.append(trimmed)
            waitingForMoreSince = nil
        }
        partial = ""
        transcriptChangedAt = now()
        publishTranscript()
        if !partialTranscript.isEmpty { lastSentTurn = nil }
        decideApprovalIfReady()
        if state == .listening, awaitingFinalSince != nil { submitTurn() }
    }

    /// While Atlas talks, the mic also hears Atlas. Only words Atlas isn't saying
    /// (one that isn't a backchannel like "yeah", or "stop"/"wait") mean the user is
    /// talking over it. "Stop" and "wait" only silence Atlas; they are never sent.
    /// Returns true when `heard` was consumed as talk-over (or echo).
    private func checkTalkOver(_ heard: String) -> Bool {
        guard !isMuted, !isHeld else { return false }
        let isReadBack: Bool
        switch state {
        case .speaking: isReadBack = false
        case .awaitingApproval where approvalListenStart == nil: isReadBack = true
        default: return false
        }
        let words = Self.words(in: heard)
        if !isReadBack, let speakingSince, now() - speakingSince < VoiceCallTiming.talkOverGrace {
            log("speech from before the reply ignored: \"\(heard)\"")
            ambientWords.formUnion(words)
            return true
        }
        let novel = words.filter { !spokenWords.contains($0) && !ambientWords.contains($0) }
        let command = Self.command(in: heard)
        let substantive = novel.filter { !Self.backchannelWords.contains($0) }
        // Speech that carries over Atlas's words (echo) or the room's needs a second new word.
        let carriesOver = words.contains { spokenWords.contains($0) || ambientWords.contains($0) }
        let needed = carriesOver ? 2 : VoiceCallTiming.bargeInNovelWords
        guard substantive.count >= needed || novel.count >= 2 || command != nil else {
            log("echo ignored: \"\(heard)\"")
            return true
        }
        log("talk-over: \"\(heard)\" novel=\(novel)")
        speaker.stopNow()
        if !isReadBack { interruptions += 1 }
        if isReadBack {
            beginApprovalListening(seed: heard)
        } else if command != nil {
            log("stopped by voice")
            cancelRunIfStreaming()
            replyActive = false
            returnToListening()
        } else {
            bargeIn(seed: heard)
        }
        return true
    }

    /// While Atlas works on a reply it hasn't started saying, the user may still be
    /// talking: a pause ended their turn too soon. New words cancel the run and reopen
    /// the turn with them; "wait" reopens it as it was, "stop" drops it.
    /// Returns true when `heard` was consumed that way.
    private func checkContinuation(_ heard: String) -> Bool {
        guard state == .thinking, replyActive, !replyStarted, !isMuted, !isHeld,
              let sent = lastSentTurn else { return false }
        let words = Self.words(in: heard)
        let sentWords = Self.words(in: sent)
        // The recognizer finishing the utterance already sent repeats its opening words.
        if !sentWords.isEmpty, words.starts(with: sentWords.prefix(2)) { return false }
        switch Self.command(in: heard) {
        case .stop:
            log("turn dropped by voice: \"\(heard)\"")
            cancelPendingRun()
            lastSentTurn = nil
            returnToListening()
            return true
        case .wait:
            reopenTurn(sent, adding: nil)
            waitingForMoreSince = now()
            return true
        case nil:
            // Only speech that began right after the send is the user still going; later speech is the room.
            guard let speechAfterSendAt, let sentAt,
                  speechAfterSendAt - sentAt <= VoiceCallTiming.continuationWindow else { return false }
            let novel = words.filter { !sentWords.contains($0) && !spokenWords.contains($0) }
            guard novel.count >= VoiceCallTiming.continuationNovelWords else { return false }
            reopenTurn(sent, adding: heard)
            return true
        }
    }

    private func reopenTurn(_ sent: String, adding heard: String?) {
        log("turn reopened: \"\(heard ?? "")\"")
        cancelPendingRun()
        state = .listening
        restartTurn(seed: heard ?? "", keeping: sent)
    }

    /// Takes back the turn Atlas is working on: stops any hold-on line and cancels the
    /// run once the send that starts it has been answered.
    private func cancelPendingRun() {
        speaker.stopNow()
        let send = lastChatTask
        lastChatTask = Task { [chat] in
            await send?.value
            _ = await chat.cancelActiveStream()
        }
        replyActive = false
        setCue(false)
    }

    private func cancelRunIfStreaming() {
        if replyActive, lastIsStreaming, !runFinished {
            lastChatTask = Task { [chat] in _ = await chat.cancelActiveStream() }
        }
    }

    enum VoiceCommand: Equatable {
        /// Stop talking, or drop the turn Atlas is working on.
        case stop
        /// Stop talking, or give the turn just sent back to the user to finish.
        case wait
    }

    /// The command `text` says when it says nothing else ("stop", "okay, wait", "hold on").
    static func command(in text: String) -> VoiceCommand? {
        let phrase = words(in: text).filter { !commandFillers.contains($0) }.joined(separator: " ")
        if stopPhrases.contains(phrase) { return .stop }
        if waitPhrases.contains(phrase) { return .wait }
        return nil
    }

    private static let commandFillers: Set<String> = ["okay", "ok", "um", "uh", "oh", "hey", "atlas", "please"]
    private static let stopPhrases: Set<String> = [
        "stop", "stop stop", "stop it", "stop talking", "cancel", "never mind", "nevermind", "be quiet",
    ]
    private static let waitPhrases: Set<String> = [
        "wait", "wait wait", "hold on", "hang on", "one sec", "one second", "wait a second", "wait a sec",
        "just a second",
    ]
    /// Listening noises that agree rather than take the floor.
    private static let backchannelWords: Set<String> = [
        "yeah", "yep", "yes", "mm", "mhm", "hmm", "uh", "um", "oh", "ok", "okay", "right", "sure", "ah",
        "nice", "cool", "wow", "huh",
    ]

    private func noteAmbient(_ heard: String) {
        guard state == .thinking else { return }
        ambientWords.formUnion(Self.words(in: heard))
    }

    /// Whether `text` stops on a word that needs another after it ("tell me a fact about").
    /// A question mark from the recognizer means the sentence is done ("what's it for?").
    static func endsMidThought(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasSuffix("?"), let last = words(in: trimmed).last else { return false }
        return midThoughtWords.contains(last)
    }

    private static let midThoughtWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "because", "to", "of", "for", "with", "about",
        "from", "at", "into", "than", "my", "your", "our", "their", "um", "uh",
    ]

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
        // The recognizer can open a segment with the last one's punctuation (". What are my goals").
        let text = (finals + [partial])
            .map { $0.drop { $0.isPunctuation || $0.isWhitespace } }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
        case .thinking:
            if isSpeech, speechAfterSendAt == nil { speechAfterSendAt = time }
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

    /// Starts a turn already in progress, keeping the words that interrupted, after
    /// `keeping` (a turn taken back to finish).
    private func restartTurn(seed: String, keeping: String? = nil) {
        lastSentTurn = nil
        awaitingFinalSince = nil
        let time = now()
        turnDetector.reset()
        _ = turnDetector.observe(isSpeech: true, at: time - VoiceCallTiming.minimumTurnSpeech)
        _ = turnDetector.observe(isSpeech: true, at: time)
        discardFinals = false
        finals = keeping.map { [$0] } ?? []
        partial = seed
        transcriptChangedAt = time
        publishTranscript()
    }

    // MARK: - Turns

    /// Sends what has been heard. A pause that ended the turn (`tapped` false) waits a
    /// little longer when the words stop mid-thought; `tick` comes back to it.
    private func submitTurn(tapped: Bool = false) {
        guard state == .listening else { return }
        awaitingFinalSince = nil
        let text = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if Self.command(in: text) != nil {
            // "Stop" or "wait" with nothing else is for the call, not for Atlas.
            log("not sent: \"\(text)\"")
            heldMidThought = nil
            turnStartedAt = nil
            returnToListening()
            return
        }
        if !tapped, let waitingForMoreSince, now() - waitingForMoreSince < VoiceCallTiming.waitForMore {
            return
        }
        waitingForMoreSince = nil
        if !tapped, Self.endsMidThought(text), let transcriptChangedAt,
           now() - transcriptChangedAt < VoiceCallTiming.midThoughtWait {
            if heldMidThought != text {
                heldMidThought = text
                log("turn held: ends mid-thought")
            }
            return
        }
        heldMidThought = nil
        lastSentTurn = text
        let spokenFor = turnStartedAt.map { String(format: " (turn started %.1fs ago)", now() - $0) } ?? ""
        turnStartedAt = nil
        send(text, note: spokenFor)
    }

    /// Sends the opening turn once, the first time the call is listening and not on hold.
    private func sendOpeningTurnIfReady() {
        guard let turn = pendingOpeningTurn, state == .listening, !isHeld else { return }
        pendingOpeningTurn = nil
        log("opening turn")
        send(turn)
    }

    /// Hands `text` to the chat as the next turn and moves the call to `thinking`.
    private func send(_ text: String, note: String = "") {
        state = .thinking
        spokenWords = []
        ambientWords = []
        discardFinals = true
        clearTranscript()
        shaper = SpeechTextShaper()
        replyActive = true
        awaitingSendAcceptance = true
        sendCount += 1
        let turn = sendCount
        replyStarted = false
        latencyRecorded = false
        runSeenStreaming = false
        runFinished = false
        runFinishedAt = nil
        beginThinking()
        holdOnLinesSaid = 0
        sentAt = now()
        speechAfterSendAt = nil
        log("send: \"\(text)\"\(note)")
        // A cancel queued for the turn this one replaces must land first, or it stops this run.
        let previous = lastChatTask
        lastChatTask = Task { [weak self, chat] in
            await previous?.value
            let sent = await chat.sendVoiceMessage(VoiceCallPhrases.voicePrefix(at: clock()) + text)
            self?.log("send \(sent ? "accepted" : "FAILED") \(self?.since(self?.sentAt) ?? "")")
            guard let self, self.sendCount == turn else { return }
            self.awaitingSendAcceptance = false
            // The stream may have opened while the send was in flight.
            if sent, self.lastIsStreaming { self.runSeenStreaming = true }
            guard !sent, self.replyActive, self.state == .thinking else { return }
            self.replyActive = false
            self.setCue(false)
            self.say(VoiceCallPhrases.sendFailed)
            self.state = .speaking
            self.runFinished = true
        }
    }

    private func bargeIn(seed: String) {
        cancelRunIfStreaming()
        replyActive = false
        state = .listening
        restartTurn(seed: seed)
    }

    private func returnToListening() {
        state = .listening
        waitingForMoreSince = nil
        turnDetector.reset()
        clearTranscript()
        discardFinals = true
        awaitingFinalSince = nil
    }

    private func setCue(_ on: Bool) {
        guard cueOn != on else { return }
        cueOn = on
        log("thinking cue \(on ? "on" : "off")")
        speaker.setThinkingCue(on)
    }

    /// Starts (or restarts, after an approval) the wait for reply text.
    private func beginThinking() {
        thinkingSince = now()
        nextHoldOnAt = VoiceCallTiming.holdOnDelay
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
            if let currentTool {
                log("tool: \(currentTool) \(since(sentAt))")
                sayCheckingIfFirstWait()
            }
            self.currentTool = currentTool
        }
        if isStreaming != lastIsStreaming {
            log("stream \(isStreaming ? "open" : "closed") \(since(sentAt))")
        }
        lastIsStreaming = isStreaming
        if isStreaming, !awaitingSendAcceptance { runSeenStreaming = true }

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

        guard replyActive, !awaitingSendAcceptance, !isHeld, pendingApproval == nil else { return }
        if let streamingText, !streamingText.isEmpty {
            speak(shaper.append(streamingText, final: runFinished))
            if !replyStarted {
                log("first reply text \(since(sentAt))")
                if !latencyRecorded, let sentAt {
                    latencyRecorded = true
                    turnLatenciesMS.append(Int((now() - sentAt) * 1000))
                }
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

    /// A lookup means a long wait: say so the moment it starts, as the first hold-on line, instead of
    /// after `holdOnDelay` of silence.
    private func sayCheckingIfFirstWait() {
        guard state == .thinking, replyActive, !replyStarted, !isHeld, holdOnLinesSaid == 0,
              pendingApproval == nil, let thinkingSince else { return }
        setCue(false)
        say(VoiceCallPhrases.checking)
        holdOnLinesSaid = 1
        nextHoldOnAt = now() - thinkingSince + VoiceCallTiming.stillWorkingInterval
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
            beginThinking()
        } else {
            returnToListening()
        }
    }

    // MARK: - System call controls

    private func handleMuteChanged(_ muted: Bool) {
        guard isMuted != muted, !isEnded else { return }
        isMuted = muted
        if muted {
            stopListener()
            awaitingFinalSince = nil
            turnDetector.reset()
        } else if !isHeld {
            // Unmuting on hold only records it; taking the call off hold starts the mic.
            restartListener()
        }
    }

    private func handleHoldChanged(_ held: Bool) {
        guard isHeld != held, !isEnded else { return }
        isHeld = held
        if held {
            stopListener()
            speaker.stopNow()
            setCue(false)
            replyActive = false
            pendingApproval = nil
            approvalListenStart = nil
        } else {
            // While connecting, `start` brings the call up and decides about the mic.
            guard state != .connecting else { return }
            returnToListening()
            if !isMuted { restartListener() }
            sendOpeningTurnIfReady()
        }
    }

    /// The mic is wanted unless the call is over, muted, or on hold.
    private var wantsListener: Bool { !isEnded && !isMuted && !isHeld }

    private func stopListener() {
        listener.stop()
        listenerIsOn = false
    }

    /// A start can outlive the reason for it (End, the system ending the call, mute, hold):
    /// keep the mic only if the call still wants it.
    private func listenerDidStart() {
        if wantsListener {
            listenerIsOn = true
        } else {
            log("listener started after the call stopped wanting it; stopping")
            listener.stop()
        }
    }

    /// Starts the mic after mute or hold. Starts run one at a time and never on a
    /// running listener: a second tap on the audio bus throws.
    private func restartListener() {
        let previous = lastListenerTask
        lastListenerTask = Task { [weak self, listener] in
            await previous?.value
            guard let self, self.wantsListener, !self.listenerIsOn, self.state != .connecting else { return }
            do {
                try await listener.start()
                self.listenerDidStart()
            } catch {
                self.failure = .microphoneStopped
                self.tearDown(endSystemCall: true, message: nil)
            }
        }
    }
}
