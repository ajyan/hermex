import XCTest
@testable import HermesMobile

final class VoiceDisplayStripTests: XCTestCase {
    func testVoicePrefixHiddenInDisplay() {
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice] hello"), "hello")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "hello [voice]"), "hello [voice]")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice]"), "")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[Voice] hi"), "[Voice] hi")
    }

    func testTimedVoicePrefixHiddenInDisplay() {
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice 2:41 PM] what time is it"), "what time is it")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice 14:41] hi"), "hi")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice 2:41 PM]"), "")
        XCTAssertEqual(
            MessageBubbleView.displayText(forUserMessage: "[voice this is far too long to be a time] hi"),
            "[voice this is far too long to be a time] hi"
        )
        XCTAssertEqual(
            SessionRowView.displayTitle(for: SessionSummary(sessionId: "s4", title: "[voice 9:05 AM] what's today's date?")),
            "what's today's date?"
        )
    }

    func testVoicePrefixCarriesTheLocalTime() {
        let date = Date(timeIntervalSince1970: 1_791_900_000)  // 2026-10-13 14:00 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(VoiceCallPhrases.voicePrefix(at: date, locale: Locale(identifier: "en_US"), timeZone: utc), "[voice 2:00 PM] ")
        XCTAssertEqual(VoiceCallPhrases.voicePrefix(at: date, locale: Locale(identifier: "en_GB"), timeZone: utc), "[voice 14:00] ")
        let tagged = VoiceCallPhrases.voicePrefix(at: date) + "hello"
        XCTAssertEqual(VoiceCallPhrases.withoutVoiceTag(tagged), "hello", "every prefix the app sends is stripped")
    }

    func testVoicePrefixHiddenInSessionTitles() {
        XCTAssertEqual(
            SessionRowView.displayTitle(for: SessionSummary(sessionId: "s1", title: "[voice] what's today's date?")),
            "what's today's date?"
        )
        XCTAssertEqual(SessionRowView.displayTitle(for: SessionSummary(sessionId: "s2", title: "[voice]")), "Untitled Session")
        XCTAssertEqual(SessionRowView.displayTitle(for: SessionSummary(sessionId: "s3", title: "Plan [voice] work")), "Plan [voice] work")
    }
}
