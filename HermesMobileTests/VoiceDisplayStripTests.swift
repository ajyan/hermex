import XCTest
@testable import HermesMobile

final class VoiceDisplayStripTests: XCTestCase {
    func testVoicePrefixHiddenInDisplay() {
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice] hello"), "hello")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "hello [voice]"), "hello [voice]")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice]"), "")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[Voice] hi"), "[Voice] hi")
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
