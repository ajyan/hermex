import XCTest
@testable import HermesMobile

final class InteractiveAnswerBridgeTests: XCTestCase {
    private func decode(_ body: Any) -> InteractiveAnswerBridgeMessage? {
        InteractiveAnswerBridgeMessage.decode(body)
    }

    func testAskTrimmedAndBounded() {
        XCTAssertEqual(decode(["type": "ask", "text": "  hi  "]), .ask("hi"))
        XCTAssertNil(decode(["type": "ask", "text": ""]))
        XCTAssertNil(decode(["type": "ask", "text": " \n "]))
        XCTAssertNil(decode(["type": "ask", "text": String(repeating: "a", count: 4001)]))
        let max = String(repeating: "a", count: 4000)
        XCTAssertEqual(decode(["type": "ask", "text": max]), .ask(max))
    }

    func testOpenHttpsOnly() {
        XCTAssertEqual(decode(["type": "open", "url": "https://example.com/a"]), .open(URL(string: "https://example.com/a")!))
        XCTAssertNil(decode(["type": "open", "url": "http://example.com"]))
        XCTAssertNil(decode(["type": "open", "url": "javascript:alert(1)"]))
        XCTAssertNil(decode(["type": "open", "url": "file:///etc"]))
        XCTAssertNil(decode(["type": "open", "url": "https:///nohost"]))
    }

    func testResizeBounded() {
        XCTAssertEqual(decode(["type": "resize", "height": 320]), .resize(320))
        XCTAssertNil(decode(["type": "resize", "height": -1]))
        XCTAssertNil(decode(["type": "resize", "height": Double.nan]))
        XCTAssertNil(decode(["type": "resize", "height": "tall"]))
        XCTAssertNil(decode(["type": "resize", "height": 20_001]))
    }

    func testScriptAndLoadErrorsDecode() {
        XCTAssertEqual(decode(["type": "scriptError", "message": "x"]), .scriptError("x"))
        guard case .scriptError(let long)? = decode(["type": "scriptError", "message": String(repeating: "e", count: 900)]) else {
            return XCTFail("expected scriptError")
        }
        XCTAssertEqual(long.count, 500)
        XCTAssertEqual(decode(["type": "loadError"]), .loadError)
    }

    func testMalformedBodiesRejected() {
        XCTAssertNil(decode("ask"))
        XCTAssertNil(decode([String: Any]()))
        XCTAssertNil(decode(["type": "shell", "cmd": "rm"]))
    }

    func testAskMergesIntoExistingDraft() {
        XCTAssertEqual(InteractiveAnswerDraftMerge.merged(draft: "", ask: "Q"), "Q")
        XCTAssertEqual(InteractiveAnswerDraftMerge.merged(draft: "  \n", ask: "Q"), "Q")
        XCTAssertEqual(InteractiveAnswerDraftMerge.merged(draft: "Hello ", ask: "Q"), "Hello\n\nQ")
    }
}
