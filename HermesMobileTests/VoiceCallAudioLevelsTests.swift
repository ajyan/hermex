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
