import Foundation

extension AtlasWidgetGoals {
    /// Up to `limit` commitments due today across active goals, in the server's order.
    init(server: URL, home: GoalsHome) {
        self.server = server
        today = home.today
        streakDays = home.streak.days
        items = home.goals
            .flatMap { goal in
                goal.week.commitments
                    .filter(\.dueToday)
                    .map { c in
                        Item(
                            slug: goal.slug,
                            commitment: c.id,
                            action: c.action,
                            weekCount: c.done + c.min,
                            target: c.target,
                            isDone: c.today?.isShown == true
                        )
                    }
            }
            .prefix(Self.limit)
            .map { $0 }
    }
}

/// Keeps the Goals widget's snapshot current and performs its check-ins in the app
/// process. Refreshes come from session-list loads (throttled), leaving the Goals
/// screens, and each widget check-in.
@MainActor
enum GoalsWidgetSync {
    private static var lastRefresh: (server: URL, at: Date)?
    private static let refreshInterval: TimeInterval = 15 * 60

    /// Installs the widget check-in handler. Called at launch, including the background
    /// launch the system makes to perform `GoalWidgetCheckInIntent`.
    static func install() {
        GoalWidgetCheckInIntent.handler = { slug, commitment in
            await checkIn(slug: slug, commitment: commitment)
        }
    }

    /// Re-reads `GET /api/goals` into the snapshot, at most every 15 minutes unless
    /// `force`. A server without Goals (404) drops its snapshot.
    static func refresh(server: URL, force: Bool = false, store: AtlasWidgetGoalsStore = AtlasWidgetGoalsStore()) async {
        if !force, let lastRefresh, lastRefresh.server == server,
           Date().timeIntervalSince(lastRefresh.at) < refreshInterval { return }
        do {
            store.save(AtlasWidgetGoals(server: server, home: try await client(for: server).home()))
            lastRefresh = (server, Date())
        } catch {
            // Only an answer counts toward the throttle, so a refresh made before sign-in
            // settles is retried on the next trigger.
            if (error as? APIError)?.isNotFound == true {
                store.remove(for: server)
                lastRefresh = (server, Date())
            }
        }
    }

    /// Ticks the commitment at once, posts it for the snapshot's day, then takes the
    /// server's state; on failure restores the snapshot and flags it.
    static func checkIn(
        slug: String,
        commitment: String,
        store: AtlasWidgetGoalsStore = AtlasWidgetGoalsStore(),
        activeServerID: String? = ServerRegistry.shared.activeServerID,
        client makeClient: (URL) -> GoalsDataClient = { client(for: $0) }
    ) async {
        guard let snapshot = store.load() else { return }
        guard snapshot.server.absoluteString == activeServerID else {
            store.save(snapshot.failed())
            return
        }
        store.save(snapshot.checkingIn(AtlasWidgetGoals.Item.id(slug: slug, commitment: commitment)))
        let client = makeClient(snapshot.server)
        do {
            _ = try await client.checkIn(.commitment(
                slug: slug, date: snapshot.today, asOf: snapshot.today, id: commitment, status: .done
            ))
            store.save(AtlasWidgetGoals(server: snapshot.server, home: try await client.home()))
        } catch {
            // A 409 means the server's day moved on: show the new day, still flagged.
            if case .http(409, _)? = error as? APIError, let home = try? await client.home() {
                store.save(AtlasWidgetGoals(server: snapshot.server, home: home).failed())
            } else {
                store.save(snapshot.failed())
            }
        }
        lastRefresh = (snapshot.server, Date())
    }

    /// A Goals client for `server` that reads its custom headers from the Keychain, so
    /// it works in a background launch before any screen has hydrated the shared store.
    nonisolated private static func client(for server: URL) -> GoalsDataClient {
        let stored = try? KeychainStore().load(.customHeaders, scope: server.absoluteString)
        let headers = [CustomHeader].decodeFromStorage(stored)
        return APIClientGoalsAdapter(apiClient: APIClient(baseURL: server, customHeaderProvider: { headers }))
    }
}
