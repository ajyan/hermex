import XCTest
@testable import HermesMobile

/// A scripted session events stream: each `start` is one connection the test feeds by hand.
@MainActor
final class SpySessionEventStream: SessionEventStreaming {
    private(set) var starts: [(url: URL, lastEventID: String?)] = []
    private(set) var stopCount = 0
    private var onEventID: (@MainActor (String) -> Void)?
    private var onEnd: (@MainActor (SessionEventStreamEnd) -> Void)?

    func start(
        url: URL,
        lastEventID: String?,
        onEventID: @escaping @MainActor (String) -> Void,
        onEnd: @escaping @MainActor (SessionEventStreamEnd) -> Void
    ) {
        starts.append((url, lastEventID))
        self.onEventID = onEventID
        self.onEnd = onEnd
    }

    func stop() {
        stopCount += 1
        onEventID = nil
        onEnd = nil
    }

    /// One event with this SSE id on the current connection.
    func emit(_ eventID: String) { onEventID?(eventID) }

    /// The current connection ends on its own, as the real client reports it.
    func end(_ end: SessionEventStreamEnd) {
        let onEnd = onEnd
        onEventID = nil
        self.onEnd = nil
        onEnd?(end)
    }
}

@MainActor
final class SessionRunListenerTests: XCTestCase {
    private let url = URL(string: "https://example.test/api/sessions/session-abc/events")!
    private var stream: SpySessionEventStream!
    private var sleeps: [Duration] = []
    private var streamIDs: [String] = []
    private var logLines: [String] = []
    private var listener: SessionRunListener!

    override func setUp() async throws {
        stream = SpySessionEventStream()
        sleeps = []
        streamIDs = []
        logLines = []
        listener = SessionRunListener(
            url: url,
            stream: stream,
            sleep: { [unowned self] in sleeps.append($0) },
            log: { [unowned self] in logLines.append($0) }
        ) { [unowned self] in streamIDs.append($0) }
    }

    func testEndpointIsTheSessionsEventsRoute() {
        let base = URL(string: "https://example.test")!
        XCTAssertEqual(
            APIClient(baseURL: base).sessionEventsURL(sessionID: "session-abc").absoluteString,
            "https://example.test/api/sessions/session-abc/events"
        )
        XCTAssertEqual(
            Endpoint.sessionEvents(sessionID: "a/b").url(relativeTo: base).absoluteString,
            "https://example.test/api/sessions/a%2Fb/events"
        )
    }

    func testStreamIDIsTheEventIDBeforeItsSequence() {
        XCTAssertEqual(SessionRunListener.streamID(fromEventID: "3ce8c56d2af541a9942e306fa2696e5c:4"),
                       "3ce8c56d2af541a9942e306fa2696e5c")
        XCTAssertNil(SessionRunListener.streamID(fromEventID: "no-sequence"))
        XCTAssertNil(SessionRunListener.streamID(fromEventID: ":4"))
    }

    func testReportsEachRunEventsStreamAndReconnectsFromTheLastEventAfterAClose() {
        listener.start()
        XCTAssertEqual(stream.starts.count, 1)
        XCTAssertNil(stream.starts[0].lastEventID)

        stream.emit("run-a:1")
        stream.emit("run-a:2")
        stream.end(.closed)

        XCTAssertEqual(streamIDs, ["run-a", "run-a"])
        XCTAssertEqual(stream.starts.count, 2, "the server closes after each run; the next connection opens at once")
        XCTAssertEqual(stream.starts[1].url, url)
        XCTAssertEqual(stream.starts[1].lastEventID, "run-a:2")
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testFailuresBackOffAndKeepTheCursor() async {
        listener.start()
        stream.emit("run-a:7")
        stream.end(.failed)
        XCTAssertEqual(stream.starts.count, 1)
        await listener.retryTask?.value
        XCTAssertEqual(sleeps, [.seconds(1)])
        XCTAssertEqual(stream.starts.count, 2)
        XCTAssertEqual(stream.starts[1].lastEventID, "run-a:7")

        // A close that carried no event counts as a failure too, so a server that hangs up at once can't spin.
        stream.end(.closed)
        await listener.retryTask?.value
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(2)])
        XCTAssertEqual(stream.starts.count, 3)
    }

    func testNotFoundStopsQuietly() async {
        listener.start()
        stream.end(.rejected(404))

        XCTAssertNil(listener.retryTask)
        XCTAssertEqual(stream.starts.count, 1)
        XCTAssertEqual(logLines, ["session events unavailable (HTTP 404); not listening"])
        listener.start()
        XCTAssertEqual(stream.starts.count, 2, "a stopped listener can be started again by the next call")
    }

    func testStopCancelsAPendingReconnect() async {
        listener.start()
        stream.end(.failed)
        let retry = listener.retryTask
        listener.stop()
        await retry?.value

        XCTAssertEqual(stream.starts.count, 1)
        XCTAssertEqual(stream.stopCount, 1)
    }

    // MARK: - In the chat

    func testCallAttachesAServerStartedRunAndIgnoresItsOwn() async throws {
        let server = DigServer()
        let chatStream = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Let me dig into that."), lastEventID: "stream-own:1"),
            .init(.done(DoneStreamEvent())),
            .init(.streamEnd)
        ]])
        let chat = try makeViewModel(server: server, streamClient: chatStream)
        var replies: [String] = []
        chat.onServerStartedReply = { replies.append($0) }

        chat.voiceCallDidChange(isActive: true)
        XCTAssertEqual(stream.starts.map(\.url.path), ["/api/sessions/session-abc/events"])
        XCTAssertEqual(stream.starts.first?.url.host, "example.test")

        let sent = await chat.sendVoiceMessage("[voice] dig into the offer")
        XCTAssertTrue(sent)
        chatStream.playArmedConnectionScript()
        XCTAssertNil(chat.activeStreamID)

        // The call's own run, seen again on the session stream, is not a new turn.
        stream.emit("stream-own:1")
        stream.emit("stream-own:3")
        XCTAssertNil(chat.serverRunAttachTask)

        server.activeStreamID = "stream-dig"
        stream.emit("stream-dig:1")
        stream.emit("stream-dig:2")
        await chat.serverRunAttachTask?.value

        XCTAssertEqual(replies, ["stream-dig"])
        XCTAssertEqual(chat.activeStreamID, "stream-dig")
        XCTAssertEqual(
            chatStream.startedURLs.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "stream_id" }?.value },
            ["stream-own", "stream-dig"]
        )
    }

    func testAServerStartedRunAlreadyOverIsOnlyReloaded() async throws {
        let server = DigServer()
        let chatStream = ScriptedSSEStreamingClient()
        let chat = try makeViewModel(server: server, streamClient: chatStream)
        chat.onServerStartedReply = { _ in XCTFail("a finished run is not spoken") }

        chat.voiceCallDidChange(isActive: true)
        stream.emit("stream-dig:9")
        await chat.serverRunAttachTask?.value

        XCTAssertEqual(chat.messages.last?.content, "[Background task completed] the offer")
        XCTAssertTrue(chatStream.startedURLs.isEmpty)
        XCTAssertNil(chat.activeStreamID)
    }

    func testListenerStopsWhenTheCallEnds() throws {
        let chat = try makeViewModel(server: DigServer(), streamClient: ScriptedSSEStreamingClient())
        chat.voiceCallDidChange(isActive: true)
        XCTAssertEqual(stream.starts.count, 1)

        chat.voiceCallDidChange(isActive: false)
        XCTAssertEqual(stream.stopCount, 1)
        stream.end(.closed)
        XCTAssertEqual(stream.starts.count, 1, "no reconnect once the call is over")
    }

    // MARK: - Helpers

    private func makeViewModel(server: DigServer, streamClient: ScriptedSSEStreamingClient) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = server.handle
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let base = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: base, session: URLSession(configuration: configuration))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id":"session-abc","title":"Call"}"#.utf8)
        )
        let viewModel = ChatViewModel(
            session: session,
            server: base,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient(),
            sessionEventsClient: stream
        )
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }
        return viewModel
    }
}

/// A session whose server can start a run by itself. The handler runs off the main thread.
private final class DigServer: @unchecked Sendable {
    private let lock = NSLock()
    private var active: String?

    var activeStreamID: String? {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        switch request.url?.path {
        case "/api/chat/start":
            return apiTestJSONResponse(#"{"session_id":"session-abc","stream_id":"stream-own"}"#, for: request)
        case "/api/session":
            let activeField = activeStreamID.map { #", "active_stream_id": "\#($0)""# } ?? ""
            return apiTestJSONResponse("""
            {"session": {"session_id": "session-abc", "title": "Call"\(activeField), "messages": [
              {"role": "user", "content": "[voice 2:41 PM] dig into the offer", "message_id": "u1"},
              {"role": "assistant", "content": "Let me dig into that.", "message_id": "a1"},
              {"role": "user", "content": "[Background task completed] the offer", "message_id": "u2"}
            ]}}
            """, for: request)
        default:
            return apiTestJSONResponse("{}", for: request)
        }
    }
}
