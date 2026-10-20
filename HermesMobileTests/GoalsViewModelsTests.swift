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
    /// Per-item gates for overlapping check-ins: the call signals `started` with its id, waits
    /// on its own release, then answers with its own result.
    var started: AsyncStream<String>.Continuation?
    var perItem: [String: (release: AsyncStream<Void>, result: Result<GoalCheckInResult, Error>)] = [:]

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
    func confirmWeek(_ r: GoalWeekRequest) async throws -> GoalCheckInResult { throw URLError(.unsupportedURL) }
    func finish(_ r: GoalFinishRequest) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func record(slug: String) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func saveReflection(_ r: GoalReflectionRequest) async throws -> GoalRecord { throw URLError(.unsupportedURL) }

    func checkIn(_ r: GoalCheckInRequest) async throws -> GoalCheckInResult {
        lock.withLock { _checkIns.append(r) }
        let id: String
        switch r {
        case .commitment(_, _, _, let c, _), .check(_, _, _, let c, _), .item(_, _, _, let c, _, _): id = c
        }
        if let item = lock.withLock({ perItem[id] }) {
            started?.yield(id)
            for await _ in item.release { break }
            lock.withLock { _log.append("checkIn") }
            return try item.result.get()
        }
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

/// The detail fixture with tonight's stretch already done and the foot marked worse today.
private func checkedDetail() throws -> GoalDetail {
    var goal = try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.detailJSON().utf8)) as! [String: Any]
    var week = goal["week"] as! [String: Any]
    var commitments = week["commitments"] as! [[String: Any]]
    commitments[0]["today"] = "done"
    commitments[0]["done"] = 1
    commitments[0]["remaining"] = 5
    week["commitments"] = commitments
    goal["week"] = week
    var checks = goal["daily_checks"] as! [[String: Any]]
    checks[0]["today"] = "worse"
    goal["daily_checks"] = checks
    return try PrepDecoding.decode(GoalDetail.self, from: JSONSerialization.data(withJSONObject: goal))
}

/// The detail fixture with commitment `index`'s fields replaced.
private func detail(commitment index: Int, _ fields: [String: Any]) throws -> GoalDetail {
    var goal = try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.detailJSON().utf8)) as! [String: Any]
    var week = goal["week"] as! [String: Any]
    var commitments = week["commitments"] as! [[String: Any]]
    commitments[index].merge(fields) { $1 }
    week["commitments"] = commitments
    goal["week"] = week
    return try PrepDecoding.decode(GoalDetail.self, from: JSONSerialization.data(withJSONObject: goal))
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
        XCTAssertFalse(vm.offersNewGoal)
    }

    func testNewGoalIsOfferedOnceGoalsLoadEvenWithNone() async throws {
        let client = FakeGoalsClient()
        client.homeResults = [.success(try PrepDecoding.decode(GoalsHome.self, from: Data(#"{"today":"2026-10-15"}"#.utf8)))]
        let vm = GoalsHomeViewModel(client: client)
        XCTAssertFalse(vm.offersNewGoal)
        await vm.load()
        XCTAssertTrue(vm.offersNewGoal)
    }

    func testNewGoalDraftNamesTheInterviewSkill() {
        XCTAssertTrue(GoalsCopy.newGoalDraft.contains("goal-interview"))
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
            .commitment(slug: "nyc-marathon-2026", date: "2026-10-12", asOf: "2026-10-13", id: "stretch-pm", status: .done),
            .commitment(slug: "nyc-marathon-2026", date: "2026-10-13", asOf: "2026-10-13", id: "stretch-pm", status: .min),
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
        // The optimistic 1 gives way to the server: its reloaded detail reports 0.
        XCTAssertEqual(stretch(vm)?.done, 0)
        XCTAssertFalse(vm.pending.contains("stretch-pm"))
        guard case .loaded(let d) = vm.state else { return XCTFail("not loaded") }
        XCTAssertEqual(d.streak.days, 1)
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
        XCTAssertEqual(vm.error, "The day changed. Check in again.")
        // The reload replaces the optimistic tap with the server's state.
        XCTAssertNil(stretch(vm)?.today)
        XCTAssertEqual(stretch(vm)?.done, 0)
        XCTAssertTrue(vm.pending.isEmpty)
    }

    func testSuccessReloadsDetailSoHistoryIsFresh() async throws {
        let client = FakeGoalsClient()
        client.checkInResults = [.success(try result(done: 1, today: "done"))]
        let vm = try await loadedViewModel(client)
        await vm.checkIn(commitment: "stretch-pm", status: .done)
        XCTAssertEqual(client.log, ["detail:nyc-marathon-2026", "checkIn", "detail:nyc-marathon-2026"])
    }

    func testClearIsOptimisticAndPostsClear() async throws {
        let client = FakeGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.detailResults = [.success(try checkedDetail())]
        client.checkInResults = [.success(try result(done: 0, today: "done"))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        vm.day = .today
        let tap = Task { await vm.checkIn(commitment: "stretch-pm", status: .clear) }
        for await _ in started { break }
        XCTAssertNil(stretch(vm)?.today)
        XCTAssertEqual(stretch(vm)?.done, 0)
        XCTAssertEqual(stretch(vm)?.remaining, 6)
        releaseCont.yield()
        await tap.value
        XCTAssertEqual(client.checkIns, [
            .commitment(slug: "nyc-marathon-2026", date: "2026-10-13", asOf: "2026-10-13", id: "stretch-pm", status: .clear),
        ])
    }

    func testClearFailureRestoresTheCheck() async throws {
        let client = FakeGoalsClient()
        client.detailResults = [.success(try checkedDetail())]
        client.checkInResults = [.failure(URLError(.notConnectedToInternet))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        vm.day = .today
        await vm.checkIn(commitment: "stretch-pm", status: .clear)
        XCTAssertEqual(stretch(vm)?.today, .done)
        XCTAssertEqual(stretch(vm)?.done, 1)
        XCTAssertEqual(vm.error, "Couldn't save. Try again.")
    }

    func testClearDailyCheck() async throws {
        let client = FakeGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.detailResults = [.success(try checkedDetail())]
        client.checkInResults = [.success(try result(done: 1, today: "done"))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        vm.day = .today
        let tap = Task { await vm.checkIn(check: "foot", value: GoalCheckValue.clear) }
        for await _ in started { break }
        guard case .loaded(let d) = vm.state else { return XCTFail("not loaded") }
        XCTAssertNil(d.summary.dailyChecks.first?.today)
        releaseCont.yield()
        await tap.value
        XCTAssertEqual(client.checkIns, [.check(slug: "nyc-marathon-2026", date: "2026-10-13", asOf: "2026-10-13", id: "foot", value: "clear")])
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

    func testFailedCheckInRollsBackOnlyItself() async throws {
        let client = FakeGoalsClient()
        let (started, startedCont) = AsyncStream<String>.makeStream()
        let (releaseA, releaseACont) = AsyncStream<Void>.makeStream()
        let (releaseB, releaseBCont) = AsyncStream<Void>.makeStream()
        client.started = startedCont
        client.perItem = [
            "stretch-pm": (releaseA, .failure(URLError(.notConnectedToInternet))),
            "long-run": (releaseB, .success(try result(done: 0, today: "done"))),
        ]
        // The reload after the run's check-in reports it saved.
        client.detailResults = [.success(try detail()),
                                .success(try detail(commitment: 1, ["today": "done", "done": 1, "remaining": 0, "hit": true]))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        vm.day = .today
        var calls = started.makeAsyncIterator()
        let a = Task { await vm.checkIn(commitment: "stretch-pm", status: .done) }
        _ = await calls.next()
        let b = Task { await vm.checkIn(commitment: "long-run", status: .done) }
        _ = await calls.next()
        releaseBCont.yield()
        await b.value
        releaseACont.yield()
        await a.value
        guard case .loaded(let d) = vm.state else { return XCTFail("not loaded") }
        let run = d.summary.week.commitments.first { $0.id == "long-run" }
        XCTAssertEqual(run?.today, .done)
        XCTAssertEqual(run?.done, 1)
        XCTAssertNil(stretch(vm)?.today)
        XCTAssertEqual(stretch(vm)?.done, 0)
        XCTAssertEqual(vm.error, "Couldn't save. Try again.")
    }

    func testOverrideSourceDayThenClear() async throws {
        let client = FakeGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        // Prep counted today (the 13th) as done; the reload after the override reports the miss.
        let source: [String: Any] = ["source": "prep.days", "source_days": ["2026-10-13"], "done": 1, "remaining": 5]
        client.detailResults = [
            .success(try detail(commitment: 0, source)),
            .success(try detail(commitment: 0, source.merging(["today": "miss", "done": 0, "missed": 1]) { $1 })),
        ]
        client.checkInResults = [.success(try result(done: 0, today: "miss"))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        vm.day = .today
        XCTAssertEqual(stretch(vm)?.done, 1)
        let override = Task { await vm.checkIn(commitment: "stretch-pm", status: .miss) }
        for await _ in started { break }
        XCTAssertEqual(stretch(vm)?.today, .miss)
        XCTAssertEqual(stretch(vm)?.done, 0, "the override takes the day back from the source")
        XCTAssertEqual(stretch(vm)?.missed, 1)
        releaseCont.yield()
        await override.value
        client.gate = nil
        await vm.checkIn(commitment: "stretch-pm", status: .clear)
        XCTAssertEqual(client.checkIns, [
            .commitment(slug: "nyc-marathon-2026", date: "2026-10-13", asOf: "2026-10-13", id: "stretch-pm", status: .miss),
            .commitment(slug: "nyc-marathon-2026", date: "2026-10-13", asOf: "2026-10-13", id: "stretch-pm", status: .clear),
        ])
    }

    func testAddAndRemoveItemUseTheSelectedDay() async throws {
        let client = FakeGoalsClient()
        let item: [String: Any] = ["unit": "item", "target": 5, "done": 1,
                                   "items": [["date": "2026-10-12", "note": "Acme"]]]
        client.detailResults = [.success(try detail(commitment: 0, item))]
        client.checkInResults = [.success(try result(done: 1, today: "done"))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        vm.day = .yesterday
        await vm.addItem(commitment: "stretch-pm", note: "Anthropic")
        await vm.removeLastItem(commitment: "stretch-pm")
        XCTAssertEqual(client.checkIns, [
            .item(slug: "nyc-marathon-2026", date: "2026-10-12", asOf: "2026-10-13", id: "stretch-pm", n: 1, note: "Anthropic"),
            .item(slug: "nyc-marathon-2026", date: "2026-10-12", asOf: "2026-10-13", id: "stretch-pm", n: -1, note: nil),
        ])
    }

    func testClearingAnOverBudgetSkipMovesMissed() async throws {
        let client = FakeGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        // One skip allowed; yesterday's skip used it, so today's counted as a miss.
        client.detailResults = [.success(try detail(commitment: 0, ["today": "skip", "yesterday": "skip", "skipped": 1, "missed": 1]))]
        client.checkInResults = [.success(try result(done: 0, today: "done"))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        vm.day = .today
        let tap = Task { await vm.checkIn(commitment: "stretch-pm", status: .clear) }
        for await _ in started { break }
        XCTAssertNil(stretch(vm)?.today)
        XCTAssertEqual(stretch(vm)?.skipped, 1)
        XCTAssertEqual(stretch(vm)?.missed, 0)
        releaseCont.yield()
        await tap.value
    }

    func testClearingABudgetedSkipKeepsMisses() async throws {
        let client = FakeGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.detailResults = [.success(try detail(commitment: 0, ["today": "skip", "yesterday": "miss", "skipped": 1, "missed": 1]))]
        client.checkInResults = [.success(try result(done: 0, today: "done"))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        vm.day = .today
        let tap = Task { await vm.checkIn(commitment: "stretch-pm", status: .clear) }
        for await _ in started { break }
        XCTAssertEqual(stretch(vm)?.skipped, 0)
        XCTAssertEqual(stretch(vm)?.missed, 1)
        releaseCont.yield()
        await tap.value
    }

    func testFailedReloadKeepsTheLoadedGoal() async throws {
        let client = FakeGoalsClient()
        client.detailResults = [.success(try detail()), .failure(URLError(.timedOut))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        await vm.load()
        XCTAssertEqual(stretch(vm)?.id, "stretch-pm")
        XCTAssertEqual(vm.error, GoalDetailViewModel.refreshFailed)
    }

    func testFirstLoadFailureShowsTheError() async {
        let client = FakeGoalsClient()
        client.detailResults = [.failure(URLError(.timedOut))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        guard case .failed = vm.state else { return XCTFail("expected failed, got \(vm.state)") }
    }

    func testFailedHomeReloadKeepsTheLoadedHome() async throws {
        let client = FakeGoalsClient()
        let home = try PrepDecoding.decode(GoalsHome.self, from: Data(GoalsModelsTests.homeSample.utf8))
        client.homeResults = [.success(home), .failure(URLError(.timedOut))]
        let vm = GoalsHomeViewModel(client: client)
        await vm.load()
        await vm.load()
        XCTAssertEqual(vm.state, .loaded(home))
    }

    func testCheckValuePostsCheckShape() async throws {
        let client = FakeGoalsClient()
        client.checkInResults = [.success(try result(done: 0, today: "done"))]
        let vm = try await loadedViewModel(client)
        vm.day = .today
        await vm.checkIn(check: "foot", value: "worse")
        XCTAssertEqual(client.checkIns, [.check(slug: "nyc-marathon-2026", date: "2026-10-13", asOf: "2026-10-13", id: "foot", value: "worse")])
    }
}

final class GoalsCopyTests: XCTestCase {
    func testShortNameAndWeekLine() throws {
        XCTAssertEqual(GoalsCopy.shortName("Nightly stretch (knee hugs, figure-4 twists, open books)"), "Stretch")
        XCTAssertEqual(GoalsCopy.shortName("Saturday taper run (~12 mi easy)"), "Run")
        let home = try PrepDecoding.decode(GoalsHome.self, from: Data(GoalsModelsTests.homeSample.utf8))
        XCTAssertEqual(GoalsCopy.weekLine(home.goals[0].week.commitments), "Stretch 0/6 · Run 0/1")
    }

    func testItemRowCopy() throws {
        let row = try PrepDecoding.decode(GoalCommitmentProgress.self, from: Data(("""
            {"id":"outreach","action":"Outreach","target":5,"done":4,"unit":"item","items":[
            {"date":"2026-10-12","note":"A"},{"date":"2026-10-12"},{"date":"2026-10-13","note":"B"},
            {"date":"2026-10-13","note":"C"},{"date":"2026-10-14","note":"D"}]}
            """).utf8))
        XCTAssertEqual(GoalItemCopy.countLine(row), "4 of 5 this week")
        XCTAssertEqual(GoalItemCopy.noteLine(row), "D · C · B", "the three latest notes, newest first")
        XCTAssertEqual(GoalItemCopy.spoken(row), "Outreach, 4 of 5 this week")
        XCTAssertNil(GoalItemCopy.noteLine(try PrepDecoding.decode(GoalCommitmentProgress.self, from: Data(#"{"id":"x","unit":"item"}"#.utf8))))
    }

    func testRelativeDay() {
        XCTAssertEqual(GoalsCopy.relativeDay("2026-10-17", today: "2026-10-10"), "in 7 days")
        XCTAssertEqual(GoalsCopy.relativeDay("2026-10-11", today: "2026-10-10"), "tomorrow")
        XCTAssertEqual(GoalsCopy.relativeDay("2026-10-08", today: "2026-10-10"), "2 days ago")
    }

    func testShortTitleDropsParenthetical() {
        XCTAssertEqual(GoalsCopy.shortTitle("Nightly stretch (knee hugs, figure-4 twists, open books)"), "Nightly stretch")
        XCTAssertEqual(GoalsCopy.shortTitle("Finish the NYC Marathon, uninjured"), "Finish the NYC Marathon, uninjured")
    }

    func testCheckTitleAndWeekSummary() throws {
        XCTAssertEqual(GoalDetailCopy.checkTitle("Foot today: better, same, or worse?"), "Foot today")
        let home = try PrepDecoding.decode(GoalsHome.self, from: Data(GoalsModelsTests.homeSample.utf8))
        XCTAssertEqual(GoalHeroCopy.weekSummary(home.goals[0].week.commitments), "Stretch 0/6 · Run 0/1 · 1 skip left")
        XCTAssertEqual(GoalHeroCopy.countdown(home.goals[0]), "22 days · Sun Nov 1")
    }

    func testSourceErrorsLine() {
        XCTAssertNil(GoalDetailCopy.sourceErrors([]))
        XCTAssertEqual(GoalDetailCopy.sourceErrors(["prep.days: attempts file not found"]),
                       "Couldn't count Prep: attempts file not found")
        XCTAssertEqual(GoalDetailCopy.sourceErrors(["foo.bar: unknown source"]),
                       "Couldn't count foo.bar: unknown source")
        XCTAssertEqual(GoalDetailCopy.sourceErrors(["prep.days: down", "garmin.sleep: no file"]),
                       "Couldn't count Prep: down\nCouldn't count garmin.sleep: no file")
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
