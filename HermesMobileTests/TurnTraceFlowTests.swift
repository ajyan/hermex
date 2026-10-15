import XCTest
@testable import HermesMobile

/// A turn started by `ChatViewModel.sendMessage` sends a `traceparent` with chat/start and uploads its
/// timings to `/api/telemetry/turn` exactly once, whichever way it ends.
final class TurnTraceFlowTests: APIClientTestCase {
    private let traceparentPattern = "^00-[0-9a-f]{32}-[0-9a-f]{16}-01$"

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            TurnTraceUploader.reset()
            TurnTraceUploader.isEnabled = true
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated { TurnTraceUploader.isEnabled = false }
        super.tearDown()
    }

    // MARK: - chat/start header

    @MainActor
    func testChatStartCarriesTraceparentHeader() async throws {
        let recorder = RequestRecorder()
        let streamClient = ScriptedSSEStreamingClient()
        let viewModel = try makeViewModel(streamClient: streamClient, recorder: recorder)

        let didStart = await viewModel.sendMessage("Keep working")

        XCTAssertTrue(didStart)
        let header = try XCTUnwrap(recorder.chatStartTraceparent)
        XCTAssertNotNil(header.range(of: traceparentPattern, options: .regularExpression))
    }

    // MARK: - uploads

    @MainActor
    func testCompletedTurnUploadsOnceWithMarks() async throws {
        let recorder = RequestRecorder()
        let uploaded = expectation(description: "turn uploaded")
        recorder.onUpload = { uploaded.fulfill() }
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Hi"), lastEventID: "stream-123:1"),
            .init(.done(DoneStreamEvent())),
            .init(.streamEnd)
        ]])
        let viewModel = try makeViewModel(streamClient: streamClient, recorder: recorder)

        let didStart = await viewModel.sendMessage("Say hi")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        await fulfillment(of: [uploaded], timeout: 5)

        XCTAssertEqual(recorder.uploads.count, 1)
        let body = try XCTUnwrap(recorder.uploads.first)
        XCTAssertEqual(body["traceparent"] as? String, recorder.chatStartTraceparent)
        XCTAssertEqual(body["outcome"] as? String, "done")
        XCTAssertEqual(body["connection"] as? String, "tunnel")
        XCTAssertEqual(body["reconnects"] as? Int, 0)
        XCTAssertEqual(body["backgrounded"] as? Bool, false)
        let marks = try XCTUnwrap(body["marks_ms"] as? [String: Any])
        let headers = try XCTUnwrap(marks["headers"] as? Int)
        let firstToken = try XCTUnwrap(marks["first_token"] as? Int)
        let rendered = try XCTUnwrap(marks["rendered"] as? Int)
        let end = try XCTUnwrap(marks["end"] as? Int)
        XCTAssertGreaterThanOrEqual(firstToken, headers)
        XCTAssertGreaterThanOrEqual(rendered, firstToken)
        XCTAssertGreaterThanOrEqual(end, rendered)
    }

    @MainActor
    func testCancelledTurnUploadsCancelled() async throws {
        let recorder = RequestRecorder()
        let uploaded = expectation(description: "turn uploaded")
        recorder.onUpload = { uploaded.fulfill() }
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Hi"), lastEventID: "stream-123:1"),
            .init(.cancelled)
        ]])
        let viewModel = try makeViewModel(streamClient: streamClient, recorder: recorder)

        let didStart = await viewModel.sendMessage("Say hi")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        await fulfillment(of: [uploaded], timeout: 5)

        XCTAssertEqual(recorder.uploads.count, 1)
        XCTAssertEqual(recorder.uploads.first?["outcome"] as? String, "cancelled")
    }

    @MainActor
    func testReconnectCountsOnHeldTrace() async throws {
        let recorder = RequestRecorder()
        let uploaded = expectation(description: "turn uploaded")
        recorder.onUpload = { uploaded.fulfill() }
        let reconnected = expectation(description: "reconnect started")
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.transportError("The network connection was lost."))
            ],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo."), lastEventID: "stream-123:2"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient, recorder: recorder)
        streamClient.onStart = { _ in
            if streamClient.startedURLs.count == 2 { reconnected.fulfill() }
        }

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        await fulfillment(of: [reconnected], timeout: 5)
        streamClient.playArmedConnectionScript()
        await fulfillment(of: [uploaded], timeout: 5)

        XCTAssertEqual(recorder.uploads.count, 1)
        XCTAssertEqual(recorder.uploads.first?["reconnects"] as? Int, 1)
        XCTAssertEqual(recorder.uploads.first?["outcome"] as? String, "done")
    }

    // MARK: - 404

    @MainActor
    func testServer404StopsFurtherUploadsForThatServerOnly() async throws {
        let recorder = RequestRecorder()
        let client = makeClient { request in
            recorder.recordRaw(request)
            if request.url?.host == "example.test" {
                return apiTestJSONResponse(#"{"error": "not found"}"#, for: request, status: 404)
            }
            return apiTestJSONResponse("", for: request, status: 204)
        }
        let otherServer = APIClient(baseURL: URL(string: "https://other.test")!, session: clientSession())
        let upload = makeUpload()

        await TurnTraceUploader.send(upload, client: client)
        XCTAssertEqual(recorder.rawRequestCount, 1)

        await TurnTraceUploader.send(upload, client: client)
        XCTAssertEqual(recorder.rawRequestCount, 1, "a 404 stops further uploads to that server")

        await TurnTraceUploader.send(upload, client: otherServer)
        XCTAssertEqual(recorder.rawRequestCount, 2, "the block is per server")
    }

    @MainActor
    func testNon404FailureDoesNotBlockLaterUploads() async throws {
        let recorder = RequestRecorder()
        let client = makeClient { request in
            recorder.recordRaw(request)
            return apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 500)
        }
        let upload = makeUpload()

        await TurnTraceUploader.send(upload, client: client)
        await TurnTraceUploader.send(upload, client: client)

        XCTAssertEqual(recorder.rawRequestCount, 2)
    }

    // MARK: - Helpers

    private func clientSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeUpload() -> TurnTraceUpload {
        let start = ContinuousClock.now
        let trace = TurnTrace(baseURL: URL(string: "https://example.test")!)
        return trace.upload(outcome: .done, endedAt: start + .milliseconds(5))
    }

    @MainActor
    private func makeViewModel(
        streamClient: ScriptedSSEStreamingClient,
        recorder: RequestRecorder
    ) throws -> ChatViewModel {
        MockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/chat/start":
                recorder.chatStartTraceparent = request.value(forHTTPHeaderField: "traceparent")
                return apiTestJSONResponse(
                    #"{"session_id": "session-abc", "stream_id": "stream-123"}"#,
                    for: request
                )
            case "/api/telemetry/turn":
                recorder.recordUpload(apiTestBodyData(from: request))
                return apiTestJSONResponse("", for: request, status: 204)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(
                    #"{"active": false, "stream_id": "stream-123", "replay_available": true}"#,
                    for: request
                )
            case "/api/session":
                return apiTestJSONResponse(
                    #"{"session": {"session_id": "session-abc", "title": "Planning"}}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let client = APIClient(baseURL: server, session: clientSession())

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id": "session-abc", "title": "Planning", "workspace": "/tmp/workspace"}"#.utf8)
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
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }
        return viewModel
    }
}

/// Collects what the mock server saw. The handler runs off the main thread, so state sits behind a lock.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _chatStartTraceparent: String?
    private var _uploads: [[String: Any]] = []
    private var _rawRequestCount = 0
    private var _onUpload: (@Sendable () -> Void)?

    var chatStartTraceparent: String? {
        get { lock.withLock { _chatStartTraceparent } }
        set { lock.withLock { _chatStartTraceparent = newValue } }
    }

    var uploads: [[String: Any]] { lock.withLock { _uploads } }
    var rawRequestCount: Int { lock.withLock { _rawRequestCount } }

    var onUpload: (@Sendable () -> Void)? {
        get { lock.withLock { _onUpload } }
        set { lock.withLock { _onUpload = newValue } }
    }

    func recordRaw(_ request: URLRequest) {
        lock.withLock { _rawRequestCount += 1 }
    }

    func recordUpload(_ body: Data?) {
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            _uploads.append(json)
            return _onUpload
        }
        callback?()
    }
}
