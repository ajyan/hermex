import XCTest
@testable import HermesMobile

final class SpeechTextShaperTests: XCTestCase {
    private func spoken(_ text: String) -> [String] {
        var shaper = SpeechTextShaper()
        return shaper.append(text) + shaper.finish()
    }

    func testEmitsSentencesAsTheyComplete() {
        var shaper = SpeechTextShaper()
        XCTAssertEqual(shaper.append("Hi there. How"), ["Hi there."])
        XCTAssertEqual(shaper.append("Hi there. How"), [])
        XCTAssertEqual(shaper.append("Hi there. How are you? I"), ["How are you?"])
        XCTAssertEqual(shaper.finish(), ["I"])
        XCTAssertEqual(shaper.finish(), [])
    }

    func testKeepsAbbreviationsAndDecimals() {
        var shaper = SpeechTextShaper()
        XCTAssertEqual(shaper.append("Use a unit, e.g. 3.5 percent. Next"), ["Use a unit, e.g. 3.5 percent."])
    }

    func testStripsMarkdown() {
        XCTAssertEqual(
            spoken("# Heading\n**bold** move.\n- item\n1. first\nSee [text](https://a.b/c) and `ls`."),
            ["Heading", "bold move.", "item", "first", "See text and ls."]
        )
    }

    func testSkipsFencedCode() {
        XCTAssertEqual(spoken("Run this:\n```\nls -la\n```\nThat lists files."), ["Run this:", "That lists files."])
    }

    func testBareURLSpokenAsLink() {
        XCTAssertEqual(spoken("Open https://example.com/x?y=1 now. Or https://a.io."), ["Open link now.", "Or link."])
    }

    func testCodeHeavyReplySpeaksOnlyLeadSentence() {
        let full = "Here's the fix.\n\n```swift\nlet a = 1\nprint(a)\n```\nMore notes."
        var shaper = SpeechTextShaper()
        var out: [String] = []
        for end in stride(from: 1, through: full.count, by: 3) {
            out += shaper.append(String(full.prefix(end)))
        }
        out += shaper.append(full)
        out += shaper.finish()
        XCTAssertEqual(out, ["Here's the fix."])
    }

    func testStopsAtDetailsBreak() {
        XCTAssertEqual(spoken("Short answer.\n---\nLong details here."), ["Short answer."])
        XCTAssertEqual(spoken("Lead.\n\nMore context.\n\n```\ncode\n```"), ["Lead."])
        XCTAssertEqual(spoken("One.\n\nTwo."), ["One.", "Two."])
    }

    func testFinishFlushesTrailingFragment() {
        var shaper = SpeechTextShaper()
        XCTAssertEqual(shaper.append("Hello there"), [])
        XCTAssertEqual(shaper.finish(), ["Hello there"])
    }
}
