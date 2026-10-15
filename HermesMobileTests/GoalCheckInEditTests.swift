import XCTest
@testable import HermesMobile

final class GoalCheckInEditTests: XCTestCase {
    private let today = "2026-10-15"
    private let yesterday = "2026-10-14"

    private func goal(_ row: String) throws -> GoalSummary {
        let json = #"{"slug":"g","week":{"start":"2026-10-12","end":"2026-10-18","commitments":[\#(row)]}}"#
        return try PrepDecoding.decode(GoalSummary.self, from: Data(json.utf8))
    }

    private func sourceRow() -> String {
        #"{"id":"prep","target":5,"skips":1,"done":2,"remaining":3,"source":"prep.days","unit":"day","source_days":["2026-10-14"],"due_today":true,"due_yesterday":false,"today":null,"yesterday":null}"#
    }

    func testOverridingSourceDayMovesDoneToMissed() throws {
        var g = try goal(sourceRow())
        GoalCheckInEdit.apply(.miss, to: "prep", on: yesterday, today: today, yesterday: yesterday, in: &g)
        let row = g.week.commitments[0]
        XCTAssertEqual(row.done, 1)
        XCTAssertEqual(row.missed, 1)
        XCTAssertEqual(row.yesterday, .miss)
    }

    func testClearOnSourceDayRestoresDone() throws {
        var g = try goal(sourceRow())
        GoalCheckInEdit.apply(.miss, to: "prep", on: yesterday, today: today, yesterday: yesterday, in: &g)
        GoalCheckInEdit.apply(.clear, to: "prep", on: yesterday, today: today, yesterday: yesterday, in: &g)
        let row = g.week.commitments[0]
        XCTAssertEqual(row.done, 2)
        XCTAssertEqual(row.missed, 0)
        XCTAssertNil(row.yesterday)
    }

    func testClearOnPlainDayStillEmpties() throws {
        var g = try goal(#"{"id":"a","target":3,"done":1,"yesterday":"done"}"#)
        GoalCheckInEdit.apply(.clear, to: "a", on: yesterday, today: today, yesterday: yesterday, in: &g)
        XCTAssertEqual(g.week.commitments[0].done, 0)
    }

    func testAddItemAndRemoveLast() throws {
        var g = try goal(#"{"id":"outreach","unit":"item","target":3,"done":0,"remaining":3}"#)
        GoalCheckInEdit.addItem(1, note: "Anthropic", to: "outreach", on: today, in: &g)
        var row = g.week.commitments[0]
        XCTAssertEqual(row.done, 1)
        XCTAssertEqual(row.remaining, 2)
        XCTAssertFalse(row.hit)
        XCTAssertEqual(row.items, [GoalItem(date: today, note: "Anthropic")])
        GoalCheckInEdit.addItem(-1, note: nil, to: "outreach", on: today, in: &g)
        row = g.week.commitments[0]
        XCTAssertEqual(row.done, 0)
        XCTAssertEqual(row.remaining, 3)
        XCTAssertTrue(row.items.isEmpty)
        GoalCheckInEdit.addItem(-1, note: nil, to: "outreach", on: today, in: &g)
        XCTAssertEqual(g.week.commitments[0].done, 0)
        XCTAssertTrue(g.week.commitments[0].items.isEmpty)
    }

    func testAddItemReachesTarget() throws {
        var g = try goal(#"{"id":"o","unit":"item","target":1}"#)
        GoalCheckInEdit.addItem(1, note: nil, to: "o", on: today, in: &g)
        XCTAssertTrue(g.week.commitments[0].hit)
        XCTAssertEqual(g.week.commitments[0].remaining, 0)
    }
}
