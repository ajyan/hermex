import Foundation
import Observation

/// Where the vault's money snapshot script and Atlas's market note write.
enum MoneyPaths {
    static let snapshot = "finance/data/money/snapshot.json"
    static let market = "finance/data/money/market.json"
    static let spending = "finance/data/money/spending.json"
}

/// What Money reads: three vault files through the session-scoped file API, the same way the
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
    /// The server has several workspaces (these) and the Daily Brief hasn't picked the vault yet.
    case needsWorkspace([String])
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
    /// Spending, when the vault's money run has written it; Money works without it. A failed read
    /// keeps the last one.
    private(set) var spending: MoneySpending?
    /// Why the last spending read or decode failed; nil once it reads (or isn't there).
    private(set) var spendingError: String?
    /// Why the last refresh failed while older numbers stay on screen; nil after a load that works.
    private(set) var refreshError: String?
    var range: MoneyRange = .week {
        didSet {
            guard range != oldValue else { return }
            scrub(to: nil)
            updatePoints()
        }
    }
    /// The range's points, counted back from the snapshot's last day rather than the phone's, so
    /// "this week" is the same seven days the market card splits. Kept per range and snapshot,
    /// since the chart, headline and scrubbing all read it.
    private(set) var points: [MoneyPoint] = []
    /// Amounts are hidden until revealed, and hidden again whenever the screen goes away.
    private(set) var isRevealed = false
    /// The day under the finger while scrubbing the chart. Only the headline and chart read it, so a
    /// drag redraws those alone.
    private(set) var scrubbed: MoneyPoint?
    /// True while a finger is on the chart; changes only when scrubbing starts or ends.
    private(set) var isScrubbing = false

    let server: URL
    /// Reading the synthetic fixtures (Debug only), so a screenshot can never pass for real data.
    let isFixture: Bool
    private let client: any MoneyDataClient
    private let store: DailyDeckStore
    private let now: () -> Date
    private let today: String
    /// A replacement for a lost session in flight, so reads that lose it together make one.
    @ObservationIgnored private var replacement: (lost: String, task: Task<String, Error>)?

    init(server: URL, client: any MoneyDataClient, store: DailyDeckStore = DailyDeckStore(),
         now: @escaping () -> Date = Date.init, isFixture: Bool = false) {
        self.server = server
        self.isFixture = isFixture
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
                store: DailyDeckStore(defaults: UserDefaults(suiteName: "money-fixtures") ?? .standard),
                isFixture: true
            )
            return
        }
        #endif
        self.init(server: server, client: APIClientMoneyAdapter(apiClient: APIClient(baseURL: server)))
    }

    var isHidden: Bool { !isRevealed }

    private func updatePoints() {
        guard let snapshot else {
            points = []
            return
        }
        points = range.points(in: snapshot.series, today: snapshot.lastDay ?? MoneyPoint.dayFormatter.date(from: today) ?? now())
    }

    /// What can't be trusted about the numbers right now: a snapshot past its daily run, or
    /// banks whose connection is failing (counted at their last balance). Nil when all is well.
    var trustWarning: String? {
        guard let snapshot else { return nil }
        var parts: [String] = []
        if let asOf = snapshot.asOf, now().timeIntervalSince(asOf) > Self.overdueAfter {
            parts.append("Not updated since " + asOf.formatted(.dateTime.month(.abbreviated).day()))
        }
        if snapshot.missing > 0 {
            parts.append(snapshot.missing == 1 ? "1 account not syncing" : "\(snapshot.missing) accounts not syncing")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The money job runs every morning at 05:45, so a snapshot older than this missed a run.
    static let overdueAfter: TimeInterval = 26 * 60 * 60

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
        scrubbed = date.flatMap { date in
            points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        if isScrubbing != (scrubbed != nil) { isScrubbing = scrubbed != nil }
    }

    /// Picks the vault for Money and the Daily Brief, which share it, then loads.
    func chooseWorkspace(_ path: String) async {
        store.setWorkspace(path, for: server)
        await load()
    }

    /// Reads the snapshot, the market note and spending together. A failed refresh keeps what's on
    /// screen and says so; only a first load shows the error in place of the screen.
    func load() async {
        if snapshot == nil { state = .loading }
        do {
            guard let workspace = try await resolveWorkspace() else { return }
            let sessionID = try await session(workspace: workspace)
            async let snapshotText = read(MoneyPaths.snapshot, sessionID: sessionID)
            async let marketText = read(MoneyPaths.market, sessionID: sessionID)
            async let spendingText = read(MoneyPaths.spending, sessionID: sessionID)
            guard let text = try await snapshotText else {
                snapshot = nil
                market = nil
                spending = nil
                spendingError = nil
                refreshError = nil
                updatePoints()
                state = .noSnapshot
                return
            }
            let decoded = try MoneySnapshot.decode(Data(text.utf8))
            let note = (try? await marketText)
                .flatMap { $0 }
                .flatMap { try? MoneyMarketNote.decode(Data($0.utf8)) }
            do {
                spending = try await spendingText.map { try MoneySpending.decode(Data($0.utf8)) }
                spendingError = nil
            } catch {
                spendingError = error.localizedDescription
            }
            snapshot = decoded
            market = note?.matches(decoded.week) == true ? note : nil
            refreshError = nil
            scrub(to: nil)
            updatePoints()
            state = .ready
        } catch is CancellationError {
            // A newer load owns the state.
        } catch {
            if snapshot == nil || state != .ready {
                state = .failed(error.localizedDescription)
            } else {
                refreshError = error.localizedDescription
            }
        }
    }

    /// The Daily Brief's vault workspace, or the server's only one. With several and none chosen,
    /// asks which (`.needsWorkspace`) and returns nil.
    private func resolveWorkspace() async throws -> String? {
        if let stored = store.workspace(for: server) { return stored }
        let paths = try await client.workspacePaths()
        guard paths.count == 1, let only = paths.first else {
            state = .needsWorkspace(paths)
            return nil
        }
        store.setWorkspace(only, for: server)
        return only
    }

    /// Today's Daily Brief reading session, shared so Money never adds a session of its own
    /// on a day the Brief was opened. A session the server lost is replaced once.
    private func session(workspace: String, replacing lost: String? = nil) async throws -> String {
        if let stored = store.session(for: server, date: today), stored != lost { return stored }
        if let lost, let pending = replacement, pending.lost == lost { return try await pending.task.value }
        let task = Task { () async throws -> String in
            let created = try await self.client.createSession(workspace: workspace)
            self.store.setSession(created, for: self.server, date: self.today)
            try? await self.client.renameSession(id: created, title: DailyDeckViewModel.sessionTitle(for: self.today))
            return created
        }
        if let lost { replacement = (lost, task) }
        defer { if let lost, replacement?.lost == lost { replacement = nil } }
        return try await task.value
    }

    /// A file's text, or nil when it doesn't exist. A lost session is replaced once, like the Brief's.
    private func read(_ path: String, sessionID: String, retry: Bool = true) async throws -> String? {
        do {
            return try await client.fileContent(sessionID: sessionID, path: path)
        } catch let error as APIError where error.isUnusableSession {
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
/// Reads `snapshot.json`, `market.json` and `spending.json` from a local folder, for simulator checks and demos
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
