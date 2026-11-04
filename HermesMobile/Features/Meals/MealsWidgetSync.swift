import Foundation

extension AtlasWidgetMeals {
    /// Tonight's meal from the week the server answered for the phone's today.
    init(server: URL, home: MealsHome) {
        self.server = server
        day = home.day
        dishes = home.tonight?.dishes.map { Dish(slug: $0.slug, name: $0.name) } ?? []
        servings = home.tonight?.servings ?? MealsCopy.defaultServings
        logged = home.tonightLogged
    }
}

/// Keeps the Tonight widget's snapshot current and logs its Eating it taps in the app process.
/// Refreshes come from sign-in, server switches and returning to the app (throttled), and from
/// every week the Meals screen loads or saves. Only the active server's meal is ever saved.
@MainActor
enum MealsWidgetSync {
    private static var lastRefresh: (server: URL, at: Date)?
    private static let refreshInterval: TimeInterval = 15 * 60
    private static var isLogging = false

    /// Installs the widget's log handler. Called at launch, including the background launch the
    /// system makes to perform `MealsWidgetLogIntent`.
    static func install() {
        MealsWidgetLogIntent.handler = { await logTonight() }
    }

    /// Re-reads the week into the snapshot, at most every 15 minutes unless `force`, while
    /// `server` is the active server. A server without Meals (404) drops its snapshot.
    static func refresh(
        server: URL,
        force: Bool = false,
        store: AtlasWidgetMealsStore = AtlasWidgetMealsStore(),
        activeServerID: () -> String? = { ServerRegistry.shared.activeServerID },
        client makeClient: (URL) -> MealsScreenClient = { client(for: $0) },
        now: Date = Date()
    ) async {
        guard activeServerID() == server.absoluteString else { return }
        store.remove(except: server)
        if !force, let lastRefresh, lastRefresh.server == server,
           now.timeIntervalSince(lastRefresh.at) < refreshInterval,
           store.load()?.day == AtlasWidgetMeals.localDay(now) { return }
        do {
            let home = try await makeClient(server).home(day: AtlasWidgetMeals.localDay(now))
            guard activeServerID() == server.absoluteString else { return }
            store.save(AtlasWidgetMeals(server: server, home: home))
            lastRefresh = (server, now)
        } catch {
            if (error as? APIError)?.isNotFound == true {
                store.remove(for: server)
                lastRefresh = (server, now)
            }
        }
    }

    /// Takes a week the Meals screen already holds, for the active server only.
    static func update(
        server: URL,
        home: MealsHome,
        store: AtlasWidgetMealsStore = AtlasWidgetMealsStore(),
        activeServerID: () -> String? = { ServerRegistry.shared.activeServerID }
    ) {
        guard activeServerID() == server.absoluteString, !isLogging else { return }
        store.save(AtlasWidgetMeals(server: server, home: home))
        lastRefresh = (server, Date())
    }

    static func clear(except server: URL?, store: AtlasWidgetMealsStore = AtlasWidgetMealsStore()) {
        store.remove(except: server)
    }

    /// Logs the snapshot's meal for its day, showing it logged at once. When the post fails the
    /// widget goes back to Eating it, flagged.
    static func logTonight(
        store: AtlasWidgetMealsStore = AtlasWidgetMealsStore(),
        activeServerID: () -> String? = { ServerRegistry.shared.activeServerID },
        client makeClient: (URL) -> MealsScreenClient = { client(for: $0) },
        now: Date = Date()
    ) async {
        guard let snapshot = store.load(), !snapshot.logged, !snapshot.dishes.isEmpty, !isLogging else { return }
        guard snapshot.server.absoluteString == activeServerID(),
              snapshot.day == AtlasWidgetMeals.localDay(now) else {
            store.save(snapshot.failed())
            return
        }
        isLogging = true
        defer { isLogging = false }
        store.save(snapshot.logging())
        let request = MealsLogRequest(day: snapshot.day, today: snapshot.day, servings: snapshot.servings,
                                      dishes: snapshot.dishes.map { MealsLogDish(dish: $0.slug) })
        do {
            let home = try await makeClient(snapshot.server).log(request)
            if activeServerID() == snapshot.server.absoluteString {
                store.save(AtlasWidgetMeals(server: snapshot.server, home: home))
            }
        } catch {
            if let current = store.load(), current.server == snapshot.server {
                store.save(current.failed())
            }
        }
    }

    /// A Meals client for `server` that reads its custom headers from the Keychain, so it works
    /// in a background launch before any screen has hydrated the shared store.
    nonisolated static func client(for server: URL) -> MealsScreenClient {
        let headers = ProfileEntityProvider.customHeaders(for: server)
        return APIClientMealsScreenAdapter(apiClient: APIClient(baseURL: server, customHeaderProvider: { headers }))
    }
}
