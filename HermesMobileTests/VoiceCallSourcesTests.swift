import XCTest
@testable import HermesMobile

final class VoiceCallSourcesTests: XCTestCase {
    private func terminal(_ command: String, preview: String?, isError: Bool? = nil, done: Bool = true) -> ToolCall {
        ToolCall(name: "terminal", preview: preview, args: ["command": .string(command)], isError: isError, isCompleted: done)
    }

    private func labels(_ sources: [VoiceCallSource]) -> [String] { sources.map(\.label) }

    // MARK: Tool results

    func testBrainAskJSONCitationsInsideATerminalResult() throws {
        let brain: [String: Any] = ["ok": true, "data": ["query": "taper", "citations": [
            ["path": "journal/2026/10-October/2026-10-22.md", "section": "Run", "score": 0.4],
            ["path": "wiki/running/taper-plan.md", "section": "Plan", "score": 0.3],
        ]]]
        let output = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: brain), encoding: .utf8))
        let preview = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: ["output": output, "exit_code": 0]), encoding: .utf8
        ))
        let sources = VoiceCallSources.from(toolCall: terminal("brain ask \"marathon taper\" --json", preview: preview))
        XCTAssertEqual(labels(sources), ["Journal · 22 Oct", "Wiki · Taper plan"])
        XCTAssertEqual(sources.map(\.kind), [.journal, .wiki])
        XCTAssertEqual(sources.first?.path, "journal/2026/10-October/2026-10-22.md")
    }

    func testBrainAskResultCutShortStillYieldsTheCitationsBeforeTheCut() {
        // A preview capped mid-JSON: the escaped fields before the cut still read.
        let preview = #"{"output": "{\"ok\": true, \"data\": {\"citations\": [{\"path\": \"wiki/concepts/rag-evals.md\", \"section\": \"A\"}, {\"path\": \"journal/2026/09-Sept"#
        let sources = VoiceCallSources.from(toolCall: terminal("brain ask evals --json", preview: preview))
        XCTAssertEqual(labels(sources), ["Wiki · Rag evals"])
    }

    func testBrainAskPlainCitationLines() {
        let preview = "Q: taper\n\nSources:\n  journal/2026/10-October/2026-10-08.md#Run  (score 0.41)\n  book_highlights/born-to-run.md#Ch 3  (score 0.2)\n"
        let sources = VoiceCallSources.from(toolCall: terminal("brain ask taper", preview: preview))
        XCTAssertEqual(labels(sources), ["Journal · 8 Oct", "Book highlights"])
    }

    func testCRMShowIsThePersonLookedUp() {
        XCTAssertEqual(labels(VoiceCallSources.from(toolCall: terminal(#"brain crm show "Mitch Anderson""#, preview: "{}"))),
                       ["Mitch Anderson"])
        let slug = VoiceCallSources.from(toolCall: terminal("bash -lc 'crm show mitch-anderson'", preview: nil))
        XCTAssertEqual(labels(slug), ["Mitch Anderson"])
        XCTAssertEqual(slug.first?.kind, .person)
    }

    func testReadFileOfAContactDedupesWithTheCRMLookup() {
        let read = ToolCall(name: "read_file", preview: "...",
                            args: ["path": .string("/Users/me/Code/second-brain/crm/contacts/Mitch Anderson.md")],
                            isCompleted: true)
        let found = VoiceCallSources.from(toolCalls: [terminal("crm show mitch-anderson", preview: nil), read])
        XCTAssertEqual(VoiceCallSources.merged([], found).map(\.label), ["Mitch Anderson"])
    }

    func testSearchFilesMatchesAndFileLists() {
        let matches = #"{"total_count": 3, "matches": [{"path": "journal/2026/10-October/2026-10-22.md", "line": 4, "content": "taper"}, {"path": "journal/2026/10-October/2026-10-22.md", "line": 9, "content": "taper"}, {"path": "tools/brain/ask.py", "line": 1, "content": "x"}]}"#
        let files = #"{"files": ["email_ingest/summaries/2026-10-06-marathon-fueling.md", "notes/ideas.md"]}"#
        let calls = [
            ToolCall(name: "search_files", preview: matches, args: nil, isCompleted: true),
            ToolCall(name: "search_files", preview: files, args: nil, isCompleted: true),
        ]
        XCTAssertEqual(VoiceCallSources.merged([], VoiceCallSources.from(toolCalls: calls)).map(\.label),
                       ["Journal · 22 Oct", "Article · Marathon fueling", "Notes · ideas"])
    }

    func testRunningFailedAndUnrelatedCallsFindNothing() {
        let path = #"{"path": "wiki/a.md"}"#
        XCTAssertTrue(VoiceCallSources.from(toolCalls: [
            ToolCall(name: "search_files", preview: path, args: nil, isCompleted: false),
            ToolCall(name: "search_files", preview: path, args: nil, isError: true, isCompleted: true),
            terminal("ls wiki", preview: path),
            ToolCall(name: "web_search", preview: path, args: nil, isCompleted: true),
        ]).isEmpty)
    }

    // MARK: Labels

    func testLabelsByVaultFolder() {
        func label(_ path: String) -> String? { VoiceCallSources.source(path: path)?.label }
        XCTAssertEqual(label("journal/2026/10-October/2026-10-22.md"), "Journal · 22 Oct")
        XCTAssertEqual(label("/vault/wiki/concepts/taper_plan.md"), "Wiki · Taper plan")
        XCTAssertEqual(label("wiki/RAG evals.md"), "Wiki · RAG evals")
        XCTAssertEqual(label("crm/contacts/jane-doe.md"), "Jane Doe")
        XCTAssertEqual(label("email_ingest/summaries/2026-10-06-why-evals-matter.md"), "Article · Why evals matter")
        XCTAssertEqual(label("book_highlights/born-to-run.md"), "Book highlights")
        XCTAssertEqual(label("goals/marathon.md"), "Notes · marathon")
        XCTAssertNil(label("tools/brain/ask.py"))
        XCTAssertEqual(VoiceCallSources.source(path: "/vault/wiki/a.md")?.id, VoiceCallSources.source(path: "wiki/a.md")?.id)
    }

    func testKindsWearTheirBrainPapers() {
        XCTAssertEqual(VoiceCallSourceKind.journal.paper, .past)
        XCTAssertEqual(VoiceCallSourceKind.wiki.paper, .wiki)
        XCTAssertEqual(VoiceCallSourceKind.person.paper, .advisor)
        XCTAssertEqual(VoiceCallSourceKind.note.paper, .notes)
        XCTAssertEqual(VoiceCallSourceKind.article.paper, .reading)
        XCTAssertEqual(VoiceCallSourceKind.book.paper, .book)
    }

    func testMergeDedupesAndCapsWithTheFirstWinning() {
        let found = (1...8).map { VoiceCallSources.source(path: "wiki/page-\($0).md")! }
        let merged = VoiceCallSources.merged(Array(found.prefix(2)), found + [VoiceCallSources.source(path: "/v/wiki/page-1.md")!])
        XCTAssertEqual(merged.count, VoiceCallSources.cap)
        XCTAssertEqual(merged.map(\.label), (1...6).map { "Wiki · Page \($0)" })
    }

    // MARK: context_sources

    func testContextSourcesEventDecodesTolerantly() {
        let data = #"{"sources": [{"kind": "journal", "label": "Journal · 22 Oct", "path": "journal/2026/10-October/2026-10-22.md"}, "oops", {"kind": "person", "label": "Mitch Anderson"}, {"kind": "podcast", "label": "Notes · Lex 400", "path": "notes/lex-400.md", "extra": 1}]}"#
        guard case .contextSources(let payload) = SSEEventDecoder.decode(eventType: "context_sources", data: data) else {
            return XCTFail("Expected contextSources")
        }
        XCTAssertEqual(payload.sources.count, 3)
        let sources = VoiceCallSources.from(context: payload.sources)
        XCTAssertEqual(sources.map(\.label), ["Journal · 22 Oct", "Mitch Anderson", "Notes · Lex 400"])
        XCTAssertEqual(sources.map(\.kind), [.journal, .person, .note])
        XCTAssertEqual(sources[1].id, VoiceCallSources.person(named: "Mitch Anderson").id)

        guard case .contextSources(let empty) = SSEEventDecoder.decode(eventType: "context_sources", data: "{") else {
            return XCTFail("Expected contextSources")
        }
        XCTAssertTrue(empty.sources.isEmpty)
    }

    func testServerSourcesComeFirstAndDedupeWithToolFinds() {
        let context = [ContextSourcesStreamEvent.Source(kind: "wiki", label: "Wiki · Taper plan", path: "wiki/running/taper-plan.md")]
        let read = ToolCall(name: "read_file", preview: nil,
                            args: ["path": .string("/vault/wiki/running/taper-plan.md")], isCompleted: true)
        let crm = terminal("crm show mitch-anderson", preview: nil)
        let sources = VoiceCallChatSnapshot.sources(context: context, toolCalls: [read, crm])
        XCTAssertEqual(sources.map(\.label), ["Wiki · Taper plan", "Mitch Anderson"])
    }
}
