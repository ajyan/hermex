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

/// A check-in answer whose outreach row reports `done` items (and that many, when `listed`).
private func itemResult(done: Int, listed: Bool = false) throws -> GoalCheckInResult {
    let items = (0..<done).map { _ in ["date": "2026-10-14"] }
    let json = try homeJSON(commitments: [2: listed ? ["done": done, "items": items] : ["done": done]])
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

    private func loaded(_ client: FakeCardGoalsClient, _ json: [String: Any]? = nil) async throws -> GoalsHomeViewModel {
        client.homeResults = [.success(try home(json ?? homeJSON()))]
        let vm = GoalsHomeViewModel(client: client)
        await vm.load()
        return vm
    }

    private func stretch(_ vm: GoalsHomeViewModel) -> GoalCommitmentProgress? {
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
        XCTAssertEqual(GoalsHomeViewModel.yesterdayRows(goal).map(\.id), ["stretch-pm"])
        goal = try home(homeJSON(commitments: [1: ["yesterday": "done"]])).goals[0]
        XCTAssertEqual(GoalsHomeViewModel.yesterdayRows(goal).map(\.id), ["stretch-pm", "long-run"])
        XCTAssertEqual(GoalsHomeViewModel.todayCues(goal).map(\.id), ["stretch-pm", "long-run"])
    }

    func testTodayRowsAreDayRowsDueOrCheckedToday() throws {
        // Wednesday: the stretch and the run are due; Prep isn't, and Outreach counts by +1.
        var goal = try home(homeJSON()).goals[0]
        XCTAssertEqual(GoalsHomeViewModel.todayRows(goal).map(\.id), ["stretch-pm", "long-run"])
        goal = try home(homeJSON(commitments: [1: ["due_today": false], 3: ["today": "done"]])).goals[0]
        XCTAssertEqual(GoalsHomeViewModel.todayRows(goal).map(\.id), ["stretch-pm", "prep"],
                       "a row checked in today stays so it can be cleared")
    }

    private func outreach(_ vm: GoalsHomeViewModel) -> GoalCommitmentProgress? {
        guard case .loaded(let h) = vm.state else { return nil }
        return h.goals.first?.week.commitments.first { $0.id == "outreach" }
    }

    func testItemRowsAreNotYesterdayRows() throws {
        // Outreach was "due" yesterday and has a check-in, which would list it among yesterday's
        // rows if items weren't excluded; they get their own This week list instead.
        let goal = try home(homeJSON(commitments: [2: ["due_yesterday": true, "yesterday": "done"]])).goals[0]
        XCTAssertEqual(GoalsHomeViewModel.yesterdayRows(goal).map(\.id), ["stretch-pm"])
        XCTAssertEqual(GoalsHomeViewModel.itemRows(goal).map(\.id), ["outreach"])
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
        let tap = Task { await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .yesterday) }
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
        let tap = Task { await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .yesterday) }
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
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .yesterday)
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
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .yesterday)
        XCTAssertEqual(client.log, ["home", "checkIn", "home"])
        XCTAssertEqual(vm.error, "The day changed. Check in again.")
        XCTAssertNil(stretch(vm)?.yesterday)
    }

    func testConflictWithFailedReloadUndoesTheTap() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(APIError.http(statusCode: 409, body: nil))]
        let vm = try await loaded(client)
        client.homeResults = [.failure(URLError(.notConnectedToInternet))]
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .yesterday)
        XCTAssertNil(stretch(vm)?.yesterday, "nothing was saved, so nothing shows as saved")
        XCTAssertEqual(stretch(vm)?.done, 0)
        XCTAssertEqual(vm.error, "The day changed. Check in again.")
    }

    func testSavedCheckInHandsTheServersHomeOn() async throws {
        let client = FakeCardGoalsClient()
        client.homeResults = [.success(try home(homeJSON()))]
        client.checkInResults = [.success(try result(done: 3, yesterday: "done"))]
        var handed: [GoalsHome] = []
        let vm = GoalsHomeViewModel(client: client, onChange: { handed.append($0) })
        await vm.load()
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .yesterday)
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
        let row = Task { await vm.checkIn(slug: slug, commitment: "foot", status: .done, day: .yesterday) }
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
        XCTAssertFalse(GoalsHomeViewModel(client: FakeCardGoalsClient()).isLive(for: "2026-10-14"))
    }

    func testHome404IsUnavailable() async {
        let client = FakeCardGoalsClient()
        client.homeResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let vm = GoalsHomeViewModel(client: client)
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

/// Goals home's one-tap check-ins (`GoalHeroCheckIn`), through the same model as the Deck card.
@MainActor
final class GoalsHomeCheckInTests: XCTestCase {
    private let slug = "nyc-marathon-2026"

    /// Mon Oct 12 – Sun Oct 18 as the Brief draws it, on Wednesday the 14th.
    private func week(yesterday: String = "missed") -> [[String: Any]] {
        let states = ["done", yesterday, "today", "ahead", "ahead", "ahead", "ahead"]
        return states.enumerated().map { ["date": "2026-10-\(12 + $0.offset)", "state": $0.element] }
    }

    private func loaded(_ client: FakeCardGoalsClient, _ json: [String: Any]) async throws -> GoalsHomeViewModel {
        client.homeResults = [.success(try home(json))]
        let vm = GoalsHomeViewModel(client: client)
        await vm.load()
        return vm
    }

    private func stretch(_ vm: GoalsHomeViewModel) -> GoalCommitmentProgress? {
        guard case .loaded(let h) = vm.state else { return nil }
        return h.goals.first?.week.commitments.first { $0.id == "stretch-pm" }
    }

    private func todayResult(done: Int) throws -> GoalCheckInResult {
        let json = try homeJSON(commitments: [0: ["done": done, "today": "done"]])
        let body: [String: Any] = ["goal": (json["goals"] as! [[String: Any]])[0], "streak": ["days": 6, "at_risk": false],
                                   "today": "2026-10-14", "yesterday": "2026-10-13"]
        return try PrepDecoding.decode(GoalCheckInResult.self, from: JSONSerialization.data(withJSONObject: body))
    }

    func testTodayCheckInPostsTheServersTodayAndShowsAtOnce() async throws {
        let client = FakeCardGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInResults = [.success(try todayResult(done: 2))]
        var handed = 0
        client.homeResults = [.success(try home(homeJSON()))]
        let vm = GoalsHomeViewModel(client: client, onChange: { _ in handed += 1 })
        await vm.load()
        let tap = Task { await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .today) }
        for await _ in started { break }
        XCTAssertEqual(stretch(vm)?.today, .done)
        XCTAssertEqual(stretch(vm)?.done, 1)
        XCTAssertNil(stretch(vm)?.yesterday)
        releaseCont.yield()
        await tap.value
        XCTAssertEqual(client.checkIns, [
            .commitment(slug: slug, date: "2026-10-14", asOf: "2026-10-14", id: "stretch-pm", status: .done),
        ])
        XCTAssertEqual(stretch(vm)?.done, 2, "the server's summary replaces the optimistic one")
        XCTAssertEqual(handed, 1, "the widget gets the saved home")
    }

    func testTodayCheckInFailureRollsBack() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(URLError(.timedOut))]
        let vm = try await loaded(client, homeJSON())
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .today)
        XCTAssertNil(stretch(vm)?.today)
        XCTAssertEqual(stretch(vm)?.done, 0)
        XCTAssertEqual(vm.error, "Couldn't save. Try again.")
    }

    func testTodayClearAfterConflictReloadsAndSaysSo() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(APIError.http(statusCode: 409, body: nil))]
        let vm = try await loaded(client, homeJSON(commitments: [0: ["today": "done", "done": 1]]))
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .clear, day: .today)
        XCTAssertEqual(client.log, ["home", "checkIn", "home"])
        XCTAssertEqual(vm.error, "The day changed. Check in again.")
        XCTAssertEqual(stretch(vm)?.today, .done, "nothing was cleared")
    }

    func testTodayIsTappableWhileDueAndYesterdayWhileItWaits() throws {
        let tappable = { (fields: [String: Any]) throws -> Set<GoalDay> in
            let row = try home(homeJSON(commitments: [0: fields])).goals[0].week.commitments[0]
            return GoalHeroCheckIn.tappableDays(row, today: "2026-10-14", yesterday: "2026-10-13")
        }
        XCTAssertEqual(try tappable(["week_days": week()]), [.today, .yesterday], "yesterday unlogged is a ringed +")
        XCTAssertEqual(try tappable(["week_days": week(yesterday: "off")]), [.today], "a day it wasn't due stays put")
        XCTAssertEqual(try tappable(["week_days": week(), "yesterday": "skip"]), [.today, .yesterday],
                       "a check-in can be cleared")
        XCTAssertEqual(try tappable(["week_days": week(), "source": "prep.days", "source_days": ["2026-10-13"]]), [.today],
                       "a day Prep counted shows done, not waiting")
        XCTAssertEqual(try tappable(["week_days": week(), "due_today": false]), [.yesterday])
        XCTAssertEqual(try tappable(["week_days": week(), "due_today": false, "today": "min"]), [.today, .yesterday])
        XCTAssertEqual(try tappable([:]), [], "no dots from a server without week_days")
        XCTAssertEqual(try tappable(["week_days": week(), "unit": "item"]), [], "items count by +")
    }

    func testVoiceOverActionsMirrorTheDots() async throws {
        let client = FakeCardGoalsClient()
        let json = try homeJSON(commitments: [0: ["week_days": week(), "yesterday": "done"], 1: ["week_days": week(yesterday: "off")]])
        let vm = try await loaded(client, json)
        guard case .loaded(let h) = vm.state else { return XCTFail("not loaded") }
        let checkIn = GoalHeroCheckIn(slug: slug, home: h, model: vm)
        XCTAssertEqual(checkIn.actions(for: h.goals[0]).map(\.label),
                       ["Stretch done today", "Clear Stretch yesterday", "Run done today", "Add one outreach"])
    }
}

/// The instant +1 on an item row: it counts at once, then offers Add note and Undo for a few seconds.
@MainActor
final class GoalQuickItemTests: XCTestCase {
    private let slug = "nyc-marathon-2026"
    private var clock = Date(timeIntervalSince1970: 0)

    private func loaded(_ client: FakeCardGoalsClient) async throws -> GoalsHomeViewModel {
        client.homeResults = [.success(try home(homeJSON()))]
        let vm = GoalsHomeViewModel(client: client, recentItems: GoalRecentItemWindow(duration: 5, now: { self.clock }))
        await vm.load()
        return vm
    }

    private func outreach(_ vm: GoalsHomeViewModel) -> GoalCommitmentProgress? {
        guard case .loaded(let h) = vm.state else { return nil }
        return h.goals.first?.week.commitments.first { $0.id == "outreach" }
    }

    func testPlusOneThenUndoSendsMinusOneForTheSameDay() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.success(try itemResult(done: 3)), .success(try itemResult(done: 2))]
        let vm = try await loaded(client)
        await vm.addItem(slug: slug, commitment: "outreach", note: nil)
        XCTAssertEqual(vm.recentItemDate(slug: slug, commitment: "outreach"), "2026-10-14")
        await vm.undoItem(slug: slug, commitment: "outreach")
        XCTAssertEqual(client.checkIns, [
            .item(slug: slug, date: "2026-10-14", asOf: "2026-10-14", id: "outreach", n: 1, note: nil),
            .item(slug: slug, date: "2026-10-14", asOf: "2026-10-14", id: "outreach", n: -1, note: nil),
        ])
        XCTAssertEqual(outreach(vm)?.done, 2)
        XCTAssertNil(vm.recentItemDate(slug: slug, commitment: "outreach"), "Undo ends the offer")
    }

    func testFailedPlusOneRollsBackAndOffersNoUndo() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(URLError(.timedOut))]
        let vm = try await loaded(client)
        await vm.addItem(slug: slug, commitment: "outreach", note: nil)
        XCTAssertEqual(outreach(vm)?.done, 2)
        XCTAssertEqual(outreach(vm)?.items.count, 2)
        XCTAssertNil(vm.recentItemDate(slug: slug, commitment: "outreach"))
        XCTAssertEqual(vm.error, "Couldn't save. Try again.")
    }

    func testUndoAfterTheWindowIsNotOfferedAndSendsNothing() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.success(try itemResult(done: 3))]
        let vm = try await loaded(client)
        await vm.addItem(slug: slug, commitment: "outreach", note: nil)
        clock = clock.addingTimeInterval(6)
        XCTAssertNil(vm.recentItemDate(slug: slug, commitment: "outreach"))
        await vm.undoItem(slug: slug, commitment: "outreach")
        XCTAssertEqual(client.checkIns.count, 1, "only the +1 went out")
        XCTAssertEqual(outreach(vm)?.done, 3)
    }

    func testAPlusOneWithANoteOffersNoUndo() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.success(try itemResult(done: 3))]
        let vm = try await loaded(client)
        await vm.addItem(slug: slug, commitment: "outreach", note: "Anthropic")
        XCTAssertNil(vm.recentItemDate(slug: slug, commitment: "outreach"))
    }

    func testAddNoteTakesTheItemBackAndCountsItWithTheNote() async throws {
        let client = FakeCardGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.checkInResults = [.success(try itemResult(done: 3, listed: true)),
                                 .success(try itemResult(done: 2, listed: true)),
                                 .success(try itemResult(done: 3, listed: true))]
        let vm = try await loaded(client)
        await vm.addItem(slug: slug, commitment: "outreach", note: nil)
        client.gate = (startedCont, release)
        let date = try XCTUnwrap(vm.recentItems.take(GoalsHomeViewModel.key(slug, .commitment("outreach"))))
        let save = Task { await vm.noteItem(slug: slug, commitment: "outreach", date: date, note: "Acme") }
        for await _ in started { break }
        XCTAssertEqual(outreach(vm)?.done, 3, "the count holds while the item is swapped")
        XCTAssertEqual(outreach(vm)?.items.last?.note, "Acme")
        releaseCont.yield()
        releaseCont.yield()
        let outcome = await save.value
        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(Array(client.checkIns.suffix(2)), [
            .item(slug: slug, date: "2026-10-14", asOf: "2026-10-14", id: "outreach", n: -1, note: nil),
            .item(slug: slug, date: "2026-10-14", asOf: "2026-10-14", id: "outreach", n: 1, note: "Acme"),
        ])
    }

    func testAddNoteSaysWhichHalfFailed() async throws {
        let client = FakeCardGoalsClient()
        client.checkInResults = [.failure(URLError(.timedOut))]
        let vm = try await loaded(client)
        let unchanged = await vm.noteItem(slug: slug, commitment: "outreach", date: "2026-10-14", note: "Acme")
        XCTAssertEqual(unchanged, .unchanged)
        XCTAssertEqual(client.checkIns.count, 1, "no +1 after a failed -1")
        XCTAssertEqual(outreach(vm)?.done, 2)
        XCTAssertNil(outreach(vm)?.items.last?.note)

        client.checkInResults = [.success(try itemResult(done: 1)), .failure(URLError(.timedOut))]
        let removed = await vm.noteItem(slug: slug, commitment: "outreach", date: "2026-10-14", note: "Acme")
        XCTAssertEqual(removed, .removed)
        XCTAssertEqual(outreach(vm)?.done, 1, "the server took the item back")
    }
}


/// Monday's hero: each commitment's last week, with last Sunday still loggable as yesterday.
@MainActor
final class GoalsMondayLastWeekTests: XCTestCase {
    private let slug = "nyc-marathon-2026"

    /// Mon Oct 19 – Sun Oct 25, the week before Monday the 26th; Sunday unlogged.
    private func lastWeek(sunday: String = "ask") -> [String: Any] {
        let states = ["done", "done", "missed", "done", "done", "off", sunday]
        return ["target": 6, "done": 4, "hit": false,
                "days": states.enumerated().map { ["date": "2026-10-\(19 + $0.offset)", "state": $0.element] }]
    }

    /// This week, Mon Oct 26 – Sun Nov 1, on Monday the 26th.
    private func thisWeek() -> [[String: Any]] {
        let dates = ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-11-01"]
        return dates.enumerated().map { ["date": $0.element, "state": $0.offset == 0 ? "today" : "ahead"] }
    }

    private func monday(_ fields: [String: Any] = [:], today: String = "2026-10-26") throws -> GoalsHome {
        let yesterday = today == "2026-10-26" ? "2026-10-25" : "2026-10-26"
        return try home(homeJSON(today: today, yesterday: yesterday, commitments: [0: [
            "week_days": thisWeek(), "last_week": lastWeek(), "due_yesterday": true,
        ].merging(fields) { $1 }]))
    }

    func testLastWeekDecodesTolerantly() throws {
        let row = try monday().goals[0].week.commitments[0]
        XCTAssertEqual(row.lastWeek?.target, 6)
        XCTAssertEqual(row.lastWeek?.done, 4)
        XCTAssertEqual(row.lastWeek?.days.count, 7)
        XCTAssertEqual(row.lastWeek?.days.last?.state, "ask")
        let none = try home(homeJSON(commitments: [0: ["last_week": NSNull()]])).goals[0].week.commitments[0]
        XCTAssertNil(none.lastWeek, "null when the goal had no full last week")
        let junk = try home(homeJSON(commitments: [0: ["last_week": "soon"]])).goals[0].week.commitments[0]
        XCTAssertNil(junk.lastWeek, "a shape it can't read drops alone")
        let items = try home(homeJSON(commitments: [2: ["last_week": ["target": 5, "done": 3, "hit": false]]]))
        XCTAssertEqual(items.goals[0].week.commitments[2].lastWeek?.days, [], "an item row has no days")
    }

    func testLastWeekShowsOnlyOnMonday() throws {
        let row = try monday().goals[0].week.commitments[0]
        XCTAssertTrue(GoalHeroLayout.showsLastWeek(row, today: "2026-10-26"))
        XCTAssertFalse(GoalHeroLayout.showsLastWeek(row, today: "2026-10-27"), "Tuesday to Sunday it's gone")
        XCTAssertFalse(GoalHeroLayout.showsLastWeek(row, today: nil))
        var fresh = row
        fresh.lastWeek = nil
        XCTAssertFalse(GoalHeroLayout.showsLastWeek(fresh, today: "2026-10-26"), "a goal with no full last week")
        let item = try home(homeJSON(today: "2026-10-26", yesterday: "2026-10-25", commitments: [
            2: ["last_week": ["target": 5, "done": 3, "hit": false]],
        ])).goals[0].week.commitments[2]
        XCTAssertTrue(GoalHeroLayout.showsLastWeek(item, today: "2026-10-26"), "an item row reads Monday from the date")
        XCTAssertFalse(GoalHeroLayout.showsLastWeek(item, today: "2026-10-28"))
    }

    func testLastWeekDotsAndCountFollowSundaysCheckIn() throws {
        var row = try monday().goals[0].week.commitments[0]
        let pips = GoalPips(lastWeekOf: row, name: "Stretch", today: "2026-10-26")
        XCTAssertEqual(pips.states, ["done", "done", "missed", "done", "done", "off", "ask"])
        XCTAssertEqual(pips.count, "4 of 6")
        XCTAssertEqual(pips.spoken, "Stretch: 4 of 6 days, Sunday not logged yet")
        row.yesterday = .done
        let logged = GoalPips(lastWeekOf: row, name: "Stretch", today: "2026-10-26")
        XCTAssertEqual(logged.states.last, "done", "a tap on Sunday shows at once")
        XCTAssertEqual(logged.count, "5 of 6")
        let item = try home(homeJSON(commitments: [2: ["last_week": ["target": 5, "done": 3, "hit": false]]]))
            .goals[0].week.commitments[2]
        XCTAssertEqual(GoalPips(lastWeekOf: item, name: "Outreach", today: "2026-10-26").states,
                       ["done", "done", "done", "missed", "missed"])
    }

    func testSundaysDotChecksInYesterday() async throws {
        let row = try monday().goals[0].week.commitments[0]
        XCTAssertEqual(GoalHeroCheckIn.tappableDays(row, today: "2026-10-26", yesterday: "2026-10-25"), [.today, .yesterday],
                       "last week's unlogged Sunday is yesterday's ringed +")
        let off = try monday(["last_week": lastWeek(sunday: "off")]).goals[0].week.commitments[0]
        XCTAssertEqual(GoalHeroCheckIn.tappableDays(off, today: "2026-10-26", yesterday: "2026-10-25"), [.today],
                       "a Sunday it wasn't due stays put")

        let client = FakeCardGoalsClient()
        client.homeResults = [.success(try monday())]
        client.checkInResults = [.failure(URLError(.timedOut))]
        let vm = GoalsHomeViewModel(client: client)
        await vm.load()
        guard case .loaded(let h) = vm.state else { return XCTFail("not loaded") }
        let checkIn = GoalHeroCheckIn(slug: slug, home: h, model: vm)
        XCTAssertTrue(checkIn.actions(for: h.goals[0]).map(\.label).contains("Stretch done yesterday"))
        await vm.checkIn(slug: slug, commitment: "stretch-pm", status: .done, day: .yesterday)
        XCTAssertEqual(client.checkIns, [
            .commitment(slug: slug, date: "2026-10-25", asOf: "2026-10-26", id: "stretch-pm", status: .done),
        ])
    }
}
