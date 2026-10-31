import XCTest
@testable import HermesMobile

final class AtlasWidgetRecentsTests: XCTestCase {
    private let serverA = URL(string: "https://a.example")!
    private let serverB = URL(string: "https://b.example")!
    private var suiteName: String!
    private var store: AtlasWidgetRecentsStore!

    override func setUp() {
        super.setUp()
        suiteName = "AtlasWidgetRecentsTests.\(UUID().uuidString)"
        store = AtlasWidgetRecentsStore(defaults: UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testKeepsTheTwoMostRecentlyActiveSessionsNewestFirst() {
        let recents = AtlasWidgetRecents(server: serverA, sessions: [
            SessionSummary(sessionId: "old", title: "Old", lastMessageAt: 100),
            SessionSummary(sessionId: "newest", title: "Newest", lastMessageAt: 300),
            SessionSummary(sessionId: "middle", title: "  ", updatedAt: 200),
            SessionSummary(sessionId: nil, title: "No id", lastMessageAt: 999)
        ])

        XCTAssertEqual(recents.sessions.map(\.id), ["newest", "middle"])
        XCTAssertEqual(recents.sessions.last?.title, "Untitled")
        XCTAssertEqual(recents.server, serverA)
    }

    func testSaveRoundTripsAndRemoveOnlyClearsTheOwningServer() {
        let recents = AtlasWidgetRecents(server: serverA, sessions: [
            SessionSummary(sessionId: "s1", title: "One", lastMessageAt: 100)
        ])
        store.save(recents)
        XCTAssertEqual(store.load(), recents)

        store.remove(for: serverB)
        XCTAssertEqual(store.load(), recents)

        store.remove(for: serverA)
        XCTAssertNil(store.load())
    }

    func testAnotherServersLoadReplacesTheSnapshot() {
        store.save(AtlasWidgetRecents(server: serverA, sessions: [SessionSummary(sessionId: "a", lastMessageAt: 1)]))
        store.save(AtlasWidgetRecents(server: serverB, sessions: [SessionSummary(sessionId: "b", lastMessageAt: 1)]))

        XCTAssertEqual(store.load()?.server, serverB)
        XCTAssertEqual(store.load()?.sessions.map(\.id), ["b"])
    }
}

private final class WidgetGoalsClient: GoalsDataClient, @unchecked Sendable {
    var homeResults: [Result<GoalsHome, Error>] = []
    var checkInError: Error?
    /// Runs as `home()` is called, before it answers (to switch servers mid-read).
    var onHome: (() -> Void)?
    /// When set, `checkIn` signals `started` and then waits on `release`.
    var gate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?
    private(set) var checkIns: [GoalCheckInRequest] = []

    func home() async throws -> GoalsHome {
        onHome?()
        return try homeResults.removeFirst().get()
    }
    func detail(slug: String) async throws -> GoalDetail { throw URLError(.unsupportedURL) }
    func finish(_ r: GoalFinishRequest) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func record(slug: String) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func reopen(slug: String) async throws -> GoalDetail { throw URLError(.unsupportedURL) }
    func saveReflection(_ r: GoalReflectionRequest) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func confirmWeek(_ r: GoalWeekRequest) async throws -> GoalCheckInResult { throw URLError(.unsupportedURL) }
    /// Throws `checkInError` when set; otherwise accepts with a minimal result.
    func checkIn(_ r: GoalCheckInRequest, clientID: String) async throws -> GoalCheckInResult {
        checkIns.append(r)
        if let gate {
            gate.started.yield()
            for await _ in gate.release { break }
        }
        if let checkInError { throw checkInError }
        let body = #"{"goal": {"slug": "nyc-marathon-2026"}, "streak": {"days": 1}, "today": "2026-10-10", "yesterday": "2026-10-09"}"#
        return try PrepDecoding.decode(GoalCheckInResult.self, from: Data(body.utf8))
    }
}

/// Which server is active, changeable while a read is in flight.
private final class ActiveServer: @unchecked Sendable {
    var id: String?
    init(_ server: URL?) { id = server?.absoluteString }
}

@MainActor
final class GoalsWidgetSyncTests: XCTestCase {
    private let server = URL(string: "https://a.example")!
    private let serverB = URL(string: "https://b.example")!
    private var suiteName: String!
    private var store: AtlasWidgetGoalsStore!

    override func setUp() {
        super.setUp()
        suiteName = "GoalsWidgetSyncTests.\(UUID().uuidString)"
        store = AtlasWidgetGoalsStore(defaults: UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The sample home, with `stretch-pm` already done today when `stretchDone`.
    private func home(today: String = "2026-10-10", stretchDone: Bool = false) throws -> GoalsHome {
        var json = GoalsModelsTests.homeSample.replacingOccurrences(of: "\"today\": \"2026-10-10\"", with: "\"today\": \"\(today)\"")
        if stretchDone {
            json = json.replacingOccurrences(
                of: "\"done\": 0, \"min\": 0, \"skipped\": 0, \"missed\": 0, \"hit\": false, \"remaining\": 6, \"due_today\": true, \"due_yesterday\": true, \"today\": null",
                with: "\"done\": 1, \"min\": 0, \"skipped\": 0, \"missed\": 0, \"hit\": false, \"remaining\": 5, \"due_today\": true, \"due_yesterday\": true, \"today\": \"done\""
            )
        }
        return try PrepDecoding.decode(GoalsHome.self, from: Data(json.utf8))
    }

    private let stretchID = AtlasWidgetGoals.Item.id(slug: "nyc-marathon-2026", commitment: "stretch-pm")
    private let runID = AtlasWidgetGoals.Item.id(slug: "nyc-marathon-2026", commitment: "long-run")

    private func checkIn(_ commitment: String = "stretch-pm", done: Bool = true, client: WidgetGoalsClient,
                         active: String? = nil) async {
        let active = active ?? server.absoluteString
        await GoalsWidgetSync.checkIn(
            slug: "nyc-marathon-2026", commitment: commitment, done: done, store: store,
            activeServerID: { active }, client: { _ in client }
        )
    }

    func testSnapshotListsCommitmentsDueTodayWithWeekCounts() throws {
        let goals = AtlasWidgetGoals(server: server, home: try home(stretchDone: true))

        XCTAssertEqual(goals.today, "2026-10-10")
        XCTAssertEqual(goals.items.map(\.commitment), ["stretch-pm", "long-run"])
        XCTAssertEqual(goals.items[0].weekCount, 1)
        XCTAssertEqual(goals.items[0].target, 6)
        XCTAssertTrue(goals.items[0].isDone)
        XCTAssertTrue(goals.items[0].isUndoable)
        XCTAssertFalse(goals.items[1].isDone)
    }

    /// Done the way the app counts it: a day the source counted is done (and not undoable, since
    /// clearing leaves it done); item rows stay off the widget.
    func testSnapshotCountsSourceDaysAndLeavesOutItemRows() throws {
        var json = try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.homeSample.utf8)) as! [String: Any]
        var goal = (json["goals"] as! [[String: Any]])[0]
        var week = goal["week"] as! [String: Any]
        var rows = week["commitments"] as! [[String: Any]]
        rows[0]["source"] = "prep.days"
        rows[0]["source_days"] = ["2026-10-10"]
        rows.append(["id": "outreach", "action": "Outreach", "target": 5, "unit": "item", "due_today": true])
        week["commitments"] = rows
        goal["week"] = week
        json["goals"] = [goal]
        let home = try PrepDecoding.decode(GoalsHome.self, from: JSONSerialization.data(withJSONObject: json))

        let goals = AtlasWidgetGoals(server: server, home: home)

        XCTAssertEqual(goals.items.map(\.commitment), ["stretch-pm", "long-run"])
        XCTAssertTrue(goals.items[0].isDone)
        XCTAssertFalse(goals.items[0].isUndoable)
    }

    func testStaleOnlyOnceThePhonesDayTurnsAfterSaving() throws {
        let now = Date()
        // The server's today is behind the phone's: still fresh, since it was just saved.
        let goals = AtlasWidgetGoals(server: server, home: try home(today: "2026-01-01"), savedAt: now)
        XCTAssertFalse(goals.isStale(at: now))
        XCTAssertTrue(goals.isStale(at: now.addingTimeInterval(2 * 24 * 60 * 60)))

        var old = goals
        old.savedDay = nil
        XCTAssertTrue(old.isStale(at: now), "an older snapshot falls back to the server's today")
    }

    func testCheckInPostsForTheSnapshotsDayAndTakesTheServersState() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home()))
        let client = WidgetGoalsClient()
        client.homeResults = [.success(try home(stretchDone: true))]

        await checkIn(client: client)

        XCTAssertEqual(client.checkIns, [.commitment(
            slug: "nyc-marathon-2026", date: "2026-10-10", asOf: "2026-10-10", id: "stretch-pm", status: .done
        )])
        XCTAssertEqual(store.load()?.items.first?.isDone, true)
        XCTAssertEqual(store.load()?.syncFailed, false)
    }

    func testTapOnADoneRowClearsIt() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home(stretchDone: true)))
        let client = WidgetGoalsClient()
        client.homeResults = [.success(try home())]

        await checkIn(done: false, client: client)

        XCTAssertEqual(client.checkIns.first, .commitment(
            slug: "nyc-marathon-2026", date: "2026-10-10", asOf: "2026-10-10", id: "stretch-pm", status: .clear
        ))
        XCTAssertEqual(store.load()?.items.first?.isDone, false)
        XCTAssertEqual(store.load()?.items.first?.weekCount, 0)
    }

    func testSavedTickSurvivesAFailedRefresh() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home()))
        let client = WidgetGoalsClient()
        client.homeResults = [.failure(URLError(.timedOut))]

        await checkIn(client: client)

        XCTAssertEqual(store.load()?.items.first?.isDone, true)
        XCTAssertEqual(store.load()?.items.first?.weekCount, 1)
        XCTAssertEqual(store.load()?.syncFailed, false, "the server has the check-in")
    }

    func testFailedCheckInRestoresTheSnapshotAndFlagsIt() async throws {
        let original = AtlasWidgetGoals(server: server, home: try home())
        store.save(original)
        let client = WidgetGoalsClient()
        client.checkInError = URLError(.notConnectedToInternet)

        await checkIn(client: client)

        XCTAssertEqual(store.load(), original.failed())
    }

    /// Another row ticked while this one was in flight keeps its tick when this one fails.
    func testFailedCheckInPutsBackOnlyItsOwnRow() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home()))
        let client = WidgetGoalsClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.checkInError = URLError(.notConnectedToInternet)

        let tap = Task { await checkIn(client: client) }
        for await _ in started { break }
        store.save(try XCTUnwrap(store.load()).checking(runID, done: true))
        releaseCont.yield()
        await tap.value

        let stored = try XCTUnwrap(store.load())
        XCTAssertEqual(stored.items.first { $0.id == stretchID }?.isDone, false)
        XCTAssertEqual(stored.items.first { $0.id == runID }?.isDone, true)
        XCTAssertTrue(stored.syncFailed)
    }

    func testStaleDayShowsTheServersNewDayStillFlagged() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home()))
        let client = WidgetGoalsClient()
        client.checkInError = APIError.http(statusCode: 409, body: nil)
        client.homeResults = [.success(try home(today: "2026-10-11"))]

        await checkIn(client: client)

        XCTAssertEqual(store.load()?.today, "2026-10-11")
        XCTAssertEqual(store.load()?.syncFailed, true)
        XCTAssertEqual(store.load()?.items.first?.isDone, false)
    }

    func testCheckInForAnotherServerNeverPosts() async throws {
        let original = AtlasWidgetGoals(server: server, home: try home())
        store.save(original)
        let client = WidgetGoalsClient()

        await checkIn(client: client, active: serverB.absoluteString)

        XCTAssertTrue(client.checkIns.isEmpty)
        XCTAssertEqual(store.load(), original.failed())
    }

    func testRefreshThatLandsAfterASwitchIsDropped() async throws {
        let active = ActiveServer(server)
        let client = WidgetGoalsClient()
        client.homeResults = [.success(try home())]
        client.onHome = { active.id = self.serverB.absoluteString }

        await GoalsWidgetSync.refresh(server: server, force: true, store: store,
                                      activeServerID: { active.id }, client: { _ in client })

        XCTAssertNil(store.load())
    }

    func testSwitchToAServerWithoutGoalsDropsTheLastServersSnapshot() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home()))
        let client = WidgetGoalsClient()
        client.homeResults = [.failure(APIError.http(statusCode: 404, body: nil))]

        await GoalsWidgetSync.refresh(server: serverB, force: true, store: store,
                                      activeServerID: { self.serverB.absoluteString }, client: { _ in client })

        XCTAssertNil(store.load())
    }

    func testFailedReadAfterASwitchStillDropsTheLastServersSnapshot() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home()))
        let client = WidgetGoalsClient()
        client.homeResults = [.failure(URLError(.timedOut))]

        await GoalsWidgetSync.refresh(server: serverB, force: true, store: store,
                                      activeServerID: { self.serverB.absoluteString }, client: { _ in client })

        XCTAssertNil(store.load())
    }

    func testClearKeepsOnlyTheNamedServersSnapshot() throws {
        let goals = AtlasWidgetGoals(server: server, home: try home())
        store.save(goals)
        GoalsWidgetSync.clear(except: server, store: store)
        XCTAssertEqual(store.load(), goals)
        GoalsWidgetSync.clear(except: serverB, store: store)
        XCTAssertNil(store.load())
        store.save(goals)
        GoalsWidgetSync.clear(except: nil, store: store)
        XCTAssertNil(store.load())
    }

    func testUpdateSavesOnlyForTheActiveServer() throws {
        GoalsWidgetSync.update(server: server, home: try home(), store: store, activeServerID: { self.serverB.absoluteString })
        XCTAssertNil(store.load())
        GoalsWidgetSync.update(server: server, home: try home(), store: store, activeServerID: { self.server.absoluteString })
        XCTAssertEqual(store.load()?.server, server)
    }
}
