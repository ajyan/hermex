import XCTest
@testable import HermesMobile

final class TurnDetectorTests: XCTestCase {
    /// Feeds `isSpeech` samples every 100 ms over [from, to) and returns every event seen.
    private func feed(_ detector: inout TurnDetector, speech: Bool, from: TimeInterval, to: TimeInterval) -> [TurnEvent] {
        var events: [TurnEvent] = []
        var time = from
        while time < to - 0.0001 {
            if let event = detector.observe(isSpeech: speech, at: time) { events.append(event) }
            time += 0.1
        }
        return events
    }

    func testEndOfTurnAfter800msSilenceFollowing300msSpeech() {
        var detector = TurnDetector()
        XCTAssertEqual(feed(&detector, speech: true, from: 0, to: 0.4), [.speechStarted])
        XCTAssertEqual(feed(&detector, speech: false, from: 0.4, to: 1.15), [])
        XCTAssertEqual(detector.observe(isSpeech: false, at: 1.2), .endOfTurn)
    }

    func testShortBlipUnder300msNeverEndsTurn() {
        var detector = TurnDetector()
        XCTAssertEqual(feed(&detector, speech: true, from: 0, to: 0.2), [.speechStarted])
        XCTAssertEqual(feed(&detector, speech: false, from: 0.2, to: 5), [])
    }

    func testSilenceUnder800msDoesNotEndTurn() {
        var detector = TurnDetector()
        _ = feed(&detector, speech: true, from: 0, to: 1)
        XCTAssertEqual(feed(&detector, speech: false, from: 1, to: 1.7), [])
        XCTAssertEqual(feed(&detector, speech: true, from: 1.7, to: 2.5), [])
        XCTAssertEqual(feed(&detector, speech: false, from: 2.5, to: 3.25), [])
        XCTAssertEqual(detector.observe(isSpeech: false, at: 3.3), .endOfTurn)
    }

    func testMonologueCapForcesEndOfTurnAt30s() {
        var detector = TurnDetector()
        // A long spoken request (well past 10 s) is not cut off.
        XCTAssertEqual(feed(&detector, speech: true, from: 0, to: 29.95), [.speechStarted])
        XCTAssertEqual(detector.observe(isSpeech: true, at: 30.0), .endOfTurn)
    }

    func testResetClearsState() {
        var detector = TurnDetector()
        _ = feed(&detector, speech: true, from: 0, to: 1)
        detector.reset()
        XCTAssertEqual(feed(&detector, speech: false, from: 1, to: 3), [])
        XCTAssertEqual(detector.observe(isSpeech: true, at: 3), .speechStarted)
    }
}
