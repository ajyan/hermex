import CryptoKit
import Foundation

/// Posts a turn's timings to `/api/telemetry/turn`. Each upload is first written to a small per-server
/// queue on disk and removed once the server answers, so a turn that ends offline, or just before the app
/// is killed, still reaches the server: `retryPending` sends what is left the next time a chat opens or
/// returns to the foreground, and every successful upload drains the rest. Errors never surface. A server
/// that answers 404 (no such route) gets no further uploads this launch and its queue is dropped.
@MainActor
enum TurnTraceUploader {
    /// Off under XCTest so the many tests that send a message through a mocked server don't each see
    /// an unexpected `/api/telemetry/turn` request. `TurnTraceFlowTests` turns it back on.
    static var isEnabled = NSClassFromString("XCTestCase") == nil

    /// Where the per-server queues live. Caches: losing them only loses telemetry.
    static var directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TurnTraceQueue", isDirectory: true)

    static let maxPending = 50
    static let maxAge: TimeInterval = 24 * 60 * 60

    private static var unsupported: Set<String> = []
    private static var draining: Set<String> = []

    private struct Pending: Codable {
        let queuedAt: Date
        let upload: TurnTraceUpload
    }

    private enum Result { case sent, rejected, unsupported, failed }

    static func send(_ upload: TurnTraceUpload, client: APIClient, now: Date = .now) async {
        let server = client.baseURL.absoluteString
        guard isEnabled, !unsupported.contains(server) else { return }
        var queue = load(server, now: now)
        queue.append(Pending(queuedAt: now, upload: upload))
        save(Array(queue.suffix(maxPending)), server: server)
        await drain(client: client, now: now)
    }

    /// Sends this server's queued uploads, oldest first, stopping at the first one the server can't take now.
    static func retryPending(client: APIClient, now: Date = .now) async {
        guard isEnabled, !unsupported.contains(client.baseURL.absoluteString) else { return }
        await drain(client: client, now: now)
    }

    private static func drain(client: APIClient, now: Date) async {
        let server = client.baseURL.absoluteString
        guard draining.insert(server).inserted else { return }
        defer { draining.remove(server) }
        while let next = load(server, now: now).first {
            switch await post(next.upload, client: client) {
            case .sent, .rejected:
                // Uploads queued while this one was in flight are on disk; drop only the one just settled.
                save(load(server, now: now).filter { $0.upload.traceparent != next.upload.traceparent }, server: server)
            case .unsupported:
                unsupported.insert(server)
                save([], server: server)
                return
            case .failed:
                return
            }
        }
    }

    /// A 4xx other than 404 means the server will never take this body, so it is dropped like a success.
    private static func post(_ upload: TurnTraceUpload, client: APIClient) async -> Result {
        do {
            _ = try await client.sendData(endpoint: .telemetryTurn, method: "POST", body: upload)
            return .sent
        } catch let error as APIError {
            guard case .http(let statusCode, _) = error else { return .failed }
            if statusCode == 404 { return .unsupported }
            return (400..<500).contains(statusCode) && statusCode != 401 && statusCode != 408 && statusCode != 429
                ? .rejected : .failed
        } catch {
            return .failed
        }
    }

    /// One file per server, named by a hash of its URL, so one server's turns never reach another.
    private static func file(_ server: String) -> URL {
        let digest = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    private static func load(_ server: String, now: Date) -> [Pending] {
        guard let data = try? Data(contentsOf: file(server)),
              let queue = try? JSONDecoder().decode([Pending].self, from: data) else { return [] }
        return queue.filter { now.timeIntervalSince($0.queuedAt) < maxAge }
    }

    private static func save(_ queue: [Pending], server: String) {
        let url = file(server)
        guard !queue.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(queue).write(to: url, options: .atomic)
    }

    /// For tests: forget which servers lack the route.
    static func reset() {
        unsupported.removeAll()
        draining.removeAll()
    }
}
