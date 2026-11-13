import XCTest
@testable import HermesMobile

final class AtlasStatusTests: XCTestCase {
    private let sample = """
    {
      "checked_at": "2026-11-13T17:02:11-08:00",
      "health_at": "2026-11-13T17:00:03-08:00",
      "watcher_at": "2026-11-13T08:26:09-08:00",
      "overall": "down",
      "stale": null,
      "headline": "App needs you",
      "summary": "Xcode is signed out, so Hermex can't renew. Everything else is running.",
      "something_new": {"ignored": true},
      "tiles": [
        {"id": "app", "title": "App", "state": "down",
         "days": ["ok","ok","ok","ok","ok","down","down"], "fact": null,
         "problems": [{"state": "down", "text": "Xcode is signed out", "since": "2026-11-12T08:23:45-08:00"}],
         "checks": [{"name": "Xcode account", "value": "Signed out", "state": "down"}]},
        {"id": "jobs", "title": "Jobs", "state": "warn", "days": ["warn","warn","warn","warn","warn","warn","warn"],
         "problems": [{"state": "warn", "text": "cron job night-chain failed 2 of 7 runs this week"}], "checks": []},
        {"id": "chat", "title": "Chat", "state": "ok", "days": ["none","ok","none","none","ok","ok","ok"],
         "fact": "Too few chats to time this week", "problems": [], "checks": []},
        {"id": "model", "title": "Model", "state": "mystery", "days": [], "problems": [], "checks": []},
        {"title": "No id is dropped"}
      ],
      "fixed": [{"tile": "disk", "text": "Deleted 3 build caches nothing could reuse", "at": "2026-11-12T20:24:46.5-08:00"}]
    }
    """

    func testDecodesTheServerShapeTolerantly() throws {
        let status = try AtlasStatus.decode(Data(sample.utf8))
        XCTAssertEqual(status.overall, .down)
        XCTAssertEqual(status.headline, "App needs you")
        XCTAssertNotNil(status.checkedAt)
        XCTAssertEqual(status.tiles.map(\.id), ["app", "jobs", "chat", "model"])
        XCTAssertEqual(status.tile("app")?.days.last, .down)
        XCTAssertEqual(status.tile("app")?.problems.first?.since, AtlasStatusCopy.date("2026-11-12T08:23:45-08:00"))
        XCTAssertEqual(status.tile("chat")?.days.first, AtlasStatusLevel.none)
        XCTAssertEqual(status.tile("chat")?.fact, "Too few chats to time this week")
        XCTAssertEqual(status.tile("model")?.state, .warn, "an unknown state never reads as fine")
        XCTAssertNotNil(status.fixed.first?.at, "fractional seconds parse")
    }

    func testDecodesAMinimalAnswer() throws {
        let status = try AtlasStatus.decode(Data(#"{"overall":"ok"}"#.utf8))
        XCTAssertEqual(status.overall, .ok)
        XCTAssertTrue(status.tiles.isEmpty)
        XCTAssertTrue(status.fixed.isEmpty)
    }

    func testDrawerNoteForEachOverall() throws {
        var status = try AtlasStatus.decode(Data(sample.utf8))
        XCTAssertEqual(AtlasStatusCopy.drawerNote(status), AtlasStatusDrawerNote(text: "1 needs you", level: .down))

        status.tiles[0].state = .ok
        status.tiles[3].state = .ok
        status.overall = .warn
        XCTAssertEqual(AtlasStatusCopy.drawerNote(status), AtlasStatusDrawerNote(text: "1 to look at", level: .warn))

        status.tiles[1].state = .ok
        status.overall = .ok
        XCTAssertEqual(AtlasStatusCopy.drawerNote(status), AtlasStatusDrawerNote(text: "All good", level: nil))

        status.overall = .stale
        XCTAssertEqual(AtlasStatusCopy.drawerNote(status), AtlasStatusDrawerNote(text: "Checks stopped", level: .stale))
    }

    func testAskStartsWithEveryProblem() throws {
        let status = try AtlasStatus.decode(Data(sample.utf8))
        XCTAssertEqual(AtlasStatusCopy.ask(try XCTUnwrap(status.tile("app"))),
                       "Status says App needs attention:\n- Xcode is signed out")
    }

    func testAccessibilityReadsTheWeek() throws {
        let status = try AtlasStatus.decode(Data(sample.utf8))
        XCTAssertEqual(AtlasStatusCopy.accessibility(try XCTUnwrap(status.tile("app"))),
                       "App, needs you. Last 7 days: ok 5 days, needs you 2 days.")
    }

    func testCheckedLabel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AtlasStatusCopy.checked(now.addingTimeInterval(-20), now: now), "Checked just now")
        XCTAssertEqual(AtlasStatusCopy.checked(now.addingTimeInterval(-4 * 60), now: now), "Checked 4 min ago")
        XCTAssertEqual(AtlasStatusCopy.checked(now.addingTimeInterval(-2 * 3600), now: now), "Checked 2 h ago")
        XCTAssertNil(AtlasStatusCopy.checked(nil, now: now))
    }

    func testLettersEndOnToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US")
        // Friday, Nov 13 2026, noon Pacific.
        let friday = Date(timeIntervalSince1970: 1_794_600_000)
        XCTAssertEqual(AtlasStatusCopy.letters(now: friday, calendar: calendar), ["S", "S", "M", "T", "W", "T", "F"])
    }

    @MainActor
    func testViewModelLoadsThenKeepsItThroughAFailedRefresh() async throws {
        let client = ScriptedStatusClient()
        let model = AtlasStatusViewModel(client: client)
        client.next = .success(try AtlasStatus.decode(Data(sample.utf8)))
        await model.load()
        guard case .loaded = model.state else { return XCTFail("expected loaded") }
        XCTAssertFalse(model.refreshFailed)

        client.next = .failure(APIError.http(statusCode: 502, body: nil))
        await model.load()
        guard case .loaded = model.state else { return XCTFail("a failed refresh keeps the last answer") }
        XCTAssertTrue(model.refreshFailed)
    }

    @MainActor
    func testViewModelShowsUnavailableOnNotFound() async {
        let client = ScriptedStatusClient()
        client.next = .failure(APIError.http(statusCode: 404, body: nil))
        let model = AtlasStatusViewModel(client: client)
        await model.load()
        XCTAssertEqual(model.state, .unavailable)
    }

    @MainActor
    func testViewModelFailsWithNothingToShow() async {
        let client = ScriptedStatusClient()
        client.next = .failure(APIError.http(statusCode: 500, body: nil))
        let model = AtlasStatusViewModel(client: client)
        await model.load()
        guard case .failed = model.state else { return XCTFail("expected failed") }
    }

    @MainActor
    func testDrawerModelHidesOnNotFoundAndKeepsNoteOnFailure() async throws {
        let client = ScriptedStatusClient()
        let model = AtlasStatusDrawerModel(client: client)
        XCTAssertNil(model.note)

        client.next = .success(try AtlasStatus.decode(Data(sample.utf8)))
        await model.refresh()
        XCTAssertEqual(model.note?.text, "1 needs you")

        client.next = .failure(APIError.http(statusCode: 502, body: nil))
        await model.refresh()
        XCTAssertEqual(model.note?.text, "1 needs you", "a failed read keeps the bar")

        client.next = .failure(APIError.http(statusCode: 404, body: nil))
        await model.refresh()
        XCTAssertNil(model.note, "a server without Status hides the bar")
    }
}

private final class ScriptedStatusClient: AtlasStatusClient, @unchecked Sendable {
    var next: Result<AtlasStatus, Error> = .failure(APIError.http(statusCode: 500, body: nil))

    func status() async throws -> AtlasStatus {
        try next.get()
    }
}
