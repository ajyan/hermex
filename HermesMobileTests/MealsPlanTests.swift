import XCTest
@testable import HermesMobile

private final class FakePlanClient: MealsPlanClient, MealsScreenClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _reviews: [MealsReviewRequest] = []
    private var _leftovers: [[String]] = []
    private var _finishes: [MealsPlanFinishRequest] = []
    private var _nights: [MealsNightsRequest] = []
    var review: MealsPlanReview
    var left: MealsLeftovers
    var suggestions: MealsSuggestions
    var groceriesResult: MealsGroceries
    var week: MealsHome
    var saveError: Error?

    init() throws {
        review = try PlanFixture.decode("plan-review")
        left = try PlanFixture.decode("plan-left")
        suggestions = try PlanFixture.decode("plan-suggestions")
        groceriesResult = try PlanFixture.decode("plan-groceries")
        week = try PrepDecoding.decode(MealsHome.self, from: Data(PlanFixture.week.utf8))
    }

    var calls: [String] { lock.withLock { _calls } }
    var reviews: [MealsReviewRequest] { lock.withLock { _reviews } }
    var leftoverSaves: [[String]] { lock.withLock { _leftovers } }
    var finishes: [MealsPlanFinishRequest] { lock.withLock { _finishes } }
    var nights: [MealsNightsRequest] { lock.withLock { _nights } }

    private func record(_ call: String) throws {
        try lock.withLock {
            _calls.append(call)
            if let saveError, call.hasPrefix("save") { throw saveError }
        }
    }

    func review(day: String) async throws -> MealsPlanReview { try record("review \(day)"); return review }
    func finishReview(_ request: MealsReviewRequest) async throws {
        try record("save review")
        lock.withLock { _reviews.append(request) }
    }
    func leftovers(target: String) async throws -> MealsLeftovers { try record("left \(target)"); return left }
    func saveLeftovers(_ items: [String]) async throws {
        try record("save left")
        lock.withLock { _leftovers.append(items) }
    }
    func start(target: String) async throws -> MealsSuggestions { try record("start \(target)"); return suggestions }
    func groceries(target: String) async throws -> MealsGroceries { try record("groceries"); return groceriesResult }
    func finish(_ request: MealsPlanFinishRequest) async throws -> MealsPlanFinish {
        try record("save finish")
        lock.withLock { _finishes.append(request) }
        return try PrepDecoding.decode(MealsPlanFinish.self, from: Data(
            #"{"groceries": {"Weee!": 1}, "reminders": {"added": 1, "learned": []}}"#.utf8))
    }

    func home(day: String) async throws -> MealsHome { try record("home \(day)"); return week }
    func dishes() async throws -> [MealsDish] { [] }
    func saveNights(_ request: MealsNightsRequest) async throws -> MealsHome {
        try record("save nights")
        lock.withLock { _nights.append(request) }
        return week
    }
    func log(_ request: MealsLogRequest) async throws -> MealsHome { week }
    func addDish(name: String, side: Bool) async throws -> MealsDish { MealsDish(slug: name, name: name) }
}

private enum PlanFixture {
    static func decode<Value: Decodable>(_ name: String) throws -> Value {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Meals/\(name).json")
        return try PrepDecoding.decode(Value.self, from: Data(contentsOf: url))
    }

    /// The target week: Monday has the carried bibimbap, the rest are open.
    static let week = """
    {"day": "2026-11-09", "week": "2026-11-09", "days": [
     {"day": "2026-11-09", "night": {"day": "2026-11-09", "servings": 3,
       "dishes": [{"slug": "fish-collar", "name": "Fish collar"}]}},
     {"day": "2026-11-10"}, {"day": "2026-11-11"}, {"day": "2026-11-12"}, {"day": "2026-11-13"},
     {"day": "2026-11-14"}, {"day": "2026-11-15"}]}
    """

    static var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// Sat, Nov 7, 2026, noon in New York.
    static let saturday = ISO8601DateFormatter().date(from: "2026-11-07T17:00:00Z")!
}

final class MealsPlanCopyTests: XCTestCase {
    func testFridayOnPlansNextWeek() {
        let calendar = PlanFixture.newYork
        func target(_ iso: String) -> String {
            let date = ISO8601DateFormatter().date(from: iso)!
            return MealsCopy.localDay(MealsCopy.planTarget(date, calendar: calendar), calendar: calendar)
        }
        XCTAssertEqual(target("2026-11-05T17:00:00Z"), "2026-11-02", "Thursday plans this week")
        XCTAssertEqual(target("2026-11-06T17:00:00Z"), "2026-11-09")
        XCTAssertEqual(target("2026-11-09T03:00:00Z"), "2026-11-09", "Sunday 10 pm plans the coming week")
        XCTAssertEqual(target("2026-11-09T17:00:00Z"), "2026-11-09", "Monday plans this week")
        XCTAssertEqual(MealsCopy.planTitle(PlanFixture.saturday, calendar: calendar), "Plan next week")
        XCTAssertEqual(MealsCopy.planTitle(ISO8601DateFormatter().date(from: "2026-11-10T17:00:00Z")!,
                                           calendar: calendar), "Plan this week")
    }

    func testRangesAndAmounts() throws {
        XCTAssertEqual(MealsCopy.weekRange("2026-11-09"), "Nov 9–15")
        XCTAssertEqual(MealsCopy.weekRange("2026-11-30"), "Nov 30–Dec 6")
        XCTAssertEqual(MealsCopy.asciiAmount("10 2/3 lb"), "10⅔ lb")
        XCTAssertEqual(MealsCopy.asciiAmount("1/2 cup"), "½ cup")
        XCTAssertEqual(MealsCopy.asciiAmount("2 block"), "2 block")
        let groceries: MealsGroceries = try PlanFixture.decode("plan-groceries")
        XCTAssertEqual(MealsCopy.groceriesLine(groceries), "For 2 dinners, Saturday scaled to 8, minus what you have.")
    }

    func testDecodesTheServersSteps() throws {
        let review: MealsPlanReview = try PlanFixture.decode("plan-review")
        XCTAssertEqual(review.target, "2026-11-09")
        XCTAssertEqual(review.days.count, 7)
        XCTAssertEqual(review.needs.map(\.day), ["2026-11-04", "2026-11-05"])
        XCTAssertEqual(review.needs[1].choice, "skipped")
        XCTAssertTrue(review.needs[1].carry)
        XCTAssertEqual(review.needs[1].reason, "You said you ate out")
        XCTAssertEqual(review.logged, ["Fish collar"])
        let left: MealsLeftovers = try PlanFixture.decode("plan-left")
        XCTAssertEqual(left.items.first?.where, "freezer")
        XCTAssertTrue(left.items.contains { $0.why == "Thursday was skipped" })
        let suggestions: MealsSuggestions = try PlanFixture.decode("plan-suggestions")
        XCTAssertEqual(suggestions.candidates.first?.slug, "galbijjim")
        XCTAssertEqual(suggestions.sides["fish-collar"]?.map(\.slug), ["tomato-egg"])
        XCTAssertEqual(suggestions.lastYear.map(\.name), ["Galbijjim"])
        let groceries: MealsGroceries = try PlanFixture.decode("plan-groceries")
        XCTAssertEqual(groceries.stores.map(\.store), ["Weee!", "Whole Foods"])
    }
}

@MainActor
final class MealsPlanModelTests: XCTestCase {
    private func model(_ client: FakePlanClient) -> MealsPlanModel {
        MealsPlanModel(client: client, now: PlanFixture.saturday, calendar: PlanFixture.newYork)
    }

    func testReviewDefaultsAndAnswers() async throws {
        let client = try FakePlanClient()
        let model = model(client)
        XCTAssertEqual(model.target, "2026-11-09")
        XCTAssertFalse(model.reviewsLastWeek, "a Saturday reviews this week")
        await model.loadReview()
        XCTAssertEqual(client.calls, ["review 2026-11-07"])
        XCTAssertEqual(model.answer(for: "2026-11-04"), MealsReviewAnswer(day: "2026-11-04", choice: "ate", carry: false))
        model.choose("skipped", for: "2026-11-04")
        XCTAssertEqual(model.answer(for: "2026-11-04")?.carry, true, "a skipped meal carries unless he says not")
        model.toggleCarry("2026-11-04")
        model.choose("out", for: "2026-11-05")
        let saved = await model.finishReview()
        XCTAssertTrue(saved)
        XCTAssertEqual(client.reviews, [MealsReviewRequest(week: "2026-11-02", answers: [
            MealsReviewAnswer(day: "2026-11-04", choice: "skipped", carry: false),
            MealsReviewAnswer(day: "2026-11-05", choice: "out", carry: false)])])
    }

    func testAWeekWithNothingToReviewSendsNothing() async throws {
        let client = try FakePlanClient()
        client.review = try PrepDecoding.decode(MealsPlanReview.self, from: Data(
            #"{"week":"2026-11-02","target":"2026-11-09","days":[],"needs":[]}"#.utf8))
        let model = model(client)
        await model.loadReview()
        let saved = await model.finishReview()
        XCTAssertTrue(saved)
        XCTAssertEqual(client.calls, ["review 2026-11-07"])
    }

    func testLeftoversSaveWhatIsTickedInOrder() async throws {
        let client = try FakePlanClient()
        let model = model(client)
        await model.loadLeftovers()
        guard case .loaded(let items) = model.leftovers else { return XCTFail("not loaded") }
        XCTAssertEqual(model.checked, Set(items.map(\.text)))
        model.toggle(items[0].text)
        model.addLeftover("  half a napa cabbage ")
        model.addLeftover("Half a napa cabbage")
        let saved = await model.saveLeftovers()
        XCTAssertTrue(saved)
        XCTAssertEqual(client.leftoverSaves, [Array(items.dropFirst().map(\.text)) + ["half a napa cabbage"]])
    }

    func testSuggestionsSpreadOverOpenNightsAndAnotherMovesOn() async throws {
        let client = try FakePlanClient()
        let model = model(client)
        await model.startFill()
        XCTAssertEqual(client.calls, ["start 2026-11-09", "home 2026-11-09"])
        guard case .loaded(let home) = model.week.state else { return XCTFail("not loaded") }
        XCTAssertEqual(model.filledCount(home), 1)
        // Fish collar is on Monday, so Tuesday and Wednesday get the other candidates in order.
        XCTAssertEqual(model.suggestion(for: "2026-11-10", in: home)?.slug, "galbijjim")
        XCTAssertEqual(model.suggestion(for: "2026-11-11", in: home)?.slug, "kabocha-with-pork-riblets")
        XCTAssertNil(model.suggestion(for: "2026-11-12", in: home))
        model.another(for: "2026-11-10", in: home)
        XCTAssertEqual(model.suggestion(for: "2026-11-10", in: home)?.slug, "kabocha-with-pork-riblets")
        XCTAssertEqual(model.suggestion(for: "2026-11-11", in: home)?.slug, "galbijjim")
        let night = try XCTUnwrap(home.days[0].night)
        XCTAssertEqual(model.pairedSides(for: night).map(\.slug), ["tomato-egg"])
        await model.addToFirstOpenNight(MealsSeasonPick(slug: "galbijjim", name: "Galbijjim"))
        XCTAssertEqual(client.nights.last?.nights.map(\.day), ["2026-11-09", "2026-11-10"])
        XCTAssertEqual(client.nights.last?.today, "2026-11-09", "edits answer the target week")
    }

    func testAnOccasionsDishLeadsThatNight() async throws {
        let client = try FakePlanClient()
        client.suggestions = try PrepDecoding.decode(MealsSuggestions.self, from: Data("""
            {"candidates": [{"slug": "galbijjim", "name": "Galbijjim"}],
             "occasions": {"2026-11-12": {"occasion": "Thanksgiving", "date": "2026-11-12",
                                          "dishes": [{"slug": "turkey", "name": "Turkey"}]}}}
            """.utf8))
        let model = model(client)
        await model.startFill()
        guard case .loaded(let home) = model.week.state else { return XCTFail("not loaded") }
        let pick = model.suggestion(for: "2026-11-12", in: home)
        XCTAssertEqual(pick?.slug, "turkey")
        XCTAssertEqual(pick?.why, "Thanksgiving")
        XCTAssertEqual(model.suggestion(for: "2026-11-10", in: home)?.slug, "galbijjim")
    }

    func testFinishSendsRemindersAndAFailedSaveSaysSo() async throws {
        let client = try FakePlanClient()
        let model = model(client)
        let finished = await model.finish(reminders: true)
        XCTAssertTrue(finished)
        XCTAssertEqual(client.finishes, [MealsPlanFinishRequest(target: "2026-11-09", reminders: true)])
        XCTAssertEqual(model.finished?.reminders?.added, 1)
        client.saveError = APIError.http(statusCode: 500, body: nil)
        let failed = await model.finish(reminders: false)
        XCTAssertFalse(failed)
        XCTAssertEqual(model.error, "Couldn't save that. Try again.")
    }
}
