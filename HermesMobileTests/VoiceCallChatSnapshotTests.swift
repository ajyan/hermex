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
}
