import XCTest
@testable import HermesMobile

private final class FakeMealsClient: MealsScreenClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _nights: [MealsNightsRequest] = []
    private var _logs: [MealsLogRequest] = []
    var homeResults: [Result<MealsHome, Error>] = []
    var writeResults: [Result<MealsHome, Error>] = []

    var calls: [String] { lock.withLock { _log } }
    var nightsRequests: [MealsNightsRequest] { lock.withLock { _nights } }
    var logRequests: [MealsLogRequest] { lock.withLock { _logs } }

    private func next(_ results: inout [Result<MealsHome, Error>]) -> Result<MealsHome, Error> {
        results.count > 1 ? results.removeFirst() : results[0]
    }

    func home(day: String) async throws -> MealsHome {
        try lock.withLock { _log.append("home \(day)"); return next(&homeResults) }.get()
    }

    func dishes() async throws -> [MealsDish] { [] }

    func saveNights(_ request: MealsNightsRequest) async throws -> MealsHome {
        try lock.withLock { _log.append("nights"); _nights.append(request); return next(&writeResults) }.get()
    }

    func log(_ request: MealsLogRequest) async throws -> MealsHome {
        try lock.withLock { _log.append("log"); _logs.append(request); return next(&writeResults) }.get()
    }

    func addDish(name: String, side: Bool) async throws -> MealsDish {
        MealsDish(slug: name.lowercased(), name: name, kind: side ? "side" : "main")
    }
}

final class MealsModelsTests: XCTestCase {
    static func home() throws -> MealsHome {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Meals/home.json")
        return try PrepDecoding.decode(MealsHome.self, from: Data(contentsOf: url))
    }

    func testDecodesTheServersWeek() throws {
        let home = try Self.home()
        XCTAssertEqual(home.week, "2026-11-02")
        XCTAssertEqual(home.days.count, 7)
        XCTAssertEqual(home.tonight?.main?.name, "Fish collar")
        XCTAssertEqual(home.tonight?.sides.map(\.slug), ["tomato-egg"])
        XCTAssertEqual(home.tonight?.servings, 8)
        XCTAssertTrue(home.tonight?.sides.first?.isSide == true)
        XCTAssertFalse(home.tonightLogged)
        XCTAssertEqual(home.days[0].logged?.dishes.first?.rating, 1)
        XCTAssertNil(home.days[3].night)
        XCTAssertEqual(home.today?.day, "2026-11-03")
    }

    func testToleratesMissingFieldsAndBadDays() throws {
        let json = #"{"day":"2026-11-03","week":"2026-11-02","days":[{"day":"2026-11-02","night":{"dishes":[{"slug":"x"}]}},{"nope":1}]}"#
        let home = try PrepDecoding.decode(MealsHome.self, from: Data(json.utf8))
        XCTAssertEqual(home.days.count, 1)
        XCTAssertEqual(home.days[0].night?.servings, 3)
        XCTAssertEqual(home.days[0].night?.main?.name, "x")
        XCTAssertEqual(home.tomorrowPrep, [])
    }

    func testCopy() {
        XCTAssertEqual(MealsCopy.short("2026-11-03"), "Tue, Nov 3")
        XCTAssertEqual(MealsCopy.weekday("2026-11-08"), "Sun")
        XCTAssertNil(MealsCopy.serves(3))
        XCTAssertEqual(MealsCopy.serves(8), "Serves 8")
        XCTAssertEqual(MealsCopy.servingsChoices(including: 5), [2, 3, 4, 5, 6, 8, 10, 12])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        // 11 pm in New York is already the next day in UTC: the phone's day wins.
        let late = ISO8601DateFormatter().date(from: "2026-11-04T04:00:00Z")!
        XCTAssertEqual(MealsCopy.localDay(late, calendar: calendar), "2026-11-03")
    }
}

final class MealsWeekEditTests: XCTestCase {
    private let side = MealsDish(slug: "miso-soup", name: "Miso soup", kind: "side")
    private let main = MealsDish(slug: "unagi-don", name: "Unagi don")

    func testMovingOntoAPlannedDaySwapsAndOntoAnOpenDayMoves() throws {
        let home = try MealsModelsTests.home()
        let swapped = MealsWeekEdit.move(home, from: "2026-11-03", to: "2026-11-04")
        XCTAssertEqual(swapped.first { $0.day == "2026-11-04" }?.dishes, ["fish-collar", "tomato-egg"])
        XCTAssertEqual(swapped.first { $0.day == "2026-11-04" }?.servings, 8)
        XCTAssertEqual(swapped.first { $0.day == "2026-11-03" }?.dishes, ["toshikoshi-soba"])
        let moved = MealsWeekEdit.move(home, from: "2026-11-03", to: "2026-11-07")
        XCTAssertNil(moved.first { $0.day == "2026-11-03" })
        XCTAssertEqual(moved.first { $0.day == "2026-11-07" }?.dishes, ["fish-collar", "tomato-egg"])
    }

    func testAddingPutsAMainFirstAndASideLast() throws {
        let home = try MealsModelsTests.home()
        XCTAssertEqual(MealsWeekEdit.add(home, dish: side, to: "2026-11-03").first { $0.day == "2026-11-03" }?.dishes,
                       ["fish-collar", "tomato-egg", "miso-soup"])
        XCTAssertEqual(MealsWeekEdit.add(home, dish: main, to: "2026-11-03").first { $0.day == "2026-11-03" }?.dishes,
                       ["unagi-don", "fish-collar", "tomato-egg"])
        let open = MealsWeekEdit.add(home, dish: main, to: "2026-11-06").first { $0.day == "2026-11-06" }
        XCTAssertEqual(open, MealsNightBody(day: "2026-11-06", dishes: ["unagi-don"], servings: 3))
    }

    func testRemovingTheLastDishDropsTheNight() throws {
        let home = try MealsModelsTests.home()
        XCTAssertNil(MealsWeekEdit.remove(home, slug: "toshikoshi-soba", from: "2026-11-04").first { $0.day == "2026-11-04" })
        XCTAssertEqual(MealsWeekEdit.remove(home, slug: "tomato-egg", from: "2026-11-03").first { $0.day == "2026-11-03" }?.dishes,
                       ["fish-collar"])
        XCTAssertNil(MealsWeekEdit.clear(home, day: "2026-11-03").first { $0.day == "2026-11-03" })
        XCTAssertEqual(MealsWeekEdit.servings(home, day: "2026-11-04", to: 6).first { $0.day == "2026-11-04" }?.servings, 6)
    }
}

@MainActor
final class MealsHomeViewModelTests: XCTestCase {
    private func viewModel(_ client: FakeMealsClient) -> MealsHomeViewModel {
        // Nov 3, noon in New York.
        MealsHomeViewModel(client: client, now: { ISO8601DateFormatter().date(from: "2026-11-03T17:00:00Z")! })
    }

    func testNotFoundIsUnavailable() async {
        let client = FakeMealsClient()
        client.homeResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let vm = viewModel(client)
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    func testEatingItLogsTheWholeMealThenOpensTheSheet() async throws {
        let home = try MealsModelsTests.home()
        let client = FakeMealsClient()
        client.homeResults = [.success(home)]
        client.writeResults = [.success(home)]
        let vm = viewModel(client)
        await vm.load()
        await vm.eatTonight()
        XCTAssertEqual(client.logRequests, [MealsLogRequest(day: "2026-11-03", today: "2026-11-03", servings: 8, dishes: [
            MealsLogDish(dish: "fish-collar"), MealsLogDish(dish: "tomato-egg")
        ])])
        XCTAssertEqual(vm.logDraft?.dishes.map(\.dish.slug), ["fish-collar", "tomato-egg"])
    }

    func testTheSheetOnlyLogsAgainWithRatingsOrNotes() async throws {
        let home = try MealsModelsTests.home()
        let client = FakeMealsClient()
        client.homeResults = [.success(home)]
        client.writeResults = [.success(home)]
        let vm = viewModel(client)
        await vm.load()
        await vm.eatTonight()
        var draft = try XCTUnwrap(vm.logDraft)
        let closedEmpty = await vm.finishLog(draft)
        XCTAssertTrue(closedEmpty)
        XCTAssertEqual(client.logRequests.count, 1, "nothing added, nothing posted")
        draft.dishes[1].rating = 1
        draft.dishes[0].note = "  less salt  "
        let saved = await vm.finishLog(draft)
        XCTAssertTrue(saved)
        XCTAssertEqual(client.logRequests.last?.dishes, [MealsLogDish(dish: "fish-collar", note: "less salt"),
                                                         MealsLogDish(dish: "tomato-egg", rating: 1)])
        XCTAssertNil(vm.logDraft)
    }

    func testAFailedEditKeepsTheWeekAndSaysSo() async throws {
        let home = try MealsModelsTests.home()
        let client = FakeMealsClient()
        client.homeResults = [.success(home)]
        client.writeResults = [.failure(URLError(.notConnectedToInternet))]
        let vm = viewModel(client)
        await vm.load()
        await vm.move(from: "2026-11-03", to: "2026-11-05")
        XCTAssertEqual(client.nightsRequests.first?.week, "2026-11-02")
        XCTAssertEqual(vm.state, .loaded(home))
        XCTAssertEqual(vm.saveError, "Couldn't save that. Try again.")
        await vm.eatTonight()
        XCTAssertNil(vm.logDraft, "no sheet before the server has the night")
    }

    func testNotEatenPostsAnEmptyLogForThatDayAndShowsTheServersWeek() async throws {
        let home = try MealsModelsTests.home()
        let unlogged = MealsHome(day: home.day, week: home.week,
                                 days: home.days.map { MealsDay(day: $0.day, night: $0.night, logged: nil) },
                                 tonight: home.tonight, tonightLogged: false, tomorrowPrep: home.tomorrowPrep)
        let client = FakeMealsClient()
        client.homeResults = [.success(home)]
        client.writeResults = [.success(unlogged)]
        let vm = viewModel(client)
        await vm.load()
        await vm.unlog("2026-11-02")
        XCTAssertEqual(client.logRequests, [.notEaten(day: "2026-11-02", today: "2026-11-03")])
        XCTAssertEqual(vm.state, .loaded(unlogged))
        XCTAssertNil(vm.saveError)
    }

    func testNotEatenSkipsADayWithNothingLogged() async throws {
        let client = FakeMealsClient()
        client.homeResults = [.success(try MealsModelsTests.home())]
        let vm = viewModel(client)
        await vm.load()
        await vm.unlog("2026-11-03")
        XCTAssertTrue(client.logRequests.isEmpty)
    }

    func testNotEatenSendsNoDishesAndNoServings() throws {
        let body = try JSONEncoder().encode(MealsLogRequest.notEaten(day: "2026-11-02", today: "2026-11-03"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["day"] as? String, "2026-11-02")
        XCTAssertEqual(json["today"] as? String, "2026-11-03")
        XCTAssertEqual((json["dishes"] as? [Any])?.count, 0)
        XCTAssertNil(json["servings"])
    }

    func testAFailedNotEatenKeepsTheLogAndSaysSo() async throws {
        let home = try MealsModelsTests.home()
        let client = FakeMealsClient()
        client.homeResults = [.success(home)]
        client.writeResults = [.failure(APIError.http(statusCode: 400, body: nil))]
        let vm = viewModel(client)
        await vm.load()
        await vm.unlog("2026-11-02")
        XCTAssertEqual(vm.state, .loaded(home))
        XCTAssertEqual(vm.saveError, "Couldn't save that. Try again.")
    }

    func testAnEditThatChangesNothingIsNotSent() async throws {
        let home = try MealsModelsTests.home()
        let client = FakeMealsClient()
        client.homeResults = [.success(home)]
        let vm = viewModel(client)
        await vm.load()
        await vm.setServings(8, on: "2026-11-03")
        XCTAssertEqual(client.calls, ["home 2026-11-03"])
    }
}

@MainActor
final class MealsWidgetSyncTests: XCTestCase {
    private let server = URL(string: "https://a.example")!
    private var suiteName: String!
    private var store: AtlasWidgetMealsStore!
    private let now = ISO8601DateFormatter().date(from: "2026-11-03T17:00:00Z")!

    override func setUp() {
        super.setUp()
        suiteName = "MealsWidgetSyncTests.\(UUID().uuidString)"
        store = AtlasWidgetMealsStore(defaults: UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func snapshot(day: String = "2026-11-03") -> AtlasWidgetMeals {
        AtlasWidgetMeals(server: server, day: day, dishes: [.init(slug: "fish-collar", name: "Fish collar")],
                         servings: 3, logged: false)
    }

    func testSnapshotTakesTonightFromTheWeek() throws {
        let meals = AtlasWidgetMeals(server: server, home: try MealsModelsTests.home())
        XCTAssertEqual(meals.dishes.map(\.name), ["Fish collar", "Tomato egg"])
        XCTAssertEqual(meals.servings, 8)
        XCTAssertFalse(meals.logged)
    }

    func testLoggingFromTheWidgetPostsTonightAndShowsTheServersAnswer() async throws {
        var home = try MealsModelsTests.home()
        home = MealsHome(day: home.day, week: home.week, days: home.days, tonight: home.tonight, tonightLogged: true,
                         tomorrowPrep: [])
        let client = FakeMealsClient()
        client.writeResults = [.success(home)]
        store.save(snapshot())
        await MealsWidgetSync.logTonight(store: store, activeServerID: { self.server.absoluteString },
                                         client: { _ in client }, now: now)
        XCTAssertEqual(client.logRequests.first?.dishes, [MealsLogDish(dish: "fish-collar")])
        XCTAssertEqual(store.load()?.logged, true)
        XCTAssertEqual(store.load()?.dishes.count, 2)
    }

    func testAFailedLogGoesBackToEatingItFlagged() async {
        let client = FakeMealsClient()
        client.writeResults = [.failure(URLError(.timedOut))]
        store.save(snapshot())
        await MealsWidgetSync.logTonight(store: store, activeServerID: { self.server.absoluteString },
                                         client: { _ in client }, now: now)
        XCTAssertEqual(store.load()?.logged, false)
        XCTAssertEqual(store.load()?.syncFailed, true)
    }

    func testYesterdaysOrAnotherServersMealIsNeverLogged() async {
        let client = FakeMealsClient()
        client.writeResults = [.failure(URLError(.timedOut))]
        store.save(snapshot(day: "2026-11-02"))
        await MealsWidgetSync.logTonight(store: store, activeServerID: { self.server.absoluteString },
                                         client: { _ in client }, now: now)
        store.save(snapshot())
        await MealsWidgetSync.logTonight(store: store, activeServerID: { "https://b.example" },
                                         client: { _ in client }, now: now)
        XCTAssertEqual(client.calls, [])
        XCTAssertEqual(store.load()?.syncFailed, true)
    }
}
