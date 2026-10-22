import XCTest
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
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
        {"id": "one-thing", "text": "Ship the deck", "carried": 1}, {"id": "who-jon-chan", "text": "Jon Chan", "carried": 0}, {"text": "no id"}]},
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
        empty.lists = [:]
        empty.statuses = [:]
        XCTAssertFalse(empty.isAnswer(for: card))
        XCTAssertTrue(empty.isEmpty)

        var emptied = DeckAnswer(card: "energy")
        emptied.lists = ["gave": []]
        XCTAssertTrue(emptied.isAnswer(for: card), "an emptied list says none, so it answers")
        XCTAssertFalse(emptied.isEmpty)

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

    // MARK: - Answering (view model)

    @MainActor
    func testSetScoreAndNoteStoreOnTheValuesAnswer() async throws {
        let viewModel = try await weeklyViewModel()
        let values = try card("values", in: viewModel)
        viewModel.setScore("present", 7, for: values)
        viewModel.setScore("people", 9, for: values)
        viewModel.setNote("present", "Phone down at dinner, twice.", for: values)
        let answer = try XCTUnwrap(viewModel.answer(for: values))
        XCTAssertEqual(answer.scores, ["present": 7, "people": 9])
        XCTAssertEqual(answer.notes, ["present": "Phone down at dinner, twice."])
        XCTAssertNil(answer.text)

        viewModel.setScore("people", 9, for: values)
        XCTAssertEqual(viewModel.answer(for: values)?.scores, ["present": 7], "tapping the chosen score again clears it")
        viewModel.setScore("present", 11, for: values)
        viewModel.setScore("present", 0, for: values)
        XCTAssertEqual(viewModel.answer(for: values)?.scores, ["present": 7], "scores outside 1–10 are ignored")
        viewModel.setScore("present", 4, for: values)
        XCTAssertEqual(viewModel.answer(for: values)?.scores, ["present": 4])

        // Clearing a line goes back to Atlas's evidence, which is what the vault files.
        viewModel.setNote("present", "  ", for: values)
        XCTAssertNil(viewModel.answer(for: values)?.notes, "an emptied note is no note")

        // A prediction's grade and note sit under its id on the predictions answer.
        let predictions = try card("predictions", in: viewModel)
        viewModel.setStatus("2026-10-04-p", "hit", for: predictions)
        viewModel.setNote("2026-10-04-p", "Came early.", for: predictions)
        XCTAssertEqual(viewModel.answer(for: predictions)?.statuses, ["2026-10-04-p": "hit"])
        XCTAssertEqual(viewModel.answer(for: predictions)?.notes, ["2026-10-04-p": "Came early."])
    }

    @MainActor
    func testStatusCycleClearsAtNone() async throws {
        var status: String?
        var cycle: [String?] = []
        for _ in 0..<4 {
            status = CommitmentStatus.next(after: status)
            cycle.append(status)
        }
        XCTAssertEqual(cycle, ["kept", "missed", "dropped", nil])
        XCTAssertEqual(CommitmentStatus.next(after: "someday"), "kept", "an unknown status starts the cycle over")

        let viewModel = try await weeklyViewModel()
        let commitments = try card("commitments", in: viewModel)
        viewModel.setStatus("one-thing", "kept", for: commitments)
        viewModel.setStatus("who-jon-chan", "missed", for: commitments)
        XCTAssertEqual(viewModel.answer(for: commitments)?.statuses, ["one-thing": "kept", "who-jon-chan": "missed"])
        viewModel.setStatus("one-thing", nil, for: commitments)
        XCTAssertEqual(viewModel.answer(for: commitments)?.statuses, ["who-jon-chan": "missed"])
        viewModel.setStatus("who-jon-chan", nil, for: commitments)
        XCTAssertNil(viewModel.answer(for: commitments), "no statuses left leaves no answer")
    }

    @MainActor
    func testMissedCommitmentsFollowCurrentStatuses() async throws {
        let viewModel = try await weeklyViewModel()
        let commitments = try card("commitments", in: viewModel)
        XCTAssertEqual(viewModel.missedCommitments, [])
        viewModel.setStatus("one-thing", "missed", for: commitments)
        viewModel.setStatus("who-jon-chan", "kept", for: commitments)
        XCTAssertEqual(viewModel.missedCommitments.map(\.id), ["one-thing"])
        viewModel.setStatus("who-jon-chan", "missed", for: commitments)
        XCTAssertEqual(viewModel.missedCommitments.map(\.id), ["one-thing", "who-jon-chan"], "in the card's order")
        viewModel.setStatus("one-thing", "dropped", for: commitments)
        XCTAssertEqual(viewModel.missedCommitments.map(\.text), ["Jon Chan"])
    }

    @MainActor
    func testPredictionClearsWhenTextEmpty() async throws {
        let viewModel = try await weeklyViewModel()
        let keepsakes = try card("keepsakes", in: viewModel)
        let offer = DeckPrediction(text: "Offer by November", probability: 60, due: "2026-11-22")
        viewModel.setPrediction(offer, for: keepsakes)
        XCTAssertEqual(viewModel.answer(for: keepsakes)?.prediction, offer)

        viewModel.setPrediction(DeckPrediction(text: "  \n ", probability: 60, due: "2026-11-22"), for: keepsakes)
        XCTAssertNil(viewModel.answer(for: keepsakes), "a prediction without words is no prediction")

        viewModel.setText("Be kind to October.", for: keepsakes)
        viewModel.setPrediction(offer, for: keepsakes)
        viewModel.setPrediction(nil, for: keepsakes)
        XCTAssertNil(viewModel.answer(for: keepsakes)?.prediction)
        XCTAssertEqual(viewModel.answer(for: keepsakes)?.text, "Be kind to October.", "the note stays")

        XCTAssertEqual(DeckPrediction.defaultDue(deckDate: "2026-10-25"), "2026-11-22", "four weeks after the deck")
        XCTAssertEqual(DeckPrediction.defaultProbability, 70)
    }

    @MainActor
    func testPayloadCarriesV2AnswersInSnakeCase() async throws {
        let viewModel = try await weeklyViewModel()
        let deck = try XCTUnwrap(viewModel.deck)
        viewModel.setScore("present", 7, for: try card("values", in: viewModel))
        viewModel.setList("gave", ["Running"], for: try card("energy", in: viewModel))
        viewModel.setList("drained", [], for: try card("energy", in: viewModel))
        viewModel.setStatus("who-jon-chan", "missed", for: try card("commitments", in: viewModel))
        viewModel.setList("who", ["Ana"], for: try card("who", in: viewModel))
        viewModel.setPrediction(DeckPrediction(text: "Offer", probability: 70, due: "2026-11-22"),
                                for: try card("keepsakes", in: viewModel))

        let payload = DeckAnswersPayload(deck: deck, answers: viewModel.answers, completedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(payload)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNotNil(json["completed_at"])
        let answers = try XCTUnwrap(json["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.compactMap { $0["card"] as? String }, ["energy", "commitments", "values", "who", "keepsakes"])
        let byCard = Dictionary(uniqueKeysWithValues: answers.map { ($0["card"] as? String ?? "", $0) })
        XCTAssertEqual(byCard["values"]?["scores"] as? [String: Int], ["present": 7])
        XCTAssertEqual(byCard["energy"]?["lists"] as? [String: [String]], ["gave": ["Running"], "drained": []],
                       "an emptied list is sent, so the filer doesn't fall back to the drafted chips")
        XCTAssertEqual(byCard["commitments"]?["statuses"] as? [String: String], ["who-jon-chan": "missed"])
        XCTAssertEqual(byCard["who"]?["lists"] as? [String: [String]], ["who": ["Ana"]])
        XCTAssertEqual((byCard["keepsakes"]?["prediction"] as? [String: Any])?["probability"] as? Int, 70)
        for answer in answers {
            XCTAssertNil(answer["text"], "no text key on answers without text")
        }
    }

    @MainActor
    func testRemovingEveryEnergyChipKeepsTheEmptyLists() async throws {
        let viewModel = try await weeklyViewModel()
        let energy = try card("energy", in: viewModel)
        XCTAssertEqual(viewModel.list("gave", for: energy, drafted: energy.gave), ["Running", "Dinner with Jon"])
        viewModel.setList("gave", [], for: energy)
        viewModel.setList("drained", [], for: energy)
        XCTAssertEqual(viewModel.answer(for: energy)?.lists, ["gave": [], "drained": []])
        XCTAssertEqual(viewModel.list("gave", for: energy, drafted: energy.gave), [], "the card shows no chips")
        XCTAssertEqual(viewModel.list("drained", for: energy, drafted: energy.drained), [])

        let payload = DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: viewModel.answers,
                                         completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(payload.answers.first { $0.card == "energy" }?.lists, ["gave": [], "drained": []],
                       "filed as none, so the vault doesn't fall back to the drafted chips")
    }

    func testCarryChipsNeverOverwriteTypedWords() {
        let missed = [DeckReviewItem(id: "one-thing", text: "Ship the deck"), DeckReviewItem(id: "who-ana", text: "Ana")]
        XCTAssertTrue(WeekCarryChips.offers(missed, current: ""))
        XCTAssertTrue(WeekCarryChips.offers(missed, current: "Ana"), "a carried one stays, to switch or untap")
        XCTAssertFalse(WeekCarryChips.offers(missed, current: "Write the essay"))
        XCTAssertFalse(WeekCarryChips.offers([], current: ""))
    }

    func testCarryChipsLeavePeopleToTheWhoCard() {
        let missed = [DeckReviewItem(id: "one-thing", text: "Ship the deck"), DeckReviewItem(id: "who-ana", text: "Ana"),
                      DeckReviewItem(id: "plan-1", text: "Sleep by 11")]
        XCTAssertEqual(WeekCarryChips.carryable(missed).map(\.id), ["one-thing", "plan-1"],
                       "a missed person carries on the who card, not into the one thing")
        XCTAssertEqual(WeekCarryChips.carryable([DeckReviewItem(id: "who-ana", text: "Ana")]), [])
    }

    func testAddingAPersonDedupesByCase() {
        let suggested = ["Ana Ruiz", "Priya"]
        XCTAssertEqual(WeekWhoCard.adding("ana ruiz", to: [], suggested: suggested), ["Ana Ruiz"], "picks the suggestion")
        XCTAssertEqual(WeekWhoCard.adding("ANA RUIZ", to: ["Ana Ruiz"], suggested: suggested), ["Ana Ruiz"])
        XCTAssertEqual(WeekWhoCard.adding("Bea", to: ["Priya"], suggested: suggested), ["Priya", "Bea"])
        XCTAssertEqual(WeekWhoCard.adding("bea", to: ["Priya", "Bea"], suggested: suggested), ["Priya", "Bea"])
    }

    func testChapterLabelNumbersTheChapters() throws {
        let deck = try DailyDeck.decode(Self.v2DeckJSON)
        let labels = Dictionary(uniqueKeysWithValues: deck.cards.map { ($0.id, $0.chapterLabel) })
        XCTAssertEqual(labels["filmstrip"], "1 · Remember")
        XCTAssertEqual(labels["deep"], "2 · Understand")
        XCTAssertEqual(labels["values"], "3 · Account")
        XCTAssertEqual(labels["who"], "4 · Steer")
        XCTAssertNil(deck.cards[0].chapterLabel, "the cover has no chapter")
        XCTAssertNil(deck.cards[13].chapterLabel, "nor the close")
    }

    func testCoverExposesTheWeeksQuestionRecapAndTheTakeWearsItsChapter() throws {
        let deck = try DailyDeck.decode(#"""
        {"version":2,"date":"2026-11-01","kind":"weekly","cards":[
          {"id":"cover","type":"cover","title":"The week you tapered","recap":"This week was about: Is the model the product?"},
          {"id":"view-take","type":"decision","kind":"view_take","chapter":"understand","title":"Is the model the product?"},
          {"id":"view-steer","type":"prompt","chapter":"steer","question":"Keep it?","files_to":"steer"},
          {"id":"f1","type":"decision","title":"Sam"}]}
        """#)
        XCTAssertEqual(deck.cards[0].recap, "This week was about: Is the model the product?")
        XCTAssertEqual(deck.cards[1].chapterLabel, "2 · Understand", "the take closes the Understand chapter")
        XCTAssertEqual(deck.cards[2].chapterLabel, "4 · Steer")
        XCTAssertNil(deck.cards[3].chapterLabel, "a plain follow-up has no chapter line")
        let bare = try DailyDeck.decode(#"{"version":2,"date":"d","kind":"weekly","cards":[{"id":"cover","type":"cover"}]}"#)
        XCTAssertNil(bare.cards[0].recap, "a week without a question has no recap")
    }

    // MARK: - Seal

    @MainActor
    func testV2WeeklyFilesThroughBriefFileWithV2Answers() async throws {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.weekly.json"], deck: Self.v2DeckJSON)
        client.filer = .success(BriefFileResponse(ok: true, summary: "Sealed."))
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store)
        await viewModel.show(date: "2026-10-25", kind: "weekly")
        XCTAssertTrue(viewModel.isV2Weekly)

        viewModel.setScore("present", 7, for: try card("values", in: viewModel))
        viewModel.setList("gave", ["Running"], for: try card("energy", in: viewModel))
        _ = await viewModel.file()

        let request = try XCTUnwrap(client.fileRequests.first)
        XCTAssertEqual(client.fileRequests.count, 1)
        XCTAssertEqual(request.kind, "weekly")
        XCTAssertEqual(request.date, "2026-10-25")
        let byCard = Dictionary(uniqueKeysWithValues: request.answers.answers.map { ($0.card, $0) })
        XCTAssertEqual(byCard["values"]?.scores, ["present": 7])
        XCTAssertEqual(byCard["energy"]?.lists, ["gave": ["Running"]])
    }

    @MainActor
    func testAV2WeekIsSealedOnlyWhenItsRecordExists() async throws {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.weekly.json", "2026-10-25.weekly.answers.json"],
                                             deck: Self.v2DeckJSON)
        client.files["briefs/2026-10-25.weekly.answers.json"] = """
        {"version": 1, "date": "2026-10-25", "kind": "weekly", "completed_at": "x",
         "answers": [{"card": "story", "text": "You raced."}]}
        """
        // The server saved the answers, then its filer failed: no record.
        let failed = DailyDeckViewModel(server: server, client: client, store: store)
        await failed.show(date: "2026-10-25", kind: "weekly")
        XCTAssertEqual(failed.answer(for: try card("story", in: failed))?.text, "You raced.", "the answers come back to seal again")
        XCTAssertFalse(failed.isFiled, "answers alone don't make a sealed week")
        XCTAssertTrue(failed.hasChanges, "so Seal the week stays enabled")

        client.filer = .success(BriefFileResponse(ok: true, summary: "Sealed week 43."))
        _ = await failed.file()
        XCTAssertTrue(failed.isFiled, "the server confirmed the seal")
        XCTAssertFalse(failed.hasChanges)

        client.listings = ["weekly-checkins": ["2026-10-25-week-ending.json", "2026-10-25-week-ending.md"]]
        let sealed = DailyDeckViewModel(server: server, client: client, store: store)
        await sealed.show(date: "2026-10-25", kind: "weekly")
        XCTAssertTrue(sealed.isFiled)
        XCTAssertFalse(sealed.hasChanges)
    }

    @MainActor
    func testOnlyAV2WeeklyDeckIsV2Weekly() async throws {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let v1 = #"{"date":"2026-10-18","kind":"weekly","cards":[{"id":"close","type":"close"}]}"#
        let v1Client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-18.weekly.json"], deck: v1)
        let v1Model = DailyDeckViewModel(server: server, client: v1Client, store: store)
        await v1Model.show(date: "2026-10-18", kind: "weekly")
        XCTAssertEqual(v1Model.state, .ready)
        XCTAssertFalse(v1Model.isV2Weekly, "a v1 weekly keeps its filing copy")

        let morning = #"{"version":2,"date":"2026-10-25","kind":"morning","cards":[{"id":"close","type":"close"}]}"#
        let morningClient = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.morning.json"], deck: morning)
        let morningModel = DailyDeckViewModel(server: server, client: morningClient, store: store)
        await morningModel.show(date: "2026-10-25", kind: "morning")
        XCTAssertEqual(morningModel.state, .ready)
        XCTAssertFalse(morningModel.isV2Weekly)
    }

    // MARK: - Close card and prompt copy

    func testAV2WeeklyClosesOnTheWeeksPaper() throws {
        let close = DeckPage.card(Self.card("close"))
        XCTAssertEqual(DeckPalette.of(close, inV2Weekly: true), .week)
        XCTAssertEqual(DeckPalette.of(close, inV2Weekly: false), .quote, "v1 weekly and morning closes keep their paper")
        let story = DeckPage.card(try XCTUnwrap(try DailyDeck.decode(Self.v2DeckJSON).cards.first { $0.id == "story" }))
        XCTAssertEqual(DeckPalette.of(story, inV2Weekly: true), DeckPalette.of(story))
    }

    func testCloseHeadingSealsAV2WeekAndCountsReflectionsOtherwise() {
        XCTAssertEqual(DeckCopy.closeHeading(seal: true, filed: false, count: 6), "Seal the week")
        XCTAssertEqual(DeckCopy.closeHeading(seal: true, filed: true, count: 6), "Sealed")
        XCTAssertEqual(DeckCopy.closeHeading(seal: false, filed: false, count: 6), "6 reflections")
        XCTAssertEqual(DeckCopy.closeHeading(seal: false, filed: false, count: 1), "1 reflection")
        XCTAssertEqual(DeckCopy.closeHeading(seal: false, filed: true, count: 6), "Filed")
        XCTAssertEqual(DeckCopy.answered(1), "1 card answered")
        XCTAssertEqual(DeckCopy.answered(0), "0 cards answered")
        XCTAssertEqual(DeckCopy.answered(7), "7 cards answered")
        XCTAssertEqual(DeckCopy.filedStatus(seal: true, edited: false), "Sealed")
        XCTAssertEqual(DeckCopy.filedStatus(seal: false, edited: false), "Filed")
        XCTAssertEqual(DeckCopy.filedStatus(seal: true, edited: true), "Edited")
    }

    func testTheOneThingAsksForTheOneThing() throws {
        let cards = try DailyDeck.decode(Self.v2DeckJSON).cards
        XCTAssertEqual(DeckCopy.invitation(for: try XCTUnwrap(cards.first { $0.id == "one-thing" })), "Write the one thing")
        XCTAssertEqual(DeckCopy.invitation(for: try XCTUnwrap(cards.first { $0.id == "deep" })), "Write a reflection")
    }

    // MARK: - Photo of the week

    func testJPEGDownscalesToLongEdge() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f }())
        let png = renderer.pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let jpeg = try XCTUnwrap(WeekPhoto.jpeg(from: png))
        XCTAssertEqual(Array(jpeg.prefix(3)), [0xFF, 0xD8, 0xFF], "the server insists on JPEG magic")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1600)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1200)
        XCTAssertNil(WeekPhoto.jpeg(from: Data("not an image".utf8)))
    }

    @MainActor
    func testSetWeekPhotoUploadsForTheDeckDateAndBumpsTheVersion() async throws {
        let (viewModel, client) = try await weeklyViewModelAndClient()
        XCTAssertEqual(viewModel.weekPhotoPath, "weekly-checkins/photos/2026-10-25.jpg")
        XCTAssertEqual(viewModel.weekPhotoVersion, 0)
        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertEqual(client.uploadedPhotos.map(\.weekEnding), ["2026-10-25"])
        XCTAssertEqual(client.uploadedPhotos.first?.jpeg, Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertEqual(viewModel.weekPhotoVersion, 1)
        XCTAssertNil(viewModel.weekPhotoError)
        XCTAssertFalse(viewModel.isUploadingWeekPhoto)
    }

    @MainActor
    func testUploadDropsTheCachedPhotoSoAReopenedCoverReadsTheNewOne() async throws {
        let (viewModel, _) = try await weeklyViewModelAndClient()
        let key = WeekPhotoCache.key(server: server, sessionID: viewModel.sessionID, path: viewModel.weekPhotoPath)
        let otherWorkspace = WeekPhotoCache.key(server: server, sessionID: "other-session", path: viewModel.weekPhotoPath)
        XCTAssertNotEqual(key, otherWorkspace, "another workspace session never shares an entry")
        WeekPhotoCache.images.setObject(UIImage(), forKey: key)
        XCTAssertNotNil(WeekPhotoCache.images.object(forKey: key))

        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertNil(WeekPhotoCache.images.object(forKey: key), "a new view model at version 0 must miss, not show the old photo")
    }

    @MainActor
    func testFailedUploadKeepsTheCachedPhoto() async throws {
        let (viewModel, client) = try await weeklyViewModelAndClient()
        let key = WeekPhotoCache.key(server: server, sessionID: viewModel.sessionID, path: viewModel.weekPhotoPath)
        WeekPhotoCache.images.setObject(UIImage(), forKey: key)
        client.photoUpload = .failure(APIError.http(statusCode: 500, body: nil))
        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertNotNil(WeekPhotoCache.images.object(forKey: key))
        WeekPhotoCache.images.removeObject(forKey: key)
    }

    @MainActor
    func testWeeksModelReadsThroughTheDeckSession() async throws {
        let (viewModel, _) = try await weeklyViewModelAndClient()
        let weeks = try XCTUnwrap(viewModel.makeWeeksModel())
        XCTAssertEqual(weeks.server, viewModel.server)
        XCTAssertEqual(weeks.sessionID, viewModel.sessionID, "photo cache keys must match the deck's cover")
        let fresh = try XCTUnwrap(viewModel.makeWeeksModel())
        XCTAssertFalse(fresh === weeks, "a re-seal builds a model that reads records afresh")
    }

    @MainActor
    func testShowingAnotherDeckClearsTheUploadError() async throws {
        let (viewModel, client) = try await weeklyViewModelAndClient()
        client.photoUpload = .failure(APIError.http(statusCode: 500, body: nil))
        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertNotNil(viewModel.weekPhotoError)
        await viewModel.show(date: "2026-10-18", kind: "weekly")
        XCTAssertNil(viewModel.weekPhotoError)
    }

    @MainActor
    func testSetWeekPhotoFailureKeepsPreviousState() async throws {
        let (viewModel, client) = try await weeklyViewModelAndClient()
        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertEqual(viewModel.weekPhotoVersion, 1)

        client.photoUpload = .failure(APIError.http(statusCode: 500, body: nil))
        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x02]))
        XCTAssertEqual(viewModel.weekPhotoVersion, 1, "the cover keeps the image it had")
        XCTAssertNotNil(viewModel.weekPhotoError)
        XCTAssertFalse(viewModel.isUploadingWeekPhoto)

        client.photoUpload = .success(())
        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x03]))
        XCTAssertEqual(viewModel.weekPhotoVersion, 2)
        XCTAssertNil(viewModel.weekPhotoError, "a retry clears the message")
    }

    @MainActor
    func testWeekPhotoDataReadsThePathAndTreatsA404AsNoPhoto() async throws {
        let (viewModel, client) = try await weeklyViewModelAndClient()
        let missing = await viewModel.weekPhotoData(path: viewModel.weekPhotoPath)
        XCTAssertNil(missing)
        client.rawFiles["weekly-checkins/photos/2026-10-25.jpg"] = Data([1, 2, 3])
        let photo = await viewModel.weekPhotoData(path: viewModel.weekPhotoPath)
        XCTAssertEqual(photo, Data([1, 2, 3]))
    }

    // MARK: - Helpers

    private let server = URL(string: "https://brain.example.test")!
    private var suiteName = "WeeklyReviewModelTests.\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The v2 fixture deck, open on a view model as the 2026-10-25 weekly review.
    @MainActor
    private func weeklyViewModel() async throws -> DailyDeckViewModel {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.weekly.json"], deck: Self.v2DeckJSON)
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store)
        await viewModel.show(date: "2026-10-25", kind: "weekly")
        XCTAssertEqual(viewModel.state, .ready)
        return viewModel
    }

    @MainActor
    private func weeklyViewModelAndClient() async throws -> (DailyDeckViewModel, ScriptedDailyDeckClient) {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.weekly.json"], deck: Self.v2DeckJSON)
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store)
        await viewModel.show(date: "2026-10-25", kind: "weekly")
        XCTAssertEqual(viewModel.state, .ready)
        return (viewModel, client)
    }

    @MainActor
    private func card(_ id: String, in viewModel: DailyDeckViewModel) throws -> DeckCard {
        try XCTUnwrap(viewModel.cards.first { $0.id == id })
    }

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

/// The photo-of-the-week routes against `URLProtocol` mocks.
final class BriefPhotoHTTPTests: APIClientTestCase {
    func testUploadSendsJPEGToBriefPhotoWithWeekEnding() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/brief/photo")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "week_ending", value: "2026-10-25")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
            XCTAssertEqual(apiTestBodyData(from: request), jpeg)
            return apiTestJSONResponse(#"{"path":"weekly-checkins/photos/2026-10-25.jpg"}"#, for: request)
        }
        try await client.uploadWeekPhoto(weekEnding: "2026-10-25", jpeg: jpeg)
    }

    func testUploadFailureThrowsTheStatus() async {
        let client = makeClient { request in apiTestJSONResponse(#"{"error":"too big"}"#, for: request, status: 400) }
        do {
            try await client.uploadWeekPhoto(weekEnding: "2026-10-25", jpeg: Data([0xFF, 0xD8, 0xFF]))
            XCTFail("Expected an error")
        } catch let APIError.http(statusCode, _) {
            XCTAssertEqual(statusCode, 400)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testDeleteHitsBriefPhoto() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/brief/photo")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "week_ending", value: "2026-10-25")])
            return apiTestJSONResponse(#"{"removed":true}"#, for: request)
        }
        try await client.deleteWeekPhoto(weekEnding: "2026-10-25")
    }
}
