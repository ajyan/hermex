import XCTest
@testable import HermesMobile

final class MoneyModelsTests: XCTestCase {
    /// The synthetic snapshot and market note (no real data) in `Fixtures/Money/`.
    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Money/\(name)")
        return try Data(contentsOf: url)
    }

    static func day(_ s: String) -> Date { MoneyPoint.dayFormatter.date(from: s)! }

    func testDecodesFixtureAndIgnoresUnknownFields() throws {
        let snapshot = try MoneySnapshot.decode(Self.fixture("snapshot.json"))
        XCTAssertEqual(snapshot.netWorth, 184320.12, accuracy: 0.001)
        XCTAssertEqual(snapshot.slot, "close")
        XCTAssertNotNil(snapshot.asOf)
        XCTAssertEqual(snapshot.series.count, 731)
        XCTAssertTrue(snapshot.series[0].e)
        XCTAssertFalse(snapshot.series.last!.e)
        XCTAssertEqual(snapshot.accounts.count, 6)
        XCTAssertEqual(snapshot.accounts[0].tracks, "S&P 500")
        XCTAssertEqual(snapshot.accounts[0].change1w, 560)
        XCTAssertEqual(snapshot.week?.cashFlow, 340)
        XCTAssertEqual(snapshot.week?.indexes.first?.returnPct, 2.3)
        XCTAssertEqual(snapshot.stale.first?.ageDays, 9)
        XCTAssertFalse(snapshot.holdingsMissing)

        let note = try MoneyMarketNote.decode(Self.fixture("market.json"))
        XCTAssertEqual(note.drivers.count, 3)
        XCTAssertEqual(note.drivers[0].url, URL(string: "https://example.com/cpi"))
        XCTAssertTrue(note.matches(snapshot.week))
    }

    func testDecodesMinimalSnapshot() throws {
        let snapshot = try MoneySnapshot.decode(Data(#"{"net_worth": 1}"#.utf8))
        XCTAssertEqual(snapshot.netWorth, 1)
        XCTAssertTrue(snapshot.series.isEmpty)
        XCTAssertTrue(snapshot.accounts.isEmpty)
        XCTAssertNil(snapshot.week)
        XCTAssertTrue(snapshot.stale.isEmpty)
    }

    func testRangeFiltersByDate() {
        let series = (0...400).map { i in
            MoneyPoint(d: MoneyPoint.dayFormatter.string(from: Self.day("2025-09-07").addingTimeInterval(Double(i) * 86_400)), v: Double(i))
        }
        let today = Self.day("2026-10-12")
        XCTAssertEqual(MoneyRange.week.points(in: series, today: today).first?.d, "2026-10-05")
        XCTAssertEqual(MoneyRange.week.points(in: series, today: today).count, 8)
        XCTAssertEqual(MoneyRange.month.points(in: series, today: today).first?.d, "2026-09-12")
        XCTAssertEqual(MoneyRange.year.points(in: series, today: today).first?.d, "2025-10-12")
        XCTAssertEqual(MoneyRange.all.points(in: series, today: today).count, 401)
    }

    func testRangeWithOnePointHasZeroChange() {
        let change = MoneyChange.between([MoneyPoint(d: "2026-10-12", v: 100)])
        XCTAssertEqual(change, MoneyChange(amount: 0, percent: 0))
        XCTAssertEqual(MoneyChange.between([]), MoneyChange(amount: 0, percent: 0))
        let up = MoneyChange.between([MoneyPoint(d: "2026-10-05", v: 200), MoneyPoint(d: "2026-10-12", v: 250)])
        XCTAssertEqual(up.amount, 50)
        XCTAssertEqual(up.percent, 25, accuracy: 0.0001)
    }

    func testHiddenAmountsHaveFixedWidthAndKeepSign() {
        XCTAssertEqual(MoneyFormat.amount(184320.12, hidden: false), "$184,320")
        XCTAssertEqual(MoneyFormat.amount(184320.12, hidden: true), "$••••••")
        XCTAssertEqual(MoneyFormat.amount(12, hidden: true), "$••••••")
        XCTAssertEqual(MoneyFormat.amount(-2180, hidden: false), "−$2,180")
        XCTAssertEqual(MoneyFormat.amount(-2180, hidden: true), "−$••••••")
        XCTAssertEqual(MoneyFormat.signed(2140, hidden: false), "+$2,140")
        XCTAssertEqual(MoneyFormat.signed(-60, hidden: false), "−$60")
        XCTAssertEqual(MoneyFormat.signed(2140, hidden: true), "+$••••••")
        XCTAssertEqual(MoneyFormat.signed(-60, hidden: true), "−$••••••")
        XCTAssertEqual(MoneyFormat.percent(1.1712), "+1.17%")
        XCTAssertEqual(MoneyFormat.percent(-0.2), "−0.20%")
        XCTAssertEqual(MoneyFormat.compact(1800, hidden: false), "+$1.8k")
        XCTAssertEqual(MoneyFormat.compact(340, hidden: false), "+$340")
        XCTAssertEqual(MoneyFormat.compact(-60, hidden: true), "−$••••••")
    }

    func testMarketNoteHiddenWhenWindowDiffers() throws {
        let snapshot = try MoneySnapshot.decode(Self.fixture("snapshot.json"))
        let old = try MoneyMarketNote.decode(Data(#"{"window": {"start": "2026-09-28", "end": "2026-10-05"}, "story": "Old"}"#.utf8))
        XCTAssertFalse(old.matches(snapshot.week))
        XCTAssertFalse(old.matches(nil))
    }
}
