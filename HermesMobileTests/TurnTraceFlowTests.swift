import XCTest
@testable import HermesMobile

/// A turn started by `ChatViewModel.sendMessage` sends a `traceparent` with chat/start and uploads its
/// timings to `/api/telemetry/turn` exactly once, whichever way it ends.
final class TurnTraceFlowTests: APIClientTestCase {
    private let traceparentPattern = "^00-[0-9a-f]{32}-[0-9a-f]{16}-01$"

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            savedQueueDirectory = TurnTraceUploader.directory
            TurnTraceUploader.directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TurnTraceFlowTests-\(UUID().uuidString)", isDirectory: true)
            TurnTraceUploader.reset()
            TurnTraceUploader.isEnabled = true
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            TurnTraceUploader.isEnabled = false
            try? FileManager.default.removeItem(at: TurnTraceUploader.directory)
            if let savedQueueDirectory { TurnTraceUploader.directory = savedQueueDirectory }
        }
        super.tearDown()
    }

    private var savedQueueDirectory: URL?

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
        XCTAssertEqual(body["detached"] as? Bool, false)
        let marks = try XCTUnwrap(body["marks_ms"] as? [String: Any])
        let headers = try XCTUnwrap(marks["headers"] as? Int)
        let firstToken = try XCTUnwrap(marks["first_token"] as? Int)
        let rendered = try XCTUnwrap(marks["rendered"] as? Int)
        let end = try XCTUnwrap(marks["end"] as? Int)
        XCTAssertGreaterThanOrEqual(firstToken, headers)
        XCTAssertGreaterThanOrEqual(rendered, firstToken)
        XCTAssertGreaterThanOrEqual(end, rendered)
        XCTAssertNil(body["voice"], "only voice-call turns carry the call's timings")
    }

    /// A call learns when the reply became audible (and of any barge-in) after the stream can end, so its
    /// turn's upload waits for the call and carries those timings.
    @MainActor
    func testVoiceCallTurnUploadWaitsForTheCallsTimings() async throws {
        let recorder = RequestRecorder()
        let uploaded = expectation(description: "turn uploaded")
        recorder.onUpload = { uploaded.fulfill() }
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Hi"), lastEventID: "stream-123:1"),
            .init(.done(DoneStreamEvent())),
            .init(.streamEnd)
        ]])
        let viewModel = try makeViewModel(streamClient: streamClient, recorder: recorder)
        viewModel.voiceCallDidChange(isActive: true)

        let didStart = await viewModel.sendVoiceMessage("Say hi")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        viewModel.noteVoiceTiming(speechEndToAudibleMS: 2840, bargeInMS: nil)
        viewModel.noteVoiceTiming(speechEndToAudibleMS: nil, bargeInMS: 920)
        viewModel.voiceCallDidChange(isActive: false)
        await fulfillment(of: [uploaded], timeout: 5)

        XCTAssertEqual(recorder.uploads.count, 1)
        let body = try XCTUnwrap(recorder.uploads.first)
        XCTAssertEqual(body["outcome"] as? String, "done")
        XCTAssertEqual(body["voice"] as? Bool, true)
        XCTAssertEqual(body["speech_end_to_audible_ms"] as? Int, 2840)
        XCTAssertEqual(body["barge_in_ms"] as? Int, 920)
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
        XCTAssertEqual(recorder.uploads.first?["detached"] as? Bool, false, "a dropped connection is not the user leaving")
    }

    /// Leaving the chat mid-turn suspends the stream; the turn finishes from the replay on return, and its
    /// upload says so, so the gap reads as time away rather than latency.
    @MainActor
    func testLeavingTheChatMarksTheTurnDetached() async throws {
        let recorder = RequestRecorder()
        let uploaded = expectation(description: "turn uploaded")
        recorder.onUpload = { uploaded.fulfill() }
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeViewModel(streamClient: streamClient, recorder: recorder)

        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        viewModel.suspendStreamForNavigation()
        await viewModel.reconnectStreamIfNeeded()
        XCTAssertEqual(streamClient.startedURLs.count, 2)
        streamClient.playArmedConnectionScript()
        await fulfillment(of: [uploaded], timeout: 5)

        XCTAssertEqual(recorder.uploads.count, 1)
        XCTAssertEqual(recorder.uploads.first?["detached"] as? Bool, true)
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
        let client = makeQueueClient { request in
            recorder.recordRaw(request)
            return apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 500)
        }
        let upload = makeUpload()

        await TurnTraceUploader.send(upload, client: client)
        await TurnTraceUploader.send(upload, client: client)

        XCTAssertEqual(recorder.rawRequestCount, 2)
    }

    // MARK: - Pending queue

    /// An upload the server couldn't take stays on disk and goes out, once, with the next retry.
    @MainActor
    func testFailedUploadIsKeptAndRetried() async throws {
        let recorder = RequestRecorder()
        let serverIsUp = LockedFlag()
        let client = makeQueueClient { request in
            guard serverIsUp.value else { throw URLError(.notConnectedToInternet) }
            recorder.recordUpload(apiTestBodyData(from: request))
            return apiTestJSONResponse("", for: request, status: 204)
        }
        let upload = makeUpload()

        await TurnTraceUploader.send(upload, client: client)
        XCTAssertTrue(recorder.uploads.isEmpty)

        serverIsUp.value = true
        await TurnTraceUploader.retryPending(client: client)
        XCTAssertEqual(recorder.uploads.map { $0["traceparent"] as? String }, [upload.traceparent])

        await TurnTraceUploader.retryPending(client: client)
        XCTAssertEqual(recorder.uploads.count, 1, "a delivered upload leaves the queue")
    }

    /// The next turn that uploads carries the earlier, unsent ones with it, oldest first.
    @MainActor
    func testSuccessfulUploadDrainsEarlierFailures() async throws {
        let recorder = RequestRecorder()
        let serverIsUp = LockedFlag()
        let client = makeQueueClient { request in
            guard serverIsUp.value else {
                return apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 503)
            }
            recorder.recordUpload(apiTestBodyData(from: request))
            return apiTestJSONResponse("", for: request, status: 204)
        }
        let first = makeUpload()
        let second = makeUpload()

        await TurnTraceUploader.send(first, client: client)
        serverIsUp.value = true
        await TurnTraceUploader.send(second, client: client)

        XCTAssertEqual(
            recorder.uploads.map { $0["traceparent"] as? String },
            [first.traceparent, second.traceparent]
        )
    }

    @MainActor
    func testPendingUploadsNeverReachAnotherServer() async throws {
        let recorder = RequestRecorder()
        let serverIsUp = LockedFlag()
        let client = makeQueueClient { request in
            guard serverIsUp.value else { throw URLError(.notConnectedToInternet) }
            recorder.recordHost(request.url?.host)
            return apiTestJSONResponse("", for: request, status: 204)
        }
        let otherServer = APIClient(baseURL: URL(string: "https://other.test")!, session: clientSession())

        await TurnTraceUploader.send(makeUpload(), client: client)
        serverIsUp.value = true
        await TurnTraceUploader.retryPending(client: otherServer)
        await TurnTraceUploader.send(makeUpload(), client: otherServer)
        XCTAssertEqual(recorder.hosts, ["other.test"], "server A's turn stays queued for server A")

        await TurnTraceUploader.retryPending(client: client)
        XCTAssertEqual(recorder.hosts, ["other.test", "queue.test"])
    }

    @MainActor
    func testQueueKeepsTheNewestAndDropsExpired() async throws {
        let recorder = RequestRecorder()
        let serverIsUp = LockedFlag()
        let client = makeQueueClient { request in
            guard serverIsUp.value else { throw URLError(.notConnectedToInternet) }
            recorder.recordUpload(apiTestBodyData(from: request))
            return apiTestJSONResponse("", for: request, status: 204)
        }
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = makeUpload()
        await TurnTraceUploader.send(stale, client: client, now: old)

        let now = old.addingTimeInterval(TurnTraceUploader.maxAge + 1)
        var sent: [TurnTraceUpload] = []
        for _ in 0..<(TurnTraceUploader.maxPending + 2) {
            let upload = makeUpload()
            sent.append(upload)
            await TurnTraceUploader.send(upload, client: client, now: now)
        }

        serverIsUp.value = true
        await TurnTraceUploader.retryPending(client: client, now: now)
        XCTAssertEqual(
            recorder.uploads.map { $0["traceparent"] as? String },
            sent.suffix(TurnTraceUploader.maxPending).map(\.traceparent)
        )
    }

    /// A body the server refuses outright is not retried forever.
    @MainActor
    func testRejectedUploadLeavesTheQueue() async throws {
        let recorder = RequestRecorder()
        let client = makeQueueClient { request in
            recorder.recordRaw(request)
            return apiTestJSONResponse(#"{"error": "invalid traceparent"}"#, for: request, status: 400)
        }

        await TurnTraceUploader.send(makeUpload(), client: client)
        await TurnTraceUploader.retryPending(client: client)

        XCTAssertEqual(recorder.rawRequestCount, 1)
    }

    /// A turn whose end the app never saw still uploads when the next one starts, marked as left.
    @MainActor
    func testTurnWithoutAnEndUploadsWhenTheNextOneStarts() async throws {
        let recorder = RequestRecorder()
        let uploaded = expectation(description: "abandoned turn uploaded")
        recorder.onUpload = { uploaded.fulfill() }
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Hi"), lastEventID: "stream-123:1")
        ]])
        let viewModel = try makeViewModel(streamClient: streamClient, recorder: recorder)

        let didStart = await viewModel.sendMessage("Say hi")
        XCTAssertTrue(didStart)
        let firstTraceparent = recorder.chatStartTraceparent
        streamClient.playArmedConnectionScript()
        viewModel.streamCoordinator.prepareForNewResponse()
        await fulfillment(of: [uploaded], timeout: 5)

        XCTAssertEqual(recorder.uploads.count, 1)
        let body = try XCTUnwrap(recorder.uploads.first)
        XCTAssertEqual(body["traceparent"] as? String, firstTraceparent)
        XCTAssertEqual(body["outcome"] as? String, "cancelled")
        XCTAssertEqual(body["detached"] as? Bool, true)
    }

    /// What goes to disk and over the wire is ids, flags and timings: nothing the user or the agent wrote.
    @MainActor
    func testUploadCarriesNoMessageText() async throws {
        let recorder = RequestRecorder()
        let uploaded = expectation(description: "turn uploaded")
        recorder.onUpload = { uploaded.fulfill() }
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("SECRET-REPLY"), lastEventID: "stream-123:1"),
            .init(.done(DoneStreamEvent())),
            .init(.streamEnd)
        ]])
        let viewModel = try makeViewModel(streamClient: streamClient, recorder: recorder)

        let didStart = await viewModel.sendMessage("SECRET-PROMPT")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        await fulfillment(of: [uploaded], timeout: 5)

        let body = try XCTUnwrap(recorder.uploads.first)
        XCTAssertEqual(
            Set(body.keys),
            ["traceparent", "start_unix_nano", "connection", "outcome", "reconnects", "backgrounded", "detached", "marks_ms"]
        )
        let text = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.contains("session-abc"))
    }

    // MARK: - Helpers

    /// A server of its own for the tests that call the uploader directly: a view model left over from an
    /// earlier test retries `example.test`'s queue when it wakes, and must find nothing of theirs there.
    private func makeQueueClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler
        return APIClient(baseURL: URL(string: "https://queue.test")!, session: clientSession())
    }

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
            btwStreamClient: ScriptedSSEStreamingClient(),
            sessionEventsClient: SpySessionEventStream()
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

    private var _hosts: [String] = []
    var hosts: [String] { lock.withLock { _hosts } }
    func recordHost(_ host: String?) { lock.withLock { _hosts.append(host ?? "") } }

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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
