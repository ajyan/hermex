import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class DesignSystemTests: XCTestCase {
    private func entries(_ calls: [(String, [String: JSONValue])], isLive: Bool = false) -> [ToolCallLogEntry] {
        let toolCalls = calls.enumerated().map { index, call in
            ToolCall(id: "call-\(index)", name: call.0, preview: nil, args: call.1, isCompleted: !isLive)
        }
        return ToolCallSummaryFormatter.entries(for: toolCalls, isLive: isLive)
    }

    func testToolKindsWearTheirObjectPaper() {
        XCTAssertEqual(HermexPaper.forTool(.read), .file)
        XCTAssertEqual(HermexPaper.forTool(.write), .file)
        XCTAssertEqual(HermexPaper.forTool(.list), .file)
        XCTAssertEqual(HermexPaper.forTool(.search), .file, "grep and find search files, not the Brain")
        XCTAssertEqual(HermexPaper.forTool(.web), .web)
        XCTAssertEqual(HermexPaper.forTool(.memory), .recall)
        XCTAssertEqual(HermexPaper.forTool(.skill), .recall)
        XCTAssertEqual(HermexPaper.forTool(.shell), .tool)
        XCTAssertEqual(HermexPaper.forTool(.unknown), .tool)
        XCTAssertEqual(HermexPaper.request, .opener, "requests share the Brief's opener paper")
    }

    func testLiveChipsKeepTheNewestCallsAndCountTheRest() {
        let all = entries((0..<6).map { ("terminal", ["command": .string("echo \($0)")]) }, isLive: true)
        let chips = ToolActivityPresentation.chips(all)

        XCTAssertEqual(chips.shown.map(\.id), ["call-2", "call-3", "call-4", "call-5"])
        XCTAssertEqual(chips.hiddenCount, 2)
    }

    func testChipLabelPrefersTheTargetAndCutsLongOnes() {
        let row = entries([("read_file", ["path": .string("/vault/interview-prep/stripe.md")])])[0].row
        XCTAssertEqual(ToolActivityPresentation.chipLabel(row), "stripe.md")

        let long = entries([("terminal", ["command": .string("qmd query --collection vault 'stripe ledger design'")])])[0].row
        let label = ToolActivityPresentation.chipLabel(long)
        XCTAssertEqual(label.count, ToolActivityPresentation.chipLabelLimit)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func testSettledRunCountsEachKindInFirstRunOrderWithFailures() {
        var all = entries([
            ("terminal", ["command": .string("bin/brain search creativity")]),
            ("search_files", ["query": .string("stripe")]),
            ("terminal", ["command": .string("ls")]),
            ("search_files", ["query": .string("ledger")]),
            ("web_search", ["query": .string("ledger")]),
        ])
        let failed = ToolCall(id: "call-5", name: "terminal", preview: "boom", args: ["command": .string("false")],
                              isError: true, isCompleted: true)
        all += ToolCallSummaryFormatter.entries(for: [failed], isLive: false)

        let counts = ToolActivityPresentation.kindCounts(all)
        XCTAssertEqual(counts.map(\.label), ["3 commands", "2 searches", "1 web lookup"])
        XCTAssertEqual(counts.map(\.failures), [1, 0, 0])
        XCTAssertEqual(counts.map(\.paper), [.tool, .file, .web])
    }

    func testBrainCitationsAreDistinctLinkedPagesInOrder() {
        let text = """
        See [Stripe ledger](brain://wiki/stripe-ledger) and [Idempotency](brain://wiki/idempotency).
        Again: [Stripe ledger](brain://wiki/stripe-ledger). A web link [docs](https://stripe.com).
        """
        let citations = BrainCitation.citations(in: text)

        XCTAssertEqual(citations.map(\.title), ["Stripe ledger", "Idempotency"])
        XCTAssertEqual(citations.first?.module, .wiki)
    }

    func testBrainCitationsCapAndSkipUnknownModules() {
        XCTAssertTrue(BrainCitation.citations(in: "[x](brain://nowhere/id)").isEmpty)
        XCTAssertTrue(BrainCitation.citations(in: "plain text").isEmpty)

        let five = (1...5).map { "[P\($0)](brain://people/p\($0))" }.joined(separator: " ")
        XCTAssertEqual(BrainCitation.citations(in: five).count, BrainCitation.limit)
    }

    func testGlowTextClearsAAOnItsWashInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let canvas = UIColor(Color.hxCanvas).resolvedColor(with: traits)
            for paper in HermexPaper.all {
                let text = UIColor(paper.glow).resolvedColor(with: traits)
                let wash = Self.composite(UIColor(paper.wash).resolvedColor(with: traits), over: canvas)
                XCTAssertGreaterThanOrEqual(Self.contrast(text, wash), 4.5, "\(style.rawValue) glow on wash")
            }
        }
    }

    private static func composite(_ top: UIColor, over bottom: UIColor) -> UIColor {
        var (tr, tg, tb, ta): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: tr * ta + br * (1 - ta), green: tg * ta + bg * (1 - ta), blue: tb * ta + bb * (1 - ta), alpha: 1)
    }

    private static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var (r, g, b, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
            func channel(_ c: CGFloat) -> Double {
                let c = Double(c)
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
