import Foundation
import WidgetKit

/// The few most recent sessions the Ask Atlas widget lists, written by the app after
/// each successful session-list load and read by the widget extension. It holds only
/// the server that produced it, so a row always opens on its own server. Built from
/// session summaries by the app-only `init(server:sessions:)` in `SessionListViewModel.swift`.
struct AtlasWidgetRecents: Codable, Equatable {
    struct Session: Codable, Equatable {
        let id: String
        let title: String
        let lastActivity: Date
    }

    let server: URL
    let sessions: [Session]

    static let limit = 2
}

/// App-group storage for `AtlasWidgetRecents`, shared by the app and the widget.
struct AtlasWidgetRecentsStore {
    static let widgetKind = "AtlasAskWidget"
    private static let key = "atlasWidget.recents"

    var defaults: UserDefaults? = Self.sharedDefaults

    static var sharedDefaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "HermesAppGroupIdentifier") as? String,
              !group.isEmpty else { return nil }
        return UserDefaults(suiteName: group)
    }

    func load() -> AtlasWidgetRecents? {
        guard let data = defaults?.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(AtlasWidgetRecents.self, from: data)
    }

    /// Stores `recents` and reloads the widget, only when they differ from what's stored.
    func save(_ recents: AtlasWidgetRecents) {
        guard let defaults, load() != recents, let data = try? JSONEncoder().encode(recents) else { return }
        defaults.set(data, forKey: Self.key)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }

    /// Drops the stored recents when they belong to `server` (sign-out or removal).
    func remove(for server: URL) {
        guard let defaults, load()?.server.absoluteString == server.absoluteString else { return }
        defaults.removeObject(forKey: Self.key)
        WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
    }
}
