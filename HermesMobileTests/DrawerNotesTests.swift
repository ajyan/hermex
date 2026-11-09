import XCTest
@testable import HermesMobile

/// The drawer's rows and their trailing notes: the order, each note's words from the
/// section's own models, and a model that never blocks or loses a note to a failed read.
final class DrawerNotesTests: XCTestCase {
    func testDrawerListsTheSecondBrainInOrderWithNoOperatorScreens() {
        XCTAssertEqual(DrawerSection.allCases.map(\.title),
                       ["Daily Brief", "People", "Brain", "Interview prep", "Goals", "Body", "Meals", "Money"])
        XCTAssertEqual(DrawerSection.allCases.map(\.destination), [
            .dailyDeck, .brainRoute(.module(.people)), .brain, .brainRoute(.prep(.home)),
            .goals, .body, .meals, .money
        ])
    }

    // MARK: Copy

    func testBriefNoteSaysFiledWithTheAnswersFileTime() throws {
        let json = #"""
        {"entries": [{"name": "2026-11-09.morning.json", "mtime_ns": "1794225000000000000"},
                     {"name": "2026-11-09.morning.answers.json", "mtime_ns": "1794231720000000000"},
                     {"name": "2026-11-08.morning.answers.json"}]}
        """#
        // As `APIClient` decodes it.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let entries = try XCTUnwrap(decoder.decode(DirectoryListResponse.self, from: Data(json.utf8)).entries)
        let filedAt = Date(timeIntervalSince1970: 1_794_231_720).formatted(date: .omitted, time: .shortened)

        XCTAssertEqual(DrawerNoteCopy.brief(entries, today: "2026-11-09"), "Filed \(filedAt)")
        XCTAssertEqual(DrawerNoteCopy.brief(entries, today: "2026-11-08"), "Filed", "no timestamp, no time")
        XCTAssertNil(DrawerNoteCopy.brief(entries, today: "2026-11-10"), "no deck yet, nothing to say")
    }

    func testBriefNoteSaysReadyWhileTodaysDeckWaits() {
        let entries = [WorkspaceEntry(name: "2026-11-09.morning.json", path: nil)]
        XCTAssertEqual(DrawerNoteCopy.brief(entries, today: "2026-11-09"), "Ready")
    }

    func testPeopleNoteCountsWhoIsDue() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let due = try decoder.decode(BrainPeopleHome.self, from: Data(
            #"{"due": [{"id": "a.md", "title": "A"}, {"id": "b.md", "title": "B"}]}"#.utf8))
        let none = try decoder.decode(BrainPeopleHome.self, from: Data(#"{"due": []}"#.utf8))

        XCTAssertEqual(DrawerNoteCopy.people(due), "2 due")
        XCTAssertNil(DrawerNoteCopy.people(none))
    }

    func testInterviewNoteNamesTheSoonestDay() throws {
        func pipeline(on: String, inDays: Int) throws -> JobPipeline {
            let json = #"{"today": "2026-11-09", "upcoming": [{"id": "x", "key": "k", "label": "First round", "on": "\#(on)", "in_days": \#(inDays)}]}"#
            return try PrepDecoding.decode(JobPipeline.self, from: Data(json.utf8))
        }
        XCTAssertEqual(DrawerNoteCopy.interview(try pipeline(on: "2026-11-09", inDays: 0)), "Interview today")
        XCTAssertEqual(DrawerNoteCopy.interview(try pipeline(on: "2026-11-10", inDays: 1)), "Interview tomorrow")
        XCTAssertEqual(DrawerNoteCopy.interview(try pipeline(on: "2026-11-12", inDays: 3)), "Interview Thu")
        XCTAssertEqual(DrawerNoteCopy.interview(try pipeline(on: "2026-11-19", inDays: 10)), "Interview Nov 19")
        let empty = try PrepDecoding.decode(JobPipeline.self, from: Data(#"{"today": "2026-11-09", "upcoming": []}"#.utf8))
        XCTAssertNil(DrawerNoteCopy.interview(empty))
    }

    func testGoalsNoteAsksForTheWeekBeforeCountingToday() throws {
        var home = try PrepDecoding.decode(GoalsHome.self, from: Data(GoalsModelsTests.homeSample.utf8))
        XCTAssertEqual(DrawerNoteCopy.goals(home), "2 left today")

        home.goals[0].weekPending = "2026-10-11"
        XCTAssertEqual(DrawerNoteCopy.goals(home), "Confirm the week")

        home.goals = []
        XCTAssertNil(DrawerNoteCopy.goals(home))
    }

    func testBodyNoteSaysDoneTodayElseWhatIsNext() throws {
        let home = try PrepDecoding.decode(BodyHome.self, from: BodyModelsTests.fixture("home.json"))
        XCTAssertEqual(DrawerNoteCopy.body(home, today: "2026-11-27"), "Pull done")
        XCTAssertEqual(DrawerNoteCopy.body(home, today: "2026-11-28"), "Push next")
    }

    func testMealsNoteIsTonightsMain() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Meals/home.json")
        let home = try PrepDecoding.decode(MealsHome.self, from: Data(contentsOf: url))
        XCTAssertEqual(DrawerNoteCopy.meals(home), "Fish collar")
    }

    // MARK: Model

    @MainActor
    func testRefreshKeepsANoteWhenItsReadFailsAndClearsOneWithNothingToSay() async {
        let loader = ScriptedNotesLoader()
        let model = DrawerNotesModel(loader: loader)

        loader.results = [.goals: .success("Confirm the week"), .meals: .success("Fish collar")]
        await model.refresh()
        XCTAssertEqual(model.notes, [.goals: "Confirm the week", .meals: "Fish collar"])

        loader.results = [.goals: .failure(URLError(.notConnectedToInternet)), .meals: .success(nil)]
        await model.refresh()
        XCTAssertEqual(model.notes, [.goals: "Confirm the week"], "a failed read keeps the last note")
    }

    @MainActor
    func testRefreshIfStaleReadsOncePerMinute() async {
        let loader = ScriptedNotesLoader()
        let model = DrawerNotesModel(loader: loader)
        let start = Date(timeIntervalSince1970: 1_000)

        await model.refresh(now: start)
        let reads = loader.readCount
        model.refreshIfStale(now: start.addingTimeInterval(30))
        XCTAssertEqual(loader.readCount, reads, "a second open inside a minute reads nothing")
    }
}

private final class ScriptedNotesLoader: DrawerNotesLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _results: [DrawerSection: Result<String?, Error>] = [:]
    private var _readCount = 0

    var results: [DrawerSection: Result<String?, Error>] {
        get { lock.withLock { _results } }
        set { lock.withLock { _results = newValue } }
    }
    var readCount: Int { lock.withLock { _readCount } }

    func note(for section: DrawerSection, now: Date) async throws -> String? {
        let result: Result<String?, Error>? = lock.withLock {
            _readCount += 1
            return _results[section]
        }
        return try result?.get()
    }
}
