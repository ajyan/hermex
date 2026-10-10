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
