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

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop() { stopCount += 1 }
}

@MainActor
private final class FakeSpeaker: SpeechSpeaking {
    var onFinishedQueue: (() -> Void)?
    var spoken: [String] = []
    var queue: [String] = []
    var stopCount = 0
    var cueStates: [Bool] = []
    var isSpeaking: Bool { !queue.isEmpty }

    func enqueue(_ sentence: String) {
        spoken.append(sentence)
        queue.append(sentence)
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

    func sendVoiceMessage(_ text: String) async -> Bool {
        sent.append(text)
        return sendResult
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
    private var suppressCue = false
    private var controller: VoiceCallController!

    override func setUp() async throws {
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
            suppressThinkingCue: { [unowned self] in suppressCue },
            tickInterval: nil
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

    /// Starts a call and gets Atlas mid-reply with "First sentence." queued.
    private func startSpeaking() async {
        await controller.start()
        await say("hello")
        update(text: "First sentence. Second")
    }

    // MARK: - Tests

    func testFullLoopListenThinkSpeakListen() async {
        await controller.start()
        XCTAssertEqual(bridge.startCount, 1)
        XCTAssertEqual(listener.startCount, 1)
        XCTAssertEqual(controller.state, .listening)

        await say("hello")
        XCTAssertEqual(chat.sent, ["[voice] hello"])
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
        XCTAssertEqual(chat.sent, ["[voice] hello", "[voice] thanks"])
    }

    func testPartialTranscriptShownWhileListening() async {
        await controller.start()
        listener.onFinal?("hello")
        listener.onPartial?("there")
        XCTAssertEqual(controller.partialTranscript, "hello there")
    }

    func testNoSecondSendWhileThinking() async {
        await controller.start()
        await say("hello")
        await say("are you there")
        XCTAssertEqual(chat.sent, ["[voice] hello"])
        XCTAssertEqual(controller.state, .thinking)
    }

    func testBargeInStopsSpeakerAndCancelsOnce() async {
        await startSpeaking()
        XCTAssertEqual(controller.state, .speaking)

        voice(true, for: 0.4)
        await controller.lastChatTask?.value
        XCTAssertEqual(speaker.stopCount, 1)
        XCTAssertEqual(chat.cancelCount, 1)
        XCTAssertEqual(controller.state, .listening)

        // More text from the cancelled run is not spoken, and the new speech is kept.
        update(text: "First sentence. Second sentence. Third.")
        XCTAssertEqual(speaker.spoken, ["First sentence."])
        listener.onFinal?("wait stop")
        voice(false, for: 0.9)
        await controller.lastChatTask?.value
        XCTAssertEqual(chat.sent, ["[voice] hello", "[voice] wait stop"])
        XCTAssertEqual(chat.cancelCount, 1)
    }

    func testBargeInIgnoredWhileSpeakerEchoBelowThreshold() async {
        await startSpeaking()
        voice(true, for: 0.2)
        voice(false, for: 0.3)
        voice(true, for: 0.2)
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
        XCTAssertEqual(chat.sent, ["[voice] hello"])
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
}
