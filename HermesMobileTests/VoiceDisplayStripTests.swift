import XCTest
@testable import HermesMobile

final class VoiceDisplayStripTests: XCTestCase {
    func testVoicePrefixHiddenInDisplay() {
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice] hello"), "hello")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "hello [voice]"), "hello [voice]")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[voice]"), "")
        XCTAssertEqual(MessageBubbleView.displayText(forUserMessage: "[Voice] hi"), "[Voice] hi")
    }
}
