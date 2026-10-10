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
}
