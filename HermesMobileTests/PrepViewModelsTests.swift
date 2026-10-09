import XCTest
import Foundation
@testable import HermesMobile

private final class FakePrepClient: PrepDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _attempts: [PrepAttemptRequest] = []

    var homeResults: [Result<PrepHome, Error>] = []
    var todayResults: [Result<PrepRun, Error>] = []
    var mapResults: [Result<PrepTrackMap, Error>] = []
    var attemptResults: [Result<PrepAttemptResult, Error>] = []

    /// When set, `attempt` signals `started` and then waits on `release`.
    var gate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

    var log: [String] { lock.withLock { _log } }
    var attempts: [PrepAttemptRequest] { lock.withLock { _attempts } }

    private func next<T>(_ name: String, _ queue: inout [Result<T, Error>]) throws -> T {
        lock.lock(); defer { lock.unlock() }
        _log.append(name)
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        return try (queue.count > 1 ? queue.removeFirst() : queue[0]).get()
    }

    func home() async throws -> PrepHome { try next("home", &homeResults) }
    func today() async throws -> PrepRun { try next("today", &todayResults) }
    func map(track: String) async throws -> PrepTrackMap { try next("map:\(track)", &mapResults) }

    func attempt(_ r: PrepAttemptRequest) async throws -> PrepAttemptResult {
        lock.withLock { _attempts.append(r) }
        if let gate {
            gate.started.yield()
            for await _ in gate.release { break }
        }
        return try next("attempt", &attemptResults)
    }
}

@MainActor
final class PrepViewModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! PrepDecoding.decode(type, from: Data(json.utf8))
    }

    private func rep(_ index: Int, drill: String = "pattern_id", extra: String = "") -> String {
        #"{"index": \#(index), "block": "new", "drill": "\#(drill)", "item": {"id": "dsa.\#(index)", "hints": ["h1", "h2"]\#(extra)}}"#
    }

    private func run(index: Int, reps: [String], date: String = "2026-10-09") -> PrepRun {
        decode(PrepRun.self, #"{"date": "\#(date)", "index": \#(index), "reps": [\#(reps.joined(separator: ","))]}"#)
    }

    private func result(next: Int, streak: Bool = true) -> PrepAttemptResult {
        decode(PrepAttemptResult.self, #"{"verdict": "correct", "credit": 1.0, "next_index": \#(next)\#(streak ? #", "streak": {"days": 3, "freezes": 1}"# : "")}"#)
    }

    private func map(_ mastery: [(String, Double)]) -> PrepTrackMap {
        let skills = mastery.map { #"{"id": "\#($0.0)", "title": "\#($0.0)", "state": "in_progress", "mastery": \#($0.1)}"# }
        return decode(PrepTrackMap.self, #"{"track": "dsa", "title": "DSA", "levels": [{"title": "L1", "skills": [\#(skills.joined(separator: ","))]}]}"#)
    }

    private func http(_ code: Int) -> APIError { .http(statusCode: code, body: "") }

    private func makeVM(_ client: FakePrepClient, clock: @escaping () -> Date = Date.init) -> PrepRunViewModel {
        PrepRunViewModel(client: client, now: clock)
    }

    private func currentRep(_ vm: PrepRunViewModel) -> PrepRep? {
        if case let .rep(rep, _) = vm.phase { return rep }
        return nil
    }

    // MARK: Home / track

    func testHome404IsUnavailable() async {
        let client = FakePrepClient()
        client.homeResults = [.failure(http(404))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    func testHomeOtherErrorFails() async {
        let client = FakePrepClient()
        client.homeResults = [.failure(http(500))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        if case .failed = vm.state {} else { XCTFail("expected failed, got \(vm.state)") }
    }

    func testTrackLoadsAndMaps404() async {
        let client = FakePrepClient()
        client.mapResults = [.success(map([("a", 0.1)]))]
        let vm = PrepTrackViewModel(track: "dsa", client: client)
        await vm.load()
        XCTAssertEqual(client.log, ["map:dsa"])
        if case .loaded = vm.state {} else { XCTFail("expected loaded") }
        client.mapResults = [.failure(http(404))]
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    // MARK: Run

    func testRunStartsAtServerIndex() async {
        let client = FakePrepClient()
        // Stable indices have gaps: the server's index 4 is the first unanswered rep.
        client.todayResults = [.success(run(index: 4, reps: [rep(0), rep(4), rep(7)]))]
        client.mapResults = [.success(map([("a", 0.1)]))]
        let vm = makeVM(client)
        await vm.load()
        guard case let .rep(rep, index) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(rep.index, 4)
        XCTAssertEqual(index, 4)
        XCTAssertEqual(client.log, ["today", "map:dsa"])
    }

    func testRun404IsUnavailable() async {
        let client = FakePrepClient()
        client.todayResults = [.failure(http(404))]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertEqual(vm.phase, .unavailable)
    }

    func testChoosePostsElapsedAndHints() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 2, reps: [rep(2)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 3))]
        var t = Date(timeIntervalSince1970: 1_000)
        let vm = makeVM(client, clock: { t })
        await vm.load()
        vm.showHint()
        vm.showHint()
        vm.showHint() // capped at hints.count
        XCTAssertEqual(vm.hintsShown, 2)
        t = t.addingTimeInterval(8.25)
        await vm.choose(.choice("dsa.stack"))
        let sent = try! XCTUnwrap(client.attempts.first)
        XCTAssertEqual(sent.index, 2)
        XCTAssertEqual(sent.item, "dsa.2")
        XCTAssertEqual(sent.drill, .patternID)
        XCTAssertEqual(sent.date, "2026-10-09")
        XCTAssertEqual(sent.answer, .choice("dsa.stack"))
        XCTAssertEqual(sent.elapsedMS, 8250)
        XCTAssertEqual(sent.hintsUsed, 2)
        if case .result = vm.phase {} else { XCTFail("phase \(vm.phase)") }
    }

    func testContinueFollowsNextIndexAndFinishes() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0), rep(3), rep(5)]))]
        client.mapResults = [.success(map([("a", 0.1)]))]
        client.attemptResults = [.success(result(next: 1)), .success(result(next: 4)), .success(result(next: 6))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("x"))
        await vm.continue()
        XCTAssertEqual(currentRep(vm)?.index, 3, "next_index 1 lands on the first rep with index >= 1")
        await vm.choose(.choice("x"))
        await vm.continue()
        XCTAssertEqual(currentRep(vm)?.index, 5)
        await vm.choose(.choice("x"))
        await vm.continue()
        guard case let .finished(streak, moved) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(streak.days, 3)
        XCTAssertEqual(moved, [])
        XCTAssertEqual(client.attempts.map(\.index), [0, 3, 5])
    }

    func testSubmitFailureKeepsAnswerAndDoesNotAdvance() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "parsons", extra: #", "lines": ["a", "b"]"#)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(URLError(.notConnectedToInternet)), .success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        vm.place(poolIndex: 0)
        await vm.checkParsons()
        XCTAssertEqual(vm.submitError, "Couldn't save. Try again.")
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertEqual(vm.board?.placed, ["a"])
        XCTAssertEqual(currentRep(vm)?.index, 0)
        // Retrying works and clears the error.
        await vm.checkParsons()
        XCTAssertNil(vm.submitError)
        XCTAssertEqual(client.attempts.last?.answer, .lines(["a"]))
        if case .result = vm.phase {} else { XCTFail("phase \(vm.phase)") }
    }

    func testDoubleSubmitPostsOnce() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        let vm = makeVM(client)
        await vm.load()
        let first = Task { await vm.choose(.choice("a")) }
        for await _ in started { break }
        XCTAssertTrue(vm.isSubmitting)
        await vm.choose(.choice("b"))
        releaseCont.yield()
        await first.value
        XCTAssertEqual(client.attempts.count, 1)
        XCTAssertEqual(client.attempts.first?.answer, .choice("a"))
    }

    func testConflictReloadsRun() async {
        let client = FakePrepClient()
        client.todayResults = [
            .success(run(index: 0, reps: [rep(0)], date: "2026-10-08")),
            .success(run(index: 2, reps: [rep(0), rep(2)], date: "2026-10-09")),
        ]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(http(409))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        XCTAssertNil(vm.submitError)
        XCTAssertEqual(vm.run?.date, "2026-10-09")
        XCTAssertEqual(currentRep(vm)?.index, 2)
    }

    func testFinishedComputesMovedSkills() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [
            .success(map([("a", 0.1), ("b", 0.5), ("c", 0.9)])),
            .success(map([("a", 0.1), ("b", 0.7), ("c", 1.0)])),
        ]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        await vm.continue()
        guard case let .finished(_, moved) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(moved.map(\.id), ["b", "c"])
        XCTAssertEqual(client.log, ["today", "map:dsa", "attempt", "map:dsa"])
    }

    func testFinishedMovedEmptyWhenMapFetchFails() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([("a", 0.1)])), .failure(http(500))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        await vm.continue()
        guard case let .finished(_, moved) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(moved, [])
    }

    func testPrimerAcknowledgePostsSeen() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "primer")]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.acknowledgePrimer()
        XCTAssertEqual(client.attempts.first?.answer, .choice("seen"))
        XCTAssertEqual(client.attempts.first?.hintsUsed, 0)
        XCTAssertEqual(client.attempts.first?.drill, .primer)
    }

    func testParsonsRepBuildsBoardFromLines() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "parsons", extra: #", "lines": ["x", "x", "y"]"#)]))]
        client.mapResults = [.success(map([]))]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertEqual(vm.board?.pool, ["x", "x", "y"])
    }

    // MARK: Parsons board

    func testParsonsBoardDuplicatesTrackedByIndex() {
        var board = ParsonsBoard(pool: ["x", "x", "y"])
        board.place(poolIndex: 1)
        XCTAssertEqual(board.placed, ["x"])
        XCTAssertEqual(board.remaining, [0, 2])
        board.place(poolIndex: 1) // already placed: ignored
        XCTAssertEqual(board.placed, ["x"])
        board.place(poolIndex: 0)
        XCTAssertEqual(board.placed, ["x", "x"])
        XCTAssertEqual(board.remaining, [2])
        XCTAssertFalse(board.isFull(target: 3))
        board.place(poolIndex: 2)
        XCTAssertTrue(board.isFull(target: 3))
    }

    func testParsonsBoardUnplaceReturnsLineToPool() {
        var board = ParsonsBoard(pool: ["a", "b", "c"])
        board.place(poolIndex: 2)
        board.place(poolIndex: 0)
        board.unplace(at: 0)
        XCTAssertEqual(board.placed, ["a"])
        XCTAssertEqual(board.remaining, [1, 2])
        board.unplace(at: 5) // out of range: ignored
        XCTAssertEqual(board.placed, ["a"])
    }
}
