import XCTest
@testable import HermesMobile

/// A Prep client that serves only the mock routes; every other route fails.
private final class FakeMockClient: PrepDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _grades: [(mockID: String, sessionID: String, turnMS: [Int])] = []

    var mocksResults: [Result<PrepMocks, Error>] = []
    var startResult: Result<PrepMockStart, Error> = .failure(URLError(.badServerResponse))

    var log: [String] { lock.withLock { _log } }
    var grades: [(mockID: String, sessionID: String, turnMS: [Int])] { lock.withLock { _grades } }

    func mocks() async throws -> PrepMocks {
        try lock.withLock {
            _log.append("mocks")
            guard !mocksResults.isEmpty else { throw URLError(.badServerResponse) }
            return try (mocksResults.count > 1 ? mocksResults.removeFirst() : mocksResults[0]).get()
        }
    }

    func mockStart(kind: PrepMockKind) async throws -> PrepMockStart {
        lock.withLock { _log.append("start:\(kind.rawValue)") }
        return try startResult.get()
    }

    func mockGrade(mockID: String, sessionID: String, turnMS: [Int]) async throws {
        lock.withLock {
            _log.append("grade:\(mockID)")
            _grades.append((mockID, sessionID, turnMS))
        }
    }

    func home() async throws -> PrepHome { throw URLError(.badServerResponse) }
    func today(run: PrepRunKind, unit: String?) async throws -> PrepRun { throw URLError(.badServerResponse) }
    func map(track: String) async throws -> PrepTrackMap { throw URLError(.badServerResponse) }
    func attempt(_ r: PrepAttemptRequest) async throws -> PrepAttemptResult { throw URLError(.badServerResponse) }
    func gaps() async throws -> [PrepGapSummary] { throw URLError(.badServerResponse) }
    func gap(id: String) async throws -> PrepGapDetail { throw URLError(.badServerResponse) }
    func flag(item: String) async throws { throw URLError(.badServerResponse) }
    func course() async throws -> PrepCourse { throw URLError(.badServerResponse) }
    func lesson(id: String) async throws -> PrepLesson { throw URLError(.badServerResponse) }
    func stories() async throws -> PrepStoryList { throw URLError(.badServerResponse) }
    func storyCandidate(id: String, action: String) async throws { throw URLError(.badServerResponse) }
    func override(attempt: String, point: String) async throws -> PrepAttemptResult { throw URLError(.badServerResponse) }
}

/// `GET /api/tutor/mocks` after a graded D1, as the server's routes return it (Task 13), plus a level
/// with no minutes and a junk recent element that must be dropped.
private let mocksJSON = #"""
{"ladders": {
  "behavioral": {"level": "B1", "unlocked": ["B1"], "best": null,
                 "levels": [{"level": "B1", "title": "One story", "minutes": 6},
                            {"level": "B2", "title": "Two probes", "minutes": null}],
                 "last_score": null},
  "design": {"level": "D2", "unlocked": ["D1", "D2"], "best": "D1",
             "levels": [{"level": "D1", "title": "Requirements", "minutes": 8},
                        {"level": "D2", "title": "Through architecture", "minutes": 15}], "last_score": 4.0}},
 "recent": [
  {"mock_id": "b-started", "kind": "behavioral", "level": "B1", "status": "started", "score": null,
   "dims": {}, "misses": [], "hits": [], "ttft_p50_ms": null, "ts": "2026-10-18T14:41:59.485006-04:00"},
  "junk",
  {"mock_id": "d-graded", "kind": "design", "level": "D1", "status": "graded", "score": 4.0,
   "dims": {"requirements": 5.0, "communication": 3.0},
   "misses": [
     {"concept": "frame-concept-3", "quote": "", "why": "No scale or cost ceiling.", "point": "Frame point 3"},
     {"concept": "frame-concept-4", "quote": "", "why": "", "point": "Frame point 4"},
     {"concept": null, "quote": "", "why": "Long pauses.", "point": "communication"}],
   "hits": [
     {"concept": "frame-concept-1", "quote": "who are the users", "point": "Frame point 1"},
     {"concept": "frame-concept-2", "quote": "Non-goals: no write access.", "point": "Frame point 2"},
     {"concept": "state-requirements-before-architecture", "quote": "who are the users", "point": "requirements"}],
   "ttft_p50_ms": 900, "ts": "2026-10-18T14:41:59.484389-04:00"}]}
"""#

private func decodeMocks(_ json: String) throws -> PrepMocks {
    try PrepDecoding.decode(PrepMocks.self, from: Data(json.utf8))
}

private func mocks(status: String, score: Double? = nil) throws -> PrepMocks {
    let scoreJSON = score.map { "\($0)" } ?? "null"
    return try decodeMocks("""
    {"ladders": {}, "recent": [{"mock_id": "m1", "kind": "design", "level": "D1", "status": "\(status)",
      "score": \(scoreJSON), "dims": {}, "misses": [], "hits": [], "ttft_p50_ms": null}]}
    """)
}

private let designStart = PrepMockStart(
    mockID: "m1", level: "D1", brief: "[mock brief] System design mock D1", profile: "interviewer", title: "Requirements")

@MainActor
final class PrepMockTests: APIClientTestCase {
    // MARK: Decoding

    func testDecodesMocksView() throws {
        let view = try decodeMocks(mocksJSON)

        let design = try XCTUnwrap(view.ladders["design"])
        XCTAssertEqual(design.level, "D2")
        XCTAssertEqual(design.unlocked, ["D1", "D2"])
        XCTAssertEqual(design.best, "D1")
        XCTAssertEqual(design.lastScore, 4.0)
        XCTAssertEqual(design.levels.map(\.title), ["Requirements", "Through architecture"])
        XCTAssertEqual(design.current?.minutes, 15)

        let behavioral = try XCTUnwrap(view.ladder(.behavioral))
        XCTAssertNil(behavioral.best)
        XCTAssertNil(behavioral.lastScore)
        XCTAssertEqual(behavioral.levels[1].minutes, 0, "a null minutes decodes as 0")

        XCTAssertEqual(view.recent.map(\.mockID), ["b-started", "d-graded"], "the junk element is dropped")
        let graded = view.recent[1]
        XCTAssertEqual(graded.status, "graded")
        XCTAssertEqual(graded.score, 4.0)
        XCTAssertEqual(graded.dims["requirements"], 5.0)
        XCTAssertEqual(graded.misses.count, 3)
        XCTAssertNil(graded.misses[2].concept)
        XCTAssertEqual(graded.misses[0].point, "Frame point 3")
        XCTAssertEqual(graded.misses[0].why, "No scale or cost ceiling.")
        XCTAssertEqual(graded.hits.map(\.quote), ["who are the users", "Non-goals: no write access.", "who are the users"])
        XCTAssertEqual(graded.ttftP50MS, 900)
        XCTAssertNil(view.recent[0].score)
        XCTAssertEqual(view.recent(for: .design).map(\.mockID), ["d-graded"])
    }

    func testDecodesMockStart() throws {
        let start = try PrepDecoding.decode(PrepMockStart.self, from: Data(#"""
        {"mock_id": "e779", "level": "D1", "brief": "[mock brief] System design mock D1",
         "profile": "interviewer", "title": "Requirements"}
        """#.utf8))
        XCTAssertEqual(start, PrepMockStart(mockID: "e779", level: "D1", brief: "[mock brief] System design mock D1",
                                            profile: "interviewer", title: "Requirements"))
    }

    // MARK: Starting

    func testMockStartWithoutProfileShowsCopy() async {
        let client = FakeMockClient()
        client.startResult = .failure(APIError.http(statusCode: 409, body: #"{"error": "no_interviewer_profile"}"#))
        let viewModel = PrepMockViewModel(client: client)

        let start = await viewModel.start(kind: .design)

        XCTAssertNil(start)
        XCTAssertEqual(viewModel.errorMessage, "Interviewer isn't set up on this server.")
    }

    func testStartHandsBriefToOpener() async {
        let client = FakeMockClient()
        client.startResult = .success(designStart)
        let viewModel = PrepMockViewModel(client: client)
        let opener = OpenMockCallAction()
        var opened: [PrepMockStart] = []
        opener.handler = { opened.append($0) }

        await viewModel.startCall(kind: .design, open: opener)

        XCTAssertEqual(client.log, ["start:design"])
        XCTAssertEqual(opened, [designStart])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isStarting)
    }

    func testFailedStartOpensNothing() async {
        let client = FakeMockClient()
        let viewModel = PrepMockViewModel(client: client)
        let opener = OpenMockCallAction()
        var opened: [PrepMockStart] = []
        opener.handler = { opened.append($0) }

        await viewModel.startCall(kind: .behavioral, open: opener)

        XCTAssertTrue(opened.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: The call's end

    func testGradePostedOnceOnCallEndWithMockID() async {
        var call = MockCallState(mockID: "m1", openingTurn: "[mock brief] B1")
        XCTAssertEqual(call.openingTurn, "[mock brief] B1")

        let first = call.callEnded(sessionID: "sess-1", turnMS: [900, 300])
        let second = call.callEnded(sessionID: "sess-1", turnMS: [500])

        let grade = MockCallGrade(mockID: "m1", sessionID: "sess-1", turnMS: [900, 300])
        XCTAssertEqual(first, MockCallEnd(mockID: "m1", grade: grade))
        XCTAssertNil(second, "a second call on the same chat is an ordinary call")
        XCTAssertNil(call.openingTurn, "the brief opens only the mock's own call")

        let client = FakeMockClient()
        try? await grade.post(to: client)
        XCTAssertEqual(client.log, ["grade:m1"])
        XCTAssertEqual(client.grades.first?.sessionID, "sess-1")
        XCTAssertEqual(client.grades.first?.turnMS, [900, 300])
    }

    func testNoGradePostWithoutMockID() {
        var plain = MockCallState(mockID: nil, openingTurn: nil)
        XCTAssertNil(plain.callEnded(sessionID: "sess-1", turnMS: [900]))

        var noSession = MockCallState(mockID: "m1", openingTurn: "brief")
        XCTAssertEqual(noSession.callEnded(sessionID: "  ", turnMS: [900]), MockCallEnd(mockID: "m1", grade: nil))
    }

    func testNoGradeWhenTheInterviewerNeverAnswered() {
        var call = MockCallState(mockID: "m1", openingTurn: "brief")
        XCTAssertEqual(call.callEnded(sessionID: "sess-1", turnMS: []), MockCallEnd(mockID: "m1", grade: nil),
                       "the end still reports, so the profile switches back, but nothing is graded")
    }

    func testGradeRequestBody() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/tutor/mock/grade")
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["mock_id"] as? String, "m1")
            XCTAssertEqual(body["session_id"] as? String, "sess-1")
            XCTAssertEqual(body["turn_ms"] as? [Int], [900, 300])
            return apiTestJSONResponse(#"{"status": "grading"}"#, for: request, status: 202)
        }
        try await APIClientPrepAdapter(apiClient: client).mockGrade(mockID: "m1", sessionID: "sess-1", turnMS: [900, 300])
    }

    // MARK: The result

    func testResultShowsGradingUntilGraded() async throws {
        let client = FakeMockClient()
        client.mocksResults = [.success(try mocks(status: "grading")), .success(try mocks(status: "graded", score: 4.5))]
        let viewModel = PrepMockViewModel(client: client)

        await viewModel.load()
        XCTAssertEqual(PrepMockCopy.display(viewModel.result(mockID: "m1")), .grading)
        XCTAssertEqual(PrepMockCopy.grading, "Grading your mock…")

        await viewModel.load()
        guard case .graded(let result) = PrepMockCopy.display(viewModel.result(mockID: "m1")) else {
            return XCTFail("expected the graded result")
        }
        XCTAssertEqual(result.score, 4.5)
        XCTAssertEqual(client.log, ["mocks", "mocks"])
    }

    func testResultStatesForUngradedAndTooShort() throws {
        XCTAssertEqual(PrepMockCopy.display(try mocks(status: "ungraded").recent.first), .ungraded)
        XCTAssertEqual(PrepMockCopy.display(try mocks(status: "too_short").recent.first), .tooShort)
        XCTAssertEqual(PrepMockCopy.display(try mocks(status: "started").recent.first), .notSent)
        XCTAssertEqual(PrepMockCopy.display(nil), .notFound)
        XCTAssertEqual(PrepMockCopy.notFound, "Couldn't find this mock")
        XCTAssertEqual(PrepMockCopy.ungraded, "Couldn't grade, saved for tonight")
        XCTAssertEqual(PrepMockCopy.tooShort, "Too short to grade")
    }

    func testRowTitleAndNextLevel() throws {
        let view = try decodeMocks(mocksJSON)
        let behavioral = try XCTUnwrap(view.ladder(.behavioral))
        XCTAssertEqual(PrepMockCopy.rowTitle(.behavioral, ladder: behavioral), "Behavioral · B1 One story")
        let design = try XCTUnwrap(view.ladder(.design))
        XCTAssertEqual(PrepMockCopy.rowTitle(.design, ladder: design), "System design · D2 Through architecture")
        XCTAssertEqual(PrepMockCopy.next(after: "D1", in: design), "Next: D2 Through architecture")
        XCTAssertNil(PrepMockCopy.next(after: "D2", in: design))
        XCTAssertEqual(PrepMockCopy.firstWord(900), "First word in 0.9 s (median)")
    }

    // MARK: The brief's start

    func testStartCallShowsWhyTheProfileSwitchFailed() async {
        let client = FakeMockClient()
        client.startResult = .success(designStart)
        let viewModel = PrepMockViewModel(client: client)
        let opener = OpenMockCallAction()
        opener.handler = { _ in throw PrepMockProfileError(detail: "unknown profile") }

        await viewModel.startCall(kind: .design, open: opener)

        XCTAssertEqual(viewModel.errorMessage, "Couldn't switch to the interviewer profile: unknown profile")
        XCTAssertFalse(viewModel.isStarting)
    }

    func testSendForGradingPostsAndReloads() async throws {
        let client = FakeMockClient()
        client.mocksResults = [.success(try mocks(status: "grading"))]
        let viewModel = PrepMockViewModel(client: client)

        await viewModel.sendForGrading(MockCallGrade(mockID: "m1", sessionID: "sess-1", turnMS: [700]))

        XCTAssertEqual(client.log, ["grade:m1", "mocks"])
        XCTAssertEqual(PrepMockCopy.display(viewModel.result(mockID: "m1")), .grading)
    }

    func testSectionShowsOnlyWithLadders() throws {
        XCTAssertFalse(PrepMockSection.isShown(nil))
        XCTAssertFalse(PrepMockSection.isShown(try decodeMocks(#"{"ladders": {}, "recent": []}"#)))
        XCTAssertTrue(PrepMockSection.isShown(try decodeMocks(mocksJSON)))
    }

    // MARK: The interviewer profile

    private func makeStore() -> PrepMockReturnStore {
        let name = "PrepMockTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return PrepMockReturnStore(serverID: "https://example.test", defaults: defaults)
    }

    func testEnterSavesThePreviousProfileAndSwitches() async throws {
        let paths = MockRequestLog()
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(#"{"active": "default", "profiles": [{"name": "default"}, {"name": "interviewer"}]}"#,
                                           for: request)
            case "/api/profile/switch":
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["name"] as? String, "interviewer")
                return apiTestJSONResponse(#"{"active": "interviewer"}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }
        let store = makeStore()

        try await PrepMockProfile(client: client, store: store).enter("interviewer")

        XCTAssertEqual(store.profile, "default")
        XCTAssertEqual(paths.values, ["/api/profiles", "/api/profile/switch"])
    }

    func testReturnProfileIsKeyedByServerNotURL() {
        let store = makeStore()
        store.save("default")
        let other = PrepMockReturnStore(serverID: "https://other.test", defaults: store.defaults)
        XCTAssertNil(other.profile)
        XCTAssertFalse(store.defaults.dictionaryRepresentation().keys.contains { $0.contains("example.test") },
                       "the server's address never lands in UserDefaults")
    }

    func testEnterWhenAlreadyActiveSwitchesNothing() async throws {
        let paths = MockRequestLog()
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            return apiTestJSONResponse(#"{"active": "interviewer"}"#, for: request)
        }
        let store = makeStore()

        try await PrepMockProfile(client: client, store: store).enter("interviewer")
        XCTAssertNil(store.profile)
        XCTAssertEqual(paths.values, ["/api/profiles"])

        try await PrepMockProfile(client: client, store: store).enter("interviewer", fallback: "default")
        XCTAssertEqual(store.profile, "default", "a server left on the interviewer still goes back to the drawer's profile")
    }

    func testEnterKeepsAnEarlierSavedProfile() async throws {
        let client = makeClient { request in apiTestJSONResponse(#"{"active": "interviewer"}"#, for: request) }
        let store = makeStore()
        store.save("work")

        try await PrepMockProfile(client: client, store: store).enter("interviewer", fallback: "default")

        XCTAssertEqual(store.profile, "work")
    }

    func testEnterThrowsOnASwitchErrorAndSavesNothing() async {
        let client = makeClient { request in
            if request.url?.path == "/api/profiles" { return apiTestJSONResponse(#"{"active": "default"}"#, for: request) }
            return apiTestJSONResponse(#"{"error": "Profile not found"}"#, for: request)
        }
        let store = makeStore()

        do {
            try await PrepMockProfile(client: client, store: store).enter("interviewer")
            XCTFail("a refused switch must not open the call")
        } catch {
            XCTAssertEqual(error as? PrepMockProfileError, PrepMockProfileError(detail: "Profile not found"))
        }
        XCTAssertNil(store.profile)
    }

    func testLeaveSwitchesBackAndForgets() async {
        let paths = MockRequestLog()
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["name"] as? String, "default")
            return apiTestJSONResponse(#"{"active": "default"}"#, for: request)
        }
        let store = makeStore()
        let profile = PrepMockProfile(client: client, store: store)
        store.save("default")

        let first = await profile.leave()
        let second = await profile.leave()

        XCTAssertTrue(first)
        XCTAssertFalse(second, "nothing saved, nothing to switch")
        XCTAssertNil(store.profile)
        XCTAssertEqual(paths.values, ["/api/profile/switch"])
    }

    func testFailedLeaveIsRetriedLater() async {
        let offline = MockRequestLog()
        offline.append("offline")
        let client = makeClient { request in
            if !offline.values.isEmpty { throw URLError(.notConnectedToInternet) }
            return apiTestJSONResponse(#"{"active": "default"}"#, for: request)
        }
        let store = makeStore()
        let profile = PrepMockProfile(client: client, store: store)
        store.save("default")

        let failed = await profile.leave()
        XCTAssertFalse(failed)
        XCTAssertEqual(store.profile, "default", "kept for the next launch or foreground")

        offline.clear()
        let recovered = await profile.leave()
        XCTAssertTrue(recovered)
        XCTAssertNil(store.profile)
    }

    func testRefusedLeaveForgets() async {
        let client = makeClient { request in apiTestJSONResponse(#"{"error": "gone"}"#, for: request, status: 404) }
        let store = makeStore()
        store.save("deleted")

        let switched = await PrepMockProfile(client: client, store: store).leave()

        XCTAssertFalse(switched)
        XCTAssertNil(store.profile, "a profile the server refuses is never retried")
    }

    // MARK: Finishing the call

    private func finisher(log: FinishLog, gradeFailures: Int = 0, stillOnMockChat: Bool = true) -> PrepMockCallFinisher {
        var failures = gradeFailures
        return PrepMockCallFinisher(
            leave: { log.append("leave") },
            postGrade: { grade in
                log.append("grade:\(grade.mockID)")
                if failures > 0 {
                    failures -= 1
                    throw URLError(.timedOut)
                }
            },
            isStillOnMockChat: { stillOnMockChat },
            replaceRoot: { log.append("root") },
            show: { log.shown = $0; log.append("show") },
            pause: { log.append("pause:\($0)") }
        )
    }

    func testFinishSwitchesBackThenReplacesTheChatThenShowsTheResult() async {
        let log = FinishLog()
        let grade = MockCallGrade(mockID: "m1", sessionID: "sess-1", turnMS: [900])

        await finisher(log: log).finish(MockCallEnd(mockID: "m1", grade: grade))

        XCTAssertEqual(log.events, ["leave", "grade:m1", "root", "show"])
        XCTAssertEqual(log.shown, [.home, .mockResult("m1", unsent: nil)])
    }

    func testFinishRetriesTheGradeTwice() async {
        let log = FinishLog()
        let grade = MockCallGrade(mockID: "m1", sessionID: "sess-1", turnMS: [900])

        await finisher(log: log, gradeFailures: 2).finish(MockCallEnd(mockID: "m1", grade: grade))

        XCTAssertEqual(log.events, ["leave", "grade:m1", "pause:1", "grade:m1", "pause:2", "grade:m1", "root", "show"])
        XCTAssertEqual(log.shown, [.home, .mockResult("m1", unsent: nil)])
    }

    func testFinishCarriesAGradeThatNeverGotThrough() async {
        let log = FinishLog()
        let grade = MockCallGrade(mockID: "m1", sessionID: "sess-1", turnMS: [900])

        await finisher(log: log, gradeFailures: 3).finish(MockCallEnd(mockID: "m1", grade: grade))

        XCTAssertEqual(log.events.filter { $0 == "grade:m1" }.count, 3)
        XCTAssertEqual(log.shown, [.home, .mockResult("m1", unsent: grade)])
    }

    func testFinishWithNothingToGradeShowsPrepHome() async {
        let log = FinishLog()

        await finisher(log: log).finish(MockCallEnd(mockID: "m1", grade: nil))

        XCTAssertEqual(log.events, ["leave", "root", "show"])
        XCTAssertEqual(log.shown, [.home])
    }

    func testFinishAfterLeavingTheChatOnlySwitchesBack() async {
        let log = FinishLog()
        let grade = MockCallGrade(mockID: "m1", sessionID: "sess-1", turnMS: [900])

        await finisher(log: log, stillOnMockChat: false).finish(MockCallEnd(mockID: "m1", grade: grade))

        XCTAssertEqual(log.events, ["leave", "grade:m1"])
        XCTAssertNil(log.shown)
    }
}

@MainActor
private final class FinishLog {
    var events: [String] = []
    var shown: [PrepRoute]?

    func append(_ event: String) { events.append(event) }
}

private final class MockRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) { lock.withLock { paths.append(path) } }
    func clear() { lock.withLock { paths.removeAll() } }
    var values: [String] { lock.withLock { paths } }
}
