import XCTest
@testable import HermesMobile

final class VoiceCallSceneTests: XCTestCase {
    private let journal = VoiceCallSources.source(path: "journal/2026/10-October/2026-10-22.md")!
    private let wiki = VoiceCallSources.source(path: "wiki/running/taper-plan.md")!

    // MARK: Phase from the call's state

    func testBasePhaseFollowsTheCall() {
        func base(_ state: VoiceCallState, heard: Bool = true, sources: Int = 0) -> VoiceCallScenePhase {
            .base(state: state, heardUser: heard, sourceCount: sources)
        }
        XCTAssertEqual(base(.connecting, heard: false), .idle)
        XCTAssertEqual(base(.listening, heard: false), .idle)
        XCTAssertEqual(base(.listening), .listen)
        XCTAssertEqual(base(.thinking), .think)
        XCTAssertEqual(base(.thinking, sources: 2), .tools)
        XCTAssertEqual(base(.speaking, sources: 2), .speak)
        XCTAssertEqual(base(.awaitingApproval("rm"), sources: 2), .think)
        XCTAssertEqual(base(.reconnecting), .idle)
        XCTAssertEqual(base(.ended(nil)), .idle)
    }

    func testReplyLandsFirstAndACutOffWins() {
        func resolved(_ base: VoiceCallScenePhase, now: TimeInterval) -> VoiceCallScenePhase {
            .resolved(base: base, now: now, convergeUntil: 10, interruptUntil: 5)
        }
        XCTAssertEqual(resolved(.speak, now: 4), .interrupt)
        XCTAssertEqual(resolved(.speak, now: 9.9), .converge)
        XCTAssertEqual(resolved(.speak, now: 10), .speak)
        XCTAssertEqual(resolved(.listen, now: 9), .listen)
        XCTAssertEqual(resolved(.listen, now: 4.9), .interrupt)
    }

    // MARK: Tracking a turn

    func testFirstWordsWakeTheField() {
        var tracker = VoiceCallSceneTracker()
        tracker.heard("")
        XCTAssertFalse(tracker.heardUser)
        tracker.heard("When did")
        XCTAssertTrue(tracker.heardUser)
    }

    func testMemoriesResetWhenATurnIsSentAndGrowOnlyWhileStreaming() {
        var tracker = VoiceCallSceneTracker()
        tracker.stateChanged(from: .listening, to: .thinking)
        XCTAssertTrue(tracker.heardUser)
        tracker.absorb([journal], isStreaming: false)
        XCTAssertTrue(tracker.sources.isEmpty)
        tracker.absorb([journal], isStreaming: true)
        tracker.absorb([wiki, journal], isStreaming: true)
        XCTAssertEqual(tracker.sources, [journal, wiki])

        // An approval mid-turn keeps them.
        tracker.stateChanged(from: .thinking, to: .awaitingApproval("ok?"))
        tracker.stateChanged(from: .awaitingApproval("ok?"), to: .thinking)
        XCTAssertEqual(tracker.sources.count, 2)

        tracker.stateChanged(from: .thinking, to: .speaking)
        XCTAssertEqual(tracker.replyStarts, 1)
        XCTAssertEqual(tracker.foundAnnouncement, "Found 2 notes")

        // The run ends; the reply's memories stay until the next turn goes out.
        tracker.absorb([], isStreaming: false)
        tracker.stateChanged(from: .speaking, to: .listening)
        XCTAssertEqual(tracker.sources.count, 2)
        tracker.stateChanged(from: .listening, to: .thinking)
        XCTAssertTrue(tracker.sources.isEmpty)
        XCTAssertNil(tracker.foundAnnouncement)
    }

    func testAReplyWithOneMemoryAnnouncesItSingular() {
        var tracker = VoiceCallSceneTracker()
        tracker.stateChanged(from: .listening, to: .thinking)
        tracker.absorb([wiki], isStreaming: true)
        tracker.stateChanged(from: .thinking, to: .speaking)
        XCTAssertEqual(tracker.foundAnnouncement, "Found 1 note")
    }

    // MARK: Layout

    func testScatterKeepsItsGapForEverySeed() {
        for seed in UInt64(0)..<60 {
            var rng = StarfieldRandom(seed: seed)
            for (count, gap) in [(4, 0.62), (6, 0.5), (6, 0.95)] {
                let points = ConstellationLayout.scatter(count: count, rMin: 0.45, rMax: 1, minGap: gap, using: &rng)
                XCTAssertEqual(points.count, count)
                for i in points.indices {
                    let radius = (points[i].x * points[i].x + points[i].y * points[i].y).squareRoot()
                    XCTAssertLessThanOrEqual(radius, 1.000_001)
                    XCTAssertGreaterThanOrEqual(radius, 0.449_999)
                    for j in points.indices where j > i {
                        let d = points[i] - points[j]
                        XCTAssertGreaterThanOrEqual((d.x * d.x + d.y * d.y).squareRoot(), gap - 1e-9, "seed \(seed)")
                    }
                }
            }
        }
    }

    func testEachTurnDrawsADifferentConstellation() {
        var first = StarfieldRandom(seed: 1), second = StarfieldRandom(seed: 2), replay = StarfieldRandom(seed: 1)
        let a = ConstellationLayout.turn(using: &first)
        let b = ConstellationLayout.turn(using: &second)
        let c = ConstellationLayout.turn(using: &replay)
        XCTAssertNotEqual(a.slots, b.slots)
        XCTAssertEqual(a.slots, c.slots)
        XCTAssertEqual(a.slots.count, VoiceCallSources.cap)
        // The shape keeps the layout's arrangement, pulled in, flipped to y-up, at a bounded depth.
        for (slot, knot) in zip(a.slots, a.shape) {
            XCTAssertEqual(knot.x, slot.x * 0.68, accuracy: 1e-9)
            XCTAssertEqual(knot.y, -slot.y * 0.68, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(abs(knot.z), 0.45)
        }
    }

    func testNoiseIsSmoothAndInRange() {
        for step in 0..<200 {
            let x = Double(step) * 0.037
            let value = StarNoise.value(x, 1.3, -2.7)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
            XCTAssertLessThan(abs(StarNoise.value(x + 0.001, 1.3, -2.7) - value), 0.01)
        }
    }
}
