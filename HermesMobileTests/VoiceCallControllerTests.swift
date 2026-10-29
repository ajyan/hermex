import XCTest
@testable import HermesMobile

@MainActor
private final class FakeListener: SpeechListening {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onVoiceActivity: ((Bool, TimeInterval) -> Void)?
    var startCount = 0
    var stopCount = 0
    var startError: Error?
    /// True from a finished start until the next stop: the mic is live.
    private(set) var isRunning = false
    /// Starts that finished on a running listener. The real one installs a second
    /// tap on the input bus, which crashes.
    private(set) var overlappingStarts = 0
    /// When set, each start waits for `releaseStarts()`, like a permission prompt or speech download.
    var holdsStart = false
    private var pendingStarts: [CheckedContinuation<Void, Never>] = []
    /// Yields each time a held start begins waiting.
    let startHeld: AsyncStream<Void>
    private let startHeldContinuation: AsyncStream<Void>.Continuation

    init() {
        (startHeld, startHeldContinuation) = AsyncStream<Void>.makeStream()
    }

    func start() async throws {
        startCount += 1
        if holdsStart {
            await withCheckedContinuation {
                pendingStarts.append($0)
                startHeldContinuation.yield()
            }
        }
        if let startError { throw startError }
        if isRunning { overlappingStarts += 1 }
        isRunning = true
    }

    /// Lets every held start finish, and later starts run straight through, so a start the
    /// controller wrongly queues behind a held one fails its test rather than hanging it.
    func releaseStarts() {
        holdsStart = false
        let starts = pendingStarts
        pendingStarts = []
        starts.forEach { $0.resume() }
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    var endTurnCount = 0
    func endTurn() { endTurnCount += 1 }
}

@MainActor
private final class FakeSpeaker: SpeechSpeaking {
    var onFinishedQueue: (() -> Void)?
    var spoken: [String] = []
    var queue: [String] = []
    var stopCount = 0
    var cueStates: [Bool] = []
    var onEnqueue: (() -> Void)?
    var isSpeaking: Bool { !queue.isEmpty }

    func enqueue(_ sentence: String) {
        spoken.append(sentence)
        queue.append(sentence)
        onEnqueue?()
    }

    func stopNow() {
        stopCount += 1
        queue.removeAll()
    }

    func setThinkingCue(_ on: Bool) { cueStates.append(on) }

    /// Plays out the queue, as the synthesizer would.
    func drain() {
        guard !queue.isEmpty else { return }
        queue.removeAll()
        onFinishedQueue?()
    }
}

@MainActor
private final class FakeChat: VoiceCallChatDriving {
    var sent: [String] = []
    var cancelCount = 0
    var responses: [ApprovalChoice] = []
    var sendResult = true
    /// When set, each send waits for `releaseSend()`, like a slow `chat/start`.
    var holdsSend = false
    private var pendingSend: CheckedContinuation<Void, Never>?

    func sendVoiceMessage(_ text: String) async -> Bool {
        sent.append(text)
        if holdsSend { await withCheckedContinuation { pendingSend = $0 } }
        return sendResult
    }

    func releaseSend() {
        holdsSend = false
        pendingSend?.resume()
        pendingSend = nil
    }

    func cancelActiveStream() async -> Bool {
        cancelCount += 1
        return true
    }

    func respondToApproval(_ choice: ApprovalChoice) async -> Bool {
        responses.append(choice)
        return true
    }
}

@MainActor
private final class FakeBridge: CallSystemBridging {
    var onEnded: (() -> Void)?
    var onMuteChanged: ((Bool) -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    var startCount = 0
    var endCount = 0
    var muteRequests: [Bool] = []
    /// When set, `startCall` waits here, like a call whose audio never activates.
    var pendingStart: CheckedContinuation<Void, Error>?
    var holdsStart = false

    func startCall() async throws {
        startCount += 1
        guard holdsStart else { return }
        try await withCheckedThrowingContinuation { pendingStart = $0 }
    }
    func endCall() { endCount += 1 }
    func setMuted(_ muted: Bool) { muteRequests.append(muted) }
}

@MainActor
final class VoiceCallControllerTests: XCTestCase {
    private var listener: FakeListener!
    private var speaker: FakeSpeaker!
    private var chat: FakeChat!
    private var bridge: FakeBridge!
    private var clock: TimeInterval = 0
    /// The wall clock each turn is tagged with, and that tag.
    private static let callTime = Date(timeIntervalSince1970: 1_791_900_000)
    private let tag = VoiceCallPhrases.voicePrefix(at: VoiceCallControllerTests.callTime)
    private var suppressCue = false
    private var controller: VoiceCallController!
    private var logLines: [String] = []

    override func setUp() async throws {
        logLines = []
        listener = FakeListener()
        speaker = FakeSpeaker()
        chat = FakeChat()
        bridge = FakeBridge()
        clock = 100
        suppressCue = false
        controller = VoiceCallController(
            listener: listener,
            speaker: speaker,
            chat: chat,
            bridge: bridge,
            now: { [unowned self] in clock },
            clock: { Self.callTime },
            suppressThinkingCue: { [unowned self] in suppressCue },
            tickInterval: nil,
            log: { [unowned self] in logLines.append($0) }
        )
    }

    // MARK: - Helpers

    /// Speaks `text` as one turn: voice for `seconds`, a final, then silence until end of turn.
    private func say(_ text: String, seconds: TimeInterval = 0.6) async {
        voice(true, for: seconds)
        listener.onFinal?(text)
        voice(false, for: 0.9)
        await controller.lastChatTask?.value
    }

    /// Voice-activity samples every 100 ms, advancing the clock.
    private func voice(_ isSpeech: Bool, for seconds: TimeInterval) {
        let steps = Int((seconds / 0.1).rounded())
        for _ in 0..<steps {
            listener.onVoiceActivity?(isSpeech, clock)
            clock += 0.1
        }
    }

    private func update(
        text: String? = nil,
        streaming: Bool = true,
        approval: ApprovalPromptState? = nil,
        reconnecting: Bool = false,
        tool: String? = nil
    ) {
        controller.chatDidUpdate(
            streamingText: text, isStreaming: streaming, approval: approval,
            isReconnecting: reconnecting, currentTool: tool
        )
    }

    private func approval(_ id: String = "a1", description: String? = "send email to Sam") -> ApprovalPromptState {
        ApprovalPromptState(
            sessionID: "s1",
            pending: PendingApproval(approvalId: id, command: "himalaya send", description: description),
            pendingCount: 1
        )
    }

    /// Starts a call and gets Atlas mid-reply with "First sentence." queued, past the
    /// talk-over grace, so new speech can interrupt it.
    private func startSpeaking() async {
        await controller.start()
        await say("hello")
        update(text: "First sentence. Second")
        clock += VoiceCallTiming.talkOverGrace
    }

    /// A controller wired to the same fakes, with an opening turn.
    private func makeController(openingTurn: String?, speaksStatusLines: Bool = true) -> VoiceCallController {
        VoiceCallController(
            listener: listener,
            speaker: speaker,
            chat: chat,
            bridge: bridge,
            openingTurn: openingTurn,
            speaksStatusLines: speaksStatusLines,
            now: { [unowned self] in clock },
            clock: { Self.callTime },
            suppressThinkingCue: { [unowned self] in suppressCue },
            tickInterval: nil,
            log: { [unowned self] in logLines.append($0) }
        )
    }

    // MARK: - Tests

    func testAnswerWaitIsMeasuredFromReplyEndToSpeechStart() async {
        await controller.start()
        await say("hello")
        update(text: "Hi Andrew. How")
        update(text: "Hi Andrew. How are you?", streaming: false)
        clock = 10
        speaker.drain()
        XCTAssertEqual(controller.state, .listening)
        clock = 11.4
        await say("good")
        XCTAssertEqual(controller.answerWaitsMS, [1400])

        update(text: "Great. What")
        update(text: "Great. What did you eat?", streaming: false)
        clock = 20
        speaker.drain()
        clock = 20.2
        await say("noodles")
        XCTAssertEqual(controller.answerWaitsMS, [1400, 200])
    }

    func testOpeningTurnHasNoAnswerWait() async {
        await controller.start()
        await say("hello")
        XCTAssertEqual(controller.answerWaitsMS, [])
    }

    func testMandarinCallSaysNoHoldOnLines() async {
        controller = makeController(openingTurn: nil, speaksStatusLines: false)
        await controller.start()
        await say("你好")
        XCTAssertEqual(controller.state, .thinking)
        clock += VoiceCallTiming.holdOnDelay + VoiceCallTiming.stillWorkingInterval
        controller.tick()
        XCTAssertEqual(speaker.spoken, [])
        XCTAssertEqual(controller.state, .thinking)
    }

    func testMandarinCallHangsUpSilentlyWhenNobodySpeaks() async {
        controller = makeController(openingTurn: nil, speaksStatusLines: false)
        await controller.start()
        for _ in 0..<VoiceCallTiming.noSpeechPromptsBeforeHangUp {
            clock += VoiceCallTiming.noSpeechTimeout
            controller.tick()
            XCTAssertEqual(controller.state, .listening)
        }
        clock += VoiceCallTiming.noSpeechTimeout
        controller.tick()
        XCTAssertEqual(speaker.spoken, [])
        XCTAssertTrue(controller.isFinished)
        XCTAssertEqual(bridge.endCount, 1)
    }

    func testLanguageCarriesLocaleVoiceAndLines() {
        XCTAssertEqual(VoiceCallLanguage.mandarin.locale.identifier, "zh-CN")
        XCTAssertEqual(VoiceCallLanguage.english.locale.identifier, "en-US")
        XCTAssertEqual(VoiceCallLanguage.mandarin.serverVoice, "zm_yunxi")
        XCTAssertNil(VoiceCallLanguage.english.serverVoice)
        XCTAssertEqual(VoiceCallLanguage.mandarin.appleVoiceLanguage, "zh-CN")
        XCTAssertFalse(VoiceCallLanguage.mandarin.speaksStatusLines)
        XCTAssertTrue(VoiceCallLanguage.english.speaksStatusLines)
    }

    func testOpeningTurnSentOnceAfterListening() async {
        controller = makeController(openingTurn: "[mock brief] Interview me for the role.")
        listener.holdsStart = true
        let start = Task { await controller.start() }
        for await _ in listener.startHeld { break }
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertTrue(chat.sent.isEmpty)
        listener.releaseStarts()
        await start.value
        await controller.lastChatTask?.value
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(chat.sent, [tag + "[mock brief] Interview me for the role."])
        XCTAssertNil(controller.lastSentTurn)

        // A mute and unmute restarts the listener; the brief is not sent again.
        XCTAssertEqual(listener.startCount, 1)
        bridge.onMuteChanged?(true)
        bridge.onMuteChanged?(false)
        await controller.lastListenerTask?.value
        XCTAssertEqual(listener.startCount, 2)
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent.count, 1)
    }

    func testOpeningTurnWaitsOutAHoldDuringConnecting() async {
        controller = makeController(openingTurn: "[mock brief] go")
        listener.holdsStart = true
        let start = Task { await controller.start() }
        for await _ in listener.startHeld { break }
        bridge.onHoldChanged?(true)
        listener.releaseStarts()
        await start.value
        await controller.lastChatTask?.value
        XCTAssertTrue(chat.sent.isEmpty)
        bridge.onHoldChanged?(false)
        await controller.lastListenerTask?.value
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "[mock brief] go"])
        XCTAssertEqual(controller.state, .thinking)
    }

    func testApprovalPauseDoesNotRecordASecondLatencySample() async {
        controller = makeController(openingTurn: "[mock brief] go")
        clock = 10
        await controller.start()
        await controller.lastChatTask?.value
        clock = 11
        update(text: "First sentence. Second", streaming: true)
        XCTAssertEqual(controller.turnLatenciesMS, [1000])
        update(text: "First sentence. Second", streaming: true, approval: approval())
        XCTAssertEqual(controller.state, .awaitingApproval("send email to Sam"))
        controller.approvalAnsweredOnScreen()
        XCTAssertEqual(controller.state, .thinking)
        clock = 40
        update(text: "First sentence. Second sentence. Third", streaming: true)
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(controller.turnLatenciesMS, [1000])
    }

    func testNoOpeningTurnSendsNothing() async {
        await controller.start()
        await controller.lastChatTask?.value
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(chat.sent.isEmpty)
    }

    func testTurnLatencyRecordedAtFirstReplyText() async {
        controller = makeController(openingTurn: "[mock brief] go")
        clock = 10
        await controller.start()
        await controller.lastChatTask?.value
        XCTAssertTrue(controller.turnLatenciesMS.isEmpty)
        update(text: nil, streaming: true)
        XCTAssertTrue(controller.turnLatenciesMS.isEmpty)
        clock = 12.5
        update(text: "Hello there. Welcome", streaming: true)
        XCTAssertEqual(controller.turnLatenciesMS, [2500])
        // Later text in the same reply does not add another sample.
        clock = 14
        update(text: "Hello there. Welcome in.", streaming: true)
        XCTAssertEqual(controller.turnLatenciesMS, [2500])
    }

    func testFullLoopListenThinkSpeakListen() async {
        await controller.start()
        XCTAssertEqual(bridge.startCount, 1)
        XCTAssertEqual(listener.startCount, 1)
        XCTAssertEqual(controller.state, .listening)

        await say("hello")
        XCTAssertEqual(chat.sent, [tag + "hello"])
        XCTAssertEqual(controller.state, .thinking)

        update(text: "Hi Andrew. It is")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(speaker.spoken, ["Hi Andrew."])

        update(text: "Hi Andrew. It is sunny.", streaming: false)
        XCTAssertEqual(speaker.spoken, ["Hi Andrew.", "It is sunny."])
        XCTAssertEqual(controller.state, .speaking)

        speaker.drain()
        XCTAssertEqual(controller.state, .listening)

        await say("thanks")
        XCTAssertEqual(chat.sent, [tag + "hello", tag + "thanks"])
    }

    func testQuietFirstUtteranceSendsEvenWhenVoiceActivityNeverFires() async {
        await controller.start()
        // The mic level never crosses the speech threshold, but the recognizer hears words.
        listener.onPartial?("what time is it")
        clock += 1.0
        controller.tick()
        XCTAssertEqual(controller.state, .listening)
        clock += 0.5
        controller.tick()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "what time is it"])
        XCTAssertEqual(controller.state, .thinking)
    }

    func testTranscriptStallDoesNotCutOffASpeakerVoiceActivityStillHears() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onPartial?("send a message to")
        clock += 3
        controller.tick()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(chat.sent.isEmpty)
    }

    func testSettledFinalSendsWhileTheLevelMeterStillHearsNoise() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onFinal?("what time is it")
        // Background noise keeps the meter "in a turn", but nothing new is recognized.
        voice(true, for: VoiceCallTiming.finalTranscriptSettle - 0.2)
        controller.tick()
        XCTAssertTrue(chat.sent.isEmpty)
        voice(true, for: 0.3)
        controller.tick()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "what time is it"])
    }

    func testFinalFollowedByMoreSpeechDoesNotSendEarly() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onFinal?("send a message")
        clock += 0.5
        listener.onPartial?("to Sam")
        clock += VoiceCallTiming.finalTranscriptSettle
        controller.tick()
        XCTAssertTrue(chat.sent.isEmpty)
        XCTAssertEqual(controller.partialTranscript, "send a message to Sam")
    }

    func testEndOfTurnWithAPartialAsksTheRecognizerToFinalize() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onPartial?("explain how tailscale works in det")
        voice(false, for: 0.9)
        XCTAssertEqual(listener.endTurnCount, 1)
        XCTAssertTrue(chat.sent.isEmpty)
        listener.onFinal?("Explain how Tailscale works in detail.")
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "Explain how Tailscale works in detail."])
    }

    func testSilentListeningSaysIDidntCatchThatOnceThenRearms() async {
        await controller.start()
        clock += VoiceCallTiming.noSpeechTimeout - 1
        controller.tick()
        XCTAssertTrue(speaker.spoken.isEmpty)
        clock += 1
        controller.tick()
        XCTAssertEqual(speaker.spoken, [VoiceCallPhrases.didntCatch])
        controller.tick()
        XCTAssertEqual(speaker.spoken.count, 1)
        speaker.drain()
        XCTAssertEqual(controller.state, .listening)
        clock += VoiceCallTiming.noSpeechTimeout
        controller.tick()
        XCTAssertEqual(speaker.spoken.count, 2)
    }

    /// Lets one no-speech timeout pass and plays out whatever the call said.
    private func sitSilentThroughNoSpeechTimeout() {
        clock += VoiceCallTiming.noSpeechTimeout
        controller.tick()
        speaker.drain()
    }

    func testForgottenCallHangsUpAfterUnansweredNoSpeechPrompts() async {
        await controller.start()
        for _ in 0..<VoiceCallTiming.noSpeechPromptsBeforeHangUp {
            sitSilentThroughNoSpeechTimeout()
        }
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(bridge.endCount, 0)

        clock += VoiceCallTiming.noSpeechTimeout
        controller.tick()
        XCTAssertEqual(controller.state, .ended(VoiceCallPhrases.hangingUpNoSpeech))
        XCTAssertEqual(speaker.spoken.last, VoiceCallPhrases.hangingUpNoSpeech + ".")
        XCTAssertEqual(listener.stopCount, 1)
        speaker.drain()
        XCTAssertEqual(bridge.endCount, 1)
        XCTAssertTrue(controller.isFinished)
    }

    func testSpeakingResetsTheNoSpeechHangUpCount() async {
        await controller.start()
        for _ in 0..<VoiceCallTiming.noSpeechPromptsBeforeHangUp {
            sitSilentThroughNoSpeechTimeout()
        }
        // A mumble too short to send still counts as someone being there.
        voice(true, for: 0.6)
        listener.onPartial?("um")
        listener.onFinal?("")
        voice(false, for: 0.9)
        XCTAssertTrue(chat.sent.isEmpty)
        // The user spoke, so the next silence prompts again instead of hanging up.
        sitSilentThroughNoSpeechTimeout()
        XCTAssertEqual(speaker.spoken.last, VoiceCallPhrases.didntCatch)
        XCTAssertEqual(bridge.endCount, 0)
    }

    func testReplyCutMidSentenceAtRunEndIsCompletedWhenTheFullTextLands() async {
        await startSpeaking()
        let cut = "An octopus has three hearts, and its blood is blue because it uses copper to carry oxygen instead of"
        update(text: "First sentence. " + cut, streaming: false)
        XCTAssertEqual(speaker.spoken, ["First sentence.", cut])
        // The transcript refresh then delivers the whole message.
        update(text: "First sentence. " + cut + " iron.", streaming: false)
        XCTAssertEqual(speaker.spoken, ["First sentence.", cut, "iron."])
        speaker.drain()
        XCTAssertEqual(controller.state, .listening)
    }

    func testRunEndedBeforeAnyReplyTextWaitsForTheText() async {
        await controller.start()
        await say("hello")
        update(text: nil, streaming: true)
        update(text: nil, streaming: false)
        XCTAssertEqual(controller.state, .thinking)
        update(text: "Your entry is bare. Just the check-in.", streaming: false)
        XCTAssertEqual(speaker.spoken, ["Your entry is bare.", "Just the check-in."])
        XCTAssertEqual(controller.state, .speaking)
        speaker.drain()
        XCTAssertEqual(controller.state, .listening)
    }

    func testRunEndedWithNoReplyTextEventuallyReturnsToListening() async {
        await controller.start()
        await say("hello")
        update(text: nil, streaming: true)
        update(text: nil, streaming: false)
        clock += VoiceCallTiming.noReplyTextGrace - 0.5
        controller.tick()
        XCTAssertEqual(controller.state, .thinking)
        clock += 0.5
        controller.tick()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(speaker.spoken.isEmpty)
    }

    func testLogDistinguishesTurnStartedFromTurnSent() async {
        await controller.start()
        await say("hello", seconds: 1.0)
        let started = logLines.firstIndex { $0 == "turn started" }
        let sent = logLines.firstIndex { $0.hasPrefix("send: \"hello\" (turn started ") }
        XCTAssertNotNil(started)
        XCTAssertNotNil(sent)
        if let started, let sent { XCTAssertLessThan(started, sent) }
    }

    func testPartialTranscriptShownWhileListening() async {
        await controller.start()
        listener.onFinal?("hello")
        listener.onPartial?("there")
        XCTAssertEqual(controller.partialTranscript, "hello there")
    }

    func testSentTurnStaysOnScreenUntilNextWordsAreHeard() async {
        await controller.start()
        await say("hello there")
        XCTAssertEqual(controller.partialTranscript, "")
        XCTAssertEqual(controller.lastSentTurn, "hello there")

        update(text: "Hi.")
        update(text: "Hi.", streaming: false)
        speaker.drain()
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.lastSentTurn, "hello there")

        // Noise the level meter calls speech doesn't clear it; recognized words do.
        voice(true, for: 0.2)
        XCTAssertEqual(controller.lastSentTurn, "hello there")
        listener.onPartial?("and")
        XCTAssertNil(controller.lastSentTurn)
    }

    func testNoSecondSendWhileThinking() async {
        await controller.start()
        await say("hello")
        await say("are you there")
        XCTAssertEqual(chat.sent, [tag + "hello"])
        XCTAssertEqual(controller.state, .thinking)
    }

    func testBargeInStopsSpeakerAndCancelsOnce() async {
        await startSpeaking()
        XCTAssertEqual(controller.state, .speaking)

        voice(true, for: 0.4)
        listener.onPartial?("hold on a")
        await controller.lastChatTask?.value
        XCTAssertEqual(speaker.stopCount, 1)
        XCTAssertEqual(chat.cancelCount, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.partialTranscript, "hold on a")

        // More text from the cancelled run is not spoken, and the new speech is kept.
        update(text: "First sentence. Second sentence. Third.")
        XCTAssertEqual(speaker.spoken, ["First sentence."])
        voice(true, for: 0.3)
        listener.onFinal?("hold on a second")
        voice(false, for: 0.9)
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "hello", tag + "hold on a second"])
        XCTAssertEqual(chat.cancelCount, 1)
    }

    func testTapSendsWhatWasSaidWithoutWaitingForThePause() async {
        await controller.start()
        XCTAssertNil(controller.tapAction)
        voice(true, for: 0.5)
        listener.onPartial?("what's on my calendar")
        XCTAssertEqual(controller.tapAction, .send)

        controller.performTapAction()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "what's on my calendar"])
        XCTAssertEqual(controller.state, .thinking)
        XCTAssertEqual(controller.tapAction, .cancel)
    }

    func testTapInterruptsAtlasAndCancelsTheRunOnce() async {
        await startSpeaking()
        XCTAssertEqual(controller.tapAction, .interrupt)

        controller.performTapAction()
        await controller.lastChatTask?.value
        XCTAssertEqual(speaker.stopCount, 1)
        XCTAssertEqual(chat.cancelCount, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.partialTranscript, "")

        // The abandoned reply isn't spoken, and the next turn sends normally.
        update(text: "First sentence. Second sentence. Third.")
        XCTAssertEqual(speaker.spoken, ["First sentence."])
        await say("never mind")
        XCTAssertEqual(chat.sent, [tag + "hello", tag + "never mind"])
    }

    func testTapInterruptAfterTheRunFinishedDoesNotCancel() async {
        await startSpeaking()
        update(text: "First sentence. Second sentence.", streaming: false)
        controller.performTapAction()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.cancelCount, 0)
        XCTAssertEqual(controller.state, .listening)
    }

    func testEchoOfOwnReplyDoesNotInterrupt() async {
        await startSpeaking()
        voice(true, for: 1.0)
        listener.onPartial?("First sentence")
        listener.onFinal?("first sentence.")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(speaker.stopCount, 0)
        XCTAssertEqual(chat.cancelCount, 0)
    }

    func testStopWordAloneInterrupts() async {
        await startSpeaking()
        voice(true, for: 0.3)
        listener.onPartial?("stop")
        await controller.lastChatTask?.value
        XCTAssertEqual(speaker.stopCount, 1)
        XCTAssertEqual(controller.state, .listening)
    }

    func testTurnWaitsForFinalTranscriptBeforeSending() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onPartial?("Hi, can you rec")
        voice(false, for: 0.9)
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [])
        listener.onFinal?("Hi, can you recall my journal?")
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "Hi, can you recall my journal?"])
    }

    func testTurnSendsPartialWhenFinalNeverComes() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onPartial?("what time is it")
        voice(false, for: 0.9)
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [])
        clock += 0.9
        controller.tick()
        XCTAssertEqual(chat.sent, [])
        clock += 0.2
        controller.tick()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "what time is it"])
    }

    func testSpeakingAgainWhileWaitingForFinalContinuesTheTurn() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onPartial?("Hi, can you")
        voice(false, for: 0.9)
        voice(true, for: 0.5)
        listener.onFinal?("Hi, can you recall my journal?")
        voice(false, for: 0.9)
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "Hi, can you recall my journal?"])
    }

    func testBargeInIgnoredWhileSpeakerEchoBelowThreshold() async {
        await startSpeaking()
        // Sound with no recognized words is never an interruption.
        voice(true, for: 1.0)
        voice(false, for: 0.3)
        voice(true, for: 0.6)
        voice(false, for: 0.3)
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(speaker.stopCount, 0)
        XCTAssertEqual(chat.cancelCount, 0)
    }

    func testApprovalReadBackAndVoiceApprove() async {
        await startSpeaking()
        update(text: "First sentence. Second", approval: approval())
        XCTAssertEqual(controller.state, .awaitingApproval("send email to Sam"))
        XCTAssertEqual(speaker.stopCount, 1)
        XCTAssertEqual(speaker.spoken.last, "Atlas wants to send email to Sam. Say approve, or deny.")

        speaker.drain()
        await say("Approve.")
        XCTAssertEqual(chat.responses, [.once])
        XCTAssertEqual(speaker.spoken.last, "Approved.")
    }

    func testApprovalReadBackFallsBackToCommand() async {
        await startSpeaking()
        update(approval: approval(description: nil))
        XCTAssertEqual(speaker.spoken.last, "Atlas wants to himalaya send. Say approve, or deny.")
    }

    func testApprovalWaitsForFinalBeforeDeciding() async {
        await startSpeaking()
        update(approval: approval())
        speaker.drain()
        voice(true, for: 0.6)
        listener.onPartial?("approve")
        voice(false, for: 0.9)
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.responses, [])
        listener.onFinal?("approve the email")
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.responses, [.deny])
    }

    func testApprovalTimeoutDenies() async {
        await startSpeaking()
        update(approval: approval())
        speaker.drain()
        clock += 7.9
        controller.tick()
        XCTAssertEqual(chat.responses, [])
        clock += 0.2
        controller.tick()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.responses, [.deny])
    }

    func testCardAnswerFirstWithdrawsVoicePrompt() async {
        await startSpeaking()
        update(approval: approval())
        let stopsBefore = speaker.stopCount
        controller.approvalAnsweredOnScreen()
        XCTAssertEqual(speaker.stopCount, stopsBefore + 1)
        XCTAssertNotEqual(controller.state, .awaitingApproval("send email to Sam"))

        // A late spoken "approve" does nothing.
        await say("approve")
        clock += 10
        controller.tick()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.responses, [])
    }

    func testApprovalClearedByChatWithdrawsVoicePrompt() async {
        await startSpeaking()
        update(approval: approval())
        update(approval: nil)
        XCTAssertEqual(controller.state, .thinking)
        clock += 10
        controller.tick()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.responses, [])
    }

    func testApprovalRespondedExactlyOnce() async {
        await startSpeaking()
        update(approval: approval())
        speaker.drain()
        await say("approve")
        update(approval: approval())
        controller.approvalAnsweredOnScreen()
        await say("approve")
        clock += 10
        controller.tick()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.responses, [.once])
    }

    func testReconnectSpeaksOnceAndDoesNotResend() async {
        await startSpeaking()
        update(text: "First sentence. Second", reconnecting: true)
        update(text: "First sentence. Second", reconnecting: true)
        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertEqual(speaker.spoken.filter { $0 == "Lost connection, reconnecting." }.count, 1)

        update(text: "First sentence. Second part.", streaming: false)
        XCTAssertEqual(speaker.spoken.last, "Second part.")
        XCTAssertEqual(chat.sent, [tag + "hello"])
    }

    func testReconnectGivesUpAfter30s() async {
        await startSpeaking()
        update(reconnecting: true)
        clock += 29
        controller.tick()
        XCTAssertEqual(controller.state, .reconnecting)
        clock += 1.5
        controller.tick()
        XCTAssertEqual(controller.state, .ended("Call ended, connection lost"))
        XCTAssertEqual(speaker.spoken.last, "Call ended, connection lost.")
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(controller.isFinished)
        speaker.drain()
        XCTAssertEqual(bridge.endCount, 1)
        XCTAssertTrue(controller.isFinished)
        XCTAssertEqual(chat.cancelCount, 0)
    }

    func testEndWhileStreamingDoesNotCancelRun() async {
        await startSpeaking()
        controller.end()
        await controller.lastChatTask?.value
        XCTAssertEqual(controller.state, .ended(nil))
        XCTAssertEqual(chat.cancelCount, 0)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertEqual(bridge.endCount, 1)
        XCTAssertTrue(controller.isFinished)
        XCTAssertGreaterThanOrEqual(speaker.stopCount, 1)

        // Later chat updates don't revive the call.
        update(text: "First sentence. Second sentence.", streaming: false)
        XCTAssertEqual(speaker.spoken, ["First sentence."])
    }

    func testSystemEndReleasesWithoutEndingAgain() async {
        await startSpeaking()
        bridge.onEnded?()
        XCTAssertEqual(controller.state, .ended(nil))
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertEqual(bridge.endCount, 0)
        XCTAssertEqual(chat.cancelCount, 0)
        XCTAssertTrue(controller.isFinished)
    }

    func testStartFailureEndsWithReason() async {
        listener.startError = VoiceCallStartError.permissionDenied
        await controller.start()
        XCTAssertEqual(controller.startError, .permissionDenied)
        XCTAssertEqual(controller.state, .ended(nil))
        XCTAssertEqual(bridge.endCount, 1)
    }

    func testCallThatNeverConnectsEndsAfterTimeout() async {
        bridge.holdsStart = true
        let starting = Task { await controller.start() }
        while bridge.pendingStart == nil { await Task.yield() }
        XCTAssertEqual(controller.state, .connecting)

        clock += 9.9
        controller.tick()
        XCTAssertEqual(controller.state, .connecting)
        clock += 0.2
        controller.tick()
        XCTAssertEqual(controller.startError, .callDidNotConnect)
        XCTAssertEqual(controller.state, .ended(nil))
        XCTAssertEqual(bridge.endCount, 1)
        XCTAssertEqual(listener.startCount, 0)

        // CallKit then reports the end; start() unwinds without restarting anything.
        bridge.pendingStart?.resume(throwing: CallSystemBridge.BridgeError.ended)
        await starting.value
        XCTAssertEqual(listener.startCount, 0)
        XCTAssertEqual(controller.startError, .callDidNotConnect)
    }

    func testEndWhileTheListenerIsStartingLeavesTheMicOff() async {
        listener.holdsStart = true
        var held = listener.startHeld.makeAsyncIterator()
        let starting = Task { await controller.start() }
        await held.next()
        XCTAssertEqual(controller.state, .connecting)

        controller.end()
        listener.releaseStarts()
        await starting.value
        XCTAssertEqual(controller.state, .ended(nil))
        XCTAssertFalse(listener.isRunning)
    }

    func testSystemEndWhileTheListenerIsStartingLeavesTheMicOff() async {
        listener.holdsStart = true
        var held = listener.startHeld.makeAsyncIterator()
        let starting = Task { await controller.start() }
        await held.next()

        bridge.onEnded?()
        listener.releaseStarts()
        await starting.value
        XCTAssertEqual(controller.state, .ended(nil))
        XCTAssertFalse(listener.isRunning)
    }

    func testPermissionPromptDoesNotCountTowardTheConnectTimeout() async {
        listener.holdsStart = true
        var held = listener.startHeld.makeAsyncIterator()
        let starting = Task { await controller.start() }
        await held.next()

        // The system call connected; the user is still reading the mic prompt.
        clock += 30
        controller.tick()
        XCTAssertEqual(controller.state, .connecting)
        XCTAssertNil(controller.startError)

        listener.releaseStarts()
        await starting.value
        XCTAssertEqual(controller.state, .listening)
        XCTAssertTrue(listener.isRunning)
    }

    func testMuteWhileTheListenerIsStartingStopsItWhenItStarts() async {
        listener.holdsStart = true
        var held = listener.startHeld.makeAsyncIterator()
        let starting = Task { await controller.start() }
        await held.next()

        bridge.onMuteChanged?(true)
        listener.releaseStarts()
        await starting.value
        XCTAssertEqual(controller.state, .listening)
        XCTAssertFalse(listener.isRunning)

        bridge.onMuteChanged?(false)
        await controller.lastListenerTask?.value
        XCTAssertTrue(listener.isRunning)
        XCTAssertEqual(listener.overlappingStarts, 0)
    }

    func testUnmuteOnHoldWaitsForTheCallToComeOffHold() async {
        await startSpeaking()
        bridge.onHoldChanged?(true)
        bridge.onMuteChanged?(true)
        bridge.onMuteChanged?(false)
        await controller.lastListenerTask?.value
        // No mic while the other call has the line.
        XCTAssertFalse(listener.isRunning)

        bridge.onHoldChanged?(false)
        await controller.lastListenerTask?.value
        XCTAssertTrue(listener.isRunning)
        XCTAssertEqual(listener.overlappingStarts, 0)
        XCTAssertEqual(controller.state, .listening)
    }

    func testQuickMuteToggleNeverStartsTheListenerTwice() async {
        await controller.start()
        bridge.onMuteChanged?(true)
        listener.holdsStart = true
        var held = listener.startHeld.makeAsyncIterator()
        bridge.onMuteChanged?(false)
        await held.next()

        // Mute and unmute again while the first restart is still starting.
        bridge.onMuteChanged?(true)
        bridge.onMuteChanged?(false)
        listener.releaseStarts()
        await controller.lastListenerTask?.value
        XCTAssertTrue(listener.isRunning)
        XCTAssertEqual(listener.overlappingStarts, 0)
    }

    func testMuteStopsListeningNotSpeaking() async {
        await startSpeaking()
        controller.setMuted(true)
        XCTAssertEqual(bridge.muteRequests, [true])
        bridge.onMuteChanged?(true)
        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertEqual(speaker.stopCount, 0)

        // Muted voice never barges in.
        voice(true, for: 0.5)
        XCTAssertEqual(controller.state, .speaking)

        bridge.onMuteChanged?(false)
        await controller.lastListenerTask?.value
        XCTAssertFalse(controller.isMuted)
        XCTAssertEqual(listener.startCount, 2)
    }

    func testHoldPausesListeningAndSpeakingAndResumes() async {
        await startSpeaking()
        bridge.onHoldChanged?(true)
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertEqual(speaker.stopCount, 1)
        update(text: "First sentence. Second sentence. Third", streaming: true)
        XCTAssertEqual(speaker.spoken, ["First sentence."])

        bridge.onHoldChanged?(false)
        await controller.lastListenerTask?.value
        XCTAssertEqual(listener.startCount, 2)
        XCTAssertEqual(controller.state, .listening)
    }

    func testThinkingCueStartsAfter1500msWithoutToken() async {
        await controller.start()
        await say("hello")
        clock += 1.3
        controller.tick()
        XCTAssertEqual(speaker.cueStates, [])
        clock += 0.2
        controller.tick()
        XCTAssertEqual(speaker.cueStates, [true])
        controller.tick()
        XCTAssertEqual(speaker.cueStates, [true])
        update(text: "Hi.")
        XCTAssertEqual(speaker.cueStates, [true, false])
    }

    func testThinkingCueSuppressed() async {
        suppressCue = true
        await controller.start()
        await say("hello")
        clock += 2
        controller.tick()
        XCTAssertEqual(speaker.cueStates, [])
    }

    func testCurrentToolShown() async {
        await startSpeaking()
        update(text: "First sentence. Second", tool: "terminal")
        XCTAssertEqual(controller.currentTool, "terminal")
    }

    func testTapTakesBackTheTurnAtlasIsWorkingOn() async {
        await controller.start()
        await say("with similar like you could do demo")
        XCTAssertEqual(controller.tapAction, .cancel)

        controller.performTapAction()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.cancelCount, 1)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertNil(controller.lastSentTurn)

        // The cancelled run's text is never spoken, and the next turn sends normally.
        update(text: "Here is a demo.", streaming: false)
        XCTAssertTrue(speaker.spoken.isEmpty)
        await say("who is my dad")
        XCTAssertEqual(chat.sent.last, tag + "who is my dad")
    }

    func testTapCancelBeforeTheSendIsAcceptedCancelsTheRunItStarts() async {
        await controller.start()
        chat.holdsSend = true
        voice(true, for: 0.6)
        listener.onFinal?("hello")
        voice(false, for: 0.9)
        XCTAssertEqual(controller.state, .thinking)

        controller.performTapAction()
        XCTAssertEqual(chat.cancelCount, 0)
        chat.releaseSend()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.cancelCount, 1)
        XCTAssertEqual(controller.state, .listening)
    }

    func testTextShownBeforeTheSendIsAcceptedIsNotThisTurnsReply() async {
        await controller.start()
        chat.holdsSend = true
        voice(true, for: 0.6)
        listener.onFinal?("who is my dad")
        voice(false, for: 0.9)
        let send = controller.lastChatTask

        // An earlier call's run, still on screen until this turn lands.
        update(text: "No Richard Giant in the CRM.", streaming: true)
        update(text: "No Richard Giant in the CRM.", streaming: false)
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertEqual(controller.state, .thinking)

        chat.releaseSend()
        await send?.value
        update(text: nil, streaming: true)
        update(text: "Your dad is Richard.", streaming: false)
        XCTAssertEqual(speaker.spoken, ["Your dad is Richard."])
    }

    func testLongWaitsAreFilledWithHoldOnLines() async {
        await controller.start()
        await say("what's on my calendar")
        clock += VoiceCallTiming.holdOnDelay - 0.3
        controller.tick()
        XCTAssertTrue(speaker.spoken.isEmpty)
        clock += 0.3
        controller.tick()
        XCTAssertEqual(speaker.spoken, [VoiceCallPhrases.holdOn])
        XCTAssertEqual(speaker.cueStates.last, false)
        // The cue waits while the line plays, then resumes.
        controller.tick()
        XCTAssertEqual(speaker.cueStates.last, false)
        speaker.drain()
        XCTAssertEqual(controller.state, .thinking)
        controller.tick()
        XCTAssertEqual(speaker.cueStates.last, true)

        clock += VoiceCallTiming.stillWorkingInterval + 0.1
        controller.tick()
        XCTAssertEqual(speaker.spoken, [VoiceCallPhrases.holdOn, VoiceCallPhrases.stillWorking])

        update(text: "You have two meetings. One")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(speaker.spoken.last, "You have two meetings.")
    }

    func testQuickRepliesGetNoHoldOnLine() async {
        await controller.start()
        await say("what time is it")
        clock += 3
        controller.tick()
        update(text: "It's 2:41.")
        update(text: "It's 2:41.", streaming: false)
        speaker.drain()
        clock += VoiceCallTiming.holdOnDelay
        controller.tick()
        XCTAssertEqual(speaker.spoken, ["It's 2:41."])
    }

    func testSpeechFromBeforeTheReplyDoesNotInterruptIt() async {
        await controller.start()
        await say("find me an article")
        update(text: "Here's one from your library. It")
        // Recognized just as the reply starts: said before any of it could be heard.
        listener.onPartial?("? Put your finger on the screen")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(speaker.stopCount, 0)

        // The same speech, recognized further along, is still not talk-over.
        clock += VoiceCallTiming.talkOverGrace
        listener.onPartial?("? Put your finger on the screen now")
        XCTAssertEqual(controller.state, .speaking)

        // New words are.
        listener.onPartial?("hold on a second")
        await controller.lastChatTask?.value
        XCTAssertEqual(controller.state, .listening)
    }

    func testWordsHeardWhileThinkingAreNotTalkOver() async {
        await controller.start()
        await say("find me an article")
        listener.onPartial?("put your finger on the")
        update(text: "Here's one. It")
        clock += VoiceCallTiming.talkOverGrace
        listener.onPartial?("put your finger on the screen")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(speaker.stopCount, 0)
    }

    func testTurnEndingMidThoughtWaitsForTheNextWord() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onFinal?(". Tell me an interesting fact about.")
        voice(false, for: 0.9)
        controller.tick()
        XCTAssertTrue(chat.sent.isEmpty)

        voice(true, for: 0.5)
        listener.onFinal?("Wales.")
        voice(false, for: 0.9)
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "Tell me an interesting fact about. Wales."])
    }

    func testTurnEndingMidThoughtSendsAfterTheLongerWait() async {
        await controller.start()
        voice(true, for: 0.6)
        listener.onFinal?("Tell me a fact about.")
        voice(false, for: 0.9)
        clock += VoiceCallTiming.midThoughtWait - 1.0
        controller.tick()
        XCTAssertTrue(chat.sent.isEmpty)
        clock += 0.6
        controller.tick()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "Tell me a fact about."])
    }

    func testTapSendsATurnEndingMidThoughtAtOnce() async {
        await controller.start()
        voice(true, for: 0.5)
        listener.onPartial?("remind me to")
        controller.performTapAction()
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, [tag + "remind me to"])
    }

    func testEndsMidThought() {
        XCTAssertTrue(VoiceCallController.endsMidThought("Tell me an interesting fact about."))
        XCTAssertTrue(VoiceCallController.endsMidThought("send it to the"))
        XCTAssertTrue(VoiceCallController.endsMidThought("I was thinking, um"))
        XCTAssertFalse(VoiceCallController.endsMidThought("What's it for?"))
        XCTAssertFalse(VoiceCallController.endsMidThought("Who is Alex Fisher?"))
        XCTAssertFalse(VoiceCallController.endsMidThought("October 2018."))
        XCTAssertFalse(VoiceCallController.endsMidThought(""))
    }

    func testTranscriptDropsTheRecognizersLeadingPunctuation() async {
        await controller.start()
        voice(true, for: 0.5)
        listener.onPartial?(". What are my current goals")
        XCTAssertEqual(controller.partialTranscript, "What are my current goals")
    }
}

final class VoiceCallCaptionsTests: XCTestCase {
    private func content(sent: String? = nil, live: String = "", reply: String? = nil, replying: Bool = false)
        -> VoiceCallCaptions.Content? {
        VoiceCallCaptions.content(sent: sent, live: live, reply: reply, isReplying: replying)
    }

    func testCaptionsFollowATurn() {
        XCTAssertNil(content(reply: "an older chat reply"))
        XCTAssertEqual(content(live: "what time"), .init(speaker: .user, body: "what time", isActive: true))
        // Sent, Atlas hasn't answered yet: the question stays in place, dimmed.
        XCTAssertEqual(content(sent: "what time is it", replying: true),
                       .init(speaker: .user, body: "what time is it", isActive: false))
        XCTAssertEqual(content(sent: "what time is it", reply: "It's 2:37.", replying: true),
                       .init(speaker: .atlas, context: "what time is it", body: "It's 2:37.", isActive: true))
        // Done: the reply stays, dimmed, until the user's next words.
        XCTAssertEqual(content(sent: "what time is it", reply: "It's 2:37."),
                       .init(speaker: .atlas, context: "what time is it", body: "It's 2:37.", isActive: false))
        XCTAssertEqual(content(live: "thanks", reply: "It's 2:37.")?.body, "thanks")
    }
}

@MainActor
final class ServerSpeechSpeakerTests: XCTestCase {
    private var requests: [String] = []
    private var fallback: FakeSpeaker!

    override func setUp() async throws {
        requests = []
        fallback = FakeSpeaker()
    }

    /// `respond` answers each request in order; Data() is undecodable, so the clip is skipped.
    private func makeSpeaker(_ respond: @escaping (Int) async throws -> Data) -> ServerSpeechSpeaker {
        ServerSpeechSpeaker(
            synthesize: { [unowned self] text in
                requests.append(text)
                return try await respond(requests.count)
            },
            fallback: fallback,
            requestSpacing: 0
        )
    }

    func testFirstSentenceIsFetchedAloneAndLaterOnesAreBatched() async {
        var gate: CheckedContinuation<Void, Never>?
        let firstRequested = expectation(description: "first request")
        let drained = expectation(description: "queue drained")
        let speaker = makeSpeaker { count in
            if count == 1 {
                await withCheckedContinuation { gate = $0; firstRequested.fulfill() }
            }
            return Data()
        }
        speaker.onFinishedQueue = { drained.fulfill() }
        speaker.enqueue("One.")
        await fulfillment(of: [firstRequested], timeout: 5)
        speaker.enqueue("Two.")
        speaker.enqueue("Three.")
        XCTAssertTrue(speaker.isSpeaking)
        gate?.resume()
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(requests, ["One.", "Two. Three."])
        XCTAssertTrue(fallback.spoken.isEmpty)
    }

    func testRateLimitedRequestIsRetried() async {
        let drained = expectation(description: "queue drained")
        let speaker = makeSpeaker { count in
            if count == 1 { throw APIError.http(statusCode: 429, body: nil) }
            return Data()
        }
        speaker.onFinishedQueue = { drained.fulfill() }
        speaker.enqueue("One.")
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(requests, ["One.", "One."])
    }

    func testFailureHandsTheRestOfTheCallToTheOnDeviceVoice() async {
        let failed = expectation(description: "fell back")
        let speaker = makeSpeaker { _ in throw URLError(.cannotConnectToHost) }
        fallback.onEnqueue = { failed.fulfill() }
        speaker.enqueue("One.")
        await fulfillment(of: [failed], timeout: 5)
        fallback.onEnqueue = nil
        XCTAssertEqual(fallback.spoken, ["One."])
        speaker.enqueue("Two.")
        XCTAssertEqual(fallback.spoken, ["One.", "Two."])
        XCTAssertEqual(requests, ["One."])

        let drained = expectation(description: "queue drained")
        speaker.onFinishedQueue = { drained.fulfill() }
        fallback.drain()
        await fulfillment(of: [drained], timeout: 5)
    }

    func testThinkingCueUsesTheOnDeviceSpeaker() {
        let speaker = makeSpeaker { _ in Data() }
        speaker.setThinkingCue(true)
        XCTAssertEqual(fallback.cueStates, [true])
    }
}
