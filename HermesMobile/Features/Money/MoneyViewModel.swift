import Foundation
import Observation

/// Where the vault's money snapshot script and Atlas's market note write.
enum MoneyPaths {
    static let snapshot = "finance/data/money/snapshot.json"
    static let market = "finance/data/money/market.json"
}

/// What Money reads: two vault files through the session-scoped file API, the same way the
/// Daily Deck reads `briefs/`.
protocol MoneyDataClient: Sendable {
    func workspacePaths() async throws -> [String]
    func createSession(workspace: String) async throws -> String
    func renameSession(id: String, title: String) async throws
    func fileContent(sessionID: String, path: String) async throws -> String
}

enum MoneyState: Equatable {
    case idle
    case loading
    /// The server has several workspaces and the Daily Brief hasn't picked the vault yet.
    case needsWorkspace
    /// The vault has no snapshot: the money job hasn't run.
    case noSnapshot
    case ready
    case failed(String)
}

@MainActor
@Observable
final class MoneyViewModel {
    private(set) var state: MoneyState = .idle
    private(set) var snapshot: MoneySnapshot?
    /// The market note, only when it describes the snapshot's week.
    private(set) var market: MoneyMarketNote?
    var range: MoneyRange = .week {
        didSet { if range != oldValue { scrubbed = nil } }
    }
    /// Amounts are hidden until revealed, and hidden again whenever the screen goes away.
    private(set) var isRevealed = false
    /// The day under the finger while scrubbing the chart.
    private(set) var scrubbed: MoneyPoint?

    let server: URL
    private let client: any MoneyDataClient
    private let store: DailyDeckStore
    private let now: () -> Date
    private let today: String

    init(server: URL, client: any MoneyDataClient, store: DailyDeckStore = DailyDeckStore(), now: @escaping () -> Date = Date.init) {
        self.server = server
        self.client = client
        self.store = store
        self.now = now
        today = DailyDeckPaths.day(now())
    }

    convenience init(server: URL) {
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["HERMEX_MONEY_FIXTURES"] {
            // Its own store, so the fixture workspace never replaces the Daily Brief's.
            self.init(
                server: server,
                client: FixtureMoneyDataClient(directory: URL(fileURLWithPath: directory)),
                store: DailyDeckStore(defaults: UserDefaults(suiteName: "money-fixtures") ?? .standard)
            )
            return
        }
        #endif
        self.init(server: server, client: APIClientMoneyAdapter(apiClient: APIClient(baseURL: server)))
    }

    var isHidden: Bool { !isRevealed }

    var points: [MoneyPoint] {
        guard let snapshot else { return [] }
        return range.points(in: snapshot.series, today: MoneyPoint.dayFormatter.date(from: today) ?? now())
    }

    /// The range's change, up to the scrubbed day while scrubbing.
    var change: MoneyChange {
        let points = points
        guard let scrubbed, let end = points.firstIndex(of: scrubbed) else { return MoneyChange.between(points) }
        return MoneyChange.between(Array(points[...end]))
    }

    var displayedValue: Double { scrubbed?.v ?? snapshot?.netWorth ?? 0 }

    func toggleReveal() { isRevealed.toggle() }

    func hide() { isRevealed = false }

    /// Selects the point nearest `date`, or ends scrubbing for nil.
    func scrub(to date: Date?) {
        guard let date else {
            scrubbed = nil
            return
        }
        scrubbed = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    func load() async {
        if snapshot == nil { state = .loading }
        do {
            guard let workspace = try await resolveWorkspace() else {
                state = .needsWorkspace
                return
            }
            let sessionID = try await session(workspace: workspace)
            guard let text = try await read(MoneyPaths.snapshot, sessionID: sessionID) else {
                snapshot = nil
                market = nil
                state = .noSnapshot
                return
            }
            let decoded = try MoneySnapshot.decode(Data(text.utf8))
            let note = (try? await read(MoneyPaths.market, sessionID: sessionID))
                .flatMap { $0 }
                .flatMap { try? MoneyMarketNote.decode(Data($0.utf8)) }
            snapshot = decoded
            market = note?.matches(decoded.week) == true ? note : nil
            scrubbed = nil
            state = .ready
        } catch is CancellationError {
            // A newer load owns the state.
        } catch {
            // A failed refresh keeps the chart; only a first load shows the error.
            if snapshot == nil || state != .ready { state = .failed(error.localizedDescription) }
        }
    }

    /// The Daily Brief's vault workspace, or the server's only one.
    private func resolveWorkspace() async throws -> String? {
        if let stored = store.workspace(for: server) { return stored }
        let paths = try await client.workspacePaths()
        guard paths.count == 1, let only = paths.first else { return nil }
        store.setWorkspace(only, for: server)
        return only
    }

    /// Today's Daily Brief reading session, shared so Money never adds a session of its own
    /// on a day the Brief was opened. A session the server lost is replaced once.
    private func session(workspace: String, replacing lost: String? = nil) async throws -> String {
        if let stored = store.session(for: server, date: today), stored != lost { return stored }
        let created = try await client.createSession(workspace: workspace)
        store.setSession(created, for: server, date: today)
        try? await client.renameSession(id: created, title: DailyDeckViewModel.sessionTitle(for: today))
        return created
    }

    /// A file's text, or nil when it doesn't exist. A lost session is replaced once, like the Brief's.
    private func read(_ path: String, sessionID: String, retry: Bool = true) async throws -> String? {
        do {
            return try await client.fileContent(sessionID: sessionID, path: path)
        } catch let error as APIError where error.isVanishedSession {
            guard retry, let workspace = store.workspace(for: server) else { throw error }
            let fresh = try await session(workspace: workspace, replacing: sessionID)
            return try await read(path, sessionID: fresh, retry: false)
        } catch let error as APIError where error.isNotFound {
            return nil
        }
    }
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol.
private struct APIClientMoneyAdapter: MoneyDataClient {
    let apiClient: APIClient

    func workspacePaths() async throws -> [String] {
        try await apiClient.workspaces().workspaces?.compactMap(\.path) ?? []
    }

    func createSession(workspace: String) async throws -> String {
        let response = try await apiClient.createSession(workspace: workspace, model: nil, modelProvider: nil, profile: nil)
        guard let id = response.session?.sessionId, !id.isEmpty else {
            throw APIError.http(statusCode: 500, body: "The server did not return a session.")
        }
        return id
    }

    func renameSession(id: String, title: String) async throws {
        _ = try await apiClient.renameSession(id: id, title: title)
    }

    func fileContent(sessionID: String, path: String) async throws -> String {
        let response = try await apiClient.file(sessionID: sessionID, path: path)
        guard let content = response.content else { throw APIError.http(statusCode: 404, body: response.error) }
        return content
    }
}

#if DEBUG
/// Reads `snapshot.json` and `market.json` from a local folder, for simulator checks and demos
/// with synthetic data (`SIMCTL_CHILD_HERMEX_MONEY_FIXTURES=<folder>`).
private struct FixtureMoneyDataClient: MoneyDataClient {
    let directory: URL

    func workspacePaths() async throws -> [String] { ["/fixtures"] }
    func createSession(workspace: String) async throws -> String { "fixtures" }
    func renameSession(id: String, title: String) async throws {}

    func fileContent(sessionID: String, path: String) async throws -> String {
        let url = directory.appendingPathComponent((path as NSString).lastPathComponent)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw APIError.http(statusCode: 404, body: nil) }
        return text
    }
}
#endif
