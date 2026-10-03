import XCTest
@testable import HermesMobile

final class VoiceSelectionTests: XCTestCase {
    private let basic = VoiceCandidate(identifier: "basic", language: "en-US", quality: .standard, isPersonalVoice: false)
    private let enhanced = VoiceCandidate(identifier: "enhanced", language: "en-GB", quality: .enhanced, isPersonalVoice: false)
    private let premium = VoiceCandidate(identifier: "premium", language: "en-US", quality: .premium, isPersonalVoice: false)
    private let personal = VoiceCandidate(identifier: "personal", language: "en-US", quality: .standard, isPersonalVoice: true)
    private let french = VoiceCandidate(identifier: "french", language: "fr-FR", quality: .premium, isPersonalVoice: false)

    func testPersonalVoiceWinsWhenAuthorized() {
        let voices = [basic, premium, personal]
        XCTAssertEqual(VoiceSelection.best(from: voices, personalVoiceAuthorized: true, language: "en")?.identifier, "personal")
        XCTAssertEqual(VoiceSelection.best(from: voices, personalVoiceAuthorized: false, language: "en")?.identifier, "premium")
    }

    func testPremiumBeatsEnhanced() {
        XCTAssertEqual(VoiceSelection.best(from: [basic, enhanced, premium], personalVoiceAuthorized: false, language: "en")?.identifier, "premium")
        XCTAssertEqual(VoiceSelection.best(from: [basic, enhanced], personalVoiceAuthorized: false, language: "en")?.identifier, "enhanced")
    }

    func testLanguageMismatchExcluded() {
        XCTAssertEqual(VoiceSelection.best(from: [french, basic], personalVoiceAuthorized: false, language: "en")?.identifier, "basic")
    }

    func testNilWhenNoMatch() {
        XCTAssertNil(VoiceSelection.best(from: [french], personalVoiceAuthorized: true, language: "en"))
        XCTAssertNil(VoiceSelection.best(from: [], personalVoiceAuthorized: true, language: "en"))
    }
}
