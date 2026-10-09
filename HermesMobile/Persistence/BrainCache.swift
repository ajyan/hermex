import Foundation
import SwiftData

/// One cached Brain API payload (module list, a module's list, or a page),
/// keyed by server + kind + id so nothing for one server is visible under another.
@Model
final class CachedBrainEntry {
    @Attribute(.unique) var cacheKey: String
    var serverURLString: String
    var kind: String
    var payload: Data
    var accessedAt: Date

    init(cacheKey: String, serverURLString: String, kind: String, payload: Data, accessedAt: Date = Date()) {
        self.cacheKey = cacheKey
        self.serverURLString = serverURLString
        self.kind = kind
        self.payload = payload
        self.accessedAt = accessedAt
    }
}

enum BrainCache {
    static let maxEntries = 500

    static func key(server: URL, kind: String, id: String) -> String {
        "\(server.absoluteString)|\(kind)|\(id)"
    }

    @MainActor
    static func store<T: Encodable>(
        _ value: T,
        server: URL,
        kind: String,
        id: String,
        in context: ModelContext,
        limit: Int = BrainCache.maxEntries
    ) throws {
        let data = try JSONEncoder().encode(value)
        let cacheKey = key(server: server, kind: kind, id: id)
        let now = Date()
        if let existing = try fetchEntry(cacheKey, in: context) {
            existing.payload = data
            existing.accessedAt = now
        } else {
            context.insert(CachedBrainEntry(
                cacheKey: cacheKey,
                serverURLString: server.absoluteString,
                kind: kind,
                payload: data,
                accessedAt: now
            ))
        }
        try context.save()
        try evict(limit: limit, in: context)
    }

    @MainActor
    static func load<T: Decodable>(
        _ type: T.Type,
        server: URL,
        kind: String,
        id: String,
        in context: ModelContext
    ) throws -> T? {
        guard let entry = try fetchEntry(key(server: server, kind: kind, id: id), in: context) else {
            return nil
        }
        guard let value = try? JSONDecoder().decode(T.self, from: entry.payload) else {
            return nil
        }
        entry.accessedAt = Date()
        try context.save()
        return value
    }

    @MainActor
    static func clear(server: URL, in context: ModelContext) throws {
        let serverURLString = server.absoluteString
        let descriptor = FetchDescriptor<CachedBrainEntry>(
            predicate: #Predicate { $0.serverURLString == serverURLString }
        )
        for entry in try context.fetch(descriptor) {
            context.delete(entry)
        }
        try context.save()
    }

    @MainActor
    private static func fetchEntry(_ cacheKey: String, in context: ModelContext) throws -> CachedBrainEntry? {
        var descriptor = FetchDescriptor<CachedBrainEntry>(
            predicate: #Predicate { $0.cacheKey == cacheKey }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    private static func evict(limit: Int, in context: ModelContext) throws {
        let total = try context.fetchCount(FetchDescriptor<CachedBrainEntry>())
        guard total > limit else { return }
        var descriptor = FetchDescriptor<CachedBrainEntry>(
            sortBy: [SortDescriptor(\.accessedAt, order: .forward)]
        )
        descriptor.fetchLimit = total - limit
        for entry in try context.fetch(descriptor) {
            context.delete(entry)
        }
        try context.save()
    }
}
