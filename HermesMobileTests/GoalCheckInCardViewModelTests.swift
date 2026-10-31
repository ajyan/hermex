import XCTest
import Foundation
@testable import HermesMobile

/// A scripted Goals API for the Daily Deck's goal card: queued home and check-in results, and an
/// optional gate that holds a check-in until released.
private final class FakeCardGoalsClient: GoalsDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _checkIns: [GoalCheckInRequest] = []

    var homeResults: [Result<GoalsHome, Error>] = []
    var checkInResults: [Result<GoalCheckInResult, Error>] = []
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
    func detail(slug: String) async throws -> GoalDetail { throw URLError(.unsupportedURL) }
    func finish(_ r: GoalFinishRequest) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func record(slug: String) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func reopen(slug: String) async throws -> GoalDetail { throw URLError(.unsupportedURL) }
    func saveReflection(_ r: GoalReflectionRequest) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func confirmWeek(_ r: GoalWeekRequest) async throws -> GoalCheckInResult { throw URLError(.unsupportedURL) }

    func checkIn(_ r: GoalCheckInRequest, clientID: String) async throws -> GoalCheckInResult {
        lock.withLock { _checkIns.append(r) }
        if let gate {
            gate.started.yield()
            for await _ in gate.release { break }
        }
        return try next("checkIn", &checkInResults)
    }
}

/// The Goals home fixture on Wednesday Oct 14 (yesterday inside the week), with edits to its goal.
private func homeJSON(today: String = "2026-10-14", yesterday: String = "2026-10-13",
                      commitments: [Int: [String: Any]] = [:]) throws -> [String: Any] {
    var home = try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.homeSample.utf8)) as! [String: Any]
    home["today"] = today
    home["yesterday"] = yesterday
    var goal = (home["goals"] as! [[String: Any]])[0]
    var week = goal["week"] as! [String: Any]
    var rows = week["commitments"] as! [[String: Any]]
    // An item row (Outreach, 2 of 5) and a day row the Prep source counts (yesterday's the 13th).
    rows.append(["id": "outreach", "action": "Outreach", "target": 5, "skips": 0, "cue": "", "minimum": "",
                 "done": 2, "min": 0, "skipped": 0, "missed": 0, "hit": false, "remaining": 3,
                 "due_today": true, "due_yesterday": false, "unit": "item",
                 "items": [["date": "2026-10-13", "note": "Acme"], ["date": "2026-10-14"]]])
    rows.append(["id": "prep", "action": "Prep session", "target": 5, "skips": 0, "cue": "", "minimum": "",
                 "done": 1, "min": 0, "skipped": 0, "missed": 0, "hit": false, "remaining": 4,
                 "due_today": false, "due_yesterday": false, "unit": "day", "source": "prep.days",
                 "source_days": ["2026-10-13"]])
    for (i, fields) in commitments { rows[i].merge(fields) { $1 } }
    week["commitments"] = rows
    goal["week"] = week
    home["goals"] = [goal]
    return home
}

private func home(_ json: [String: Any]) throws -> GoalsHome {
    try PrepDecoding.decode(GoalsHome.self, from: JSONSerialization.data(withJSONObject: json))
}

/// A check-in answer whose outreach row reports `done` items.
private func itemResult(done: Int) throws -> GoalCheckInResult {
    let json = try homeJSON(commitments: [2: ["done": done]])
    let body: [String: Any] = ["goal": (json["goals"] as! [[String: Any]])[0], "streak": ["days": 5, "at_risk": false],
                               "today": "2026-10-14", "yesterday": "2026-10-13"]
    return try PrepDecoding.decode(GoalCheckInResult.self, from: JSONSerialization.data(withJSONObject: body))
}

/// A check-in answer whose stretch row reports `done` and yesterday's status.
private func result(done: Int, yesterday: String?) throws -> GoalCheckInResult {
    let json = try homeJSON(commitments: [0: ["done": done, "yesterday": yesterday as Any]])
    let body: [String: Any] = ["goal": (json["goals"] as! [[String: Any]])[0], "streak": ["days": 5, "at_risk": false],
                               "today": "2026-10-14", "yesterday": "2026-10-13"]
    return try PrepDecoding.decode(GoalCheckInResult.self, from: JSONSerialization.data(withJSONObject: body))
}

private func card(goals: [String]) throws -> DeckCard {
    let json: [String: Any] = ["id": "goal", "type": "goal", "goals": goals, "fallback": "Nightly stretch 2/6"]
    return try JSONDecoder().decode(DeckCard.self, from: JSONSerialization.data(withJSONObject: json))
}

@MainActor
final class GoalCheckInCardViewModelTests: XCTestCase {
    private let slug = "nyc-marathon-2026"

    private func loaded(_ client: FakeCardGoalsClient, _ json: [String: Any]? = nil) async throws -> GoalCheckInCardViewModel {
        client.homeResults = [.success(try home(json ?? homeJSON()))]
        let vm = GoalCheckInCardViewModel(client: client)
        await vm.load()
        return vm
    }

    private func stretch(_ vm: GoalCheckInCardViewModel) -> GoalCommitmentProgress? {
        guard case .loaded(let h) = vm.state else { return nil }
        return h.goals.first?.week.commitments.first { $0.id == "stretch-pm" }
    }

    func testGoalsFilterToCardSlugs() async throws {
        let vm = try await loaded(FakeCardGoalsClient())
        XCTAssertEqual(vm.goals(for: try card(goals: [slug, "gone"])).map(\.slug), [slug])
        XCTAssertEqual(vm.goals(for: try card(goals: ["gone"])), [])
    }

    func testYesterdayRowsIncludeUnscheduledAndCheckedOnly() throws {
        // Wednesday: the Saturday run wasn't due yesterday and has no check-in, so only the stretch shows.
        var goal = try home(homeJSON()).goals[0]
        XCTAssertEqual(GoalCheckInCardViewModel.yesterdayRows(goal).map(\.id), ["stretch-pm"])
        goal = try home(homeJSON(commitments: [1: ["yesterday": "done"]])).goals[0]
        XCTAssertEqual(GoalCheckInCardViewModel.yesterdayRows(goal).map(\.id), ["stretch-pm", "long-run"])
        XCTAssertEqual(GoalCheckInCardViewModel.todayCues(goal).map(\.id), ["stretch-pm", "long-run"])
    }

    private func outreach(_ vm: GoalCheckInCardViewModel) -> GoalCommitmentProgress? {
        guard case .loaded(let h) = vm.state else { return nil }
        return h.goals.first?.week.commitments.first { $0.id == "outreach" }
    }

    func testItemRowsAreNotYesterdayRows() throws {
        // Outreach was "due" yesterday and has a check-in, which would list it among yesterday's
        // rows if items weren't excluded; they get their own This week list instead.
        let goal = try home(homeJSON(commitments: [2: ["due_yesterday": true, "yesterday": "done"]])).goals[0]
        XCTAssertEqual(GoalCheckInCardViewModel.yesterdayRows(goal).map(\.id), ["stretch-pm"])
        XCTAssertEqual(GoalCheckInCardViewModel.itemRows(goal).map(\.id), ["outreach"])
    }

    func testAddItemPostsTodayAndCountsOptimistically() async throws {
        let client = FakeCardGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInResults = [.success(try itemResult(done: 3))]
        let vm = try await loaded(client)
        let tap = Task { await vm.addItem(slug: slug, commitment: "outreach", note: "Anthropic") }
        for await _ in started { break }
        XCTAssertEqual(outreach(vm)?.done, 3)
        XCTAssertEqual(outreach(vm)?.items.last?.note, "Anthropic")
        XCTAssertTrue(vm.isPending(slug, .commitment("outreach")))
        releaseCont.yield()
        await tap.value
        XCTAssertEqual(client.checkIns, [
            .item(slug: slug, date: "2026-10-14", asOf: "2026-10-14", id: "outreach", n: 1, note: "Anthropic"),
        ])
        XCTAssertTrue(vm.pending.isEmpty)
        XCTAssertNil(vm.error)
    }

    func testDoubleAddWhilePendingSendsOnce() async throws {
        let client = FakeCardGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInResults = [.success(try itemResult(done: 3))]
        let vm = try await loaded(client)
        let first = Task { await vm.addItem(slug: slug, commitment: "outreach", note: nil) }
        for await _ in started { break }
        await vm.addItem(slug: slug, commitment: "outreach", note: "again")
        releaseCont.yield()
        await first.value
        XCTAssertEqual(client.checkIns.count, 1)
    }

    func testRemoveLastFailureRollsBack() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(APIError.http(statusCode: 400, body: nil))]
        let vm = try await loaded(client)
        await vm.removeLastItem(slug: slug, commitment: "outreach")
        XCTAssertEqual(client.checkIns, [
            .item(slug: slug, date: "2026-10-14", asOf: "2026-10-14", id: "outreach", n: -1, note: nil),
        ])
        XCTAssertEqual(outreach(vm)?.done, 2)
        XCTAssertEqual(outreach(vm)?.items.count, 2)
        XCTAssertEqual(vm.error, "Couldn't save. Try again.")
        XCTAssertTrue(vm.pending.isEmpty)
    }

    func testCheckInPostsYesterdayWithServerTodayAndShowsAtOnce() async throws {
        let client = FakeCardGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInResults = [.success(try result(done: 3, yesterday: "done"))]
        let vm = try await loaded(client)
        let tap = Task { await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done) }
        for await _ in started { break }
        XCTAssertEqual(stretch(vm)?.yesterday, .done)
        XCTAssertEqual(stretch(vm)?.done, 1)
        XCTAssertTrue(vm.isPending(slug, .commitment("stretch-pm")))
        releaseCont.yield()
        await tap.value
        XCTAssertEqual(client.checkIns, [
            .commitment(slug: slug, date: "2026-10-13", asOf: "2026-10-14", id: "stretch-pm", status: .done),
        ])
        XCTAssertEqual(stretch(vm)?.done, 3, "the server's summary replaces the optimistic one")
        guard case .loaded(let h) = vm.state else { return XCTFail("not loaded") }
        XCTAssertEqual(h.streak.days, 5)
        XCTAssertTrue(vm.pending.isEmpty)
        XCTAssertNil(vm.error)
    }

    func testMondayYesterdayOutsideWeekLeavesCounts() async throws {
        let client = FakeCardGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInResults = [.success(try result(done: 0, yesterday: "done"))]
        let vm = try await loaded(client, homeJSON(today: "2026-10-12", yesterday: "2026-10-11"))
        let tap = Task { await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done) }
        for await _ in started { break }
        XCTAssertEqual(stretch(vm)?.yesterday, .done)
        XCTAssertEqual(stretch(vm)?.done, 0, "last Sunday doesn't count toward this week")
        releaseCont.yield()
        await tap.value
        XCTAssertEqual(client.checkIns.first,
                       .commitment(slug: slug, date: "2026-10-11", asOf: "2026-10-12", id: "stretch-pm", status: .done))
    }

    func testCheckValuePostsTodayOptimistically() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(URLError(.notConnectedToInternet))]
        let vm = try await loaded(client)
        await vm.checkIn(slug: slug, check: "foot", value: "same")
        XCTAssertEqual(client.checkIns, [.check(slug: slug, date: "2026-10-14", asOf: "2026-10-14", id: "foot", value: "same")])
        guard case .loaded(let h) = vm.state else { return XCTFail("not loaded") }
        XCTAssertNil(h.goals[0].dailyChecks[0].today, "a failed answer rolls back")
        XCTAssertEqual(vm.error, "Couldn't save. Try again.")
    }

    func testFailureRollsBackOnlyThatItem() async throws {
        let client = FakeCardGoalsClient()
        let json = try homeJSON(commitments: [1: ["yesterday": "done", "done": 1]])
        client.checkInResults = [.failure(URLError(.timedOut))]
        let vm = try await loaded(client, json)
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done)
        XCTAssertNil(stretch(vm)?.yesterday)
        XCTAssertEqual(stretch(vm)?.done, 0)
        guard case .loaded(let h) = vm.state else { return XCTFail("not loaded") }
        XCTAssertEqual(h.goals[0].week.commitments[1].yesterday, .done, "the other row keeps its check-in")
        XCTAssertEqual(vm.error, "Couldn't save. Try again.")
        XCTAssertTrue(vm.pending.isEmpty)
    }

    func testConflictReloadsAndSaysDayChanged() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(APIError.http(statusCode: 409, body: nil))]
        let vm = try await loaded(client)
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done)
        XCTAssertEqual(client.log, ["home", "checkIn", "home"])
        XCTAssertEqual(vm.error, "The day changed. Check in again.")
        XCTAssertNil(stretch(vm)?.yesterday)
    }

    func testConflictWithFailedReloadUndoesTheTap() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(APIError.http(statusCode: 409, body: nil))]
        let vm = try await loaded(client)
        client.homeResults = [.failure(URLError(.notConnectedToInternet))]
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done)
        XCTAssertNil(stretch(vm)?.yesterday, "nothing was saved, so nothing shows as saved")
        XCTAssertEqual(stretch(vm)?.done, 0)
        XCTAssertEqual(vm.error, "The day changed. Check in again.")
    }

    func testSavedCheckInHandsTheServersHomeOn() async throws {
        let client = FakeCardGoalsClient()
        client.homeResults = [.success(try home(homeJSON()))]
        client.checkInResults = [.success(try result(done: 3, yesterday: "done"))]
        var handed: [GoalsHome] = []
        let vm = GoalCheckInCardViewModel(client: client, onChange: { handed.append($0) })
        await vm.load()
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done)
        XCTAssertEqual(handed.count, 1)
        XCTAssertEqual(handed.first?.goals.first?.week.commitments.first?.done, 3)
        XCTAssertEqual(handed.first?.streak.days, 5)

        client.checkInResults = [.failure(URLError(.timedOut))]
        await vm.checkIn(slug: slug, check: "foot", value: "same")
        XCTAssertEqual(handed.count, 1, "a failed check-in hands nothing on")
    }

    func testACommitmentAndACheckSharingAnIdStayApart() async throws {
        let client = FakeCardGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInResults = [.success(try result(done: 1, yesterday: "done"))]
        let vm = try await loaded(client, homeJSON(commitments: [0: ["id": "foot"]]))
        let row = Task { await vm.checkIn(slug: slug, commitment: "foot", status: .done) }
        for await _ in started { break }
        XCTAssertTrue(vm.isPending(slug, .commitment("foot")))
        XCTAssertFalse(vm.isPending(slug, .check("foot")), "the check with the same id stays free")
        releaseCont.yield()
        await row.value
    }

    func testLiveOnlyForTheServersToday() async throws {
        let vm = try await loaded(FakeCardGoalsClient())
        XCTAssertTrue(vm.isLive(for: "2026-10-14"))
        XCTAssertFalse(vm.isLive(for: "2026-10-13"), "an older deck shows its own text, not today's check-ins")
        XCTAssertFalse(GoalCheckInCardViewModel(client: FakeCardGoalsClient()).isLive(for: "2026-10-14"))
    }

    func testHome404IsUnavailable() async {
        let client = FakeCardGoalsClient()
        client.homeResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let vm = GoalCheckInCardViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    func testFailedReloadKeepsTheLoadedGoals() async throws {
        let client = FakeCardGoalsClient()
        let vm = try await loaded(client)
        client.homeResults = [.failure(URLError(.timedOut))]
        await vm.load()
        guard case .loaded = vm.state else { return XCTFail("a failed reload dropped the card's goals") }
    }
}
