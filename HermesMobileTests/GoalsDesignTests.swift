import SwiftUI
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

    /// A day's state shows by its mark, never amber: a missed day is the empty gray with an xmark, and
    /// today with nothing yet isn't gray at all.
    func testMissedDayIsGrayNotAmberAndTodayIsNotMissed() {
        let ink = Color.blue
        XCTAssertEqual(GoalPaper.fill(.miss, ink: ink), GoalPaper.fill(.none, ink: ink))
        XCTAssertNotEqual(GoalPaper.fill(.miss, ink: ink), Color.hxWarning.opacity(0.55))
        XCTAssertEqual(GoalHeroCopy.glyph(.miss), "xmark", "the miss says so with its mark")
        XCTAssertEqual(GoalPaper.fill(.none, ink: ink, isToday: true), Color.clear)
        XCTAssertNotEqual(GoalPaper.fill(.none, ink: ink, isToday: true), GoalPaper.fill(.miss, ink: ink))
        XCTAssertEqual(GoalPaper.fill(.done, ink: ink, isToday: true), ink, "today checked in still fills")
    }

    /// At accessibility sizes a commitment stacks its name and count above its dots, Home's compact
    /// cards drop the identity line, and the dots grow with the text without ever touching.
    func testLargeTextStacksTheHeroAndCapsTheDots() {
        XCTAssertFalse(GoalHeroLayout.stacks(.xxxLarge))
        XCTAssertTrue(GoalHeroLayout.stacks(.accessibility1))
        XCTAssertTrue(GoalHeroLayout.stacks(.accessibility5))
        XCTAssertFalse(GoalHeroLayout.showsIdentity(isCompact: true, stacked: true))
        XCTAssertTrue(GoalHeroLayout.showsIdentity(isCompact: false, stacked: true), "detail keeps it")
        XCTAssertTrue(GoalHeroLayout.showsIdentity(isCompact: true, stacked: false))

        XCTAssertEqual(GoalDotMetrics.scaled(DeckDots.dot), .standard)
        let huge = GoalDotMetrics.scaled(60)
        XCTAssertEqual(huge.dot, GoalDotMetrics.maxDot)
        XCTAssertGreaterThan(huge.column, huge.dot, "air between neighbors")
        XCTAssertLessThanOrEqual(huge.trailingWidth, 256, "seven columns fit an iPhone SE's card")
        // Five pips and a + share the seven columns, and a long pip row shrinks its dots to fit.
        let five = huge.pipColumn(pips: 5, addsOne: true)
        XCTAssertLessThanOrEqual(five * 6, huge.trailingWidth)
        let thirteen = huge.pipColumn(pips: 13, addsOne: true)
        XCTAssertLessThan(huge.dot(in: thirteen), thirteen)
        XCTAssertLessThan(GoalDotMetrics.standard.dot(in: GoalDotMetrics.standard.pipColumn(pips: 13, addsOne: true)),
                          GoalDotMetrics.standard.pipColumn(pips: 13, addsOne: true))
    }

    func testNotDueRowSaysSoInsteadOfFading() {
        XCTAssertEqual(GoalCommitmentRow.notDueLabel(isDue: false, shown: nil, day: .today), "Not due today")
        XCTAssertEqual(GoalCommitmentRow.notDueLabel(isDue: false, shown: nil, day: .yesterday), "Wasn't due yesterday")
        XCTAssertNil(GoalCommitmentRow.notDueLabel(isDue: true, shown: nil, day: .today))
        XCTAssertNil(GoalCommitmentRow.notDueLabel(isDue: false, shown: .done, day: .today), "a check-in speaks for itself")
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

    func testMergedHeatmapTakesThisWeeksDaysUpToToday() throws {
        let heat = try [day("2026-10-13", "none"), day("2026-10-14", "miss")]
        let week = try [day("2026-10-14", "done"), day("2026-10-15", "min"), day("2026-10-16", "none")]
        let merged = GoalCalendar.merged(heatmap: heat, week: week, today: "2026-10-15")
        XCTAssertEqual(merged.map(\.date), ["2026-10-13", "2026-10-14", "2026-10-15"], "nothing after today")
        XCTAssertEqual(merged.map(\.status), [GoalStatus.none, .done, .min])
    }

    func testCalendarModelHasStableIdsAndCounts() throws {
        let heat = try [day("2026-10-14", "skip"), day("2026-10-15", "done")]
        let model = GoalCalendarModel(heatmap: heat, today: "2026-10-15", deadline: nil)
        XCTAssertEqual(Set(model.slots.map(\.id)).count, model.slots.count, "every cell has its own id")
        XCTAssertEqual(model.slots.first { $0.day?.date == "2026-10-15" }?.id, "2026-10-15", "a day's id is its date")
        XCTAssertEqual(model.shown, 1)
        XCTAssertEqual(model.total, 2)
        XCTAssertEqual(GoalHeroCopy.weekdayLetter("2026-10-15"), "T")
        XCTAssertEqual(GoalHeroCopy.weekdayLetter("2026-10-18"), "S")
        XCTAssertEqual(GoalHeroCopy.glyph(.skip), "arrow.uturn.forward")
        XCTAssertEqual(GoalHeroCopy.glyph(.miss), "xmark")
        XCTAssertNil(GoalHeroCopy.glyph(.none), "an empty day has no mark")
    }

    func testShownUpLineOnDayOne() {
        XCTAssertEqual(GoalDetailCopy.shownUpLine((0, 0)), "Starts today")
        XCTAssertEqual(GoalDetailCopy.shownUpLine((5, 6)), "Showed up 5 of 6 days")
    }

    /// Started Thu Oct 15, today Mon Nov 2, deadline Sun Feb 28: the weeks so far and this one.
    private func detailCalendar(today: String = "2026-11-02", deadline: String? = "2027-02-28") throws -> GoalCalendarModel {
        let heat = try (15...31).map { try day("2026-10-\($0)") } + [day("2026-11-01", "none"), day("2026-11-02", "none")]
        return GoalCalendarModel.throughThisWeek(heatmap: heat, today: today, deadline: deadline)
    }

    func testDetailCalendarEndsWithThisWeek() throws {
        let model = try detailCalendar()
        XCTAssertEqual(model.slots.count, 28, "Oct 12 – Nov 8, none of the weeks ahead")
        XCTAssertEqual(model.slots.last?.day?.date, "2026-11-08")
        XCTAssertTrue(model.slots.last?.day?.isFuture ?? false)
        XCTAssertFalse(model.slots.contains { $0.day?.isDeadline == true }, "the deadline is a line, not a cell")
        XCTAssertEqual(model.shown, 17)
        XCTAssertEqual(model.total, 18, "today isn't counted until it's shown")
        XCTAssertEqual(model.summary, "Showed up 17 of 18 days", "the hero's kicker says the days left")
    }

    func testDetailCalendarStopsAtADeadlineThisWeek() throws {
        let model = try detailCalendar(today: "2026-10-28", deadline: "2026-10-30")
        XCTAssertEqual(model.slots.count, 21)
        XCTAssertTrue(model.slots.first { $0.id == "2026-10-30" }?.day?.isDeadline ?? false)
        XCTAssertNil(model.slots.last?.day, "nothing after the deadline")
    }

    func testDetailCalendarWithoutDeadlineKeepsTheFourWeekCap() throws {
        let heat = try (1...30).map { try day(String(format: "2026-09-%02d", $0)) }
        let model = GoalCalendarModel.throughThisWeek(heatmap: heat, today: "2026-09-30", deadline: nil)
        XCTAssertEqual(model.slots.count, 28)
        XCTAssertEqual(model.summary, "Showed up 30 of 30 days")
    }

    func testCalendarRowsNameTheMonthWhereItStarts() throws {
        let rows = GoalCalendarRows.rows(try detailCalendar().slots)
        XCTAssertEqual(rows.map(\.month), ["Oct", nil, "Nov", nil], "the first row, then the row holding Nov 1")
        XCTAssertEqual(rows.map(\.slots.count), [7, 7, 7, 7])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(GoalCalendarRows.month("2026-12-25"), "Dec")
        XCTAssertNil(GoalCalendarRows.month("later"))
    }

    /// Watch for sits under one header whether or not the Today / Yesterday picker shows.
    func testCheckInHeader() {
        XCTAssertEqual(GoalDetailCopy.checkInHeader(canCheckInYesterday: true, day: .yesterday), "Check in")
        XCTAssertEqual(GoalDetailCopy.checkInHeader(canCheckInYesterday: false, day: .today), "Today")
        XCTAssertEqual(GoalDetailCopy.checkInHeader(canCheckInYesterday: false, day: .yesterday), "Yesterday")
    }

    /// This week leads the hero; Monday's last week follows as compact 24 pt lines, which grow only
    /// with large-text dots and stay shorter than a tap target (a Sunday that checks in overflows it).
    func testHeroLeadsWithThisWeekThenACompactLastWeek() {
        XCTAssertEqual(GoalHeroLayout.sections(hasLastWeek: true), [.thisWeek, .lastWeek])
        XCTAssertEqual(GoalHeroLayout.sections(hasLastWeek: false), [.thisWeek])
        XCTAssertEqual(GoalHeroLayout.lastWeekRowHeight(.standard), 24)
        XCTAssertLessThan(GoalHeroLayout.lastWeekRowHeight(.standard), BrainStyle.minTapTarget)
        let huge = GoalDotMetrics.scaled(60)
        XCTAssertGreaterThan(GoalHeroLayout.lastWeekRowHeight(huge), huge.dot, "large dots still fit their line")
    }

    /// An item row's pips pack at their own pitch against the trailing edge, so "3 of 5" never lines
    /// up under Mon–Wed; a long row still shrinks to fit beside its +.
    func testItemPipsPackTighterThanTheDayColumns() {
        let standard = GoalDotMetrics.standard
        let pitch = standard.packedPitch(pips: 5, addsOne: true)
        XCTAssertEqual(pitch, DeckDots.dot + GoalDotMetrics.packedGap)
        XCTAssertLessThan(pitch, standard.column, "a different rhythm from the weekdays")
        XCTAssertEqual(standard.packedPitch(pips: 5, addsOne: false), pitch)
        let thirteen = standard.packedPitch(pips: 13, addsOne: true)
        XCTAssertLessThanOrEqual(thirteen * 13 + standard.column, standard.trailingWidth)
        XCTAssertLessThan(standard.dot(in: thirteen), thirteen, "air between pips")
        let huge = GoalDotMetrics.scaled(60)
        XCTAssertEqual(huge.packedPitch(pips: 5, addsOne: true), huge.dot + GoalDotMetrics.packedGap)
        XCTAssertLessThan(huge.packedPitch(pips: 5, addsOne: true), huge.column)
    }

    /// No goal wears amber: it means waiting on you. A goal file's `color: opener` wears reading.
    func testGoalPapersExcludeAmber() {
        XCTAssertFalse(GoalPaper.choices.contains(.opener))
        XCTAssertFalse(GoalPaper.names.contains("opener"))
        XCTAssertEqual(GoalPaper.choices.count, GoalPaper.names.count)
        XCTAssertEqual(GoalPaper.palette(named: "opener", slug: "x"), DeckPalette.reading)
        for slug in ["land-ai-role", "nyc-marathon", "learn-piano"] + (0..<200).map({ "goal-\($0)" }) {
            XCTAssertNotEqual(GoalPaper.palette(named: "", slug: slug), DeckPalette.opener, slug)
        }
    }
}
