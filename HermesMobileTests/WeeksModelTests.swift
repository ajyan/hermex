import XCTest
@testable import HermesMobile

@MainActor
final class WeeksModelTests: XCTestCase {
    private let server = URL(string: "https://hermes.example.com")!

    private var iso: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    private func day(_ value: String) -> Date { DailyDeckPaths.date(day: value, calendar: iso)! }

    /// Every Sunday whose ISO week-based year is `year`, found by walking the days around it.
    private func isoSundays(of year: Int) -> [String] {
        var sundays: [String] = []
        var date = day("\(year - 1)-12-01")
        let end = day("\(year + 1)-01-31")
        while date <= end {
            if iso.component(.weekday, from: date) == 1, iso.component(.yearForWeekOfYear, from: date) == year {
                sundays.append(DailyDeckPaths.day(date, calendar: iso))
            }
            date = iso.date(byAdding: .day, value: 1, to: date)!
        }
        return sundays
    }

    private func tiles(_ year: Int, today: String = "2026-10-22", records: Set<String> = [], photos: Set<String> = [],
                       decks: Set<String> = []) -> [(weekEnding: String, number: Int, state: WeekTileState)] {
        WeeksModel.tiles(year: year, today: day(today), records: records, photos: photos, decks: decks)
    }

    // MARK: Tiles

    func testTilesFor2026Has53Sundays() {
        let expected = isoSundays(of: 2026)
        let tiles = tiles(2026)
        XCTAssertEqual(tiles.map(\.weekEnding), expected)
        XCTAssertEqual(tiles.count, 53, "2026 starts on a Thursday, so it is a long ISO year")
        XCTAssertEqual(tiles.map(\.number), Array(1...expected.count))
        XCTAssertEqual(tiles.first?.weekEnding, "2026-01-04")
    }

    func testTilesAcrossYearBoundaryUseTheSundaysISOYear() {
        let year2026 = tiles(2026)
        XCTAssertEqual(year2026.last?.weekEnding, "2027-01-03")
        XCTAssertEqual(year2026.last?.number, 53)
        let year2027 = tiles(2027)
        XCTAssertFalse(year2027.contains { $0.weekEnding == "2027-01-03" })
        XCTAssertEqual(year2027.first?.weekEnding, "2027-01-10")
        XCTAssertEqual(year2027.map(\.weekEnding), isoSundays(of: 2027))
        XCTAssertFalse(tiles(2025).contains { $0.weekEnding == "2026-01-04" })
    }

    func testTileStates() {
        let tiles = tiles(2026, today: "2026-10-22",
                          records: ["2026-10-18", "2026-10-11"],
                          photos: ["2026-10-18", "2026-09-20"],
                          decks: ["2026-10-04", "2026-10-18"])
        func state(_ week: String) -> WeekTileState? { tiles.first { $0.weekEnding == week }?.state }
        XCTAssertEqual(state("2026-10-18"), .reviewed(hasPhoto: true), "a filed deck's week is reviewed")
        XCTAssertEqual(state("2026-10-11"), .reviewed(hasPhoto: false))
        XCTAssertEqual(state("2026-10-04"), .unreviewed(hasDeck: true))
        XCTAssertEqual(state("2026-09-27"), .unreviewed(hasDeck: false))
        XCTAssertEqual(state("2026-09-20"), .unreviewed(hasDeck: false), "a photo alone isn't a review")
        XCTAssertEqual(state("2026-10-25"), .current, "Thursday's week ends on Sunday the 25th")
        XCTAssertEqual(state("2026-11-01"), .future)
        XCTAssertEqual(tiles.first { $0.weekEnding == "2026-10-25" }?.number, 43)
    }

    func testSundayTileOfTodayIsCurrentUntilItIsReviewed() {
        XCTAssertEqual(tiles(2026, today: "2026-10-25").first { $0.weekEnding == "2026-10-25" }?.state, .current)
        XCTAssertEqual(tiles(2026, today: "2026-10-25", records: ["2026-10-25"]).first { $0.weekEnding == "2026-10-25" }?.state,
                       .reviewed(hasPhoto: false))
        XCTAssertEqual(tiles(2026, today: "2026-10-26").first { $0.weekEnding == "2026-10-25" }?.state, .unreviewed(hasDeck: false))
    }

    func testRangeLabels() {
        XCTAssertEqual(WeeksModel.weekLabel(weekEnding: "2026-10-25", number: nil), "Week 43 · Oct 19–25, 2026")
        XCTAssertEqual(WeeksModel.weekLabel(weekEnding: "2026-10-04", number: 40), "Week 40 · Sep 28–Oct 4, 2026")
        XCTAssertEqual(WeeksModel.weekLabel(weekEnding: "2027-01-03", number: nil), "Week 53 · Dec 28, 2026–Jan 3, 2027")
    }

    // MARK: Loading

    func testLoadKeepsSundayRecordsPhotosAndUnfiledWeeklyDecks() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [
            "2026-10-18.weekly.json", "2026-10-18.weekly.answers.json",
            "2026-10-25.weekly.json", "2026-10-22.daily.json", "2026-09-30.monthly.json"
        ], deck: "")
        client.listings = [
            "weekly-checkins": ["2026-10-18-week-ending.json", "2026-10-18-week-ending.md", "2025-07-03-week-ending.json",
                                "2025-12-28-week-ending.json", "photos", "notes.json"],
            "weekly-checkins/photos": ["2026-10-18.jpg", "2026-10-18.jpg.tmp", "readme.txt"]
        ]
        let model = makeModel(client)
        await model.load()
        XCTAssertEqual(model.recordDates, ["2026-10-18", "2025-12-28"], "a Thursday-dated check-in has no tile")
        XCTAssertEqual(model.photoDates, ["2026-10-18"])
        XCTAssertEqual(model.unfiledDecks, ["2026-10-25"])
        XCTAssertEqual(model.years, [2025, 2026])
    }

    func testAWeekWhoseSealFailedStillWaits() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [
            "2026-10-11.weekly.json", "2026-10-11.weekly.answers.json", "2026-10-11.weekly.filed.json",
            "2026-10-18.weekly.json", "2026-10-18.weekly.answers.json",
            "2026-10-25.weekly.json", "2026-10-25.weekly.answers.json"
        ], deck: "")
        client.listings = ["weekly-checkins": ["2026-10-18-week-ending.json"], "weekly-checkins/photos": []]
        let model = makeModel(client)
        await model.load()
        XCTAssertEqual(model.unfiledDecks, ["2026-10-25"],
                       "saved answers without a record (or a v1 filing) are a seal that failed, so the deck still waits")
    }

    func testMissingFoldersLoadAsEmpty() async {
        let model = makeModel(ScriptedDailyDeckClient(workspaces: ["/vault"], names: nil, deck: ""))
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.recordDates, [])
        XCTAssertEqual(model.photoDates, [])
        XCTAssertEqual(model.unfiledDecks, [])
        XCTAssertEqual(model.years, [2026], "the current year is always there")
    }

    func testATransientListingErrorKeepsTheLastListing() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: ["2026-10-25.weekly.json"], deck: "")
        client.listings = ["weekly-checkins": ["2026-10-18-week-ending.json"], "weekly-checkins/photos": ["2026-10-18.jpg"]]
        let model = makeModel(client)
        await model.load()
        XCTAssertNil(model.loadError)

        let offline = URLError(.notConnectedToInternet)
        client.listingErrors = ["weekly-checkins": offline, "weekly-checkins/photos": APIError.http(statusCode: 502, body: nil)]
        await model.load()
        XCTAssertEqual(model.recordDates, ["2026-10-18"])
        XCTAssertEqual(model.photoDates, ["2026-10-18"])
        XCTAssertEqual(model.unfiledDecks, ["2026-10-25"])
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.photosListed)
    }

    func testAFailedFirstLoadIsNotComplete() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        client.listings = ["weekly-checkins": ["2026-10-18-week-ending.json"]]
        client.listingErrors = ["weekly-checkins/photos": URLError(.timedOut)]
        let model = makeModel(client)
        await model.load()
        XCTAssertFalse(model.isLoaded)
        XCTAssertFalse(model.photosListed, "the week's photo is unknown, not absent")
        XCTAssertEqual(model.recordDates, ["2026-10-18"])
        XCTAssertNotNil(model.loadError)
    }

    func testAMissingPhotosFolderIsNoPhotos() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        client.listings = ["weekly-checkins": ["2026-10-18-week-ending.json"]]
        client.listingErrors = ["weekly-checkins/photos": APIError.http(statusCode: 404, body: #"{"error": "Not a directory"}"#)]
        let model = makeModel(client)
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertTrue(model.photosListed)
        XCTAssertEqual(model.photoDates, [])
        XCTAssertNil(model.loadError)
    }

    func testRecordIsReadOnceAndKept() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        client.files = [WeeksModel.recordPath("2026-10-18"): Self.record("2026-10-18", title: "Quiet week")]
        let model = makeModel(client)
        let first = await model.record("2026-10-18")
        let second = await model.record("2026-10-18")
        XCTAssertEqual(first?.title, "Quiet week")
        XCTAssertEqual(second, first)
        XCTAssertEqual(client.readPaths, ["weekly-checkins/2026-10-18-week-ending.json"])
    }

    // MARK: Photos

    func testRemovePhotoFailureKeepsPhotoDates() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        client.listings = ["weekly-checkins/photos": ["2026-10-18.jpg"]]
        client.photoDelete = .failure(APIError.http(statusCode: 500, body: nil))
        let model = makeModel(client)
        await model.load()
        do {
            try await model.removePhoto(for: "2026-10-18")
            XCTFail("expected the delete to throw")
        } catch {}
        XCTAssertEqual(model.photoDates, ["2026-10-18"])
        XCTAssertEqual(model.photoVersion(for: "2026-10-18"), 0)
        XCTAssertEqual(client.deletedPhotos, ["2026-10-18"])
    }

    func testPhotoChangesUpdatePhotoDatesAndDropTheCachedImage() async throws {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        let model = makeModel(client)
        let key = WeekPhotoCache.key(server: server, sessionID: "s1", path: WeeksModel.photoPath("2026-10-18"))
        WeekPhotoCache.images.setObject(UIImage(), forKey: key)

        try await model.setPhoto(Data([1, 2, 3]), for: "2026-10-18")
        XCTAssertEqual(model.photoDates, ["2026-10-18"])
        XCTAssertEqual(model.photoVersion(for: "2026-10-18"), 1)
        XCTAssertNil(WeekPhotoCache.images.object(forKey: key))
        XCTAssertEqual(client.uploadedPhotos.map(\.weekEnding), ["2026-10-18"])

        try await model.removePhoto(for: "2026-10-18")
        XCTAssertEqual(model.photoDates, [])
        XCTAssertEqual(model.photoVersion(for: "2026-10-18"), 2)
    }

    func testSetPhotoFailureLeavesPhotoDates() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        client.photoUpload = .failure(APIError.http(statusCode: 413, body: nil))
        let model = makeModel(client)
        try? await model.setPhoto(Data([1]), for: "2026-10-18")
        XCTAssertEqual(model.photoDates, [])
        XCTAssertEqual(model.photoVersion(for: "2026-10-18"), 0)
    }

    // MARK: Predictions

    func testGradeFoundInALaterRecord() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        client.listings = ["weekly-checkins": ["2026-10-04-week-ending.json", "2026-10-18-week-ending.json"]]
        client.files = [
            WeeksModel.recordPath("2026-10-04"): Self.record("2026-10-04", prediction: ("p-ship", "Ship the app", "2026-10-15")),
            WeeksModel.recordPath("2026-10-18"): Self.record("2026-10-18", graded: [("p-ship", "partly")])
        ]
        let model = makeModel(client)
        await model.load()
        let grade = await model.grade(for: "p-ship")
        XCTAssertEqual(grade, "partly")
        let missing = await model.grade(for: "p-other")
        XCTAssertNil(missing)
    }

    func testPredictionsDueAreOpenAndPastTheirDay() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        client.listings = ["weekly-checkins": [
            "2026-09-06-week-ending.json", "2026-09-13-week-ending.json", "2026-09-20-week-ending.json",
            "2026-10-11-week-ending.json", "2026-10-18-week-ending.json"
        ]]
        client.files = [
            WeeksModel.recordPath("2026-09-06"): Self.record("2026-09-06", prediction: ("p-graded", "Graded already", "2026-10-04")),
            WeeksModel.recordPath("2026-09-13"): Self.record("2026-09-13", prediction: ("p-open", "Run a 10k", "2026-10-11")),
            WeeksModel.recordPath("2026-09-20"): Self.record("2026-09-20", prediction: ("p-today", "Read two books", "2026-10-22")),
            WeeksModel.recordPath("2026-10-11"): Self.record("2026-10-11", prediction: ("p-later", "Not yet", "2026-11-08"),
                                                             graded: [("p-graded", "hit")]),
            WeeksModel.recordPath("2026-10-18"): Self.record("2026-10-18")
        ]
        let model = makeModel(client)
        await model.load()
        await model.loadDuePredictions()
        XCTAssertEqual(model.duePredictions.map(\.id), ["p-open", "p-today"])
        XCTAssertEqual(model.duePredictions.first?.text, "Run a 10k")
        XCTAssertEqual(model.duePredictions.first?.due, "2026-10-11")
    }

    func testEveryRecordIsReadWhenThereAreMoreThanAtOnce() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "")
        let weeks = (0..<(WeeksModel.recordReadsAtOnce * 2 + 1)).map { DailyDeckPaths.day(iso.date(byAdding: .day, value: -7 * $0, to: day("2026-10-18"))!, calendar: iso) }
        client.listings = ["weekly-checkins": weeks.map { "\($0)-week-ending.json" }]
        client.files = Dictionary(uniqueKeysWithValues: weeks.map { (WeeksModel.recordPath($0), Self.record($0)) })
        let model = makeModel(client)
        await model.load()
        _ = await model.grade(for: "none")
        XCTAssertEqual(Set(client.readPaths), Set(weeks.map(WeeksModel.recordPath)))
        XCTAssertTrue(weeks.allSatisfy { model.cachedRecord($0) != nil })
    }

    // MARK: Calendar routing

    func testWeeklyReviewOpensPageWhenRecordExists() {
        let records: Set<String> = ["2026-10-18"]
        XCTAssertEqual(DeckCalendarRoute.for(review: DeckReview(date: "2026-10-18", kind: "weekly", isFiled: true), records: records),
                       .weekPage("2026-10-18"))
        XCTAssertEqual(DeckCalendarRoute.for(review: DeckReview(date: "2026-10-11", kind: "weekly", isFiled: true), records: records),
                       .deck("2026-10-11", "weekly"), "a filed week without a record opens its deck")
        XCTAssertEqual(DeckCalendarRoute.for(review: DeckReview(date: "2026-10-18", kind: "monthly", isFiled: false), records: records),
                       .deck("2026-10-18", "monthly"), "only weekly reviews have a week page")
    }

    func testWeekPageOffersEditOnlyForAMomentsRecordOrAnUnreadableOne() throws {
        let moments = try WeekRecord.decode(Data(#"{"version": 2, "week_ending": "2026-11-01", "moments": []}"#.utf8))
        let older = try WeekRecord.decode(Data(#"{"week_ending": "2026-10-25", "title": "The v2 week", "story": "Slept more."}"#.utf8))
        XCTAssertTrue(WeekPageView.showsEdit(for: moments), "today's review reopens to change and seal again")
        XCTAssertFalse(WeekPageView.showsEdit(for: older), "an earlier review's deck can't be edited any more")
        XCTAssertTrue(WeekPageView.showsEdit(for: nil), "an unreadable record can still be sealed again")
    }

    func testSealedV2WeeklyOpensWeekPage() throws {
        // A moments-era deck is only reachable as its week page once the record exists.
        let deck = try DailyDeck.decode(#"{"version": 2, "date": "2026-10-25", "kind": "weekly", "cards": [{"id": "cover", "type": "cover"}]}"#)
        XCTAssertEqual(deck.version, 2)
        let review = DeckReview(date: deck.date, kind: deck.kind, isFiled: true)
        XCTAssertEqual(DeckCalendarRoute.for(review: review, records: [deck.date]), .weekPage("2026-10-25"))
        XCTAssertEqual(DeckCalendarRoute.for(review: review, records: []), .deck("2026-10-25", "weekly"),
                       "unsealed, it still opens as a deck")
    }

    // MARK: Helpers

    private func makeModel(_ client: ScriptedDailyDeckClient) -> WeeksModel {
        let today = day("2026-10-22")
        return WeeksModel(server: server, client: client, sessionID: "s1", now: { today })
    }

    static func record(_ weekEnding: String, title: String = "A week", prediction: (String, String, String)? = nil,
                       graded: [(String, String)] = []) -> String {
        var object: [String: Any] = ["version": 1, "week_ending": weekEnding, "title": title, "story": "It happened."]
        if let prediction {
            object["prediction"] = ["id": prediction.0, "text": prediction.1, "probability": 70, "due": prediction.2]
        }
        object["graded"] = graded.map { ["id": $0.0, "grade": $0.1, "made_week": "2026-09-06", "text": "..."] }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}
