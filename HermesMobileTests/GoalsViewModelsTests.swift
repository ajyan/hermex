import XCTest
import Foundation
@testable import HermesMobile

private final class FakeGoalsClient: GoalsDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _checkIns: [GoalCheckInRequest] = []

    var homeResults: [Result<GoalsHome, Error>] = []
    var detailResults: [Result<GoalDetail, Error>] = []
    var checkInResults: [Result<GoalCheckInResult, Error>] = []

    /// When set, `checkIn` signals `started` and then waits on `release`.
    var gate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

    var log: [String] { lock.withLock { _log } }
    var checkIns: [GoalCheckInRequest] { lock.withLock { _checkIns } }

    private func next<T>(_ name: String, _ queue: inout [Result<T, Error>]) throws -> T {
        lock.lock(); defer { lock.unlock() }
        _log.append(name)
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        return try (queue.count > 1 ? queue.removeFirst() : queue[0]).get()
    }

    func home() async throws -> GoalsHome { try next("home", &homeResults) }
    func detail(slug: String) async throws -> GoalDetail { try next("detail:\(slug)", &detailResults) }

    func checkIn(_ r: GoalCheckInRequest) async throws -> GoalCheckInResult {
        lock.withLock { _checkIns.append(r) }
        if let gate {
            gate.started.yield()
            for await _ in gate.release { break }
        }
        return try next("checkIn", &checkInResults)
    }
}

private func detail() throws -> GoalDetail {
    try PrepDecoding.decode(GoalDetail.self, from: Data(GoalsModelsTests.detailJSON().utf8))
}

/// A check-in response whose first commitment reports `done` completions and `today` status.
private func result(done: Int, today: String) throws -> GoalCheckInResult {
    let home = try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.homeSample.utf8)) as! [String: Any]
    var goal = (home["goals"] as! [[String: Any]])[0]
    var week = goal["week"] as! [String: Any]
    var commitments = week["commitments"] as! [[String: Any]]
    commitments[0]["done"] = done
    commitments[0]["today"] = today
    week["commitments"] = commitments
    goal["week"] = week
    let body: [String: Any] = ["goal": goal, "streak": ["days": 4, "at_risk": false],
                               "today": "2026-10-13", "yesterday": "2026-10-12"]
    return try PrepDecoding.decode(GoalCheckInResult.self, from: JSONSerialization.data(withJSONObject: body))
}

@MainActor
final class GoalsViewModelsTests: XCTestCase {
    private func loadedViewModel(_ client: FakeGoalsClient) async throws -> GoalDetailViewModel {
        client.detailResults = [.success(try detail())]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        return vm
    }

    private func stretch(_ vm: GoalDetailViewModel) -> GoalCommitmentProgress? {
        guard case .loaded(let d) = vm.state else { return nil }
        return d.summary.week.commitments.first { $0.id == "stretch-pm" }
    }

    func testHome404IsUnavailable() async {
        let client = FakeGoalsClient()
        client.homeResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let vm = GoalsHomeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    func testCheckInSendsServerDates() async throws {
        let client = FakeGoalsClient()
        client.checkInResults = [.success(try result(done: 1, today: "done"))]
        let vm = try await loadedViewModel(client)
        vm.day = .yesterday
        await vm.checkIn(commitment: "stretch-pm", status: .done)
        vm.day = .today
        await vm.checkIn(commitment: "stretch-pm", status: .min)
        XCTAssertEqual(client.checkIns, [
            .commitment(slug: "nyc-marathon-2026", date: "2026-10-12", id: "stretch-pm", status: .done),
            .commitment(slug: "nyc-marathon-2026", date: "2026-10-13", id: "stretch-pm", status: .min),
        ])
    }

    func testOptimisticUpdateThenServerSummaryWins() async throws {
        let client = FakeGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInResults = [.success(try result(done: 3, today: "done"))]
        let vm = try await loadedViewModel(client)
        let tap = Task { await vm.checkIn(commitment: "stretch-pm", status: .done) }
        for await _ in started { break }
        XCTAssertEqual(stretch(vm)?.today, .done)
        XCTAssertEqual(stretch(vm)?.done, 1)
        XCTAssertEqual(stretch(vm)?.remaining, 5)
        XCTAssertTrue(vm.pending.contains("stretch-pm"))
        releaseCont.yield()
        await tap.value
        XCTAssertEqual(stretch(vm)?.done, 3)
        XCTAssertFalse(vm.pending.contains("stretch-pm"))
        guard case .loaded(let d) = vm.state else { return XCTFail("not loaded") }
        XCTAssertEqual(d.streak.days, 4)
    }

    func testFailureRollsBackAndSetsError() async throws {
        let client = FakeGoalsClient()
        client.checkInResults = [.failure(URLError(.notConnectedToInternet))]
        let vm = try await loadedViewModel(client)
        await vm.checkIn(commitment: "stretch-pm", status: .done)
        XCTAssertNil(stretch(vm)?.today)
        XCTAssertEqual(stretch(vm)?.done, 0)
        XCTAssertEqual(vm.error, "Couldn't save. Try again.")
        XCTAssertTrue(vm.pending.isEmpty)
    }

    func testConflictReloads() async throws {
        let client = FakeGoalsClient()
        client.checkInResults = [.failure(APIError.http(statusCode: 409, body: nil))]
        let vm = try await loadedViewModel(client)
        await vm.checkIn(commitment: "stretch-pm", status: .done)
        XCTAssertEqual(client.log, ["detail:nyc-marathon-2026", "checkIn", "detail:nyc-marathon-2026"])
        XCTAssertNil(vm.error)
    }

    func testDoubleTapPostsOnce() async throws {
        let client = FakeGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInResults = [.success(try result(done: 1, today: "done"))]
        let vm = try await loadedViewModel(client)
        let first = Task { await vm.checkIn(commitment: "stretch-pm", status: .done) }
        for await _ in started { break }
        await vm.checkIn(commitment: "stretch-pm", status: .miss)
        releaseCont.yield()
        await first.value
        XCTAssertEqual(client.checkIns.count, 1)
    }

    func testCheckValuePostsCheckShape() async throws {
        let client = FakeGoalsClient()
        client.checkInResults = [.success(try result(done: 0, today: "done"))]
        let vm = try await loadedViewModel(client)
        vm.day = .today
        await vm.checkIn(check: "foot", value: "worse")
        XCTAssertEqual(client.checkIns, [.check(slug: "nyc-marathon-2026", date: "2026-10-13", id: "foot", value: "worse")])
    }
}

final class GoalsCopyTests: XCTestCase {
    func testShortNameAndWeekLine() throws {
        XCTAssertEqual(GoalsCopy.shortName("Nightly stretch (knee hugs, figure-4 twists, open books)"), "Stretch")
        XCTAssertEqual(GoalsCopy.shortName("Saturday taper run (~12 mi easy)"), "Run")
        let home = try PrepDecoding.decode(GoalsHome.self, from: Data(GoalsModelsTests.homeSample.utf8))
        XCTAssertEqual(GoalsCopy.weekLine(home.goals[0].week.commitments), "Stretch 0/6 · Run 0/1")
    }

    func testToCheckInCountsOnlyYesterdaysDueCommitments() throws {
        let home = try PrepDecoding.decode(GoalsHome.self, from: Data(GoalsModelsTests.homeSample.utf8))
        // stretch-pm is due yesterday with no check-in; long-run isn't due yesterday.
        XCTAssertEqual(GoalsCopy.toCheckIn(home), 1)
        XCTAssertEqual(GoalsCopy.brainRowSubtitle(home), "0-day streak · 1 to check in")
    }

    func testRelativeDay() {
        XCTAssertEqual(GoalsCopy.relativeDay("2026-10-17", today: "2026-10-10"), "in 7 days")
        XCTAssertEqual(GoalsCopy.relativeDay("2026-10-11", today: "2026-10-10"), "tomorrow")
        XCTAssertEqual(GoalsCopy.relativeDay("2026-10-08", today: "2026-10-10"), "2 days ago")
    }

    func testHeatmapColumnsStartOnMonday() {
        // 2026-10-10 is a Saturday: five blank cells, then Sat, Sun; then Mon starts a new column.
        let days = ["2026-10-10", "2026-10-11", "2026-10-12"].map {
            try! PrepDecoding.decode(GoalHeatDay.self, from: Data(#"{"date":"\#($0)","status":"done"}"#.utf8))
        }
        let columns = GoalDetailCopy.heatmapColumns(days)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].prefix(5).compactMap { $0 }.count, 0)
        XCTAssertEqual(columns[0][5], .done)
        XCTAssertEqual(columns[1][0], .done)
    }

    func testSkipDisabledWhenBudgetSpentUnlessAlreadySkipped() throws {
        var row = try PrepDecoding.decode(GoalCommitmentProgress.self, from: Data(#"{"id":"x","skips":1,"skipped":1}"#.utf8))
        XCTAssertTrue(GoalDetailCopy.skipDisabled(row, selected: nil))
        XCTAssertFalse(GoalDetailCopy.skipDisabled(row, selected: .skip))
        row.skipped = 0
        XCTAssertFalse(GoalDetailCopy.skipDisabled(row, selected: nil))
        XCTAssertEqual(GoalDetailCopy.countLine(row), "0/0 · 1 skip left")
    }
}
