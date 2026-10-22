import XCTest
import Foundation
@testable import HermesMobile

final class WeeklyReviewModelTests: XCTestCase {
    private static let v2DeckJSON = """
    {"version": 2, "date": "2026-10-25", "kind": "weekly", "wrapped": true, "generated_at": "2026-10-25T18:00:00-04:00",
     "future_top_level": {"x": 1},
     "cards": [
      {"id": "cover", "type": "cover", "week_number": 43, "range": "Oct 19–25", "title": "The week you tapered",
       "chapters": [{"id": "remember", "label": "Remember", "minutes": 2}, {"id": "steer", "label": "Steer", "minutes": 3}, {"label": "no id"}],
       "note_from_past": {"week_ending": "2025-10-26", "title": "A year ago", "text": "Be kind to October."}},
      {"id": "filmstrip", "type": "filmstrip", "chapter": "remember", "days": [
        {"label": "Mon", "line": "Easy run", "people": ["Jon Chan"], "sleep_hours": 7.5, "run": "5 mi"},
        {"label": "Tue", "line": "Rest", "people": []},
        {"label": "Wed", "line": "Deep work", "people": ["Ana"], "sleep_hours": 6.9},
        {"label": "Thu", "line": "Dinner", "people": []},
        {"label": "Fri", "line": "Long day", "people": []},
        {"label": "Sat", "line": "Hike", "people": ["Sam"], "run": "3 mi"},
        {"label": "Sun", "line": "Reset", "people": []}]},
      {"id": "story", "type": "story", "chapter": "remember", "draft": "You tapered and slept more."},
      {"id": "energy", "type": "energy", "chapter": "understand", "gave": ["Running", "Dinner with Jon"], "drained": ["Meetings"]},
      {"id": "deep", "type": "prompt", "chapter": "understand", "question": "What did you notice?", "rotation": "Examen", "files_to": "Reflection"},
      {"id": "commitments", "type": "commitments", "chapter": "account", "items": [
        {"id": "one-thing", "text": "Ship the deck", "carried": 1}, {"id": "who-jon-chan", "text": "See Jon Chan", "carried": 0}, {"text": "no id"}]},
      {"id": "values", "type": "values", "chapter": "account", "values": [
        {"id": "present", "name": "Present", "evidence": "Phone down at dinner."}, {"id": "people", "name": "People", "evidence": ""}]},
      {"id": "goals-career", "type": "item", "kind": "goals", "chapter": "account", "title": "Your goals", "meters": []},
      {"id": "predictions", "type": "predictions", "chapter": "account", "items": [
        {"id": "2026-10-04-p", "text": "Offer by November", "probability": 70, "due": "2026-10-25", "made_week": "2026-10-04"}]},
      {"id": "week-career", "type": "week_ahead", "chapter": "steer", "goal": "career"},
      {"id": "one-thing", "type": "prompt", "chapter": "steer", "question": "What's the one thing for this week?", "files_to": "Upcoming Week Planning"},
      {"id": "who", "type": "who", "chapter": "steer", "suggested": ["Jon Chan", "Ana"]},
      {"id": "keepsakes", "type": "keepsakes", "chapter": "steer"},
      {"id": "close", "type": "close", "title": "Seal the week"}
     ]}
    """

    func testV2DeckDecodesEveryCardKind() throws {
        let deck = try DailyDeck.decode(Self.v2DeckJSON)
        XCTAssertEqual(deck.version, 2)
        XCTAssertEqual(deck.cards.map(\.id), [
            "cover", "filmstrip", "story", "energy", "deep", "commitments", "values", "goals-career",
            "predictions", "week-career", "one-thing", "who", "keepsakes", "close",
        ])
        XCTAssertEqual(deck.cards.map(\.type), [
            .cover, .filmstrip, .story, .energy, .prompt, .commitments, .values, .item,
            .predictions, .weekAhead, .prompt, .who, .keepsakes, .close,
        ])

        let cover = deck.cards[0]
        XCTAssertEqual(cover.weekNumber, 43)
        XCTAssertEqual(cover.range, "Oct 19–25")
        XCTAssertEqual(cover.title, "The week you tapered")
        XCTAssertNil(cover.chapter, "the cover has no chapter")
        XCTAssertEqual(cover.chapters.map(\.id), ["remember", "steer"], "a chapter without an id is dropped alone")
        XCTAssertEqual(cover.chapters.map(\.minutes), [2, 3])
        XCTAssertEqual(cover.noteFromPast, DeckPastNote(weekEnding: "2025-10-26", title: "A year ago", text: "Be kind to October."))

        let filmstrip = deck.cards[1]
        XCTAssertEqual(filmstrip.chapter, "remember")
        XCTAssertEqual(filmstrip.days.count, 7)
        XCTAssertEqual(filmstrip.days[0], DeckDay(label: "Mon", line: "Easy run", people: ["Jon Chan"], sleepHours: 7.5, run: "5 mi"))
        XCTAssertEqual(filmstrip.days[1].people, [])
        XCTAssertNil(filmstrip.days[1].sleepHours)
        XCTAssertNil(filmstrip.days[1].run)

        XCTAssertEqual(deck.cards[2].storyDraft, "You tapered and slept more.")
        XCTAssertNil(deck.cards[2].draft, "the story's string is not a DeckDraft")
        XCTAssertEqual(deck.cards[3].gave, ["Running", "Dinner with Jon"])
        XCTAssertEqual(deck.cards[3].drained, ["Meetings"])
        XCTAssertEqual(deck.cards[4].rotation, "Examen")
        XCTAssertEqual(deck.cards[4].question, "What did you notice?")

        XCTAssertEqual(deck.cards[5].items.map(\.id), ["one-thing", "who-jon-chan"], "an item without an id is dropped alone")
        XCTAssertEqual(deck.cards[5].items.map(\.carried), [1, 0])
        XCTAssertEqual(deck.cards[6].values, [
            DeckValue(id: "present", name: "Present", evidence: "Phone down at dinner."),
            DeckValue(id: "people", name: "People", evidence: ""),
        ])
        XCTAssertEqual(deck.cards[8].items, [
            DeckReviewItem(id: "2026-10-04-p", text: "Offer by November", carried: nil, probability: 70,
                           due: "2026-10-25", madeWeek: "2026-10-04"),
        ])
        XCTAssertEqual(deck.cards[11].suggested, ["Jon Chan", "Ana"])
        XCTAssertEqual(deck.cards[7].chapter, "account")
        XCTAssertEqual(deck.cards[9].chapter, "steer")
        XCTAssertNil(deck.cards[13].chapter)
    }

    func testNewCardsTakeNoFeedbackAndReadTheirTitleOrDraft() throws {
        let deck = try DailyDeck.decode(Self.v2DeckJSON)
        for index in [0, 1, 2, 3, 5, 6, 8, 11, 12] {
            XCTAssertFalse(deck.cards[index].takesFeedback, deck.cards[index].id)
        }
        XCTAssertEqual(DeckCardText(deck.cards[0]).lead, "The week you tapered")
        XCTAssertEqual(DeckCardText(deck.cards[2]).lead, "You tapered and slept more.")
    }

    func testUnknownV2FieldsAndTypesStillDecode() throws {
        let deck = try DailyDeck.decode(#"""
        {"version": 3, "date": "2026-10-25", "kind": "weekly", "extra": true, "cards": [
          {"id": "cover", "type": "cover", "week_number": 43, "brand_new": [1, 2], "chapters": "not a list"},
          {"id": "later", "type": "future_card", "chapter": "steer", "gadgets": [{"a": 1}]},
          {"id": "story", "type": "story", "draft": "", "days": 7, "items": {"x": 1}},
          {"id": "close", "type": "close"}
        ]}
        """#)
        XCTAssertEqual(deck.cards.map(\.id), ["cover", "later", "story", "close"])
        XCTAssertEqual(deck.cards[1].type, .unknown("future_card"))
        XCTAssertEqual(deck.cards[0].chapters, [], "a mistyped field is empty, not fatal")
        XCTAssertEqual(deck.cards[2].items, [])
        XCTAssertEqual(deck.cards[2].days, [])
        XCTAssertEqual(deck.cards[2].storyDraft, "")
    }

    func testV1WeeklyDeckStillDecodes() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"2026-10-18","kind":"weekly","cards":[
          {"id":"headline","type":"headline","title":"Your week","lines":["Weekly review"],"recap":"You tapered."},
          {"id":"mood","type":"item","kind":"mood","title":"Energy and mood","points":[{"label":"Tue","energy":8,"mood":7}]},
          {"id":"week-career","type":"week_ahead","goal":"career","start":"2026-10-19","commitments":[{"id":"outreach","action":"Outreach","target":6,"skips":0,"unit":"item"}]},
          {"id":"changes","type":"changes","title":"What changed","rows":[]},
          {"id":"close","type":"close"}
        ]}
        """#)
        XCTAssertEqual(deck.cards.map(\.type), [.headline, .item, .weekAhead, .changes, .close])
        XCTAssertNil(deck.version)
        let card = deck.cards[2]
        XCTAssertEqual(card.weekCommitments.map(\.id), ["outreach"])
        XCTAssertNil(card.chapter)
        XCTAssertNil(card.weekNumber)
        XCTAssertEqual(card.items, [])
        XCTAssertEqual(card.values, [])
        XCTAssertEqual(card.days, [])
        XCTAssertNil(card.noteFromPast)
    }

    func testAnswerEncodesOnlySetFields() throws {
        var answer = DeckAnswer(card: "values")
        answer.scores = ["present": 7, "people": 9]
        let json = try Self.encode(answer)
        XCTAssertEqual(json["scores"] as? [String: Int], ["present": 7, "people": 9])
        for key in ["notes", "lists", "statuses", "prediction", "text"] {
            XCTAssertNil(json[key], key)
        }
        XCTAssertTrue(answer.isAnswer(for: Self.card("values")))

        var keepsake = DeckAnswer(card: "keepsakes")
        keepsake.prediction = DeckPrediction(text: "Offer", probability: 70, due: "2026-11-30")
        let prediction = try XCTUnwrap(try Self.encode(keepsake)["prediction"] as? [String: Any])
        XCTAssertEqual(prediction["text"] as? String, "Offer")
        XCTAssertEqual(prediction["probability"] as? Int, 70)
        XCTAssertEqual(prediction["due"] as? String, "2026-11-30")
    }

    func testAnswerIsAnAnswerWhenAnyNewFieldIsNonEmpty() {
        let card = Self.card("commitments")
        XCTAssertFalse(DeckAnswer(card: "commitments").isAnswer(for: card))
        var empty = DeckAnswer(card: "commitments")
        empty.scores = [:]
        empty.notes = [:]
        empty.lists = ["gave": []]
        empty.statuses = [:]
        XCTAssertFalse(empty.isAnswer(for: card))
        XCTAssertTrue(empty.isEmpty)

        var statuses = DeckAnswer(card: "commitments")
        statuses.statuses = ["one-thing": "kept"]
        XCTAssertTrue(statuses.isAnswer(for: card))
        XCTAssertFalse(statuses.isEmpty)

        var notes = DeckAnswer(card: "values")
        notes.notes = ["present": "Quiet dinner."]
        XCTAssertTrue(notes.isAnswer(for: card))

        var lists = DeckAnswer(card: "energy")
        lists.lists = ["gave": ["Running"], "drained": []]
        XCTAssertTrue(lists.isAnswer(for: card))

        var prediction = DeckAnswer(card: "keepsakes")
        prediction.prediction = DeckPrediction(text: "Offer", probability: 70, due: "2026-11-30")
        XCTAssertTrue(prediction.isAnswer(for: card))
    }

    func testAnswersPayloadKeepsAScoresOnlyAnswer() throws {
        let deck = try DailyDeck.decode(Self.v2DeckJSON)
        var answer = DeckAnswer(card: "values")
        answer.scores = ["present": 7]
        let payload = DeckAnswersPayload(deck: deck, answers: ["values": answer], completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(payload.answers.map(\.card), ["values"])
        XCTAssertEqual(payload.version, 1)
    }

    func testTopAndBottomValues() {
        let order = WeeklyValues.order
        XCTAssertEqual(order, ["present", "people", "dad", "potential", "body"])
        let scores = ["present": 6, "people": 9, "dad": 7, "potential": 3, "body": 5]
        XCTAssertEqual(WeeklyValues.topAndBottom(scores, order: order), ["people", "potential"])
        // A tie goes to the earlier value in fixed order, at both ends.
        let ties = ["present": 4, "people": 9, "dad": 9, "potential": 4, "body": 6]
        XCTAssertEqual(WeeklyValues.topAndBottom(ties, order: order), ["people", "present"])
        let equal = Dictionary(uniqueKeysWithValues: order.map { ($0, 5) })
        XCTAssertEqual(WeeklyValues.topAndBottom(equal, order: order), ["present"])
        XCTAssertEqual(WeeklyValues.topAndBottom(["dad": 8], order: order), ["dad"])
        XCTAssertEqual(WeeklyValues.topAndBottom([:], order: order), [])
        XCTAssertEqual(WeeklyValues.topAndBottom(["unlisted": 9, "body": 2], order: order), ["body"], "scores for values outside the order are ignored")
    }

    func testWeekRecordDecodesMinimalBackfill() throws {
        let record = try WeekRecord.decode(Data(#"""
        {"version": 1, "week_ending": "2025-07-06", "week_number": 27, "title": "Week 27", "story": "A quiet week.",
         "photo": null, "energy": {"gave": [], "drained": []}, "deep": null, "commitments": [], "values": [],
         "one_thing": null, "who": [], "note": null, "prediction": null, "graded": []}
        """#.utf8))
        XCTAssertEqual(record.weekEnding, "2025-07-06")
        XCTAssertEqual(record.weekNumber, 27)
        XCTAssertEqual(record.title, "Week 27")
        XCTAssertEqual(record.story, "A quiet week.")
        XCTAssertNil(record.photo)
        XCTAssertNil(record.deep)
        XCTAssertNil(record.oneThing)
        XCTAssertNil(record.note)
        XCTAssertNil(record.prediction)
        XCTAssertEqual(record.energy.gave, [])
        XCTAssertEqual(record.commitments, [])
        XCTAssertEqual(record.values, [])
        XCTAssertEqual(record.who, [])
        XCTAssertEqual(record.graded, [])

        let bare = try WeekRecord.decode(Data(#"{"week_ending": "2025-07-13"}"#.utf8))
        XCTAssertEqual(bare.weekEnding, "2025-07-13")
        XCTAssertNil(bare.title)
        XCTAssertEqual(bare.graded, [])
        XCTAssertThrowsError(try WeekRecord.decode(Data(#"{"title": "No date"}"#.utf8)))
    }

    func testWeekRecordDecodesAFullRecord() throws {
        let record = try WeekRecord.decode(Data(#"""
        {"version": 1, "week_ending": "2026-10-25", "week_number": 43, "title": "The week you tapered", "story": "Slept more.",
         "photo": "weekly-checkins/photos/2026-10-25.jpg", "unknown_key": 1,
         "energy": {"gave": ["Running"], "drained": ["Meetings"]},
         "deep": {"rotation": "Examen", "question": "What did you notice?", "answer": "That I rushed."},
         "commitments": [{"id": "one-thing", "text": "Ship the deck", "status": "kept", "carried": 0}, {"text": "no id"}],
         "values": [{"id": "present", "name": "Present", "score": 7, "evidence": "Phone down."},
                    {"id": "people", "name": "People", "score": null, "evidence": null}],
         "one_thing": {"text": "Send three asks", "carried": 2}, "who": [{"name": "Jon Chan", "carried": 2}],
         "note": {"text": "Be kind.", "opens_on": "2027-10-24"},
         "prediction": {"id": "2026-10-25-p", "text": "Offer", "probability": 70, "due": "2026-11-30"},
         "graded": [{"id": "2026-10-04-p", "made_week": "2026-10-04", "grade": "hit", "text": "Offer", "note": "Early."},
                    {"id": "x-p", "made_week": "2026-09-27", "grade": "miss", "text": "Other"}]}
        """#.utf8))
        XCTAssertEqual(record.photo, "weekly-checkins/photos/2026-10-25.jpg")
        XCTAssertEqual(record.energy.drained, ["Meetings"])
        XCTAssertEqual(record.deep?.answer, "That I rushed.")
        XCTAssertEqual(record.commitments.map(\.id), ["one-thing"])
        XCTAssertEqual(record.commitments.first?.status, "kept")
        XCTAssertEqual(record.values.map(\.score), [7, nil])
        XCTAssertNil(record.values[1].evidence)
        XCTAssertEqual(record.oneThing?.text, "Send three asks")
        XCTAssertEqual(record.oneThing?.carried, 2)
        XCTAssertEqual(record.who, [WeekRecord.Who(name: "Jon Chan", carried: 2)])
        XCTAssertEqual(record.note?.opensOn, "2027-10-24")
        XCTAssertEqual(record.prediction?.probability, 70)
        XCTAssertEqual(record.graded.map(\.grade), ["hit", "miss"])
        XCTAssertEqual(record.graded.map(\.madeWeek), ["2026-10-04", "2026-09-27"])
        XCTAssertEqual(record.graded.map(\.note), ["Early.", nil])
    }

    // MARK: - Helpers

    private static func card(_ id: String) -> DeckCard {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(DeckCard.self, from: Data(#"{"id":"\#(id)","type":"close"}"#.utf8))
    }

    private static func encode(_ answer: DeckAnswer) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(answer)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
