import XCTest
@testable import HermesMobile

@MainActor
final class MoneyViewModelTests: XCTestCase {
    private let server = URL(string: "https://money-tests.example")!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "MoneyViewModelTests")!
        defaults.removePersistentDomain(forName: "MoneyViewModelTests")
    }

    private func makeModel(_ client: MockMoneyClient, workspace: String? = "/vault", session: String? = nil) -> MoneyViewModel {
        let store = DailyDeckStore(defaults: defaults)
        if let workspace { store.setWorkspace(workspace, for: server) }
        if let session { store.setSession(session, for: server, date: "2026-10-12") }
        // Noon on 2026-10-12 in this machine's time zone, since the session day is local.
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
        return MoneyViewModel(server: server, client: client, store: store, now: { noon })
    }

    func testReadyLoadsSnapshotAndMatchingMarket() async throws {
        let client = try MockMoneyClient.withFixtures()
        let model = makeModel(client)
        await model.load()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.snapshot?.netWorth ?? 0, 184320.12, accuracy: 0.001)
        XCTAssertNotNil(model.market)
        XCTAssertEqual(model.points.first?.d, "2026-10-05")
        XCTAssertEqual(client.readPaths, [MoneyPaths.snapshot, MoneyPaths.market])
    }

    func testMissingSnapshotIsNoSnapshot() async {
        let model = makeModel(MockMoneyClient(files: [:]))
        await model.load()
        XCTAssertEqual(model.state, .noSnapshot)
        XCTAssertNil(model.snapshot)
    }

    func testMissingMarketStillReady() async throws {
        let client = try MockMoneyClient.withFixtures()
        client.files[MoneyPaths.market] = nil
        let model = makeModel(client)
        await model.load()
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.market)
    }

    func testSeveralWorkspacesNeedsWorkspace() async throws {
        let client = try MockMoneyClient.withFixtures()
        client.workspaces = ["/a", "/b"]
        let model = makeModel(client, workspace: nil)
        await model.load()
        XCTAssertEqual(model.state, .needsWorkspace)
    }

    func testReusesDeckSession() async throws {
        let client = try MockMoneyClient.withFixtures()
        let model = makeModel(client, session: "deck-session")
        await model.load()
        XCTAssertEqual(client.createdSessions, 0)
        XCTAssertEqual(client.readSessions, ["deck-session", "deck-session"])
    }

    func testCreatesAndStoresSessionWhenNone() async throws {
        let client = try MockMoneyClient.withFixtures()
        let model = makeModel(client)
        await model.load()
        XCTAssertEqual(client.createdSessions, 1)
        XCTAssertEqual(DailyDeckStore(defaults: defaults).session(for: server, date: "2026-10-12"), "new-session-1")
    }

    func testLostSessionIsReplacedOnlyOnce() async throws {
        let client = try MockMoneyClient.withFixtures()
        client.sessionsVanish = true
        let model = makeModel(client, session: "deck-session")
        await model.load()
        XCTAssertEqual(client.createdSessions, 1)
        XCTAssertEqual(client.readSessions, ["deck-session", "new-session-1"])
        guard case .failed = model.state else { return XCTFail("expected failed, got \(model.state)") }
    }

    func testFailedRefreshKeepsTheSnapshot() async throws {
        let client = try MockMoneyClient.withFixtures()
        let model = makeModel(client)
        await model.load()
        client.failReads = true
        await model.load()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.snapshot?.netWorth ?? 0, 184320.12, accuracy: 0.001)
    }

    func testFirstLoadFailureShowsTheError() async throws {
        let client = try MockMoneyClient.withFixtures()
        client.failReads = true
        let model = makeModel(client)
        await model.load()
        guard case .failed = model.state else { return XCTFail("expected failed, got \(model.state)") }
    }

    func testStartsHiddenAndHideResets() async throws {
        let model = makeModel(try MockMoneyClient.withFixtures())
        XCTAssertFalse(model.isRevealed)
        model.toggleReveal()
        XCTAssertTrue(model.isRevealed)
        model.hide()
        XCTAssertFalse(model.isRevealed)
    }

    func testScrubChangesDisplayedValue() async throws {
        let model = makeModel(try MockMoneyClient.withFixtures())
        await model.load()
        XCTAssertEqual(model.displayedValue, 184320.12, accuracy: 0.001)
        let middle = model.points[3]
        model.scrub(to: middle.date.addingTimeInterval(3600))
        XCTAssertEqual(model.scrubbed, middle)
        XCTAssertEqual(model.displayedValue, middle.v)
        XCTAssertEqual(model.change, MoneyChange.between(Array(model.points[0...3])))
        model.scrub(to: nil)
        XCTAssertNil(model.scrubbed)
        XCTAssertEqual(model.change, MoneyChange.between(model.points))
    }

    func testChangingRangeClearsScrub() async throws {
        let model = makeModel(try MockMoneyClient.withFixtures())
        await model.load()
        model.scrub(to: model.points[2].date)
        model.range = .year
        XCTAssertNil(model.scrubbed)
        XCTAssertEqual(model.points.first?.d, "2025-10-12")
    }
}

final class MockMoneyClient: MoneyDataClient, @unchecked Sendable {
    var files: [String: String]
    var workspaces = ["/vault"]
    /// Every read answers "Session not found", as a server that keeps losing sessions would.
    var sessionsVanish = false
    var failReads = false
    private(set) var createdSessions = 0
    private(set) var readPaths: [String] = []
    private(set) var readSessions: [String] = []

    init(files: [String: String]) { self.files = files }

    static func withFixtures() throws -> MockMoneyClient {
        MockMoneyClient(files: [
            MoneyPaths.snapshot: String(decoding: try MoneyModelsTests.fixture("snapshot.json"), as: UTF8.self),
            MoneyPaths.market: String(decoding: try MoneyModelsTests.fixture("market.json"), as: UTF8.self),
        ])
    }

    func workspacePaths() async throws -> [String] { workspaces }

    func createSession(workspace: String) async throws -> String {
        // Ends an unbounded retry loop with a failure instead of a hang.
        guard createdSessions < 5 else { throw URLError(.cannotConnectToHost) }
        createdSessions += 1
        return "new-session-\(createdSessions)"
    }

    func renameSession(id: String, title: String) async throws {}

    func fileContent(sessionID: String, path: String) async throws -> String {
        readPaths.append(path)
        readSessions.append(sessionID)
        if sessionsVanish { throw APIError.http(statusCode: 404, body: #"{"error": "Session not found"}"#) }
        if failReads { throw URLError(.timedOut) }
        guard let text = files[path] else { throw APIError.http(statusCode: 404, body: #"{"error": "File not found"}"#) }
        return text
    }
}
