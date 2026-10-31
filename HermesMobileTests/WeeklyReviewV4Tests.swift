import XCTest
@testable import HermesMobile

final class WeeklyReviewV4Tests: XCTestCase {
    /// A trimmed v4 weekly review as the vault's `build_weekly` writes it: one card of each weekly kind.
    private static let deckJSON = """
    {"version": 4, "date": "2026-11-01", "kind": "weekly", "wrapped": true,
     "cards": [
      {"id": "cover", "type": "month_cover", "title": "Bib in hand", "range": "Oct 26 – Nov 1", "color": "dusk",
       "note_from_past": {"week_ending": "2025-11-02", "text": "Hi from last year."},
       "month": {"name": "Week 44", "totals": [],
                 "day_lines": [{"day": "Mon", "line": "Warm while tired", "value": "present"}, {"line": "no day"}]}},
      {"id": "held", "type": "week_held", "color": "notes",
       "month": {"held": {"intention": "Get my sleep in a good place", "reasons": ["Tired", "Late screens"]},
                 "tiles": [{"text": "4 of 5", "label": "nights over 7 h"}]}},
      {"id": "numbers", "type": "month_sleep", "title": "Your week in numbers", "color": "notes",
       "month": {"days_in_month": 7, "first_weekday": 0, "labels": ["M", "T", "W", "T", "F", "S", "S"],
                 "rows": [{"id": "prep", "label": "Prep", "days": [1, 3]}],
                 "pips": [{"id": "apps", "label": "Applications", "count": 4}],
                 "sleep": {"score": 82, "delta": 5, "nights": [], "hrv": [], "tiles": []}}},
      {"id": "value-dad", "type": "value", "value": "dad", "name": "Becoming a dad", "color": "advisor",
       "month": {"scored": true, "input_first": true, "stat": {"value": 6, "label": "letters to her this week"},
                 "days": [1, 2, 3, 4, 5, 6], "days_in_month": 7}},
      {"id": "proud", "type": "month_question", "question": "What are you proudest of?", "color": "past",
       "month": {"input_first": true}},
      {"id": "plan", "type": "week_plan", "color": "dusk",
       "month": {"proposal": {"intention": "One story a day", "obstacle": "Tired", "if_then": "If wiped, one story"}}},
      {"id": "keepsakes", "type": "week_letter", "range": "Nov 1, 2027", "color": "dusk",
       "month": {"themes": [{"title": "The night before the race", "line": "At peace."}]}},
      {"id": "close", "type": "close", "color": "dusk", "month": {"name": "Week 44", "year": 2026,
       "months": [{"month": "Jan"}, {"month": "", "title": "Bib in hand"}]}}
     ]}
    """

    private func deck() throws -> DailyDeck { try DailyDeck.decode(Self.deckJSON) }

    func testDecodesEveryWeeklyCardKind() throws {
        XCTAssertEqual(try deck().cards.map(\.type),
                       [.monthCover, .weekHeld, .monthSleep, .value, .monthQuestion, .weekPlan, .weekLetter, .close])
    }

    func testCoverCarriesDaysToStarAndLastYearsLetter() throws {
        let cover = try deck().cards[0]
        XCTAssertEqual(cover.month?.dayLines.map(\.day), ["Mon"])
        XCTAssertEqual(cover.month?.dayLines.first?.value, "present")
        XCTAssertEqual(cover.noteFromPast?.text, "Hi from last year.")
    }

    func testHeldPlanAndLetterDecode() throws {
        let cards = try deck().cards
        XCTAssertEqual(cards[1].month?.held?.intention, "Get my sleep in a good place")
        XCTAssertEqual(cards[1].month?.held?.reasons, ["Tired", "Late screens"])
        XCTAssertEqual(cards[5].month?.proposal?.ifThen, "If wiped, one story")
        XCTAssertEqual(cards[6].range, "Nov 1, 2027")
        XCTAssertEqual(cards[6].month?.themes.first?.title, "The night before the race")
    }

    func testWeekScaleNumbersAndInputFirstCards() throws {
        let cards = try deck().cards
        XCTAssertEqual(cards[2].month?.daysInMonth, 7)
        XCTAssertEqual(cards[2].month?.labels.count, 7)
        XCTAssertEqual(cards[2].month?.pips.first?.count, 4)
        XCTAssertEqual(cards[3].month?.scored, true)
        XCTAssertEqual(cards[3].month?.inputFirst, true)
        XCTAssertEqual(cards[3].month?.stat?.value, 6)
        XCTAssertEqual(cards[4].month?.inputFirst, true)
    }

    func testWeeklyCardsWearTheirPapersAndShowNoChapterLine() throws {
        let cards = try deck().cards
        XCTAssertEqual(DeckPalette.of(cards[1]).colors, .notes)
        XCTAssertEqual(DeckPalette.of(cards[3]).colors, .advisor)
        XCTAssertEqual(DeckPalette.of(cards[5]).colors, .dusk)
        XCTAssertEqual(DeckPalette.of(cards[6]).colors, .dusk)
        XCTAssertTrue(cards.allSatisfy { $0.chapterLabel == nil })
    }
}
