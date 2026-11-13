import XCTest
@testable import HermesMobile

final class VoiceCallChatSnapshotTests: XCTestCase {
    private func make(_ messages: [ChatMessage], activeStreamID: String? = "stream-1",
                      recovery: ActiveStreamRecoveryState = .idle, tools: [ToolCall] = []) -> VoiceCallChatSnapshot {
        VoiceCallChatSnapshot.make(messages: messages, activeStreamID: activeStreamID, recovery: recovery,
                                   approval: nil, liveToolCalls: tools)
    }

    private func message(_ role: String, _ content: String?, _ id: String) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: nil, messageId: id)
    }

    func testReplyIsEverythingAtlasSaidAfterTheLatestUserTurn() {
        let snapshot = make([
            message("assistant", "Old reply.", "a0"),
            message("user", "[voice] hi", "u1"),
            message("assistant", "Let me check.", "a1"),
            message("tool", "{}", "t1"),
            message("assistant", "", "a2"),
            message("assistant", "Hello there.", "a3"),
        ], tools: [ToolCall(name: "terminal", preview: nil, args: nil, isCompleted: true),
                   ToolCall(name: "web_search", preview: nil, args: nil)])
        XCTAssertEqual(snapshot.streamingText, "Let me check.\nHello there.")
        XCTAssertTrue(snapshot.isStreaming)
        XCTAssertFalse(snapshot.isReconnecting)
        XCTAssertEqual(snapshot.currentTool, "web_search")
    }

    func testNoReplyYetReadsNothing() {
        let snapshot = make([message("assistant", "Old reply.", "a0"), message("user", "[voice] hi", "u1")],
                            activeStreamID: nil)
        XCTAssertNil(snapshot.streamingText)
        XCTAssertFalse(snapshot.isStreaming)
        XCTAssertNil(snapshot.currentTool)
    }

    func testRunningToolReadsAsPlainWords() {
        func activity(_ name: String, _ args: [String: JSONValue]? = nil) -> String? {
            make([message("user", "[voice] hi", "u1")], tools: [ToolCall(name: name, preview: nil, args: args)])
                .toolActivity?.label
        }
        XCTAssertEqual(activity("web_search"), "Searching the web")
        XCTAssertEqual(activity("read_file", ["path": .string("people/jane-doe.md")]), "Checking your notes")
        XCTAssertEqual(activity("search_files"), "Checking your notes")
        XCTAssertEqual(activity("terminal", ["command": .string("brain crm show jane-doe")]), "Looking up Jane Doe")
        XCTAssertEqual(activity("terminal", ["command": .string("bash -lc 'brain crm show \"Bo Test\"'")]), "Looking up Bo Test")
        XCTAssertEqual(activity("terminal", ["command": .string("brain crm show people/sam_lee.md")]), "Looking up Sam Lee")
        XCTAssertEqual(activity("terminal", ["command": .string("cd ~/vault && brain ask 'goals'")]), "Checking your notes")
        XCTAssertEqual(activity("terminal", ["command": .string("ls -la")]), "Working")
        XCTAssertEqual(activity("delegate_task"), "Working")
        XCTAssertEqual(activity("mcp__linear__create_issue"), "Working")
        XCTAssertEqual(activity("terminal")?.contains("terminal"), false)
    }

    func testOnlyANamedLookupHasASpokenLine() {
        func line(_ name: String, _ args: [String: JSONValue]? = nil) -> String? {
            make([message("user", "[voice] hi", "u1")], tools: [ToolCall(name: name, preview: nil, args: args)])
                .toolActivity?.spokenLine
        }
        XCTAssertEqual(line("terminal", ["command": .string("brain crm show jane-doe")]), "Looking up Jane Doe.")
        XCTAssertEqual(line("terminal", ["command": .string("brain deep 'the taper'")]), "Checking your notes.")
        XCTAssertEqual(line("web_search"), "Searching the web.")
        XCTAssertNil(line("terminal", ["command": .string("ls -la")]))
        XCTAssertNil(line("delegate_task"))
    }

    func testRunningToolKeepsItsKindForTheChipColor() {
        let snapshot = make([], tools: [ToolCall(name: "web_search", preview: nil, args: nil)])
        XCTAssertEqual(snapshot.toolActivity?.kind, .web)
        XCTAssertNil(make([], tools: [ToolCall(name: "web_search", preview: nil, args: nil, isCompleted: true)]).toolActivity)
    }

    func testRecoveryStatesCountAsReconnecting() {
        for state: ActiveStreamRecoveryState in [.reconnecting, .waitingForNetwork] {
            XCTAssertTrue(make([], recovery: state).isReconnecting)
        }
    }

    // MARK: - Reply feed

    @MainActor
    func testANewTokenNotifiesOnlyReplyReaders() {
        let feed = VoiceCallReplyFeed()
        feed.update(make([message("user", "hi", "u1"), message("assistant", "One.", "a1")]))
        let toolReaders = ObservationFlag()
        withObservationTracking { _ = feed.toolActivity } onChange: { toolReaders.fired = true }
        let replyReaders = ObservationFlag()
        withObservationTracking { _ = feed.reply } onChange: { replyReaders.fired = true }

        feed.update(make([message("user", "hi", "u1"), message("assistant", "One. Two.", "a1")]))

        XCTAssertTrue(replyReaders.fired)
        XCTAssertFalse(toolReaders.fired, "An unchanged tool must not re-render the call screen")
        XCTAssertEqual(feed.caption, "One. Two.")
    }

    @MainActor
    func testAnUnchangedSnapshotNotifiesNobody() {
        let feed = VoiceCallReplyFeed()
        let snapshot = make([message("user", "hi", "u1"), message("assistant", "One.", "a1")])
        feed.update(snapshot)
        let readers = ObservationFlag()
        withObservationTracking { _ = feed.reply; _ = feed.toolActivity } onChange: { readers.fired = true }

        feed.update(snapshot)

        XCTAssertFalse(readers.fired)
    }

    // MARK: - Diagnostics log

    func testTheLogNamesSpeechByLengthOnly() {
        XCTAssertEqual(VoiceCallDiagnostics.size("send the email"), "14 chars")
        XCTAssertEqual(VoiceCallDiagnostics.size(Optional<String>.none), "0 chars")
    }

    func testTheLogKeepsItsNewestHalfOncePastTheCap() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-call-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = Data(String(repeating: "x", count: 99).appending("\n").utf8)

        for _ in 0..<25 { VoiceCallDiagnostics.append(line, to: url, limit: 1_000) }

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 1_000)
        XCTAssertGreaterThan(size, 0)
    }
}

/// Records an observation's onChange, which runs synchronously on the setter's thread.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}
