import XCTest
@testable import HermesMobile

final class InteractiveAnswerDocumentTests: XCTestCase {
    private let lightHTML = InteractiveAnswerDocument.html(fragment: "<p>hi</p>", theme: .current(.light))

    func testContainsCSPMeta() {
        XCTAssertTrue(lightHTML.contains(
            #"<meta http-equiv="Content-Security-Policy" content="\#(InteractiveAnswerDocument.contentSecurityPolicy)">"#
        ))
        XCTAssertEqual(
            InteractiveAnswerDocument.contentSecurityPolicy,
            "default-src 'none'; script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'"
        )
    }

    func testThemeVariables() {
        let light = InteractiveAnswerTheme.current(.light)
        let dark = InteractiveAnswerTheme.current(.dark)
        XCTAssertEqual(light.canvas, "#F8FAFF")
        XCTAssertEqual(dark.canvas, "#0D1117")
        XCTAssertEqual(light.accent, "#0053FD")
        XCTAssertEqual(dark.accent, "#4A84FE")

        let darkHTML = InteractiveAnswerDocument.html(fragment: "", theme: dark)
        let pairs: [(String, String)] = [
            ("canvas", dark.canvas), ("surface", dark.surface), ("text", dark.text), ("text2", dark.text2),
            ("sep", dark.sep), ("accent", dark.accent), ("ok", dark.ok), ("warn", dark.warn), ("danger", dark.danger)
        ]
        for (name, value) in pairs {
            XCTAssertTrue(darkHTML.contains("--\(name): \(value);"), "missing --\(name)")
        }
        XCTAssertTrue(darkHTML.contains("--font:"))
        XCTAssertTrue(darkHTML.contains("color-scheme: dark"))
        XCTAssertTrue(lightHTML.contains("color-scheme: light"))
    }

    func testFragmentEmbeddedVerbatim() {
        let fragment = #"<script>const s = "</scr" + "ipt>"; const p = "$1 $&";</script><p>$5</p>"#
        let html = InteractiveAnswerDocument.html(fragment: fragment, theme: .current(.light))
        XCTAssertEqual(html.components(separatedBy: fragment).count - 1, 1)
    }

    func testBridgeDefinesAtlasAPI() {
        for needle in ["window.atlas", "ask:", "open:", "webkit.messageHandlers.atlas.postMessage", "ResizeObserver"] {
            XCTAssertTrue(lightHTML.contains(needle), "missing \(needle)")
        }
        XCTAssertEqual(InteractiveAnswerDocument.messageHandlerName, "atlas")
    }

    func testBridgeReportsResourceErrors() {
        XCTAssertTrue(lightHTML.contains("addEventListener('error'"))
        XCTAssertTrue(lightHTML.contains("type: 'loadError'"))
        XCTAssertTrue(lightHTML.contains("type: 'scriptError'"))
        XCTAssertTrue(lightHTML.contains("addEventListener('unhandledrejection'"))
    }

    func testBridgeRunsBeforeFragment() throws {
        let html = InteractiveAnswerDocument.html(fragment: "<p id=frag></p>", theme: .current(.light))
        let bridge = try XCTUnwrap(html.range(of: "window.atlas"))
        let fragment = try XCTUnwrap(html.range(of: "<p id=frag></p>"))
        XCTAssertLessThan(bridge.lowerBound, fragment.lowerBound)
    }
}
