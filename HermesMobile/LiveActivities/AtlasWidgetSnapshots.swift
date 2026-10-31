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
        /// The row's source (such as Prep) counts today as done, so clearing a check-in would
        /// leave it done. Nil in snapshots saved before this was recorded.
        var sourceCounted: Bool?
        /// The row's Mon–Sun as `DeckDot` states, and today's place in it; nil for a row without
        /// days (and in older snapshots), which shows count pips instead.
        var days: [String]?
        var todayIndex: Int?

        var id: String { Self.id(slug: slug, commitment: commitment) }

        /// A tap on a done row clears it, unless only its source would keep it done.
        var isUndoable: Bool { isDone && sourceCounted != true }

        static func id(slug: String, commitment: String) -> String { "\(slug)/\(commitment)" }
    }

    let server: URL
    /// The server's today (`yyyy-MM-dd`), sent back as a check-in's `date` and `as_of`.
    let today: String
    let streakDays: Int
    var items: [Item]
    var syncFailed = false
    /// The phone's day (`yyyy-MM-dd`) when the app saved this; nil in older snapshots.
    var savedDay: String?

    /// Whether the phone's day has turned since the app saved this, so its check-ins may land on
    /// a day the server has left. Compares the phone's days with each other, never with the
    /// server's `today` (the server may keep another time zone); an older snapshot without
    /// `savedDay` falls back to `today`.
    func isStale(at date: Date) -> Bool {
        (savedDay ?? today) < Self.phoneDay(date)
    }

    static func phoneDay(_ date: Date) -> String { phoneDayFormatter.string(from: date) }

    private static let phoneDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The snapshot as it reads once `id` is ticked (`done`) or unticked, before the server confirms.
    func checking(_ id: String, done: Bool) -> AtlasWidgetGoals {
        var copy = self
        copy.syncFailed = false
        if let i = copy.items.firstIndex(where: { $0.id == id }), copy.items[i].isDone != done {
            copy.items[i].isDone = done
            copy.items[i].weekCount += done ? 1 : -1
        }
        return copy
    }

    /// This snapshot with only row `id` put back as it was in `old`, on the same day; every
    /// other row keeps its state.
    func restoring(_ id: String, from old: AtlasWidgetGoals) -> AtlasWidgetGoals {
        var copy = self
        guard old.today == today, let item = old.items.first(where: { $0.id == id }),
              let i = copy.items.firstIndex(where: { $0.id == id }) else { return copy }
        copy.items[i] = item
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

    /// Drops the stored snapshot unless it belongs to `server` (nil drops any), so another
    /// server's snapshot never stays on a widget while this one is active.
    func remove(except server: URL?) {
        guard let defaults, let stored = load(), stored.server.absoluteString != server?.absoluteString else { return }
        defaults.removeObject(forKey: Snapshot.storageKey)
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

/// The Goals widget's check button: ticks a row (`done`) or, on a done row, clears it. A
/// `LiveActivityIntent` so the system performs it in the app's process, which holds the
/// server's sign-in; the app installs `handler` at launch. Compiled into the widget too, where
/// `handler` stays nil.
struct GoalWidgetCheckInIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Check In Goal"
    static var isDiscoverable = false

    @Parameter(title: "Goal") var slug: String
    @Parameter(title: "Commitment") var commitment: String
    @Parameter(title: "Done", default: true) var done: Bool

    init() {}

    init(slug: String, commitment: String, done: Bool) {
        self.slug = slug
        self.commitment = commitment
        self.done = done
    }

    @MainActor static var handler: ((_ slug: String, _ commitment: String, _ done: Bool) async -> Void)?

    func perform() async throws -> some IntentResult {
        if let handler = await Self.handler {
            await handler(slug, commitment, done)
        } else {
            let store = AtlasWidgetGoalsStore()
            if let snapshot = store.load() { store.save(snapshot.failed()) }
        }
        return .result()
    }
}

extension AtlasWidgetGoals.Item {
    /// The row's days with today following its check mark, which a widget tap flips at once.
    var liveDays: [String]? {
        guard var days, let todayIndex, days.indices.contains(todayIndex) else { return days }
        if isDone {
            days[todayIndex] = "done"
        } else if days[todayIndex] != "off" {
            days[todayIndex] = "today"
        }
        return days
    }
}
