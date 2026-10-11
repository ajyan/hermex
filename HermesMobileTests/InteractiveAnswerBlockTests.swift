import XCTest
@testable import HermesMobile

final class InteractiveAnswerBlockTests: XCTestCase {
    func testMatchesLanguage() {
        XCTAssertTrue(InteractiveAnswerBlock.matches("atlas-ui"))
        XCTAssertTrue(InteractiveAnswerBlock.matches(" ATLAS-UI "))
        XCTAssertFalse(InteractiveAnswerBlock.matches("html"))
        XCTAssertFalse(InteractiveAnswerBlock.matches(nil))
    }

    func testStreamingIsBuildingWithTitleOnceClosed() {
        XCTAssertEqual(
            InteractiveAnswerBlock.classify(language: "atlas-ui", content: "<title>Split", isStreaming: true),
            .building(title: nil)
        )
        XCTAssertEqual(
            InteractiveAnswerBlock.classify(language: "atlas-ui", content: "<title>Split the bill</title><div>", isStreaming: true),
            .building(title: "Split the bill")
        )
    }

    func testCompleteFragmentIsCard() {
        let fragment = "<title>T</title><style>p{}</style><p>x</p><script>1</script>"
        XCTAssertEqual(
            InteractiveAnswerBlock.classify(language: "atlas-ui", content: "\n" + fragment + "\n", isStreaming: false),
            .card(fragment: fragment, title: "T")
        )
    }

    func testMissingTitleDefaultsToTool() {
        XCTAssertEqual(
            InteractiveAnswerBlock.classify(language: "atlas-ui", content: "<p>x</p>", isStreaming: false),
            .card(fragment: "<p>x</p>", title: "Tool")
        )
    }

    func testUnclosedScriptIsCode() {
        XCTAssertEqual(
            InteractiveAnswerBlock.classify(language: "atlas-ui", content: "<title>T</title><p>x</p><script>let a", isStreaming: false),
            .code
        )
        XCTAssertEqual(
            InteractiveAnswerBlock.classify(language: "atlas-ui", content: "<title>T</title><style>p{", isStreaming: false),
            .code
        )
    }

    func testOversizeIsCode() {
        let content = String(repeating: "a", count: InteractiveAnswerBlock.maxFragmentBytes + 1)
        XCTAssertEqual(InteractiveAnswerBlock.classify(language: "atlas-ui", content: content, isStreaming: false), .code)
    }

    func testEmptyIsCode() {
        XCTAssertEqual(InteractiveAnswerBlock.classify(language: "atlas-ui", content: "   \n", isStreaming: false), .code)
    }

    func testTitleDecodesEntities() {
        XCTAssertEqual(InteractiveAnswerBlock.title(in: "<title> Q&amp;A &lt;3 </title>"), "Q&A <3")
        let long = String(repeating: "x", count: 120)
        XCTAssertEqual(InteractiveAnswerBlock.title(in: "<title>\(long)</title>")?.count, 80)
        XCTAssertNil(InteractiveAnswerBlock.title(in: "<title>open"))
    }
}
