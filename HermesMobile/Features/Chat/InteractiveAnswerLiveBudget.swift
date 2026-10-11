import CryptoKit
import Foundation
import Observation

/// Decides which interactive answer cards hold a live web view. The transcript
/// keeps every row alive, so without a cap a long chat would keep one WebKit
/// page per tool forever; only cards on or near screen are live, at most
/// `capacity` at once, and the least recently visible one rests first.
@MainActor @Observable
final class InteractiveAnswerLiveBudget {
    static let shared = InteractiveAnswerLiveBudget(capacity: 3)

    private(set) var live: Set<String> = []
    /// Live IDs, least recently visible first.
    @ObservationIgnored private var recency: [String] = []
    /// Last measured heights, so a resting card keeps its size and the chat does not jump.
    @ObservationIgnored private var heights: [String: CGFloat] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func becameVisible(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
        if recency.count > capacity {
            recency.removeFirst(recency.count - capacity)
        }
        let next = Set(recency)
        if next != live { live = next }
    }

    func becameHidden(_ id: String) {
        recency.removeAll { $0 == id }
        if live.contains(id) { live.remove(id) }
    }

    func isLive(_ id: String) -> Bool {
        live.contains(id)
    }

    func rememberHeight(_ height: CGFloat, for id: String) {
        heights[id] = height
    }

    func height(for id: String) -> CGFloat? {
        heights[id]
    }
}

/// A card's identity: the same tool keeps its ID across transcript rebuilds.
enum InteractiveAnswerCardID {
    static func make(fragment: String) -> String {
        SHA256.hash(data: Data(fragment.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
