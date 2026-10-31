import XCTest
@testable import HermesMobile

final class MonthlyReviewModelTests: XCTestCase {
    /// A trimmed v2 monthly review as the vault's `build_monthly` writes it: one card of each kind.
    private static let deckJSON = """
    {"version": 2, "date": "2026-10-31", "kind": "monthly", "wrapped": true,
     "cards": [
      {"id": "cover", "type": "month_cover", "title": "Slow and steady", "range": "Oct 1–31",
       "month": {"name": "October", "totals": [{"value": 54, "label": "people"}, {"label": "no value"}]},
       "moments": [{"id": "m1", "day": "Oct 10", "line": "Longest run yet", "value": "body"}], "ended": "Tapered."},
      {"id": "weeks", "type": "month_weeks", "title": "Five weeks, one arc",
       "month": {"weeks": [{"number": 43, "range": "Oct 19–25", "title": "Warmth", "line": "Lunch with Meg."},
                           {"number": 44, "title": "Race week", "open": true}, {"title": "no number"}]}},
      {"id": "dots", "type": "month_dots", "title": "October in dots",
       "month": {"first_weekday": 4, "days_in_month": 31, "rows": [{"id": "prep", "label": "Prep", "days": [1, 2]}],
                 "pips": [{"id": "apps", "label": "Applications", "count": 11}]}},
      {"id": "proud", "type": "month_question", "title": "What made you proud", "color": "past",
       "question": "What are you proudest of?", "files_to": "Wins & Accomplishments",
       "month": {"tiles": [{"text": "20.1 mi", "label": "longest run", "day": "Oct 10"}, {"value": 11, "label": "applications"}],
                 "themes": [{"title": "Calm at the big moments", "line": "The shower."}],
                 "advisors": [{"name": "Brené Brown", "role": "courage", "text": "Let that count."}],
                 "snippets": [{"day": "Oct 18", "text": "I didn't panic.", "asked": null}],
                 "library": [{"text": "Slow and steady progress.", "source": "Kenji Yamada, Ikigai & Kaizen"}]}},
      {"id": "sleep", "type": "month_sleep", "color": "notes", "title": "Steadier sleep",
       "month": {"first_weekday": 4, "days_in_month": 31,
                 "sleep": {"score": 78, "delta": 1, "nights": [{"day": 2, "tier": "good"}, {"day": 4, "tier": "rough"}],
                           "hrv": [{"day": 10, "tier": "unbalanced"}],
                           "tiles": [{"label": "Slept", "value": "7h 42m", "note": "of 8h 10m needed"}],
                           "coach": {"name": "Mara Quinn", "text": "Guard the hour before bed."}}}},
      {"id": "value-body", "type": "value", "value": "body", "name": "Cared for my body", "color": "body",
       "month": {"week_scores": [null, null, null, 5, null], "themes": [{"title": "Pain without suffering"}]}},
      {"id": "close", "type": "close", "month": {"name": "October", "year": 2026,
       "months": [{"month": "Sep"}, {"month": "Oct", "title": "Slow and steady"}]}}
     ]}
    """

    private func deck() throws -> DailyDeck { try DailyDeck.decode(Self.deckJSON) }

    func testDecodesEveryMonthlyCardKind() throws {
        let deck = try deck()
        XCTAssertEqual(deck.cards.map(\.type),
                       [.monthCover, .monthWeeks, .monthDots, .monthQuestion, .monthSleep, .value, .close])
        XCTAssertTrue(deck.cards.allSatisfy { $0.month != nil })
    }

    func testDropsMalformedEntriesNotTheCard() throws {
        let cards = try deck().cards
        XCTAssertEqual(cards[0].month?.totals.map(\.value), [54])
        XCTAssertEqual(cards[1].month?.weeks.map(\.number), [43, 44])
        XCTAssertEqual(cards[1].month?.weeks.last?.open, true)
    }

    func testQuestionCarriesWhatLedToIt() throws {
        let month = try XCTUnwrap(deck().cards[3].month)
        XCTAssertEqual(month.tiles.first?.text, "20.1 mi")
        XCTAssertEqual(month.tiles.last?.value, 11)
        XCTAssertEqual(month.themes.map(\.title), ["Calm at the big moments"])
        XCTAssertEqual(month.advisors.first?.name, "Brené Brown")
        XCTAssertEqual(month.snippets.first?.text, "I didn't panic.")
        XCTAssertNil(month.snippets.first?.asked)
        XCTAssertEqual(month.library.first?.source, "Kenji Yamada, Ikigai & Kaizen")
    }

    func testSleepMonthDecodes() throws {
        let sleep = try XCTUnwrap(deck().cards[4].month?.sleep)
        XCTAssertEqual(sleep.score, 78)
        XCTAssertEqual(sleep.delta, 1)
        XCTAssertEqual(sleep.nights.map(\.tier), ["good", "rough"])
        XCTAssertEqual(sleep.hrv.first?.tier, "unbalanced")
        XCTAssertEqual(sleep.coach?.name, "Mara Quinn")
    }

    func testValueCardKeepsWeekScoresWithGaps() throws {
        XCTAssertEqual(try deck().cards[5].month?.weekScores, [nil, nil, nil, 5, nil])
    }

    func testMonthlyCardsWearTheirOwnPaperAndShowNoChapterLine() throws {
        let cards = try deck().cards
        XCTAssertEqual(DeckPalette.of(cards[0]).colors, .dusk)
        XCTAssertEqual(DeckPalette.of(cards[3]).colors, .past)
        XCTAssertEqual(DeckPalette.of(cards[4]).colors, .notes)
        XCTAssertEqual(DeckPalette.of(cards[5]).colors, .training, "an older deck naming the teal body paper reads as Body's cyan")
        XCTAssertEqual(DeckPalette.of(cards[6]).colors, .dusk)
        XCTAssertTrue(cards.allSatisfy { $0.chapterLabel == nil })
    }

    func testMonthlyReviewOpensOnTheMonthsLastDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 9))!
        }
        func refs(_ date: Date) -> [String] {
            DailyBriefReminder.reviews(on: date, calendar: calendar).map { "\($0.date).\($0.kind)" }
        }
        XCTAssertEqual(refs(day(2026, 10, 31)), ["2026-10-31.monthly"])
        XCTAssertEqual(refs(day(2026, 11, 1)), ["2026-11-01.weekly"])
        XCTAssertEqual(refs(day(2026, 11, 15)), ["2026-11-15.weekly"])
        XCTAssertEqual(refs(day(2026, 11, 20)), [])
        // A Sunday that ends the month opens both reviews.
        XCTAssertEqual(refs(day(2027, 1, 31)), ["2027-01-31.weekly", "2027-01-31.monthly"])
        XCTAssertEqual(refs(day(2028, 2, 29)), ["2028-02-29.monthly"])
    }
}
