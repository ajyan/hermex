import XCTest
@testable import HermesMobile

/// The receipt after a call: the pages the call's turns filed.
final class CallReceiptTests: XCTestCase {
    private let sam = FiledPage(kind: .person, title: "Sam Rivera", detail: "Note, Nov 9", module: "people",
                                pageID: "crm/contacts/Sam Rivera.md")
    private let journal = FiledPage(kind: .journal, title: "Journal", detail: "Nov 9", module: "journal",
                                    pageID: "journal/2026/11-November/2026-11-09.md")

    private func reply(_ id: String, receipt: FilingReceipt?) -> ChatMessage {
        ChatMessage(role: "assistant", content: "Saved.", timestamp: nil, messageId: id, filed: receipt)
    }

    func testItListsWhatTheCallFiledAndNothingFromBefore() {
        let before = [
            ChatMessage(role: "user", content: "Earlier", timestamp: nil, messageId: "u0"),
            reply("a0", receipt: FilingReceipt(id: "fr_old", pages: [journal])),
        ]
        let during = [
            ChatMessage(role: "user", content: "[voice] Had coffee with Sam", timestamp: nil, messageId: "u1"),
            reply("a1", receipt: FilingReceipt(id: "fr_call_1", pages: [sam])),
            reply("a2", receipt: nil),
        ]

        let receipt = CallReceipt(messages: before + during, before: CallReceipt.receiptIDs(in: before))

        XCTAssertEqual(receipt.pages, [sam])
    }

    func testAPageFiledTwiceShowsOnceAndAnUndoneFilingIsLeftOut() {
        let messages = [
            reply("a1", receipt: FilingReceipt(id: "fr_1", pages: [sam, journal])),
            reply("a2", receipt: FilingReceipt(id: "fr_2", pages: [sam])),
            reply("a3", receipt: FilingReceipt(id: "fr_3", undone: true, pages: [
                FiledPage(kind: .story, title: "Story bank"),
            ])),
        ]

        XCTAssertEqual(CallReceipt(messages: messages, before: []).pages, [sam, journal])
    }

    func testACallThatFiledNothingHasAnEmptyReceipt() {
        let messages = [reply("a1", receipt: nil)]
        XCTAssertTrue(CallReceipt(messages: messages, before: []).pages.isEmpty)
    }
}
