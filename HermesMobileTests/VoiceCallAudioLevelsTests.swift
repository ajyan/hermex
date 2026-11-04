import XCTest
@testable import HermesMobile

final class VoiceCallAudioLevelsTests: XCTestCase {
    func testMicLevelIsClamped() {
        let levels = VoiceCallAudioLevels()
        levels.setMic(1.7)
        XCTAssertEqual(levels.read(at: 0).mic, 1)
        levels.setMic(-0.2)
        XCTAssertEqual(levels.read(at: 0).mic, 0)
    }

    func testSpokenWordSwellsThenFades() {
        let levels = VoiceCallAudioLevels()
        XCTAssertEqual(levels.read(at: 10).voice, 0)
        levels.wordSpoken(length: 6, at: 10)
        let peak = levels.read(at: 10.05).voice
        XCTAssertGreaterThan(peak, 0.4)
        XCTAssertLessThan(levels.read(at: 10.6).voice, peak / 3)
        XCTAssertEqual(levels.read(at: 12).voice, 0)
    }

    func testVoiceStoppedSilencesAtOnce() {
        let levels = VoiceCallAudioLevels()
        levels.wordSpoken(length: 6, at: 10)
        levels.voiceStopped()
        XCTAssertEqual(levels.read(at: 10.05).voice, 0)
    }
}

final class VoiceRipplesTests: XCTestCase {
    /// Feeds `levels` one frame apart (60 fps) from `start`; returns the clock after the last.
    private func feed(_ ripples: inout VoiceRipples, _ levels: [Double], from start: Double = 0) -> Double {
        var clock = start
        for level in levels {
            ripples.step(voice: level, at: clock, dt: 1.0 / 60, cutOff: false)
            clock += 1.0 / 60
        }
        return clock
    }

    func testEachWordSendsOneRippleAndASteadyVoiceNone() {
        var ripples = VoiceRipples()
        var clock = feed(&ripples, Array(repeating: 0.7, count: 30))
        XCTAssertEqual(ripples.started.count, 1)
        // A dip and a new rise is the next word.
        clock = feed(&ripples, Array(repeating: 0.1, count: 6) + Array(repeating: 0.7, count: 6), from: clock)
        XCTAssertEqual(ripples.started.count, 2)
        XCTAssertEqual(ripples.started.last?.strength ?? 0, 0.82, accuracy: 0.001)
        _ = feed(&ripples, Array(repeating: 0, count: 120), from: clock)
        XCTAssertTrue(ripples.started.isEmpty)
    }

    func testRipplesRunOutAndFade() {
        var ripples = VoiceRipples()
        ripples.step(voice: 1, at: 10, dt: 1.0 / 60, cutOff: false)
        let front = ripples.fronts(at: 10.7)[0]
        XCTAssertEqual(front.front, 0.665, accuracy: 0.001)
        XCTAssertEqual(front.strength, 0.5, accuracy: 0.001)
    }

    func testCutOffClearsRipplesAtOnce() {
        var ripples = VoiceRipples()
        ripples.step(voice: 1, at: 0, dt: 1.0 / 60, cutOff: false)
        ripples.step(voice: 0, at: 0.02, dt: 1.0 / 60, cutOff: true)
        XCTAssertTrue(ripples.started.isEmpty)
    }
}
