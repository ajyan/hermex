import XCTest
@testable import HermesMobile

/// The episode/event display strings are locale-aware. Pin the display locale
/// to `en_US` so the expected strings (and time formats) are deterministic
/// regardless of the developer's machine.
final class ActivityPresentationTests: XCTestCase {
    /// A UTC calendar pinned to `en_US` so the expected strings (12-hour
    /// clock, no leading zero) are deterministic regardless of the
    /// developer's machine.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    override func setUp() {
        super.setUp()
        ActivityPresentation.localeForDisplay = Locale(identifier: "en_US")
    }

    override func tearDown() {
        ActivityPresentation.localeForDisplay = Locale.autoupdatingCurrent
        super.tearDown()
    }

    // MARK: - episodeSubtitle

    func testEpisodeSubtitleSpan() throws {
        let first = try date("2026-10-02T17:12:00Z")
        let last = try date("2026-10-02T17:14:00Z")
        let subtitle = ActivityPresentation.episodeSubtitle(
            count: 6, first: first, last: last, calendar: Self.utcCalendar
        )
        // en_US + UTC: 12-hour clock, no leading zero, en dash between times.
        XCTAssertEqual(subtitle, "6 events · 5:12–5:14 PM")
    }

    func testEpisodeSubtitleSingleEvent() throws {
        let ts = try date("2026-10-02T17:12:00Z")
        let subtitle = ActivityPresentation.episodeSubtitle(
            count: 1, first: ts, last: ts, calendar: Self.utcCalendar
        )
        XCTAssertEqual(subtitle, "1 event · at 5:12 PM")
    }

    func testEpisodeSubtitleTwoEvents() throws {
        let first = try date("2026-10-02T00:05:00Z")
        let last = try date("2026-10-02T00:06:00Z")
        let subtitle = ActivityPresentation.episodeSubtitle(
            count: 2, first: first, last: last, calendar: Self.utcCalendar
        )
        XCTAssertEqual(subtitle, "2 events · 12:05–12:06 AM")
    }

    // MARK: - episodeTitle

    func testEpisodeTitleUsesRulePlain() {
        XCTAssertEqual(
            ActivityPresentation.episodeTitle(rulePlain: "Do not read secret files"),
            "Do not read secret files"
        )
    }

    func testEpisodeTitleNilRulePlainFallsBack() {
        XCTAssertEqual(ActivityPresentation.episodeTitle(rulePlain: nil), "Unclassified event")
    }

    func testEpisodeTitleEmptyRulePlainFallsBack() {
        XCTAssertEqual(ActivityPresentation.episodeTitle(rulePlain: ""), "Unclassified event")
    }

    // MARK: - episodeHighlightOutcome (most severe present)

    func testEpisodeHighlightOutcomePicksMostSevere() {
        XCTAssertEqual(
            ActivityPresentation.episodeHighlightOutcome([.ok, .blocked, .ok]),
            .blocked
        )
        XCTAssertEqual(
            ActivityPresentation.episodeHighlightOutcome([.ok, .denied]),
            .denied
        )
        XCTAssertEqual(
            ActivityPresentation.episodeHighlightOutcome([.unknown, .error]),
            .error
        )
        // `denied` is the most severe outcome present, so it wins regardless
        // of order.
        XCTAssertEqual(
            ActivityPresentation.episodeHighlightOutcome([.error, .blocked, .denied]),
            .denied
        )
    }

    func testEpisodeHighlightOutcomeNoneWhenAllOk() {
        XCTAssertNil(ActivityPresentation.episodeHighlightOutcome([.ok, .approved, .unknown]))
        XCTAssertNil(ActivityPresentation.episodeHighlightOutcome([]))
    }

    // MARK: - showsRulePlain (event-row display selection)

    func testShowsRulePlainWhenBlockedWithRule() {
        XCTAssertTrue(ActivityPresentation.showsRulePlain(
            "Do not read secret files",
            outcome: .blocked,
            actionNeeded: ""
        ))
    }

    func testShowsRulePlainWhenDeniedWithRule() {
        XCTAssertTrue(ActivityPresentation.showsRulePlain(
            "No secret files",
            outcome: .denied,
            actionNeeded: ""
        ))
    }

    func testShowsRulePlainWhenActionNeededEvenIfOutcomeOk() {
        XCTAssertTrue(ActivityPresentation.showsRulePlain(
            "Check the path",
            outcome: .ok,
            actionNeeded: "Remove the .env path"
        ))
    }

    func testShowsRulePlainFalseForPlainOkEvent() {
        XCTAssertFalse(ActivityPresentation.showsRulePlain(
            "Some sentence",
            outcome: .ok,
            actionNeeded: ""
        ))
    }

    func testShowsRulePlainFalseWhenRulePlainNil() {
        XCTAssertFalse(ActivityPresentation.showsRulePlain(nil, outcome: .blocked, actionNeeded: ""))
    }

    func testShowsRulePlainFalseWhenRulePlainEmpty() {
        XCTAssertFalse(ActivityPresentation.showsRulePlain("", outcome: .blocked, actionNeeded: ""))
    }

    // MARK: - Helpers

    private func date(_ iso: String) throws -> Date {
        try AtlasActivityTimestampFormatter.decoder.decode(
            Date.self,
            from: Data("\"\(iso)\"".utf8)
        )
    }
}
