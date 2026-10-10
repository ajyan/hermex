import XCTest
@testable import HermesMobile

final class GoalsDesignTests: XCTestCase {
    private func day(_ date: String, _ status: String = "done") throws -> GoalHeatDay {
        try PrepDecoding.decode(GoalHeatDay.self, from: Data(#"{"date":"\#(date)","status":"\#(status)"}"#.utf8))
    }

    func testSummaryDecodesColorIconAndWeekDays() throws {
        let json = #"{"slug":"m","color":"wiki","icon":"figure.run","week":{"start":"2026-10-12","days":[{"date":"2026-10-12","status":"done"},{"date":"2026-10-13","status":"none"}]}}"#
        let goal = try PrepDecoding.decode(GoalSummary.self, from: Data(json.utf8))
        XCTAssertEqual(goal.color, "wiki")
        XCTAssertEqual(goal.icon, "figure.run")
        XCTAssertEqual(goal.week.days.map(\.status), [.done, GoalStatus.none])
        let bare = try PrepDecoding.decode(GoalSummary.self, from: Data(#"{"slug":"m"}"#.utf8))
        XCTAssertEqual(bare.color, "")
        XCTAssertEqual(bare.week.days, [])
    }

    func testPaperNamedAndFallbackIsStable() {
        XCTAssertEqual(GoalPaper.palette(named: "wiki", slug: "x"), DeckPalette.wiki)
        XCTAssertEqual(GoalPaper.palette(named: "quote", slug: "x"), DeckPalette.quote)
        let a = GoalPaper.palette(named: "", slug: "learn-piano")
        XCTAssertEqual(a, GoalPaper.palette(named: "nonsense", slug: "learn-piano"))
        XCTAssertTrue(GoalPaper.choices.contains(a))
        XCTAssertEqual(GoalPaper.symbol(""), "flag")
        XCTAssertEqual(GoalPaper.symbol("figure.run"), "figure.run")
    }

    func testCalendarSpansStartToDeadlineMondayFirst() throws {
        // Started Sat Oct 10, today Thu Oct 15, race Sun Nov 1.
        let heat = try ["2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15"].map { try day($0) }
        let weeks = GoalCalendar.weeks(heatmap: heat, today: "2026-10-15", deadline: "2026-11-01")
        XCTAssertEqual(weeks.count, 4)                        // Oct 5 – Nov 1
        XCTAssertTrue(weeks[0].prefix(5).allSatisfy { $0 == nil })
        XCTAssertEqual(weeks[0][5]?.date, "2026-10-10")
        XCTAssertEqual(weeks[3][6]?.date, "2026-11-01")
        XCTAssertTrue(weeks[3][6]?.isDeadline ?? false)
    }

    func testCalendarMarksTodayAndFuture() throws {
        let heat = try [day("2026-10-14", "miss"), day("2026-10-15", "none")]
        let weeks = GoalCalendar.weeks(heatmap: heat, today: "2026-10-15", deadline: nil)
        let days = weeks.flatMap { $0 }.compactMap { $0 }
        XCTAssertEqual(days.first { $0.date == "2026-10-14" }?.status, .miss)
        XCTAssertTrue(days.first { $0.date == "2026-10-15" }?.isToday ?? false)
        XCTAssertTrue(days.first { $0.date == "2026-10-16" }?.isFuture ?? false)
        XCTAssertEqual(days.last?.date, "2026-10-18")          // no deadline: through this Sunday
    }

    func testCalendarWithoutDeadlineShowsAtMostFourWeeks() throws {
        let heat = try (1...30).map { try day(String(format: "2026-09-%02d", $0)) }
        let weeks = GoalCalendar.weeks(heatmap: heat, today: "2026-09-30", deadline: nil)
        XCTAssertEqual(weeks.count, 4)
        XCTAssertEqual(weeks.last?.last??.date, "2026-10-04")
    }

    func testStripSelectableOnlyTodayAndYesterday() {
        XCTAssertEqual(GoalCalendar.selectableDay("2026-10-15", today: "2026-10-15", yesterday: "2026-10-14"), .today)
        XCTAssertEqual(GoalCalendar.selectableDay("2026-10-14", today: "2026-10-15", yesterday: "2026-10-14"), .yesterday)
        XCTAssertNil(GoalCalendar.selectableDay("2026-10-13", today: "2026-10-15", yesterday: "2026-10-14"))
    }

    func testShownUpCountsDaysSoFar() throws {
        // Today not yet checked in: it isn't counted against you.
        let heat = try [day("2026-10-13"), day("2026-10-14", "skip"), day("2026-10-15", "none")]
        XCTAssertEqual(GoalCalendar.shownUp(heatmap: heat, today: "2026-10-15").shown, 1)
        XCTAssertEqual(GoalCalendar.shownUp(heatmap: heat, today: "2026-10-15").total, 2)
        let done = try [day("2026-10-14", "min"), day("2026-10-15", "done")]
        XCTAssertEqual(GoalCalendar.shownUp(heatmap: done, today: "2026-10-15").shown, 2)
        XCTAssertEqual(GoalCalendar.shownUp(heatmap: done, today: "2026-10-15").total, 2)
    }

    func testShownUpLineOnDayOne() {
        XCTAssertEqual(GoalDetailCopy.shownUpLine((0, 0)), "Starts today")
        XCTAssertEqual(GoalDetailCopy.shownUpLine((5, 6)), "5 of 6 days")
    }
}
