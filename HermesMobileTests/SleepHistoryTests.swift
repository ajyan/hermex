import XCTest
@testable import HermesMobile

/// `data/sleep/history.json` (the vault's sleep_metrics.py) and the Sleep screen's trends.
@MainActor
final class SleepHistoryTests: XCTestCase {
    private let today = SleepNight.dayFormatter.date(from: "2026-10-18")!

    private static let json = """
    {"generated":"2026-10-18",
     "columns":["date","sleep_hours","sleep_need_hours","bed","wake","awake_count","hrv","hrv_band","quality","felt","performance","flags","new_field"],
     "nights":[
      ["2026-10-17",7.9,8.0,"2026-10-16T23:00","2026-10-17T07:00",1,90,[85,104],4,"Slept through",91,[],"x"],
      ["2026-10-18",7.5,8.0,"2026-10-17T23:05","2026-10-18T07:32",4,84,[85,104],1,null,90,["hrv_low"]],
      ["not a date",1],
      ["2026-10-19","seven",null,null,null,null,null,"band",9,"",null,"x",null]
     ],
     "stages":{"2026-10-18":[[0,14,"light"],[14,1,"awake"],[15,0,"deep"],[16,"x","rem"],[20,30,"nap"]]}}
    """

    func testDecodesColumnsTolerantly() throws {
        let history = try SleepHistory.decode(Data(Self.json.utf8))
        XCTAssertEqual(history.nights.map(\.date), ["2026-10-17", "2026-10-18", "2026-10-19"], "a row without a real date is dropped")
        let last = try XCTUnwrap(history.night(on: "2026-10-18"))
        XCTAssertEqual(last.hours, 7.5)
        XCTAssertEqual(last.wakeUps, 4)
        XCTAssertEqual(last.hrvBand, 85...104)
        XCTAssertEqual(last.quality, 1)
        XCTAssertEqual(last.flags, ["hrv_low"])
        XCTAssertEqual(history.night(on: "2026-10-17")?.felt, "Slept through")
        let odd = try XCTUnwrap(history.night(on: "2026-10-19"))
        XCTAssertNil(odd.hours, "a wrong type reads as missing")
        XCTAssertNil(odd.quality, "a rating outside 1–5 is dropped")
        XCTAssertNil(odd.felt, "an empty note is no note")
        XCTAssertNil(odd.hrvBand)
        XCTAssertEqual(history.stages["2026-10-18"], [SleepStage(start: 0, length: 14, kind: .light),
                                                       SleepStage(start: 14, length: 1, kind: .awake)],
                       "empty, malformed and unknown stages are dropped")
    }

    func testClockPutsLateEveningAndEarlyMorningOnOneAxis() {
        XCTAssertEqual(SleepNight.clock("2026-10-17T23:05"), 665)
        XCTAssertEqual(SleepNight.clock("2026-10-18T00:30"), 750)
        XCTAssertEqual(SleepNight.clock("2026-10-18T07:32"), 1172)
        XCTAssertNil(SleepNight.clock("11 pm"))
        XCTAssertEqual(SleepTrend.clockLabel(665), "11:05 pm")
        XCTAssertEqual(SleepTrend.clockLabel(720), "12:00 am")
        XCTAssertEqual(SleepTrend.clockLabel(0), "12:00 pm")
    }

    func testDailySpansPlotEachNightInTheSpan() {
        let nights = (0..<40).map { night(daysBefore: $0, hours: Double(60 + $0)) }
        let week = SleepTrend.points(nights, metric: .hours, range: .week, today: today)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week.last?.night, "2026-10-18")
        XCTAssertEqual(week.first?.night, "2026-10-12")
        XCTAssertEqual(SleepTrend.points(nights, metric: .hours, range: .month, today: today).count, 30)
    }

    func testLongSpansPlotWeeklyMeans() {
        let nights = (0..<14).map { night(daysBefore: $0, hours: $0 < 7 ? 90 : 70) }
        let points = SleepTrend.points(nights, metric: .hours, range: .sixMonths, today: today)
        // Oct 5–18 2026 is two Monday-started weeks; Oct 18 is a Sunday.
        XCTAssertEqual(points.map(\.value), [70, 90])
        let split = (0..<10).map { night(daysBefore: $0, hours: $0 < 7 ? 90 : 60) }
        XCTAssertEqual(SleepTrend.points(split, metric: .hours, range: .year, today: today).map(\.value), [60, 90],
                       "a partial week is the mean of the nights it has")
        XCTAssertTrue(points.allSatisfy { $0.night == nil })
    }

    func testSummaryComparesWithThePreviousSpan() {
        let nights = (0..<14).map { night(daysBefore: $0, hours: $0 < 7 ? 90 : 80) }
        let summary = SleepTrend.summary(nights, metric: .hours, range: .week, today: today)
        XCTAssertEqual(summary.average, 90)
        XCTAssertEqual(summary.change, 10)
        let noHistory = SleepTrend.summary(Array(nights.prefix(7)), metric: .hours, range: .week, today: today)
        XCTAssertNil(noHistory.change)
    }

    func testWindowAndHoursCarryBedWakeAndNeed() {
        var n = night(daysBefore: 0, hours: 90)
        n.bed = "2026-10-17T23:00"
        n.wake = "2026-10-18T07:00"
        n.hours = 7.5
        n.need = 8
        let window = SleepTrend.points([n], metric: .window, range: .week, today: today)
        XCTAssertEqual(window.first?.low, 660)
        XCTAssertEqual(window.first?.high, 1140)
        XCTAssertEqual(SleepTrend.points([n], metric: .hours, range: .week, today: today).first?.need, 8)
        XCTAssertNil(SleepTrend.points([night(daysBefore: 0, hours: 1)], metric: .window, range: .week, today: today).first)
    }

    func testViewModelShowsLastNightUntilAnotherIsPicked() async throws {
        let history = try SleepHistory.decode(Data(Self.json.utf8))
        let model = SleepViewModel(today: today) { history }
        await model.load()
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.night?.date, "2026-10-19")
        model.select("2026-10-17")
        XCTAssertEqual(model.night?.date, "2026-10-17")
        XCTAssertFalse(model.isShowingLastNight)
        model.select(nil)
        XCTAssertTrue(model.isShowingLastNight)
        XCTAssertEqual(model.tableNights.map(\.date), ["2026-10-19", "2026-10-18", "2026-10-17"])
    }

    func testViewModelStatesForMissingAndFailedHistory() async {
        let empty = SleepViewModel(today: today) { nil }
        await empty.load()
        XCTAssertEqual(empty.state, .empty)
        struct Down: Error {}
        let failed = SleepViewModel(today: today) { throw Down() }
        await failed.load()
        if case .failed = failed.state {} else { XCTFail("expected failed, got \(failed.state)") }
    }

    func testUsualIsTheNightsBefore() {
        var nights = (1...40).reversed().map { night(daysBefore: $0, hours: $0 <= 30 ? 8 : 4) }
        nights[nights.count - 1].bed = "2026-10-16T23:00"
        nights[nights.count - 2].bed = "2026-10-16T01:00"
        nights[nights.count - 3].bed = "2026-10-15T00:00"
        nights[nights.count - 8].bed = "2026-10-10T04:00"
        nights.append(night(daysBefore: 0, hours: 2))
        let usual = SleepUsual(before: "2026-10-18", in: nights)
        XCTAssertEqual(usual.hours, 8, "the 30 nights before, not the night itself or older ones")
        XCTAssertEqual(usual.bed, 720, "the week's median bedtime, 11 pm and 1 am either side of midnight")
        nights[nights.count - 4].bed = nil
        nights[nights.count - 2].bed = nil
        XCTAssertNil(SleepUsual(before: "2026-10-18", in: nights).bed, "one bedtime in the week isn't a usual")
        XCTAssertNil(SleepUsual(before: "2026-10-18", in: []).hours)
    }

    func testGaugesMarkUsualAndCallOutWhatIsFarFromIt() {
        var n = SleepNight(date: "2026-10-18")
        n.hours = 5.4
        n.bed = "2026-10-18T01:05"
        n.wakeUps = 3
        n.awakeMinutes = 52
        n.efficiency = 86
        n.hrv = 92
        n.hrvBand = 84...103
        n.restingHR = 48
        n.respiration = 14.2
        n.flags = ["breathing_up"]
        var usual = SleepUsual()
        usual.hours = 7.83
        usual.bed = 670
        usual.wakeUps = 2
        usual.awakeMinutes = 29
        usual.efficiency = 94
        usual.restingHR = 46
        usual.respiration = 14.1
        let gauges = Dictionary(uniqueKeysWithValues: SleepReadout.gauges(n, usual: usual).map { ($0.label, $0) })
        XCTAssertEqual(gauges.keys.sorted(), ["Asleep in bed", "Awake", "Breaths/min", "HRV", "Resting HR", "Wake-ups"])
        XCTAssertEqual(gauges["Awake"]?.reference, "usual 29 min", "every tick is labeled with what it is")
        XCTAssertEqual(gauges["Awake"]?.standsOut, true)
        XCTAssertEqual(gauges["Wake-ups"]?.standsOut, false, "one more than usual is noise")
        XCTAssertEqual(gauges["Asleep in bed"]?.standsOut, true)
        XCTAssertEqual(gauges["HRV"]?.reference, "normal 84–103")
        XCTAssertNil(gauges["HRV"]?.usual, "HRV shows Garmin's normal range, not a second tick")
        XCTAssertEqual(gauges["Breaths/min"]?.standsOut, true, "Garmin's flag counts even under a 1-breath rise")
        for gauge in gauges.values {
            XCTAssertTrue(gauge.scale.contains(gauge.number), "\(gauge.label) value is on its track")
            if let tick = gauge.usual { XCTAssertTrue(gauge.scale.contains(tick), "\(gauge.label) usual is on its track") }
        }
        let hours = SleepReadout.hoursAgainstUsual(n, usual: usual)
        XCTAssertEqual(hours?.standsOut, true)
        XCTAssertEqual(hours.map { ($0.diff * 100).rounded() }, -243)
        XCTAssertTrue(SleepReadout.clockStandsOut(785, usual: 670))
        XCTAssertFalse(SleepReadout.clockStandsOut(700, usual: 670))
        XCTAssertTrue(SleepReadout.gauges(SleepNight(date: "2026-10-18"), usual: usual).isEmpty)
    }

    func testClockAxisCoversBothWindowsOnWholeHours() {
        let axis = SleepClockAxis([785, 1162, 652, 1155]) // 1:05 am, 7:22 am, 10:52 pm, 7:15 am
        XCTAssertEqual(axis.range, 600...1200, "10 pm to 8 am")
        XCTAssertEqual(axis.ticks, [720, 900, 1080], "midnight, 3 am, 6 am")
        XCTAssertEqual(axis.position(900), 0.5)
    }

    private func night(daysBefore: Int, hours: Double) -> SleepNight {
        let day = today.addingTimeInterval(-Double(daysBefore) * 86_400)
        var n = SleepNight(date: SleepNight.dayFormatter.string(from: day))
        n.hours = hours
        return n
    }
}
