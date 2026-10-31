import SwiftData
import XCTest
@testable import HermesMobile

@MainActor
final class BrainPeopleListTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-10-14, midday UTC.
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))! }

    private func snakeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    // MARK: Contract

    func testEndpoint() {
        XCTAssertEqual(Endpoint.brainPeopleHome.path, "/api/brain/people/home")
        XCTAssertEqual(Endpoint.brainPeopleHome.queryItems, [])
    }

    func testPeopleHomeDecodesTolerantly() throws {
        let json = #"""
        {"due": [{"id": "crm/contacts/Dara Quill.md", "title": "Dara Quill", "subtitle": "Friend",
                  "last_seen": "2026-08-14", "headline": "Dinner", "cadence_days": 30,
                  "next_birthday": null, "extra": true},
                 {"title": "No id"}],
         "birthdays": "not-a-list"}
        """#
        let home = try snakeDecoder().decode(BrainPeopleHome.self, from: Data(json.utf8))
        XCTAssertEqual(home.due, [BrainPersonRow(id: "crm/contacts/Dara Quill.md", title: "Dara Quill", subtitle: "Friend",
                                                 lastSeen: "2026-08-14", headline: "Dinner", cadenceDays: 30)])
        XCTAssertEqual(home.birthdays, [], "a mistyped section is empty")
        XCTAssertEqual(home.recent, [], "a missing section is empty")
    }

    func testPeopleItemDecodesRelationshipTypeAndRoundTrips() throws {
        let json = #"{"module": "people", "id": "p.md", "title": "P", "relationship_type": "family"}"#
        let item = try snakeDecoder().decode(BrainItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.relationshipType, "family")
        let cached = try JSONDecoder().decode(BrainItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(cached, item)
        let wiki = try snakeDecoder().decode(BrainItem.self, from: Data(#"{"module": "wiki", "id": "w.md"}"#.utf8))
        XCTAssertNil(wiki.relationshipType)
    }

    // MARK: Sections

    func testElapsedBuckets() {
        let expected: [(Int, String)] = [
            (-2, "today"), (0, "today"), (1, "1d"), (13, "13d"), (14, "2 wk"), (59, "8 wk"),
            (60, "2 mo"), (729, "24 mo"), (730, "2 yr"),
        ]
        for (days, text) in expected {
            XCTAssertEqual(BrainPeopleLayout.elapsed(days: days), text, "\(days) days")
        }
    }

    func testSectionsKeepServerOrderAndDropEmptyOnes() {
        let home = BrainPeopleHome(
            due: [BrainPersonRow(id: "a", title: "Ann", lastSeen: "2026-06-14", headline: "Dinner")],
            recent: [BrainPersonRow(id: "b", title: "Bo", lastSeen: "2026-10-08"),
                     BrainPersonRow(id: "c", title: "Cy", lastSeen: "2026-10-01")]
        )
        let sections = BrainPeopleLayout.sections(home, today: today, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["Due for a catch-up", "Recently seen"])
        XCTAssertEqual(sections[1].rows.map(\.id), ["b", "c"])
        XCTAssertTrue(BrainPeopleLayout.sections(BrainPeopleHome(), today: today, calendar: calendar).isEmpty)
    }

    func testDueRowWearsTheGlowAndSaysHowLongAgo() {
        let home = BrainPeopleHome(due: [BrainPersonRow(id: "a", title: "Ann", subtitle: "Friend",
                                                        lastSeen: "2026-06-14", headline: "Dinner")])
        let row = BrainPeopleLayout.sections(home, today: today, calendar: calendar)[0].rows[0]
        XCTAssertEqual(row.trailing, "4 mo")
        XCTAssertTrue(row.isDue)
        XCTAssertEqual(row.subtitle, "Dinner")
        XCTAssertEqual(row.accessibilityLabel, "Ann, Dinner, seen 4 months ago, due for a catch-up")
    }

    func testDueRowLeadsWithTheirUsualGap() {
        let home = BrainPeopleHome(
            due: [BrainPersonRow(id: "a", title: "Ann", subtitle: "Friend", lastSeen: "2026-06-14", headline: "Dinner",
                                 cadenceDays: 21),
                  BrainPersonRow(id: "b", title: "Bo", subtitle: "", lastSeen: "2026-06-14", cadenceDays: 90)],
            recent: [BrainPersonRow(id: "c", title: "Cy", lastSeen: "2026-10-08", headline: "Lunch", cadenceDays: 21)])
        let sections = BrainPeopleLayout.sections(home, today: today, calendar: calendar)
        XCTAssertEqual(sections[0].rows.map(\.subtitle), ["Every 3 wk · Dinner", "Every 3 mo"])
        XCTAssertEqual(sections[0].rows[0].accessibilityLabel,
                       "Ann, Dinner, seen 4 months ago, due for a catch-up, usually every 3 weeks")
        XCTAssertEqual(sections[1].rows[0].subtitle, "Lunch", "only due rows explain themselves")
    }

    func testCadenceBuckets() {
        XCTAssertEqual(BrainPeopleLayout.cadence(days: 1).shown, "Every day")
        XCTAssertEqual(BrainPeopleLayout.cadence(days: 5).shown, "Every 5 days")
        XCTAssertEqual(BrainPeopleLayout.cadence(days: 21).shown, "Every 3 wk")
        XCTAssertEqual(BrainPeopleLayout.cadence(days: 30).spoken, "every 4 weeks")
        XCTAssertEqual(BrainPeopleLayout.cadence(days: 60).spoken, "every 2 months")
        XCTAssertEqual(BrainPeopleLayout.cadence(days: 183).shown, "Every 6 mo")
        XCTAssertEqual(BrainPeopleLayout.cadence(days: 800).spoken, "every 2 years")
    }

    func testRecentRowFallsBackToRelationshipWithoutAHeadline() {
        let home = BrainPeopleHome(recent: [BrainPersonRow(id: "b", title: "Bo", subtitle: "Colleague", lastSeen: "2026-10-08")])
        let row = BrainPeopleLayout.sections(home, today: today, calendar: calendar)[0].rows[0]
        XCTAssertEqual(row.trailing, "6d")
        XCTAssertFalse(row.isDue)
        XCTAssertEqual(row.subtitle, "Colleague")
        XCTAssertEqual(row.accessibilityLabel, "Bo, seen 6 days ago")
    }

    func testBirthdayRowsCountDown() {
        let home = BrainPeopleHome(birthdays: [
            BrainPersonRow(id: "a", title: "Ann", nextBirthday: "2026-10-14"),
            BrainPersonRow(id: "b", title: "Bo", nextBirthday: "2026-10-15"),
            BrainPersonRow(id: "c", title: "Cy", nextBirthday: "2026-10-25"),
            BrainPersonRow(id: "d", title: "Di", nextBirthday: "soon"),
            BrainPersonRow(id: "e", title: "Ed", nextBirthday: "2026-10-13"),
        ])
        let rows = BrainPeopleLayout.sections(home, today: today, calendar: calendar)[0].rows
        // A birthday that has passed (a saved copy, or the app left open overnight) and an unreadable one are dropped.
        XCTAssertEqual(rows.map(\.trailing), ["today", "tomorrow", "in 11d"])
        XCTAssertEqual(rows[2].accessibilityLabel, "Cy, birthday in 11 days")
        XCTAssertFalse(rows.contains(where: \.isDue))
    }

    // MARK: Relationship filter

    private let people = [
        BrainItem(module: .people, id: "1", title: "Ann", relationshipType: "friend"),
        BrainItem(module: .people, id: "2", title: "Bo", relationshipType: "family"),
        BrainItem(module: .people, id: "3", title: "Cy", relationshipType: "friend"),
        BrainItem(module: .people, id: "4", title: "Di", relationshipType: "colleague"),
        BrainItem(module: .people, id: "5", title: "Ed"),
        BrainItem(module: .people, id: "6", title: "Flo", relationshipType: " "),
    ]

    func testRelationshipsAreMostCommonFirstThenByName() {
        XCTAssertEqual(BrainPeopleLayout.relationships(people), [
            .init(type: "friend", label: "Friend", count: 2),
            .init(type: "colleague", label: "Colleague", count: 1),
            .init(type: "family", label: "Family", count: 1),
        ])
    }

    func testFilterNarrowsEveryoneAndNilKeepsAll() {
        XCTAssertEqual(BrainPeopleLayout.filtered(people, relationship: "friend").map(\.id), ["1", "3"])
        XCTAssertEqual(BrainPeopleLayout.filtered(people, relationship: nil).count, people.count)
    }

    // MARK: View model

    private func makeCache() throws -> BrainCacheHandle {
        let container = try ModelContainer(for: CachedBrainEntry.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return BrainCacheHandle(server: URL(string: "https://a.example")!, context: ModelContext(container))
    }

    func testViewModelShowsSectionsAndFallsBackToTheSavedCopy() async throws {
        let cache = try makeCache()
        let client = FakeBrainClient()
        client.peopleHomeResult = .success(BrainPeopleHome(recent: [BrainPersonRow(id: "b", title: "Bo", lastSeen: "2026-10-08")]))
        let first = BrainPeopleHomeViewModel(client: client, cache: cache, now: { self.today })
        await first.load()
        XCTAssertEqual(first.sections.map(\.title), ["Recently seen"])

        client.peopleHomeResult = .failure(URLError(.notConnectedToInternet))
        let offline = BrainPeopleHomeViewModel(client: client, cache: cache, now: { self.today })
        await offline.load()
        XCTAssertEqual(offline.sections, first.sections)
    }

    func testAFailedReloadRedoesTheDayMathOnTheSavedCopy() async throws {
        let cache = try makeCache()
        let client = FakeBrainClient()
        client.peopleHomeResult = .success(BrainPeopleHome(birthdays: [BrainPersonRow(id: "a", title: "Ann", nextBirthday: "2026-10-15")]))
        var now = today
        let viewModel = BrainPeopleHomeViewModel(client: client, cache: cache, now: { now })
        await viewModel.load()
        XCTAssertEqual(viewModel.sections.first?.rows.map(\.trailing), ["tomorrow"])

        // Back two days later with no connection: the birthday has passed, so its section goes.
        now = calendar.date(byAdding: .day, value: 2, to: today)!
        client.peopleHomeResult = .failure(URLError(.notConnectedToInternet))
        await viewModel.load()
        XCTAssertTrue(viewModel.sections.isEmpty)
    }

    func testViewModelOnAnOlderServerShowsNoSections() async {
        let client = FakeBrainClient()
        client.peopleHomeResult = .failure(URLError(.badServerResponse))
        let viewModel = BrainPeopleHomeViewModel(client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil))
        await viewModel.load()
        XCTAssertTrue(viewModel.sections.isEmpty)
    }
}
