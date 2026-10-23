import Foundation

/// Times the card on screen while the app is active, for the style learner's usage signal (`DeckUsage.seconds`).
/// A value driven by explicit timestamps: each call that ends a stretch of looking returns it (card, seconds), for
/// the deck's view model to add to that card's usage. No timers.
struct DeckUsageTracker {
    /// The card on screen; nil off a card.
    private(set) var current: String?
    /// When the running stretch began; nil while paused or off a card.
    private var since: Date?
    private var isPaused = false

    /// The card on screen changed to `card` (nil: none). Returns the stretch the previous card just finished.
    mutating func show(_ card: String?, at date: Date) -> (String, Double)? {
        guard card != current else { return nil }
        let finished = close(at: date)
        current = card
        since = isPaused || card == nil ? nil : date
        return finished
    }

    /// The app left the foreground: the clock stops, and the stretch so far is returned.
    mutating func pause(at date: Date) -> (String, Double)? {
        let finished = close(at: date)
        isPaused = true
        return finished
    }

    /// The app is active again: the card on screen starts a new stretch.
    mutating func resume(at date: Date) {
        isPaused = false
        if current != nil, since == nil { since = date }
    }

    private mutating func close(at date: Date) -> (String, Double)? {
        guard let current, let since else { return nil }
        self.since = nil
        return (current, max(0, date.timeIntervalSince(since)))
    }
}
