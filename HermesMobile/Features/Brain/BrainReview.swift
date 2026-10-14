import Foundation

/// Where the user is in today's review deck: which day's deck, which batch of ten, which page.
struct BrainReviewPosition: Codable, Equatable {
    var day: String
    var batch: Int
    var index: Int
}

/// Per-server review position in UserDefaults. Keys end in `|<server absoluteString>` like
/// `DailyDeckStore`; `remove(for:)` runs when a server is removed.
struct BrainReviewStore {
    var defaults: UserDefaults = .standard

    private func key(_ server: URL) -> String { "brainReview.position|\(server.absoluteString)" }

    func position(for server: URL) -> BrainReviewPosition? {
        guard let data = defaults.data(forKey: key(server)) else { return nil }
        return try? JSONDecoder().decode(BrainReviewPosition.self, from: data)
    }

    func save(_ position: BrainReviewPosition, for server: URL) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: key(server))
    }

    func remove(for server: URL) {
        defaults.removeObject(forKey: key(server))
    }

    /// `2026-10-14` in the device's time zone: the review deck's day is the user's day.
    static func today() -> String { DailyDeckPaths.day(Date()) }
}

/// One page of the review pager: a bite, then a closing summary.
enum BrainReviewPage: Identifiable, Hashable {
    case bite(BrainBite)
    case summary

    var id: String {
        switch self {
        case .bite(let bite): bite.id
        case .summary: "summary"
        }
    }
}
