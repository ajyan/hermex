import XCTest
@testable import HermesMobile

/// How long each deck card is on screen (`DeckUsageTracker`): what the style learner weighs the day's variant by.
final class DeckUsageTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    private func fold(_ segments: [(String, Double)?]) -> [String: Double] {
        segments.compactMap { $0 }.reduce(into: [:]) { $0[$1.0, default: 0] += $1.1 }
    }

    func testSecondsAccumulateAcrossVisits() {
        var tracker = DeckUsageTracker()
        tracker.resume(at: t0)
        let seconds = fold([
            tracker.show("A", at: t0),
            tracker.show("B", at: t0 + 10),
            tracker.show("A", at: t0 + 20),
            tracker.show(nil, at: t0 + 25),
        ])
        XCTAssertEqual(seconds, ["A": 15, "B": 10])
    }

    func testBackgroundStopsTheClock() {
        var tracker = DeckUsageTracker()
        tracker.resume(at: t0)
        let seconds = fold([
            tracker.show("A", at: t0),
            tracker.pause(at: t0 + 5),
            tracker.show("B", at: t0 + 30),  // swiped while backgrounded: the clock stays stopped
            { tracker.resume(at: t0 + 65); return nil }(),
            tracker.show(nil, at: t0 + 70),
        ])
        XCTAssertEqual(seconds, ["A": 5, "B": 5])
        XCTAssertNil(tracker.current)
    }

    func testStartsPausedUntilTheDeckIsOnScreen() {
        var tracker = DeckUsageTracker()
        XCTAssertNil(tracker.show("A", at: t0))
        XCTAssertNil(tracker.show(nil, at: t0 + 30), "no time before resume")
    }

    func testShowingTheSameCardKeepsTheClockRunning() {
        var tracker = DeckUsageTracker()
        tracker.resume(at: t0)
        XCTAssertNil(tracker.show("A", at: t0))
        XCTAssertNil(tracker.show("A", at: t0 + 4))
        XCTAssertEqual(tracker.show(nil, at: t0 + 9)?.1, 9)
    }
}
