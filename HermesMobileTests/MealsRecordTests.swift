import XCTest
@testable import HermesMobile

private final class FakeSeasonClient: MealsSeasonClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _days: [String] = []
    var result: Result<MealsSeasonRecord, Error>

    init(_ result: Result<MealsSeasonRecord, Error>) { self.result = result }

    var days: [String] { lock.withLock { _days } }

    func season(day: String, today: String) async throws -> MealsSeasonRecord {
        try lock.withLock { _days.append("\(day) \(today)"); return result }.get()
    }
}

private enum RecordFixture {
    static func season() throws -> MealsSeasonRecord {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Meals/season.json")
        return try PrepDecoding.decode(MealsSeasonRecord.self, from: Data(contentsOf: url))
    }

    /// Dec 10, 2026, noon in New York.
    static let now = ISO8601DateFormatter().date(from: "2026-12-10T17:00:00Z")!
}

final class MealsRecordModelTests: XCTestCase {
    func testDecodesTheServersSeason() throws {
        let season = try RecordFixture.season()
        XCTAssertEqual(season.name, "Winter 2026")
        XCTAssertEqual(season.dinners, 3)
        XCTAssertEqual(season.weeks.first?.days, ["off", "missed", "skip", "missed", "missed", "missed", "missed"])
        XCTAssertEqual(season.mains.first?.count, 3)
        XCTAssertEqual(season.sides.map(\.name), ["Tomato egg"])
        XCTAssertEqual(season.loved.map(\.slug), ["kabocha-with-pork-riblets"])
        XCTAssertEqual(season.occasions.first?.tagged, ["Toshikoshi soba"])
        XCTAssertEqual(season.prev, "2026-11-30")
        XCTAssertNil(season.next)
        XCTAssertEqual(MealsCopy.weekSpoken(season.weeks[1]), "Week of Dec 7: 2 dinners logged")
    }

    func testHomeCarriesOccasionsAndAYearAgo() throws {
        let json = """
        {"day": "2026-12-28", "week": "2026-12-28", "days": [],
         "occasions": [{"occasion": "New Year's Eve", "date": "2026-12-31",
                        "dishes": [{"slug": "toshikoshi-soba", "name": "Toshikoshi soba"}]}, {"date": "x"}],
         "year_ago": [{"slug": "galbijjim", "name": "Galbijjim", "date": "2025-12-30"}]}
        """
        let home = try PrepDecoding.decode(MealsHome.self, from: Data(json.utf8))
        XCTAssertEqual(home.occasions.map(\.occasion), ["New Year's Eve"])
        XCTAssertEqual(home.yearAgo.map(\.slug), ["galbijjim"])
        let bare = try PrepDecoding.decode(MealsHome.self, from: Data(#"{"day":"d","week":"w","days":[]}"#.utf8))
        XCTAssertEqual(bare.occasions, [])
        XCTAssertEqual(bare.yearAgo, [])
    }

    func testOccasionLines() {
        let eve = MealsOccasion(occasion: "New Year's Eve", date: "2026-12-31", dishes: [])
        XCTAssertEqual(MealsCopy.occasionLine(eve, today: "2026-12-31"), "New Year's Eve is today")
        XCTAssertEqual(MealsCopy.occasionLine(eve, today: "2026-12-30"), "New Year's Eve is tomorrow")
        XCTAssertEqual(MealsCopy.occasionLine(eve, today: "2026-12-28"), "New Year's Eve is Thursday")
        XCTAssertEqual(MealsCopy.occasionLine(eve, today: "2026-12-20"), "New Year's Eve is Thu, Dec 31")
    }
}

@MainActor
final class MealsSeasonModelTests: XCTestCase {
    func testLoadsAndMovesASeason() async throws {
        let client = FakeSeasonClient(.success(try RecordFixture.season()))
        let model = MealsSeasonModel(day: "2026-12-10", client: client, now: RecordFixture.now)
        await model.load()
        guard case .loaded(let season) = model.state else { return XCTFail("not loaded") }
        await model.go(to: try XCTUnwrap(season.prev))
        XCTAssertEqual(client.days, ["2026-12-10 2026-12-10", "2026-11-30 2026-12-10"])
        XCTAssertEqual(model.day, "2026-11-30")
    }

    func testAServerWithoutSeasonsIsUnavailable() async {
        let client = FakeSeasonClient(.failure(APIError.http(statusCode: 404, body: nil)))
        let model = MealsSeasonModel(day: "2026-12-10", client: client, now: RecordFixture.now)
        await model.load()
        XCTAssertEqual(model.state, .unavailable)
    }
}
