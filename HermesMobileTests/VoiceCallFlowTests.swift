import XCTest
@testable import HermesMobile

/// The whole call path against the real `ChatViewModel`: a spoken turn is sent,
/// a scripted SSE reply streams back, and the call speaks the complete reply.
/// The call screen's glue (`VoiceCallChatSnapshot.of`) feeds the controller, as
/// `VoiceCallView` does on each chat change.
@MainActor
final class VoiceCallFlowTests: XCTestCase {
    private var stream: ScriptedSSEStreamingClient!
    private var chat: ChatViewModel!
    private var listener: FlowListener!
    private var speaker: FlowSpeaker!
    private var controller: VoiceCallController!
    private var clock: TimeInterval = 100

    override func setUp() async throws {
        stream = ScriptedSSEStreamingClient()
        chat = try makeViewModel(streamClient: stream)
        listener = FlowListener()
        speaker = FlowSpeaker()
        clock = 100
        controller = VoiceCallController(
            listener: listener, speaker: speaker, chat: chat, bridge: FlowBridge(),
            now: { [unowned self] in clock }, suppressThinkingCue: { true }, tickInterval: nil
        )
        await controller.start()
    }

    func testVoiceTurnSpeaksTheWholeReply() async throws {
        await say("what's the weather")
        XCTAssertEqual(chat.messages.last?.content, "[voice] what's the weather")
        XCTAssertEqual(controller.state, .thinking)

        stream.emit(.token("[voice] It's sunny. "))
        feed()
        XCTAssertEqual(speaker.spoken, ["It's sunny."])

        // The rest arrives and the run ends before the screen catches up (one
        // coalesced update), and `done` swaps in the server's message IDs.
        stream.emit(.token("Seventy two degrees, with a light wind from the west."))
        stream.emit(.done(DoneStreamEvent(session: try detail(reply: [
            ("assistant", "[voice] It's sunny. Seventy two degrees, with a light wind from the west.")
        ]))))
        feed()

        XCTAssertEqual(speaker.spoken, ["It's sunny.", "Seventy two degrees, with a light wind from the west."])
        speaker.drain()
        XCTAssertEqual(controller.state, .listening)
    }

    func testReplyAroundAToolCallIsSpokenInFull() async throws {
        await say("what did I journal today")
        stream.emit(.token("Let me check. "))
        feed()
        stream.emit(.done(DoneStreamEvent(session: try detail(reply: [
            ("assistant", "Let me check."),
            ("tool", "{\"output\":\"...\"}"),
            ("assistant", "You set up the phone agent. Then you worked on the brain.")
        ]))))
        feed()
        XCTAssertEqual(speaker.spoken, ["Let me check.", "You set up the phone agent.", "Then you worked on the brain."])
    }

    func testAnOlderReplyIsNeverReadAsTheNewOne() async throws {
        await say("first")
        stream.emit(.done(DoneStreamEvent(session: try detail(reply: [("assistant", "One.")]))))
        feed()
        speaker.drain()
        XCTAssertEqual(speaker.spoken, ["One."])

        await say("second")
        feed()
        XCTAssertEqual(speaker.spoken, ["One."])
        XCTAssertEqual(controller.state, .thinking)
    }

    // MARK: - Helpers

    private func feed() {
        let snapshot = VoiceCallChatSnapshot.of(chat)
        controller.chatDidUpdate(
            streamingText: snapshot.streamingText, isStreaming: snapshot.isStreaming,
            approval: snapshot.approval, isReconnecting: snapshot.isReconnecting,
            currentTool: snapshot.currentTool
        )
    }

    private func say(_ text: String) async {
        for _ in 0..<6 { listener.onVoiceActivity?(true, clock); clock += 0.1 }
        listener.onFinal?(text)
        for _ in 0..<9 { listener.onVoiceActivity?(false, clock); clock += 0.1 }
        await controller.lastChatTask?.value
        feed()
    }

    private var sentTurns: [String] {
        chat.messages.filter { $0.role == "user" }.compactMap(\.content)
    }

    /// The server's view of the session after the latest run: every turn sent so far, then `reply`.
    private func detail(reply: [(String, String)]) throws -> SessionDetail {
        var rows: [[String: Any]] = []
        var index = 0
        for turn in sentTurns {
            index += 1
            rows.append(["role": "user", "content": turn, "message_id": "srv-\(index)"])
        }
        for (role, content) in reply {
            index += 1
            rows.append(["role": role, "content": content, "message_id": "srv-\(index)"])
        }
        let json = try JSONSerialization.data(withJSONObject: ["session_id": "session-abc", "messages": rows])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionDetail.self, from: json)
    }

    private func makeViewModel(streamClient: ScriptedSSEStreamingClient) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-1"}"#, for: request)
            default:
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id":"session-abc","title":"Call"}"#.utf8)
        )
        let viewModel = ChatViewModel(
            session: session,
            server: server,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient()
        )
        // Tokens land in `messages` as they arrive (no word-reveal timer), so each
        // `feed()` sees exactly what the scripted stream has delivered.
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }
        return viewModel
    }
}

@MainActor
private final class FlowListener: SpeechListening {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onVoiceActivity: ((Bool, TimeInterval) -> Void)?
    func start() async throws {}
    func stop() {}
}

@MainActor
private final class FlowSpeaker: SpeechSpeaking {
    var onFinishedQueue: (() -> Void)?
    var spoken: [String] = []
    private var queue: [String] = []
    var isSpeaking: Bool { !queue.isEmpty }
    func enqueue(_ sentence: String) { spoken.append(sentence); queue.append(sentence) }
    func stopNow() { queue.removeAll() }
    func setThinkingCue(_ on: Bool) {}
    func drain() {
        guard !queue.isEmpty else { return }
        queue.removeAll()
        onFinishedQueue?()
    }
}

@MainActor
private final class FlowBridge: CallSystemBridging {
    var onEnded: (() -> Void)?
    var onMuteChanged: ((Bool) -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    func startCall() async throws {}
    func endCall() {}
    func setMuted(_ muted: Bool) {}
}
