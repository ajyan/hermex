import Foundation

extension AtlasWidgetGoals {
    /// Up to `limit` day commitments due today across active goals, in the server's order. A row
    /// is done the way the app counts it (a check-in, or its source such as Prep counting the day);
    /// item commitments (counted by +1) stay off the widget.
    init(server: URL, home: GoalsHome, savedAt: Date = Date()) {
        self.server = server
        today = home.today
        streakDays = home.streak.days
        savedDay = Self.phoneDay(savedAt)
        items = home.goals
            .flatMap { goal in
                goal.week.commitments
                    .filter { $0.dueToday && !$0.isItem }
                    .map { c in
                        Item(
                            slug: goal.slug,
                            commitment: c.id,
                            action: c.action,
                            weekCount: c.done + c.min,
                            target: c.target,
                            isDone: c.effectiveStatus(home.today, today: home.today, yesterday: home.yesterday)?.isShown == true,
                            sourceCounted: c.sourceDays.contains(home.today),
                            days: c.weekDays.count == 7 ? GoalPips.weekStates(c, today: home.today) : nil,
                            todayIndex: c.weekDays.firstIndex { $0.date == home.today }
                        )
                    }
            }
            .prefix(Self.limit)
            .map { $0 }
    }
}

/// Keeps the Goals widget's snapshot current and performs its check-ins in the app process.
/// Refreshes come from sign-in, server switches and returning to the app (throttled), and
/// from every check-in in the app or on the widget. Only the active server's goals are ever
/// saved: a refresh that lands after a switch is dropped, and switching to a server that
/// can't serve Goals drops the last server's snapshot.
@MainActor
enum GoalsWidgetSync {
    private static var lastRefresh: (server: URL, at: Date)?
    private static let refreshInterval: TimeInterval = 15 * 60
    /// Widget taps still in flight, by item id: whether each marks its row done. Replayed over
    /// any snapshot saved meanwhile, so a refresh never unticks a tap the server hasn't answered.
    private static var inFlight: [String: Bool] = [:]

    /// Installs the widget check-in handler. Called at launch, including the background
    /// launch the system makes to perform `GoalWidgetCheckInIntent`.
    static func install() {
        GoalWidgetCheckInIntent.handler = { slug, commitment, done in
            await checkIn(slug: slug, commitment: commitment, done: done)
        }
    }

    /// Re-reads `GET /api/goals` into the snapshot, at most every 15 minutes unless `force`,
    /// while `server` is the active server. Another server's snapshot goes first, whatever this
    /// read returns; a server without Goals (404) drops its own too.
    static func refresh(
        server: URL,
        force: Bool = false,
        store: AtlasWidgetGoalsStore = AtlasWidgetGoalsStore(),
        activeServerID: () -> String? = { ServerRegistry.shared.activeServerID },
        client makeClient: (URL) -> GoalsDataClient = { client(for: $0) }
    ) async {
        guard activeServerID() == server.absoluteString else { return }
        store.remove(except: server)
        if !force, let lastRefresh, lastRefresh.server == server,
           Date().timeIntervalSince(lastRefresh.at) < refreshInterval { return }
        do {
            let home = try await makeClient(server).home()
            // The user may have switched servers while this was in flight.
            guard activeServerID() == server.absoluteString else { return }
            save(home, server: server, store: store)
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

    /// `refresh(server:force: true)` without waiting: after a check-in, finish or reopen in the app.
    static func refreshAfterChange(server: URL) {
        Task { await refresh(server: server, force: true) }
    }

    /// Takes a home the app already holds (the Deck's goal card after a check-in), for the
    /// active server only.
    static func update(
        server: URL,
        home: GoalsHome,
        store: AtlasWidgetGoalsStore = AtlasWidgetGoalsStore(),
        activeServerID: () -> String? = { ServerRegistry.shared.activeServerID }
    ) {
        guard activeServerID() == server.absoluteString else { return }
        save(home, server: server, store: store)
        lastRefresh = (server, Date())
    }

    /// Drops the snapshot unless it belongs to `server` (nil drops any): for an active server
    /// that can't load Goals at all, such as a Hermes server or none signed in.
    static func clear(except server: URL?, store: AtlasWidgetGoalsStore = AtlasWidgetGoalsStore()) {
        store.remove(except: server)
    }

    /// Ticks (`done`) or unticks one row at once and posts it for the snapshot's day. Once the
    /// server has it, its state replaces the snapshot, or the tick stays when that read fails.
    /// When the post fails, only this row goes back, flagged; a 409 (the server's day moved on)
    /// shows the new day, flagged.
    static func checkIn(
        slug: String,
        commitment: String,
        done: Bool = true,
        store: AtlasWidgetGoalsStore = AtlasWidgetGoalsStore(),
        activeServerID: () -> String? = { ServerRegistry.shared.activeServerID },
        client makeClient: (URL) -> GoalsDataClient = { client(for: $0) }
    ) async {
        guard let snapshot = store.load() else { return }
        guard snapshot.server.absoluteString == activeServerID() else {
            store.save(snapshot.failed())
            return
        }
        let id = AtlasWidgetGoals.Item.id(slug: slug, commitment: commitment)
        guard inFlight[id] == nil else { return }
        inFlight[id] = done
        store.save(snapshot.checking(id, done: done))
        let server = snapshot.server
        let client = makeClient(server)
        let request = GoalCheckInRequest.commitment(
            slug: slug, date: snapshot.today, asOf: snapshot.today, id: commitment, status: done ? .done : .clear
        )
        do {
            _ = try await client.checkIn(request, clientID: UUID().uuidString)
        } catch {
            inFlight[id] = nil
            if case .http(409, _)? = error as? APIError, let home = try? await client.home(),
               activeServerID() == server.absoluteString {
                var fresh = replayed(AtlasWidgetGoals(server: server, home: home))
                fresh.syncFailed = true
                store.save(fresh)
            } else if let current = store.load(), current.server == server {
                store.save(current.restoring(id, from: snapshot).failed())
            }
            return
        }
        inFlight[id] = nil
        if let home = try? await client.home(), activeServerID() == server.absoluteString {
            save(home, server: server, store: store)
        }
        lastRefresh = (server, Date())
    }

    private static func save(_ home: GoalsHome, server: URL, store: AtlasWidgetGoalsStore) {
        store.save(replayed(AtlasWidgetGoals(server: server, home: home)))
    }

    private static func replayed(_ goals: AtlasWidgetGoals) -> AtlasWidgetGoals {
        inFlight.reduce(goals) { $0.checking($1.key, done: $1.value) }
    }

    /// A Goals client for `server` that reads its custom headers from the Keychain, so
    /// it works in a background launch before any screen has hydrated the shared store.
    nonisolated private static func client(for server: URL) -> GoalsDataClient {
        let headers = ProfileEntityProvider.customHeaders(for: server)
        return APIClientGoalsAdapter(apiClient: APIClient(baseURL: server, customHeaderProvider: { headers }))
    }
}
