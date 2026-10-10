import AppIntents
import Foundation
import WidgetKit

/// What the app publishes for one Home Screen widget. Each snapshot names the server
/// that produced it, so nothing in a widget acts on another server.
protocol AtlasWidgetSnapshot: Codable, Equatable {
    static var storageKey: String { get }
    static var widgetKind: String { get }
    var server: URL { get }
}

/// The few most recent sessions the Ask Atlas widget lists, written by the app after
/// each successful session-list load. Built from session summaries by the app-only
/// `init(server:sessions:)` in `SessionListViewModel.swift`.
struct AtlasWidgetRecents: AtlasWidgetSnapshot {
    static let storageKey = "atlasWidget.recents"
    static let widgetKind = "AtlasAskWidget"
    static let limit = 2

    struct Session: Codable, Equatable {
        let id: String
        let title: String
        let lastActivity: Date
    }

    let server: URL
    let sessions: [Session]
}

/// Today's goal commitments for the Goals widget, on the server's calendar. Built from
/// `GoalsHome` by the app-only `init(server:home:)` in `GoalsWidgetSync.swift`.
struct AtlasWidgetGoals: AtlasWidgetSnapshot {
    static let storageKey = "atlasWidget.goals"
    static let widgetKind = "AtlasGoalsWidget"
    static let limit = 3

    struct Item: Codable, Equatable, Identifiable {
        let slug: String
        let commitment: String
        let action: String
        /// This week's shown-up days (done plus minimum) against the weekly target.
        var weekCount: Int
        let target: Int
        var isDone: Bool

        var id: String { Self.id(slug: slug, commitment: commitment) }

        static func id(slug: String, commitment: String) -> String { "\(slug)/\(commitment)" }
    }

    let server: URL
    /// The server's today (`yyyy-MM-dd`), sent back as a check-in's `date` and `as_of`.
    let today: String
    let streakDays: Int
    var items: [Item]
    var syncFailed = false

    /// The snapshot as it reads once `id` is checked in, before the server confirms.
    func checkingIn(_ id: String) -> AtlasWidgetGoals {
        var copy = self
        copy.syncFailed = false
        if let i = copy.items.firstIndex(where: { $0.id == id }), !copy.items[i].isDone {
            copy.items[i].isDone = true
            copy.items[i].weekCount += 1
        }
        return copy
    }

    func failed() -> AtlasWidgetGoals {
        var copy = self
        copy.syncFailed = true
        return copy
    }
}

/// App-group storage for one widget snapshot, shared by the app and the widget extension.
struct AtlasWidgetStore<Snapshot: AtlasWidgetSnapshot> {
    var defaults: UserDefaults? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String,
              !group.isEmpty else { return nil }
        return UserDefaults(suiteName: group)
    }()

    func load() -> Snapshot? {
        guard let data = defaults?.data(forKey: Snapshot.storageKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Stores `snapshot` and reloads its widget, only when it differs from what's stored.
    func save(_ snapshot: Snapshot) {
        guard let defaults, load() != snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Snapshot.storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: Snapshot.widgetKind)
    }

    /// Drops the stored snapshot when it belongs to `server` (sign-out, removal, or a
    /// server without the feature).
    func remove(for server: URL) {
        guard let defaults, load()?.server.absoluteString == server.absoluteString else { return }
        defaults.removeObject(forKey: Snapshot.storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: Snapshot.widgetKind)
    }
}

typealias AtlasWidgetRecentsStore = AtlasWidgetStore<AtlasWidgetRecents>
typealias AtlasWidgetGoalsStore = AtlasWidgetStore<AtlasWidgetGoals>

/// The Goals widget's check button. A `LiveActivityIntent` so the system performs it in
/// the app's process, which holds the server's sign-in; the app installs `handler` at
/// launch. Compiled into the widget too, where `handler` stays nil.
struct GoalWidgetCheckInIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Check In Goal"
    static var isDiscoverable = false

    @Parameter(title: "Goal") var slug: String
    @Parameter(title: "Commitment") var commitment: String

    init() {}

    init(slug: String, commitment: String) {
        self.slug = slug
        self.commitment = commitment
    }

    @MainActor static var handler: ((_ slug: String, _ commitment: String) async -> Void)?

    func perform() async throws -> some IntentResult {
        if let handler = await Self.handler {
            await handler(slug, commitment)
        } else {
            let store = AtlasWidgetGoalsStore()
            if let snapshot = store.load() { store.save(snapshot.failed()) }
        }
        return .result()
    }
}
