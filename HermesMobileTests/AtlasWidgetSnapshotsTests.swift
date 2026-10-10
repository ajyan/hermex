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
    private(set) var checkIns: [GoalCheckInRequest] = []

    func home() async throws -> GoalsHome { try homeResults.removeFirst().get() }
    func detail(slug: String) async throws -> GoalDetail { throw URLError(.unsupportedURL) }
    /// Throws `checkInError` when set; otherwise accepts with a minimal result.
    func checkIn(_ r: GoalCheckInRequest) async throws -> GoalCheckInResult {
        checkIns.append(r)
        if let checkInError { throw checkInError }
        let body = #"{"goal": {"slug": "nyc-marathon-2026"}, "streak": {"days": 1}, "today": "2026-10-10", "yesterday": "2026-10-09"}"#
        return try PrepDecoding.decode(GoalCheckInResult.self, from: Data(body.utf8))
    }
}

@MainActor
final class GoalsWidgetSyncTests: XCTestCase {
    private let server = URL(string: "https://a.example")!
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

    func testSnapshotListsCommitmentsDueTodayWithWeekCounts() throws {
        let goals = AtlasWidgetGoals(server: server, home: try home(stretchDone: true))

        XCTAssertEqual(goals.today, "2026-10-10")
        XCTAssertEqual(goals.items.map(\.commitment), ["stretch-pm", "long-run"])
        XCTAssertEqual(goals.items[0].weekCount, 1)
        XCTAssertEqual(goals.items[0].target, 6)
        XCTAssertTrue(goals.items[0].isDone)
        XCTAssertFalse(goals.items[1].isDone)
    }

    func testCheckInPostsForTheSnapshotsDayAndTakesTheServersState() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home()))
        let client = WidgetGoalsClient()
        client.homeResults = [.success(try home(stretchDone: true))]

        await GoalsWidgetSync.checkIn(
            slug: "nyc-marathon-2026", commitment: "stretch-pm", store: store,
            activeServerID: server.absoluteString, client: { _ in client }
        )

        XCTAssertEqual(client.checkIns, [.commitment(
            slug: "nyc-marathon-2026", date: "2026-10-10", asOf: "2026-10-10", id: "stretch-pm", status: .done
        )])
        XCTAssertEqual(store.load()?.items.first?.isDone, true)
        XCTAssertEqual(store.load()?.syncFailed, false)
    }

    func testFailedCheckInRestoresTheSnapshotAndFlagsIt() async throws {
        let original = AtlasWidgetGoals(server: server, home: try home())
        store.save(original)
        let client = WidgetGoalsClient()
        client.checkInError = URLError(.notConnectedToInternet)

        await GoalsWidgetSync.checkIn(
            slug: "nyc-marathon-2026", commitment: "stretch-pm", store: store,
            activeServerID: server.absoluteString, client: { _ in client }
        )

        XCTAssertEqual(store.load(), original.failed())
    }

    func testStaleDayShowsTheServersNewDayStillFlagged() async throws {
        store.save(AtlasWidgetGoals(server: server, home: try home()))
        let client = WidgetGoalsClient()
        client.checkInError = APIError.http(statusCode: 409, body: nil)
        client.homeResults = [.success(try home(today: "2026-10-11"))]

        await GoalsWidgetSync.checkIn(
            slug: "nyc-marathon-2026", commitment: "stretch-pm", store: store,
            activeServerID: server.absoluteString, client: { _ in client }
        )

        XCTAssertEqual(store.load()?.today, "2026-10-11")
        XCTAssertEqual(store.load()?.syncFailed, true)
        XCTAssertEqual(store.load()?.items.first?.isDone, false)
    }

    func testCheckInForAnotherServerNeverPosts() async throws {
        let original = AtlasWidgetGoals(server: server, home: try home())
        store.save(original)
        let client = WidgetGoalsClient()

        await GoalsWidgetSync.checkIn(
            slug: "nyc-marathon-2026", commitment: "stretch-pm", store: store,
            activeServerID: "https://b.example", client: { _ in client }
        )

        XCTAssertTrue(client.checkIns.isEmpty)
        XCTAssertEqual(store.load(), original.failed())
    }
}

