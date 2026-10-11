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
}
