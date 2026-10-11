import XCTest
import Foundation
@testable import HermesMobile

final class FeedbackModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try FeedbackDecoding.decode(type, from: Data(json.utf8))
    }

    func testDecodesEntryWithMissingFields() throws {
        let e = try decode(FeedbackEntry.self, #"{"id": "f1", "status": "planned", "notes": [{"text": "a"}, 7, {"ts": "t", "text": "b"}], "tests": null, "plan_repo": "hermex"}"#)
        XCTAssertEqual(e.id, "f1")
        XCTAssertEqual(e.status, .planned)
        XCTAssertEqual(e.feature, "")
        XCTAssertEqual(e.text, "")
        XCTAssertNil(e.item)
        XCTAssertNil(e.tests)
        XCTAssertNil(e.title)
        XCTAssertEqual(e.planRepo, "hermex")
        XCTAssertEqual(e.notes.map(\.text), ["a", "b"])

        let bare = try decode(FeedbackEntry.self, "{}")
        XCTAssertEqual(bare.id, "")
        XCTAssertEqual(bare.status, .unknown)
        XCTAssertTrue(bare.notes.isEmpty)
    }

    func testUnknownStatus() throws {
        let e = try decode(FeedbackEntry.self, #"{"id": "f1", "status": "teleporting"}"#)
        XCTAssertEqual(e.status, .unknown)
        XCTAssertEqual(e.status.group, .inProgress)
    }

    func testStatusLabelsAndGroups() {
        let expected: [(FeedbackStatus, String, FeedbackGroup)] = [
            (.new, "Waiting for tonight", .inProgress),
            (.planning, "Planning", .inProgress),
            (.planned, "Plan ready", .needsReview),
            (.approved, "Approved", .inProgress),
            (.building, "Building", .inProgress),
            (.ready, "Branch ready", .needsReview),
            (.failed, "Failed", .needsReview),
            (.rejected, "Rejected", .done),
            (.merged, "Merged", .done),
        ]
        for (status, label, group) in expected {
            XCTAssertEqual(status.label, label)
            XCTAssertEqual(status.group, group, "\(status)")
            XCTAssertEqual(FeedbackStatus(wire: status.rawValue), status)
        }
    }

    func testDecisionEncodesNote() throws {
        func json(_ d: FeedbackDecision) throws -> [String: String] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as? [String: String] ?? [:]
        }
        XCTAssertEqual(try json(.reply("narrower please")), ["decision": "reply", "note": "narrower please"])
        XCTAssertEqual(try json(.approve), ["decision": "approve"])
        XCTAssertEqual(try json(.reject), ["decision": "reject"])
        XCTAssertEqual(try json(.retry), ["decision": "retry"])
        XCTAssertEqual(try json(.merged), ["decision": "merged"])
        XCTAssertEqual(try json(.unmerge), ["decision": "unmerge"])
    }

    func testAboutJoinsContext() {
        XCTAssertEqual(FeedbackContext(feature: "Prep", screen: "Spot the bug", item: "Longest Substring").about,
                       "Prep · Spot the bug · Longest Substring")
        XCTAssertEqual(FeedbackContext(feature: "Chat", screen: "Conversation").about, "Chat · Conversation")
    }

    func testListDecodesEnvelopeTolerantly() throws {
        let list = try decode(FeedbackList.self, #"{"entries": [{"id": "a", "status": "new"}, "junk", {"id": "b"}]}"#)
        XCTAssertEqual(list.entries.map(\.id), ["a", "b"])
        XCTAssertTrue(try decode(FeedbackList.self, "{}").entries.isEmpty)
    }
    // MARK: Attachments

    /// Encodes the way `APIClient` does, so snake-case state keys are checked on the real path.
    private func wireJSON(_ body: FeedbackCreate) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONSerialization.jsonObject(with: encoder.encode(body)) as? [String: Any] ?? [:]
    }

    func testStateEncoded() throws {
        let long = String(repeating: "x", count: 2500)
        let context = FeedbackContext(feature: "Prep", screen: "Approach", item: "Two Sum",
                                      state: ["item_id": "two-sum", "rep_index": "3", "answer": long, "verdict": nil, "feedback": ""])
        let json = try wireJSON(FeedbackCreate(context: context, build: "7", text: "x"))

        let state = try XCTUnwrap(json["state"] as? [String: String])
        XCTAssertEqual(Set(state.keys), ["item_id", "rep_index", "answer"], "nil and empty facts are dropped")
        XCTAssertEqual(state["item_id"], "two-sum")
        XCTAssertEqual(state["answer"]?.count, 2000, "each value is capped at the server's 2000 characters")
        XCTAssertNil(json["screenshot"])
    }

    func testNoStateOmitsTheField() throws {
        let json = try wireJSON(FeedbackCreate(context: FeedbackContext(feature: "Prep", screen: "Home"), build: nil, text: "x"))
        XCTAssertNil(json["state"])
        XCTAssertNil(json["screenshot"])
        XCTAssertEqual(json["feature"] as? String, "Prep")
    }

    func testEntryDecodesAttachmentsTolerantly() throws {
        let e = try decode(FeedbackEntry.self, #"{"id": "f1", "attachments": [{"name": "screenshot.jpg", "kind": "screenshot"}, 3, {"name": "context.json"}]}"#)
        XCTAssertEqual(e.attachments.map(\.name), ["screenshot.jpg", "context.json"])
        XCTAssertEqual(e.attachments.first?.kind, "screenshot")
        XCTAssertNil(e.attachments.last?.kind)
        XCTAssertTrue(try decode(FeedbackEntry.self, "{}").attachments.isEmpty)
    }

    func testEntryDecodesMergedInto() throws {
        XCTAssertEqual(try decode(FeedbackEntry.self, #"{"id": "f1", "status": "rejected", "merged_into": "0123456789ab"}"#).mergedInto, "0123456789ab")
        XCTAssertNil(try decode(FeedbackEntry.self, #"{"id": "f1", "merged_into": null}"#).mergedInto)
        XCTAssertNil(try decode(FeedbackEntry.self, #"{"id": "f1", "merged_into": 7}"#).mergedInto)
        XCTAssertNil(try decode(FeedbackEntry.self, "{}").mergedInto)
    }

    // MARK: Per-screen state

    func testPrepRunStateOnAnsweredRep() throws {
        let rep = try PrepDecoding.decode(PrepRep.self, from: Data(#"{"index": 4, "block": "main", "drill": "spot_bug", "item": {"id": "longest-substring", "title": "Longest Substring"}}"#.utf8))
        let result = try PrepDecoding.decode(PrepAttemptResult.self, from: Data(#"{"verdict": "wrong", "feedback": "The window shrinks too late.", "next_index": 5}"#.utf8))

        let context = FeedbackContext.prepRun(rep: rep, answer: .bugFix(line: 2, fix: "left += 1"), result: result)

        XCTAssertEqual(context.about, "Prep · Spot the bug · Longest Substring")
        XCTAssertEqual(context.state, [
            "item_id": "longest-substring", "drill": "spot_bug", "rep_index": "4",
            "answer": "line 3: left += 1", "verdict": "wrong", "feedback": "The window shrinks too late.",
        ])
    }

    func testPrepRunStateBeforeAnswering() throws {
        let rep = try PrepDecoding.decode(PrepRep.self, from: Data(#"{"index": 0, "drill": "approach", "item": {"id": "two-sum", "title": "Two Sum"}}"#.utf8))

        XCTAssertEqual(FeedbackContext.prepRun(rep: rep, answer: .choice("hash map"), result: nil).state,
                       ["item_id": "two-sum", "drill": "approach", "rep_index": "0", "answer": "hash map"])
        XCTAssertEqual(FeedbackContext.prepRun(rep: nil, answer: nil, result: nil).state, [:])
    }

    func testDailyDeckState() throws {
        let card = try JSONDecoder().decode(DeckCard.self, from: Data(#"{"id": "c3", "type": "prompt", "title": "What moved you?"}"#.utf8))

        let context = FeedbackContext.dailyDeck(title: "Daily Brief", date: "2026-10-11", kind: "morning", page: .card(card))

        XCTAssertEqual(context.about, "Daily Deck · Daily Brief · What moved you?")
        XCTAssertEqual(context.state, ["slot": "2026-10-11.morning", "card": "c3"])
        XCTAssertEqual(FeedbackContext.dailyDeck(title: "Weekly Review", date: "2026-10-11", kind: "weekly", page: nil).state,
                       ["slot": "2026-10-11.weekly"])
    }
}
