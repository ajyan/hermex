import XCTest
@testable import HermesMobile

final class VoiceCallChatSnapshotTests: XCTestCase {
    private let messages = [
        ChatMessage(role: "assistant", content: "Old reply.", timestamp: 1, messageId: "old"),
        ChatMessage(role: "user", content: "[voice] hi", timestamp: 2, messageId: "u1"),
        ChatMessage(role: "assistant", content: "Hello there.", timestamp: 3, messageId: "live"),
    ]

    func testStreamingMessageTextAndRunState() {
        let snapshot = VoiceCallChatSnapshot.make(
            messages: messages, streamingMessageID: "live", replyMessageID: nil,
            activeStreamID: "stream-1", recovery: .idle, approval: nil,
            liveToolCalls: [ToolCall(name: "terminal", preview: nil, args: nil, isCompleted: true), ToolCall(name: "web_search", preview: nil, args: nil)]
        )
        XCTAssertEqual(snapshot.streamingText, "Hello there.")
        XCTAssertTrue(snapshot.isStreaming)
        XCTAssertFalse(snapshot.isReconnecting)
        XCTAssertEqual(snapshot.currentTool, "web_search")
    }

    func testFinishedRunReadsTheRememberedReplyOnly() {
        let finished = VoiceCallChatSnapshot.make(
            messages: messages, streamingMessageID: nil, replyMessageID: "live",
            activeStreamID: nil, recovery: .idle, approval: nil, liveToolCalls: []
        )
        XCTAssertEqual(finished.streamingText, "Hello there.")
        XCTAssertFalse(finished.isStreaming)
        XCTAssertNil(finished.currentTool)

        let noReply = VoiceCallChatSnapshot.make(
            messages: messages, streamingMessageID: nil, replyMessageID: nil,
            activeStreamID: nil, recovery: .idle, approval: nil, liveToolCalls: []
        )
        XCTAssertNil(noReply.streamingText)
    }

    func testRecoveryStatesCountAsReconnecting() {
        for state: ActiveStreamRecoveryState in [.reconnecting, .waitingForNetwork] {
            let snapshot = VoiceCallChatSnapshot.make(
                messages: [], streamingMessageID: nil, replyMessageID: nil,
                activeStreamID: "s", recovery: state, approval: nil, liveToolCalls: []
            )
            XCTAssertTrue(snapshot.isReconnecting)
        }
    }
}
