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
        XCTAssertEqual(HermexPaper.forTool(.search), .knowledge)
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

    func testSummaryNamesASingleCallAndCountsSeveral() {
        let one = entries([("read_file", ["path": .string("notes.md")])])
        XCTAssertEqual(ToolActivityPresentation.summaryTitle(one), "Read notes.md")

        let many = entries([
            ("search_files", ["query": .string("stripe")]),
            ("read_file", ["path": .string("a.md")]),
            ("read_file", ["path": .string("b.md")]),
            ("web_search", ["query": .string("ledger")]),
            ("terminal", ["command": .string("ls")]),
        ])
        XCTAssertEqual(ToolActivityPresentation.summaryTitle(many), "5 steps")
        XCTAssertEqual(ToolActivityPresentation.summaryPapers(many), [.knowledge, .file, .web],
                       "distinct papers in first-run order, at most three")
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
}
