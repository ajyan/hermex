import AppIntents
import Foundation
import SwiftUI
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
        /// The goal's paper name (`GoalPaper`'s "wiki", "quote", …), so the row's dots wear its
        /// color; nil in older snapshots.
        var paper: String?

        var id: String { Self.id(slug: slug, commitment: commitment) }

        /// A tap on a done row clears it, unless only its source would keep it done.
        var isUndoable: Bool { isDone && sourceCounted != true }

        static func id(slug: String, commitment: String) -> String { "\(slug)/\(commitment)" }
    }

    let server: URL
    /// The server's today (`yyyy-MM-dd`), sent back as a check-in's `date` and `as_of`.
    var today: String
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

    /// Whole days between two `yyyy-MM-dd` days, counted in UTC so daylight saving never shortens one.
    static func days(from start: String, to end: String) -> Int? {
        guard let a = isoDayFormatter.date(from: start), let b = isoDayFormatter.date(from: end) else { return nil }
        return isoCalendar.dateComponents([.day], from: a, to: b).day
    }

    static func isoDay(_ day: String, plus n: Int) -> String? {
        guard let date = isoDayFormatter.date(from: day),
              let moved = isoCalendar.date(byAdding: .day, value: n, to: date) else { return nil }
        return isoDayFormatter.string(from: moved)
    }

    /// Monday 0 through Sunday 6.
    static func weekdayIndex(_ day: String) -> Int? {
        isoDayFormatter.date(from: day).map { (isoCalendar.component(.weekday, from: $0) + 5) % 7 }
    }

    private static let isoCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = isoCalendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// A goal's paper by the name `GoalPaper` gives it; nil for a name it doesn't know.
    static func paper(named name: String?) -> HermexPaper? {
        switch name {
        case "wiki": .wiki
        case "quote": .quote
        case "book": .book
        case "reading": .reading
        case "notes": .notes
        case "video": .video
        case "past": .past
        case "opener": .opener
        default: nil
        }
    }

    private static let phoneDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The snapshot as the phone's day at `date` reads it. While the day it was saved lasts, itself;
    /// once the phone's day has turned (the widget at 6 am, before the app has loaded the new day),
    /// rolled forward on its own: the server's day moved by as many days, every row unchecked, today's
    /// dot ringed, the week's earlier days kept (the day before unlogged as the Brief's `ask`), and on
    /// a new week a fresh one, its count back to zero. A row its days say isn't due today drops off.
    func rolled(at date: Date) -> AtlasWidgetGoals {
        let phone = Self.phoneDay(date)
        let saved = savedDay ?? today
        guard saved < phone, let n = Self.days(from: saved, to: phone), n > 0,
              let newToday = Self.isoDay(today, plus: n) else { return self }
        let newWeek = n >= 7 || (Self.weekdayIndex(newToday) ?? 0) < (Self.weekdayIndex(today) ?? 0)
        var copy = self
        copy.today = newToday
        copy.savedDay = phone
        copy.items = items.compactMap { $0.rolled(by: n, newWeek: newWeek, weekday: Self.weekdayIndex(newToday)) }
        return copy
    }

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

/// Tonight's meal for the Tonight widget, on the phone's calendar. Built from `MealsHome` by the
/// app-only `init(server:home:)` in `MealsWidgetSync.swift`.
struct AtlasWidgetMeals: AtlasWidgetSnapshot {
    static let storageKey = "atlasWidget.meals"
    static let widgetKind = "AtlasMealsWidget"

    struct Dish: Codable, Equatable {
        let slug: String
        let name: String
    }

    let server: URL
    /// The phone's local day this snapshot is for (YYYY-MM-DD); another day shows no meal.
    let day: String
    /// Tonight's meal, main first; empty when nothing is planned.
    let dishes: [Dish]
    let servings: Int
    var logged: Bool
    var syncFailed: Bool = false

    /// The meal as logged, waiting for the server to say so.
    func logging() -> AtlasWidgetMeals {
        var copy = self
        copy.logged = true
        copy.syncFailed = false
        return copy
    }

    func failed() -> AtlasWidgetMeals {
        var copy = self
        copy.logged = false
        copy.syncFailed = true
        return copy
    }

    /// The phone's local calendar day, as `day` is written.
    static func localDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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
typealias AtlasWidgetMealsStore = AtlasWidgetStore<AtlasWidgetMeals>

/// The Tonight widget's Eating it button: logs tonight's meal. A `LiveActivityIntent` so the
/// system performs it in the app's process, which holds the server's sign-in; the app installs
/// `handler` at launch. Compiled into the widget too, where `handler` stays nil.
struct MealsWidgetLogIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Log Tonight's Dinner"
    static var isDiscoverable = false

    init() {}

    @MainActor static var handler: (() async -> Void)?

    func perform() async throws -> some IntentResult {
        if let handler = await Self.handler {
            await handler()
        } else {
            let store = AtlasWidgetMealsStore()
            if let snapshot = store.load() { store.save(snapshot.failed()) }
        }
        return .result()
    }
}

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
    /// The row `n` days later (`AtlasWidgetGoals.rolled(at:)`): unchecked, today ringed, the days it
    /// passed kept, the last of them `ask` and any before it missed; nil when today isn't due.
    /// `weekday` is the new day's place in its week, for a row without days.
    func rolled(by n: Int, newWeek: Bool, weekday: Int?) -> Self? {
        var item = self
        item.isDone = false
        item.sourceCounted = false
        if newWeek { item.weekCount = 0 }
        guard let old = liveDays, old.count == 7, let todayIndex, old.indices.contains(todayIndex) else {
            item.todayIndex = nil
            return item
        }
        let index = newWeek ? (weekday ?? (todayIndex + n) % 7) : todayIndex + n
        // A new week keeps only which days aren't due, from the last one.
        var days = newWeek ? old.map { $0 == "off" ? "off" : "ahead" } : old
        let passed = newWeek ? Array(0..<index) : Array(todayIndex..<index)
        for i in passed where days[i] == "today" || days[i] == "ahead" {
            days[i] = i == index - 1 ? "ask" : "missed"
        }
        guard days.indices.contains(index), days[index] != "off" else { return nil }
        days[index] = "today"
        item.days = days
        item.todayIndex = index
        return item
    }

    /// The row's dots and mark in its goal's paper; the Brief's quote blue for an older snapshot.
    var paperColors: HermexPaper { AtlasWidgetGoals.paper(named: paper) ?? .quote }

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

/// What an Ask Atlas widget button starts.
enum AtlasWidgetLaunch: String, AppEnum {
    case call
    case voiceChat

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Atlas Action"
    static var caseDisplayRepresentations: [AtlasWidgetLaunch: DisplayRepresentation] = [
        .call: "Call Atlas",
        .voiceChat: "New Chat with Voice",
    ]
}

/// The Ask Atlas widget's Call Atlas and Dictate buttons. An `OpenIntent` in both targets, so
/// the system opens the app and performs it there, where `handler` (installed at launch) routes
/// it like Siri's intents: the call or dictation starts once App Lock allows. A plain
/// `hermes-agent://` link can come from any app, so it waits for a tap instead. Compiled into
/// the widget too, where `handler` stays nil.
struct AtlasWidgetLaunchIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Atlas"
    static var isDiscoverable = false

    @Parameter(title: "Action") var target: AtlasWidgetLaunch

    init() {}

    init(_ target: AtlasWidgetLaunch) {
        self.target = target
    }

    @MainActor static var handler: ((AtlasWidgetLaunch) -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.handler?(target)
        return .result()
    }
}
