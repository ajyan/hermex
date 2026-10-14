import SwiftData
import XCTest
@testable import HermesMobile

@MainActor
final class BrainCacheTests: XCTestCase {
    private struct Payload: Codable, Equatable { let title: String }
    private let a = URL(string: "https://a.example")!
    private let b = URL(string: "https://b.example")!

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CachedBrainEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    func testRoundTrip() throws {
        let ctx = try makeContext()
        try BrainCache.store(Payload(title: "x"), server: a, kind: "page", id: "p1", in: ctx)
        XCTAssertEqual(try BrainCache.load(Payload.self, server: a, kind: "page", id: "p1", in: ctx), Payload(title: "x"))
        try BrainCache.store(Payload(title: "y"), server: a, kind: "page", id: "p1", in: ctx)
        XCTAssertEqual(try BrainCache.load(Payload.self, server: a, kind: "page", id: "p1", in: ctx), Payload(title: "y"))
    }

    func testServersAreIsolated() throws {
        let ctx = try makeContext()
        try BrainCache.store(Payload(title: "x"), server: a, kind: "page", id: "p1", in: ctx)
        XCTAssertNil(try BrainCache.load(Payload.self, server: b, kind: "page", id: "p1", in: ctx))
    }

    func testLRUEvictsBeyondMax() throws {
        let ctx = try makeContext()
        for i in 1...4 {
            try BrainCache.store(Payload(title: "\(i)"), server: a, kind: "page", id: "p\(i)", in: ctx, limit: 3)
        }
        XCTAssertNil(try BrainCache.load(Payload.self, server: a, kind: "page", id: "p1", in: ctx))
        XCTAssertNotNil(try BrainCache.load(Payload.self, server: a, kind: "page", id: "p4", in: ctx))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<CachedBrainEntry>()), 3)
    }

    func testLoadBumpsRecency() throws {
        let ctx = try makeContext()
        for i in 1...3 {
            try BrainCache.store(Payload(title: "\(i)"), server: a, kind: "page", id: "p\(i)", in: ctx, limit: 3)
        }
        _ = try BrainCache.load(Payload.self, server: a, kind: "page", id: "p1", in: ctx)
        try BrainCache.store(Payload(title: "4"), server: a, kind: "page", id: "p4", in: ctx, limit: 3)
        XCTAssertNotNil(try BrainCache.load(Payload.self, server: a, kind: "page", id: "p1", in: ctx))
        XCTAssertNil(try BrainCache.load(Payload.self, server: a, kind: "page", id: "p2", in: ctx))
    }

    func testClearRemovesOnlyThatServer() throws {
        let ctx = try makeContext()
        try BrainCache.store(Payload(title: "x"), server: a, kind: "page", id: "p1", in: ctx)
        try BrainCache.store(Payload(title: "y"), server: b, kind: "page", id: "p1", in: ctx)
        try BrainCache.clear(server: a, in: ctx)
        XCTAssertNil(try BrainCache.load(Payload.self, server: a, kind: "page", id: "p1", in: ctx))
        XCTAssertNotNil(try BrainCache.load(Payload.self, server: b, kind: "page", id: "p1", in: ctx))
    }

    func testHomeDeckIsCachedByDayAndBatch() async throws {
        let cache = BrainCacheHandle(server: a, context: try makeContext())
        let deck = BrainHome(
            bites: [BrainBite(id: "b1", kind: .idea, text: "An idea", ref: BrainRef(module: .wiki, id: "wiki/a.md", title: "A"))],
            batch: 0, hasMore: false)
        let client = FakeBrainClient()
        client.homeResult = .success(deck)
        let store = BrainReviewStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let online = BrainHomeViewModel(client: client, cache: cache, reviewStore: store, today: { "2026-10-14" })
        await online.load()
        let context = try XCTUnwrap(cache.context)
        XCTAssertEqual(try BrainCache.load(BrainHome.self, server: cache.server, kind: "home", id: "2026-10-14-0", in: context), deck)

        // A new day offline never shows yesterday's deck as today's.
        client.homeResult = .failure(URLError(.notConnectedToInternet))
        let nextDay = BrainHomeViewModel(client: client, cache: cache, reviewStore: store, today: { "2026-10-15" })
        await nextDay.load()
        XCTAssertTrue(nextDay.home.isEmpty)
        // The same day offline still has its cached deck.
        let sameDay = BrainHomeViewModel(client: client, cache: cache, reviewStore: store, today: { "2026-10-14" })
        await sameDay.load()
        XCTAssertEqual(sameDay.home, deck)
    }
}
