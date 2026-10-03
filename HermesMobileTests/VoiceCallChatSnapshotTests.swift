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

    func testRecoveryStatesCountAsReconnecting() {
        for state: ActiveStreamRecoveryState in [.reconnecting, .waitingForNetwork] {
            XCTAssertTrue(make([], recovery: state).isReconnecting)
        }
    }
}
