import XCTest
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class WeeklyReviewModelTests: XCTestCase {
    /// The v3 Sunday review as the vault's `build_weekly` writes it: four moments shown, two spares.
    private static let v3DeckJSON = """
    {"version": 3, "date": "2026-10-25", "kind": "weekly", "wrapped": true, "generated_at": "2026-10-25T05:30:00-04:00",
     "cards": [
      {"id": "cover", "type": "cover", "week_number": 43, "range": "Oct 19–25", "title": "The week Meg told you the truth",
       "chapters": [{"id": "remember", "label": "Remember", "minutes": 3}, {"id": "reflect", "label": "Reflect", "minutes": 6},
                    {"id": "values", "label": "Values", "minutes": 8}, {"id": "steer", "label": "Steer", "minutes": 5}],
       "moments": [{"id": "m1", "day": "Mon", "line": "Easy five miles before work", "value": "body", "strength": 2},
                   {"id": "m2", "day": "Thu", "line": "Meg said you'd seemed flat; you opened up", "value": "present", "strength": 3},
                   {"id": "m3", "day": "Fri", "line": "Read to the bump", "value": "dad", "strength": 2},
                   {"id": "m4", "day": "Sat", "line": "Shipped the eval harness", "value": "potential", "strength": 2},
                   {"day": "Sun", "line": "no id"}],
       "spares": [{"id": "m5", "day": "Sat", "line": "Solved Aunt Jenny's problem", "value": "people", "strength": 1},
                  {"id": "m6", "day": "Sun", "line": "Long lunch with Alex", "value": "people", "strength": 1}],
       "ended": "A quiet weekend, laughing with Alex", "note_from_past": null},
      {"id": "last-intention", "type": "last_intention", "text": "Get my sleep in a good place", "if_then": "",
       "fact": "6 of 7 nights over 7 h. Thu was 5.4 h.", "chapter": "remember"},
      {"id": "proud", "type": "prompt", "question": "What are you most proud of this week: opening up to Meg?",
       "files_to": "Wins & Accomplishments", "chapter": "reflect"},
      {"id": "lesson", "type": "prompt", "question": "What challenged you most this week, and what did it teach you?",
       "files_to": "Challenges & Learnings", "chapter": "reflect"},
      {"id": "value-present", "type": "value", "value": "present", "name": "Was present",
       "question": "Anything for Was present this week?", "chapter": "values"},
      {"id": "value-people", "type": "value", "value": "people", "name": "Showed up for my people",
       "fact": {"big": "22 people", "line": "Most: Meg, 3 days"}, "question": "What did Meg's honesty give you?", "chapter": "values"},
      {"id": "intention", "type": "intention", "chapter": "steer", "changes": [
        {"goal": "land-ai-role", "title": "Land an Applied AI Engineer role", "label": "Outreach 10 → 5",
         "reason": "Fewer, warmer notes landed better.", "start": "2026-10-26",
         "commitments": [{"id": "outreach", "action": "Outreach", "target": 5, "skips": 0, "unit": "item"}]},
        {"title": "no goal"}]},
      {"id": "keepsakes", "type": "keepsakes", "chapter": "steer"},
      {"id": "close", "type": "close"}
     ]}
    """

    func testDecodesV3Deck() throws {
        let deck = try DailyDeck.decode(Self.v3DeckJSON)
        XCTAssertEqual(deck.version, 3)
        XCTAssertEqual(deck.cards.map(\.type), [
            .cover, .lastIntention, .prompt, .prompt, .value, .value, .intention, .keepsakes, .close,
        ])

        let cover = deck.cards[0]
        XCTAssertNil(cover.chapter)
        XCTAssertEqual(cover.moments.map(\.id), ["m1", "m2", "m3", "m4"], "a moment without an id is dropped alone")
        XCTAssertEqual(cover.moments[1], DeckMoment(id: "m2", day: "Thu", line: "Meg said you'd seemed flat; you opened up", value: "present"))
        XCTAssertEqual(cover.spares.map(\.id), ["m5", "m6"])
        XCTAssertEqual(cover.ended, "A quiet weekend, laughing with Alex")
        XCTAssertNil(cover.noteFromPast)

        let last = deck.cards[1]
        XCTAssertEqual(last.text, "Get my sleep in a good place")
        XCTAssertEqual(last.ifThen, "")
        XCTAssertEqual(last.fact, DeckFact(big: nil, line: "6 of 7 nights over 7 h. Thu was 5.4 h."), "a plain-string fact is its line")
        XCTAssertEqual(last.chapter, "remember")

        XCTAssertEqual(deck.cards[2].question, "What are you most proud of this week: opening up to Meg?")
        XCTAssertEqual(deck.cards[2].chapter, "reflect")

        let present = deck.cards[4]
        XCTAssertEqual(present.valueID, "present")
        XCTAssertNil(present.fact, "a value without a fact has none")
        let people = deck.cards[5]
        XCTAssertEqual(people.valueID, "people")
        XCTAssertEqual(people.name, "Showed up for my people")
        XCTAssertEqual(people.fact, DeckFact(big: "22 people", line: "Most: Meg, 3 days"))
        XCTAssertEqual(people.question, "What did Meg's honesty give you?")
        XCTAssertEqual(people.chapter, "values")

        let intention = deck.cards[6]
        XCTAssertEqual(intention.changes.map(\.goal), ["land-ai-role"], "a change without a goal is dropped alone")
        let change = try XCTUnwrap(intention.changes.first)
        XCTAssertEqual(change.title, "Land an Applied AI Engineer role")
        XCTAssertEqual(change.label, "Outreach 10 → 5")
        XCTAssertEqual(change.reason, "Fewer, warmer notes landed better.")
        XCTAssertEqual(change.start, "2026-10-26")
        XCTAssertEqual(change.commitments.map(\.id), ["outreach"])
        XCTAssertEqual(change.commitments.first?.target, 5)
        XCTAssertEqual(change.commitments.first?.unit, "item")

        for card in deck.cards where [.lastIntention, .value, .intention].contains(card.type) {
            XCTAssertFalse(card.takesFeedback, card.id)
            XCTAssertEqual(DeckPalette.of(card), .week, card.id)
        }
    }

    @MainActor
    func testV3WeeklyIsASealedWeekly() async throws {
        let (viewModel, _) = try await v3ViewModelAndClient()
        XCTAssertTrue(viewModel.isSealedWeekly)
    }

    @MainActor
    func testSwapUsesFirstUnshownSpareAndStopsWhenNoneLeft() async throws {
        let (viewModel, _) = try await v3ViewModelAndClient()
        let cover = try card("cover", in: viewModel)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m2", "m3", "m4"], "with no answer, the card's moments")
        XCTAssertNil(viewModel.answer(for: cover), "reading the kept moments answers nothing")
        XCTAssertTrue(viewModel.canSwap(for: cover))

        viewModel.swapMoment("m2", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m5", "m3", "m4"], "the first spare takes the row's place")
        XCTAssertEqual(viewModel.answer(for: cover)?.lists?["moments"], ["m1", "m5", "m3", "m4"])

        viewModel.swapMoment("m5", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m6", "m3", "m4"], "a swapped-in spare swaps for the next")
        XCTAssertFalse(viewModel.canSwap(for: cover), "every spare has been shown")

        viewModel.swapMoment("m1", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m6", "m3", "m4"], "no spare left: swap does nothing")
        viewModel.swapMoment("m9", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m6", "m3", "m4"], "an id not kept: nothing")
    }

    @MainActor
    func testRemoveStopsAtThree() async throws {
        let (viewModel, _) = try await v3ViewModelAndClient()
        let cover = try card("cover", in: viewModel)
        XCTAssertTrue(viewModel.canRemove(for: cover))
        viewModel.removeMoment("m3", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m2", "m4"])
        XCTAssertFalse(viewModel.canRemove(for: cover))
        viewModel.removeMoment("m1", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m2", "m4"], "never under three")

        viewModel.swapMoment("m1", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m5", "m2", "m4"])
        XCTAssertTrue(viewModel.canSwap(for: cover), "m6 is still unshown")
        viewModel.swapMoment("m5", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m6", "m2", "m4"], "m5, once shown, never swaps back in")
        XCTAssertFalse(viewModel.canSwap(for: cover))
    }

    @MainActor
    func testRemoveCountsOnlyMomentsTheCoverCanShow() async throws {
        let (viewModel, _) = try await v3ViewModelAndClient()
        let cover = try card("cover", in: viewModel)
        viewModel.setList("moments", ["m1", "m2", "gone", "m3"], for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m2", "m3"])
        XCTAssertFalse(viewModel.canRemove(for: cover), "a stale id isn't a fourth moment")
        viewModel.removeMoment("m1", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m2", "m3"])
    }

    @MainActor
    func testALateDraftIsDroppedOnceAnotherDeckIsOnScreen() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let intention = try card("intention", in: viewModel)
        client.intentionDraft = .success(WeekIntentionDraft(thread: "Honesty", intention: "Drafted", obstacle: "Late calls", ifThen: nil))
        let arrived = expectation(description: "the draft was asked for")
        let (release, releaser) = AsyncStream<Void>.makeStream()
        client.intentionGate = {
            arrived.fulfill()
            for await _ in release { break }
        }
        let drafting = Task { await viewModel.intentionDraft() }
        await fulfillment(of: [arrived], timeout: 5)

        // He opens last week's review from the calendar, and its load fails before the deck opens.
        client.listingErrors[DailyDeckPaths.directory] = APIError.http(statusCode: 500, body: nil)
        await viewModel.show(date: "2026-10-18", kind: "weekly")
        if case .failed = viewModel.state {} else { XCTFail("expected the load to fail, got \(viewModel.state)") }
        releaser.yield()
        releaser.finish()
        await drafting.value

        XCTAssertFalse(viewModel.isDraftingIntention)
        XCTAssertTrue(store.answers(for: server, date: "2026-10-18", kind: "weekly").isEmpty, "nothing lands on the other deck")
        XCTAssertNil(store.answers(for: server, date: "2026-10-25", kind: "weekly")["intention"])
        XCTAssertNil(viewModel.answer(for: intention), "the old deck's answers are untouched")
    }

    @MainActor
    func testAnswerPayloadForV3Cards() async throws {
        let (viewModel, _) = try await v3ViewModelAndClient()
        let deck = try XCTUnwrap(viewModel.deck)
        let cover = try card("cover", in: viewModel)
        let last = try card("last-intention", in: viewModel)
        let people = try card("value-people", in: viewModel)
        let intention = try card("intention", in: viewModel)
        viewModel.setText("The week Meg told me the truth", for: cover)
        viewModel.removeMoment("m4", for: cover)
        viewModel.setStatus("last", "partly", for: last)
        viewModel.setText("Late calls", for: last)
        viewModel.setScore("people", 8, for: people)
        viewModel.setText("Called Mom twice.", for: people)
        viewModel.setIntentionField("text", "Asleep by 11, five nights", for: intention)
        viewModel.setIntentionField("thread", "Honesty", for: intention)
        viewModel.setIntentionField("obstacle", "Late calls", for: intention)
        viewModel.setIntentionField("if_then", "If it's 10:30, the phone goes on the charger", for: intention)
        XCTAssertEqual(viewModel.intentionFieldsTouched, ["text", "thread", "obstacle", "if_then"])
        XCTAssertEqual(viewModel.intentionField("if_then", for: intention), "If it's 10:30, the phone goes on the charger")
        XCTAssertEqual(viewModel.intentionField("text", for: intention), "Asleep by 11, five nights")

        let payload = DeckAnswersPayload(deck: deck, answers: viewModel.answers, completedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let answers = try XCTUnwrap(json["answers"] as? [[String: Any]])
        XCTAssertEqual(answers.compactMap { $0["card"] as? String }, ["cover", "last-intention", "value-people", "intention"])
        let byCard = Dictionary(uniqueKeysWithValues: answers.map { ($0["card"] as? String ?? "", $0) })
        XCTAssertEqual(byCard["cover"]?["text"] as? String, "The week Meg told me the truth")
        XCTAssertEqual(byCard["cover"]?["lists"] as? [String: [String]], ["moments": ["m1", "m2", "m3"]])
        XCTAssertEqual(byCard["last-intention"]?["statuses"] as? [String: String], ["last": "partly"])
        XCTAssertEqual(byCard["last-intention"]?["text"] as? String, "Late calls")
        XCTAssertEqual(byCard["value-people"]?["scores"] as? [String: Int], ["people": 8])
        XCTAssertEqual(byCard["value-people"]?["text"] as? String, "Called Mom twice.")
        XCTAssertEqual(byCard["intention"]?["text"] as? String, "Asleep by 11, five nights")
        XCTAssertEqual(byCard["intention"]?["notes"] as? [String: String], [
            "thread": "Honesty", "obstacle": "Late calls", "if_then": "If it's 10:30, the phone goes on the charger",
        ])

        // Read back as the filed answers file, `if_then` stays the vault's key.
        let filed = DeckAnswersFile.decodeAnswers(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(filed["intention"]?.notes?["if_then"], "If it's 10:30, the phone goes on the charger")
    }

    @MainActor
    func testIntentionDraftDoesNotOverwriteTouchedFields() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let intention = try card("intention", in: viewModel)
        viewModel.setStatus("last", "didnt", for: try card("last-intention", in: viewModel))
        client.intentionDraft = .success(WeekIntentionDraft(thread: "Honesty with Meg", intention: "Asleep by 11, five nights",
                                                            obstacle: "Late calls", ifThen: "If it's 10:30, the phone goes on the charger"))
        viewModel.setIntentionField("obstacle", "My own words", for: intention)

        await viewModel.intentionDraft()
        XCTAssertEqual(client.intentionRequests.count, 1)
        XCTAssertEqual(client.intentionRequests.first?.date, "2026-10-25")
        XCTAssertEqual(client.intentionRequests.first?.answers.answers.first { $0.card == "last-intention" }?.statuses, ["last": "didnt"],
                       "the draft reads the answers so far")
        XCTAssertEqual(viewModel.intentionField("obstacle", for: intention), "My own words", "his edit stands")
        XCTAssertEqual(viewModel.intentionField("text", for: intention), "Asleep by 11, five nights")
        XCTAssertEqual(viewModel.intentionField("thread", for: intention), "Honesty with Meg")
        XCTAssertEqual(viewModel.intentionField("if_then", for: intention), "If it's 10:30, the phone goes on the charger")

        // Touched, so editing an earlier answer doesn't ask again.
        viewModel.setText("Proud of it", for: try card("proud", in: viewModel))
        await viewModel.intentionDraft()
        XCTAssertEqual(client.intentionRequests.count, 1)
    }

    @MainActor
    func testALateDraftFillsOnlyWhatHeHasNotTyped() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let intention = try card("intention", in: viewModel)
        client.intentionDraft = .success(WeekIntentionDraft(thread: "Honesty", intention: "Drafted", obstacle: "Drafted obstacle", ifThen: nil))
        let arrived = expectation(description: "the draft was asked for")
        let (release, releaser) = AsyncStream<Void>.makeStream()
        client.intentionGate = {
            arrived.fulfill()
            for await _ in release { break }
        }
        let drafting = Task { await viewModel.intentionDraft() }
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertTrue(viewModel.isDraftingIntention)
        viewModel.setIntentionField("text", "Typed while it drafted", for: intention)
        releaser.yield()
        releaser.finish()
        await drafting.value

        XCTAssertFalse(viewModel.isDraftingIntention)
        XCTAssertEqual(viewModel.intentionField("text", for: intention), "Typed while it drafted")
        XCTAssertEqual(viewModel.intentionField("obstacle", for: intention), "Drafted obstacle")
        XCTAssertEqual(viewModel.intentionField("thread", for: intention), "Honesty")
        XCTAssertEqual(viewModel.intentionField("if_then", for: intention), "", "a field the draft left out stays blank")
    }

    @MainActor
    func testUntouchedIntentionDraftsAgainOnlyWhenAnEarlierAnswerChanged() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let intention = try card("intention", in: viewModel)
        client.intentionDraft = .success(WeekIntentionDraft(thread: nil, intention: "First", obstacle: nil, ifThen: nil))
        await viewModel.intentionDraft()
        await viewModel.intentionDraft()
        XCTAssertEqual(client.intentionRequests.count, 1, "nothing changed: no second draft")

        viewModel.setText("Proud of it", for: try card("proud", in: viewModel))
        client.intentionDraft = .success(WeekIntentionDraft(thread: nil, intention: "Second", obstacle: nil, ifThen: nil))
        await viewModel.intentionDraft()
        XCTAssertEqual(client.intentionRequests.count, 2)
        XCTAssertEqual(viewModel.intentionField("text", for: intention), "Second", "an untouched field takes the newer draft")
        XCTAssertTrue(viewModel.intentionFieldsTouched.isEmpty)
    }

    @MainActor
    func testIntentionDraftFailurePrefillsFromLastWeek() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let intention = try card("intention", in: viewModel)
        let last = try card("last-intention", in: viewModel)
        viewModel.setStatus("last", "partly", for: last)
        viewModel.setText("Late calls with the West Coast", for: last)
        client.intentionDraft = .failure(URLError(.timedOut))

        await viewModel.intentionDraft()
        XCTAssertEqual(viewModel.intentionField("text", for: intention), "Get my sleep in a good place", "it didn't fully hold")
        XCTAssertEqual(viewModel.intentionField("obstacle", for: intention), "Late calls with the West Coast")
        XCTAssertEqual(viewModel.intentionField("thread", for: intention), "")
        XCTAssertEqual(viewModel.intentionField("if_then", for: intention), "")
        XCTAssertTrue(viewModel.intentionFieldsTouched.isEmpty, "a prefill is not his edit")
    }

    @MainActor
    func testAnEmptyDraftAfterAHeldWeekLeavesTheIntentionBlank() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let intention = try card("intention", in: viewModel)
        viewModel.setStatus("last", "held", for: try card("last-intention", in: viewModel))
        client.intentionDraft = .success(WeekIntentionDraft(thread: nil, intention: " ", obstacle: nil, ifThen: nil))

        await viewModel.intentionDraft()
        XCTAssertEqual(viewModel.intentionField("text", for: intention), "", "a held intention isn't carried")
        XCTAssertEqual(viewModel.intentionField("obstacle", for: intention), "", "nothing got in the way")
        XCTAssertNil(viewModel.answer(for: intention))
    }

    @MainActor
    func testTheIntentionDraftsOnlyOnTheIntentionCardWithTheLastValueAnswered() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let people = try card("value-people", in: viewModel)
        viewModel.index = try XCTUnwrap(viewModel.visiblePages.firstIndex { $0.id == people.id })
        await viewModel.draftIntentionOnArrival()
        XCTAssertTrue(client.intentionRequests.isEmpty, "the card under the top one doesn't draft")

        viewModel.setScore("people", 8, for: people)
        viewModel.index = try XCTUnwrap(viewModel.visiblePages.firstIndex { $0.id == "intention" })
        await viewModel.draftIntentionOnArrival()
        XCTAssertEqual(client.intentionRequests.count, 1)
        let sent = try XCTUnwrap(client.intentionRequests.first?.answers.answers.first { $0.card == "value-people" })
        XCTAssertEqual(sent.scores, ["people": 8], "the draft sees the last value's answer")

        await viewModel.draftIntentionOnArrival()
        XCTAssertEqual(client.intentionRequests.count, 1, "a started intention isn't drafted again on return")
    }

    @MainActor
    func testAWeekSinceMarkedHeldDoesNotMakeItsOldWordsTheObstacle() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let intention = try card("intention", in: viewModel)
        let last = try card("last-intention", in: viewModel)
        viewModel.setStatus("last", "partly", for: last)
        viewModel.setText("Late calls", for: last)
        viewModel.setStatus("last", "held", for: last)
        client.intentionDraft = .failure(URLError(.timedOut))

        await viewModel.intentionDraft()
        XCTAssertEqual(viewModel.intentionField("obstacle", for: intention), "")
        XCTAssertEqual(viewModel.intentionField("text", for: intention), "")
        XCTAssertEqual(viewModel.answer(for: last)?.text, "Late calls", "his words stay on the card for Partly")
    }

    func testWordsBoxSpeaksItsLabelOnce() {
        XCTAssertEqual(WeekWordsBox.spoken(label: "Thread", words: "Honesty"), "Thread: Honesty")
        XCTAssertEqual(WeekWordsBox.spoken(label: "What got in the way?", words: "Late calls"), "What got in the way? Late calls")
        XCTAssertEqual(WeekWordsBox.spoken(label: nil, words: "A line"), "A line")
    }

    @MainActor
    func testAcceptChangeOnlyAfterServerSuccess() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        let intention = try card("intention", in: viewModel)
        let change = try XCTUnwrap(intention.changes.first)
        client.serverToday = .success("2026-10-25")
        client.weekConfirm = .failure(APIError.http(statusCode: 500, body: nil))

        let failed = await viewModel.acceptChange(change, for: intention)
        XCTAssertFalse(failed)
        XCTAssertNil(viewModel.answer(for: intention)?.lists?["accepted"], "a failed confirm accepts nothing")
        XCTAssertFalse(viewModel.isAccepted(change, for: intention))

        client.weekConfirm = .success(())
        let arrived = expectation(description: "the confirm was sent")
        let (release, releaser) = AsyncStream<Void>.makeStream()
        client.confirmGate = {
            arrived.fulfill()
            for await _ in release { break }
        }
        let accepting = Task { await viewModel.acceptChange(change, for: intention) }
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertEqual(viewModel.acceptingChanges, ["land-ai-role"])
        XCTAssertFalse(viewModel.isAccepted(change, for: intention), "not before the server answers")
        releaser.yield()
        releaser.finish()
        let accepted = await accepting.value

        XCTAssertTrue(accepted)
        XCTAssertTrue(viewModel.acceptingChanges.isEmpty)
        XCTAssertEqual(viewModel.answer(for: intention)?.lists?["accepted"], ["land-ai-role"])
        XCTAssertTrue(viewModel.isAccepted(change, for: intention))
        let request = try XCTUnwrap(client.weekRequests.last)
        XCTAssertEqual(client.weekRequests.count, 2)
        XCTAssertEqual(request.slug, "land-ai-role")
        XCTAssertEqual(request.start, "2026-10-26")
        XCTAssertEqual(request.asOf, "2026-10-25", "the Goals server's today, as the week-ahead confirm sends")
        XCTAssertEqual(request.commitments.map(\.id), ["outreach"])
        XCTAssertEqual(request.commitments.first?.target, 5)

        let again = await viewModel.acceptChange(change, for: intention)
        XCTAssertTrue(again)
        XCTAssertEqual(client.weekRequests.count, 2, "an accepted change isn't sent twice")
        XCTAssertEqual(viewModel.answer(for: intention)?.lists?["accepted"], ["land-ai-role"])
    }

    func testUnknownFieldsAndTypesStillDecode() throws {
        let deck = try DailyDeck.decode(#"""
        {"version": 3, "date": "2026-10-25", "kind": "weekly", "extra": true, "cards": [
          {"id": "cover", "type": "cover", "week_number": 43, "brand_new": [1, 2], "moments": "not a list", "spares": {"x": 1}},
          {"id": "later", "type": "future_card", "chapter": "steer", "gadgets": [{"a": 1}]},
          {"id": "value-body", "type": "value", "value": "body", "fact": 7, "changes": "none"},
          {"id": "close", "type": "close"}
        ]}
        """#)
        XCTAssertEqual(deck.cards.map(\.id), ["cover", "later", "value-body", "close"])
        XCTAssertEqual(deck.cards[1].type, .unknown("future_card"))
        XCTAssertEqual(deck.cards[0].moments, [], "a mistyped field is empty, not fatal")
        XCTAssertEqual(deck.cards[0].spares, [])
        XCTAssertNil(deck.cards[2].fact)
        XCTAssertEqual(deck.cards[2].changes, [])
    }

    func testV1WeeklyDeckStillDecodes() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"2026-10-18","kind":"weekly","cards":[
          {"id":"headline","type":"headline","title":"Your week","lines":["Weekly review"],"recap":"You tapered."},
          {"id":"mood","type":"item","kind":"mood","title":"Energy and mood","points":[{"label":"Tue","energy":8,"mood":7}]},
          {"id":"week-career","type":"week_ahead","goal":"career","start":"2026-10-19","fallback":"Next week: Outreach 6"},
          {"id":"changes","type":"changes","title":"What changed","rows":[]},
          {"id":"close","type":"close"}
        ]}
        """#)
        XCTAssertEqual(deck.cards.map(\.type), [.headline, .item, .unknown("week_ahead"), .changes, .close],
                       "a retired week-ahead card reads as its fallback")
        XCTAssertNil(deck.version)
        let card = deck.cards[2]
        XCTAssertEqual(DeckCardText(card).lead, "Next week: Outreach 6")
        XCTAssertNil(card.chapter)
        XCTAssertNil(card.weekNumber)
        XCTAssertEqual(card.moments, [])
        XCTAssertNil(card.noteFromPast)
    }

    func testAnswerEncodesOnlySetFields() throws {
        var answer = DeckAnswer(card: "value-people")
        answer.scores = ["people": 7]
        let json = try Self.encode(answer)
        XCTAssertEqual(json["scores"] as? [String: Int], ["people": 7])
        for key in ["notes", "lists", "statuses", "text"] {
            XCTAssertNil(json[key], key)
        }
        XCTAssertTrue(answer.isAnswer(for: Self.card("value-people")))
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
    }

    func testAnswersPayloadKeepsAScoresOnlyAnswer() throws {
        let deck = try DailyDeck.decode(Self.v3DeckJSON)
        var answer = DeckAnswer(card: "value-people")
        answer.scores = ["people": 7]
        let payload = DeckAnswersPayload(deck: deck, answers: ["value-people": answer], completedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(payload.answers.map(\.card), ["value-people"])
        XCTAssertEqual(payload.version, 1)
    }

    func testDecodesV2WeekRecord() throws {
        let record = try WeekRecord.decode(Data(#"""
        {"version": 2, "week_ending": "2026-11-01", "week_number": 44, "title": "The week you tapered", "story": "Slept more.",
         "photo": "weekly-checkins/photos/2026-11-01.jpg",
         "moments": [{"day": "Thu", "line": "Called Dad.", "value": "present"}, {"day": "", "line": "my own words", "value": ""}, {"line": 4}],
         "ended": "On the couch, tired.",
         "last_intention": {"text": "Send three asks", "status": "partly", "note": "Only two."},
         "reflect": {"proud": {"question": "What are you most proud of?", "answer": "Showing up."},
                     "lesson": {"question": "What did it teach you?", "answer": null}},
         "values": [{"id": "people", "name": "Showed up for my people", "score": 9, "question": "Who?", "answer": "Meg.",
                     "fact": {"big": "22 people", "line": "Most: Meg, 3 days"}},
                    {"id": "body", "name": "Body", "score": null, "fact": "ran twice"}],
         "intention": {"thread": "Outreach", "text": "Send five asks", "obstacle": "Tuesdays", "if_then": "If it is 9am, then I write."},
         "note": {"text": "Be kind.", "opens_on": "2027-10-31"}, "brand_new": [1]}
        """#.utf8))
        XCTAssertEqual(record.moments.map(\.line), ["Called Dad.", "my own words"], "a moment that fails to decode is dropped")
        XCTAssertEqual(record.moments.map(\.day), ["Thu", ""])
        XCTAssertEqual(record.moments.map(\.value), ["present", ""])
        XCTAssertEqual(record.ended, "On the couch, tired.")
        XCTAssertEqual(record.lastIntention?.text, "Send three asks")
        XCTAssertEqual(record.lastIntention?.status, "partly")
        XCTAssertEqual(record.lastIntention?.note, "Only two.")
        XCTAssertEqual(record.reflect?.proud?.question, "What are you most proud of?")
        XCTAssertEqual(record.reflect?.proud?.answer, "Showing up.")
        XCTAssertNil(record.reflect?.lesson?.answer)
        XCTAssertEqual(record.values.map(\.answer), ["Meg.", nil])
        XCTAssertEqual(record.values[0].question, "Who?")
        XCTAssertEqual(record.values[0].fact, DeckFact(big: "22 people", line: "Most: Meg, 3 days"))
        XCTAssertEqual(record.values[1].fact, DeckFact(big: nil, line: "ran twice"))
        XCTAssertEqual(record.intention?.thread, "Outreach")
        XCTAssertEqual(record.intention?.text, "Send five asks")
        XCTAssertEqual(record.intention?.obstacle, "Tuesdays")
        XCTAssertEqual(record.intention?.ifThen, "If it is 9am, then I write.")
        XCTAssertEqual(record.note?.opensOn, "2027-10-31")

        let nulls = try WeekRecord.decode(Data(#"{"version": 2, "week_ending": "2026-11-08", "moments": null, "last_intention": null, "reflect": null, "intention": null}"#.utf8))
        XCTAssertEqual(nulls.moments, [])
        XCTAssertNil(nulls.lastIntention)
        XCTAssertNil(nulls.reflect)
        XCTAssertNil(nulls.intention)
    }

    func testV1WeekRecordStillDecodes() throws {
        let record = try WeekRecord.decode(Data(#"""
        {"version": 1, "week_ending": "2026-10-25", "week_number": 43, "title": "The week you tapered", "story": "Slept more.",
         "energy": {"gave": ["Running"], "drained": []}, "deep": {"rotation": "Examen", "question": "Q?", "answer": "A."},
         "values": [{"id": "present", "name": "Present", "score": 7, "evidence": "Phone down."}],
         "one_thing": {"text": "Send three asks", "carried": 2}, "note": null}
        """#.utf8))
        XCTAssertEqual(record.moments, [])
        XCTAssertNil(record.ended)
        XCTAssertNil(record.lastIntention)
        XCTAssertNil(record.reflect)
        XCTAssertNil(record.intention)
        XCTAssertEqual(record.values.map(\.evidence), ["Phone down."])
        XCTAssertNil(record.values[0].answer)
        XCTAssertNil(record.values[0].fact)
        XCTAssertEqual(record.deep?.answer, "A.")
        XCTAssertEqual(record.oneThing?.text, "Send three asks")
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
    func testValueCardSliderWritesScore() async throws {
        let (viewModel, _) = try await v3ViewModelAndClient()
        let people = try card("value-people", in: viewModel)
        viewModel.setScore("people", 7, for: people)
        XCTAssertEqual(viewModel.answer(for: people)?.scores, ["people": 7])
        XCTAssertNil(viewModel.answer(for: people)?.text)
        viewModel.setScore("people", 11, for: people)
        viewModel.setScore("people", 0, for: people)
        XCTAssertEqual(viewModel.answer(for: people)?.scores, ["people": 7], "scores outside 1–10 are ignored")
        viewModel.setScore("people", 4, for: people)
        XCTAssertEqual(viewModel.answer(for: people)?.scores, ["people": 4])
        viewModel.setScore("people", 4, for: people)
        XCTAssertNil(viewModel.answer(for: people), "tapping the chosen score again clears it")
    }

    @MainActor
    func testAnOwnMomentJoinsTheCoverAndCanAlwaysGo() async throws {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let quiet = #"{"version":3,"date":"2026-10-25","kind":"weekly","cards":[{"id":"cover","type":"cover","moments":[],"spares":[]},{"id":"close","type":"close"}]}"#
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.weekly.json"], deck: quiet)
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store)
        await viewModel.show(date: "2026-10-25", kind: "weekly")
        let cover = try card("cover", in: viewModel)
        XCTAssertEqual(viewModel.keptMoments(for: cover), [])

        viewModel.addOwnMoment("  ", for: cover)
        XCTAssertNil(viewModel.answer(for: cover), "blank words add nothing")
        viewModel.addOwnMoment("Dinner with Meg ", for: cover)
        viewModel.addOwnMoment("Long run", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover), [
            DeckMoment(id: "own-1", day: "", line: "Dinner with Meg", value: ""),
            DeckMoment(id: "own-2", day: "", line: "Long run", value: ""),
        ])
        XCTAssertEqual(viewModel.answer(for: cover)?.lists?["moments"], ["own-1", "own-2"])
        XCTAssertEqual(viewModel.answer(for: cover)?.notes, ["own-1": "Dinner with Meg", "own-2": "Long run"])
        XCTAssertFalse(viewModel.canRemove(for: cover), "two moments is under the three the brief's need")
        XCTAssertTrue(viewModel.canRemoveMoment("own-1", for: cover), "one of his own can always go")

        viewModel.removeMoment("own-1", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["own-2"])
        XCTAssertEqual(viewModel.answer(for: cover)?.notes, ["own-2": "Long run"], "its words go with it")
        viewModel.addOwnMoment("Read to the bump", for: cover)
        XCTAssertEqual(viewModel.answer(for: cover)?.lists?["moments"], ["own-2", "own-1"], "the next free number")
    }

    @MainActor
    func testOwnMomentsCountTowardTheThreeTheCoverKeeps() async throws {
        let (viewModel, _) = try await v3ViewModelAndClient()
        let cover = try card("cover", in: viewModel)
        viewModel.removeMoment("m4", for: cover)
        XCTAssertFalse(viewModel.canRemove(for: cover))
        viewModel.addOwnMoment("Long lunch", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m1", "m2", "m3", "own-1"])
        XCTAssertTrue(viewModel.canRemove(for: cover), "four moments, one can go")
        viewModel.removeMoment("m1", for: cover)
        XCTAssertFalse(viewModel.canRemoveMoment("m2", for: cover))
        viewModel.removeMoment("m2", for: cover)
        XCTAssertEqual(viewModel.keptMoments(for: cover).map(\.id), ["m2", "m3", "own-1"])
    }

    func testChapterLabelNumbersTheChapters() throws {
        let deck = try DailyDeck.decode(Self.v3DeckJSON)
        let labels = Dictionary(uniqueKeysWithValues: deck.cards.map { ($0.id, $0.chapterLabel) })
        XCTAssertEqual(labels["last-intention"], "1 · Remember")
        XCTAssertEqual(labels["proud"], "2 · Reflect")
        XCTAssertEqual(labels["value-people"], "3 · Values")
        XCTAssertEqual(labels["intention"], "4 · Steer")
        XCTAssertEqual(labels["keepsakes"], "4 · Steer")
        XCTAssertNil(labels["cover"] ?? nil, "the cover has no chapter")
        XCTAssertNil(labels["close"] ?? nil, "nor the close")
    }

    func testCoverExposesTheWeeksQuestionRecapAndTheTakeWearsItsChapter() throws {
        let deck = try DailyDeck.decode(#"""
        {"version":2,"date":"2026-11-01","kind":"weekly","cards":[
          {"id":"cover","type":"cover","title":"The week you tapered","recap":"This week was about: Is the model the product?"},
          {"id":"view-take","type":"decision","kind":"view_take","chapter":"reflect","title":"Is the model the product?"},
          {"id":"view-steer","type":"prompt","chapter":"steer","question":"Keep it?","files_to":"steer"},
          {"id":"f1","type":"decision","title":"Sam"}]}
        """#)
        XCTAssertEqual(deck.cards[0].recap, "This week was about: Is the model the product?")
        XCTAssertEqual(deck.cards[1].chapterLabel, "2 · Reflect", "the take closes the Reflect chapter")
        XCTAssertEqual(deck.cards[2].chapterLabel, "4 · Steer")
        XCTAssertNil(deck.cards[3].chapterLabel, "a plain follow-up has no chapter line")
        let bare = try DailyDeck.decode(#"{"version":2,"date":"d","kind":"weekly","cards":[{"id":"cover","type":"cover"}]}"#)
        XCTAssertNil(bare.cards[0].recap, "a week without a question has no recap")
    }

    // MARK: - Seal

    @MainActor
    func testSealedWeeklyFilesThroughBriefFileWithItsAnswers() async throws {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.weekly.json"], deck: Self.v3DeckJSON)
        client.filer = .success(BriefFileResponse(ok: true, summary: "Sealed."))
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store)
        await viewModel.show(date: "2026-10-25", kind: "weekly")
        XCTAssertTrue(viewModel.isSealedWeekly)

        viewModel.setScore("people", 7, for: try card("value-people", in: viewModel))
        viewModel.removeMoment("m4", for: try card("cover", in: viewModel))
        _ = await viewModel.file()

        let request = try XCTUnwrap(client.fileRequests.first)
        XCTAssertEqual(client.fileRequests.count, 1)
        XCTAssertEqual(request.kind, "weekly")
        XCTAssertEqual(request.date, "2026-10-25")
        let byCard = Dictionary(uniqueKeysWithValues: request.answers.answers.map { ($0.card, $0) })
        XCTAssertEqual(byCard["value-people"]?.scores, ["people": 7])
        XCTAssertEqual(byCard["cover"]?.lists, ["moments": ["m1", "m2", "m3"]])
    }

    @MainActor
    func testASealedWeekIsSealedOnlyWhenItsRecordExists() async throws {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.weekly.json", "2026-10-25.weekly.answers.json"],
                                             deck: Self.v3DeckJSON)
        client.files["briefs/2026-10-25.weekly.answers.json"] = """
        {"version": 1, "date": "2026-10-25", "kind": "weekly", "completed_at": "x",
         "answers": [{"card": "proud", "text": "You raced."}]}
        """
        // The server saved the answers, then its filer failed: no record.
        let failed = DailyDeckViewModel(server: server, client: client, store: store)
        await failed.show(date: "2026-10-25", kind: "weekly")
        XCTAssertEqual(failed.answer(for: try card("proud", in: failed))?.text, "You raced.", "the answers come back to seal again")
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
    func testOnlyAV2OrLaterWeeklyDeckIsSealedWeekly() async throws {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let v1 = #"{"date":"2026-10-18","kind":"weekly","cards":[{"id":"close","type":"close"}]}"#
        let v1Client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-18.weekly.json"], deck: v1)
        let v1Model = DailyDeckViewModel(server: server, client: v1Client, store: store)
        await v1Model.show(date: "2026-10-18", kind: "weekly")
        XCTAssertEqual(v1Model.state, .ready)
        XCTAssertFalse(v1Model.isSealedWeekly, "a v1 weekly keeps its filing copy")

        let morning = #"{"version":2,"date":"2026-10-25","kind":"morning","cards":[{"id":"close","type":"close"}]}"#
        let morningClient = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.morning.json"], deck: morning)
        let morningModel = DailyDeckViewModel(server: server, client: morningClient, store: store)
        await morningModel.show(date: "2026-10-25", kind: "morning")
        XCTAssertEqual(morningModel.state, .ready)
        XCTAssertFalse(morningModel.isSealedWeekly)
    }

    // MARK: - Close card and prompt copy

    func testASealedWeeklyClosesOnTheWeeksPaper() throws {
        let close = DeckPage.card(Self.card("close"))
        XCTAssertEqual(DeckPalette.of(close, inV2Weekly: true), .week)
        XCTAssertEqual(DeckPalette.of(close, inV2Weekly: false), .quote, "v1 weekly and morning closes keep their paper")
        let last = DeckPage.card(try XCTUnwrap(try DailyDeck.decode(Self.v3DeckJSON).cards.first { $0.id == "last-intention" }))
        XCTAssertEqual(DeckPalette.of(last, inV2Weekly: true), DeckPalette.of(last))
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
        let cards = try DailyDeck.decode(#"""
        {"date":"2026-10-18","kind":"weekly","cards":[
          {"id":"one-thing","type":"prompt","question":"What's the one thing for this week?"},
          {"id":"deep","type":"prompt","question":"What did you notice?"}]}
        """#).cards
        XCTAssertEqual(DeckCopy.invitation(for: cards[0]), "Write the one thing")
        XCTAssertEqual(DeckCopy.invitation(for: cards[1]), "Write a reflection")
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
        let (viewModel, client) = try await v3ViewModelAndClient()
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
        let (viewModel, _) = try await v3ViewModelAndClient()
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
        let (viewModel, client) = try await v3ViewModelAndClient()
        let key = WeekPhotoCache.key(server: server, sessionID: viewModel.sessionID, path: viewModel.weekPhotoPath)
        WeekPhotoCache.images.setObject(UIImage(), forKey: key)
        client.photoUpload = .failure(APIError.http(statusCode: 500, body: nil))
        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertNotNil(WeekPhotoCache.images.object(forKey: key))
        WeekPhotoCache.images.removeObject(forKey: key)
    }

    @MainActor
    func testWeeksModelReadsThroughTheDeckSession() async throws {
        let (viewModel, _) = try await v3ViewModelAndClient()
        let weeks = try XCTUnwrap(viewModel.makeWeeksModel())
        XCTAssertEqual(weeks.server, viewModel.server)
        XCTAssertEqual(weeks.sessionID, viewModel.sessionID, "photo cache keys must match the deck's cover")
        let fresh = try XCTUnwrap(viewModel.makeWeeksModel())
        XCTAssertFalse(fresh === weeks, "a re-seal builds a model that reads records afresh")
    }

    @MainActor
    func testShowingAnotherDeckClearsTheUploadError() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
        client.photoUpload = .failure(APIError.http(statusCode: 500, body: nil))
        await viewModel.setWeekPhoto(Data([0xFF, 0xD8, 0xFF, 0x01]))
        XCTAssertNotNil(viewModel.weekPhotoError)
        await viewModel.show(date: "2026-10-18", kind: "weekly")
        XCTAssertNil(viewModel.weekPhotoError)
    }

    @MainActor
    func testSetWeekPhotoFailureKeepsPreviousState() async throws {
        let (viewModel, client) = try await v3ViewModelAndClient()
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
        let (viewModel, client) = try await v3ViewModelAndClient()
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

    /// The v3 fixture deck, open on a view model as the 2026-10-25 weekly review.
    @MainActor
    private func v3ViewModelAndClient() async throws -> (DailyDeckViewModel, ScriptedDailyDeckClient) {
        let store = DailyDeckStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-25.weekly.json"], deck: Self.v3DeckJSON)
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

/// The intention draft route against `URLProtocol` mocks.
final class BriefIntentionHTTPTests: APIClientTestCase {
    private func payload() throws -> DeckAnswersPayload {
        let deck = try DailyDeck.decode(#"""
        {"version": 3, "date": "2026-10-25", "kind": "weekly", "cards": [
          {"id": "last-intention", "type": "last_intention", "text": "Sleep"}, {"id": "intention", "type": "intention"}]}
        """#)
        var last = DeckAnswer(card: "last-intention")
        last.statuses = ["last": "partly"]
        var intention = DeckAnswer(card: "intention")
        intention.notes = ["if_then": "If 10:30, then bed"]
        return DeckAnswersPayload(deck: deck, answers: ["last-intention": last, "intention": intention],
                                  completedAt: Date(timeIntervalSince1970: 0))
    }

    func testDraftPostsTheDateAndAnswersAndReadsIfThen() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/brief/intention")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(apiTestBodyData(from: request))) as? [String: Any])
            XCTAssertEqual(body["date"] as? String, "2026-10-25")
            let answers = try XCTUnwrap(body["answers"] as? [[String: Any]], "the answers list, as the vault reads it")
            XCTAssertEqual(answers.compactMap { $0["card"] as? String }, ["last-intention", "intention"])
            XCTAssertEqual(answers[0]["statuses"] as? [String: String], ["last": "partly"])
            XCTAssertEqual(answers[1]["notes"] as? [String: String], ["if_then": "If 10:30, then bed"])
            return apiTestJSONResponse(
                #"{"thread":"Honesty","intention":"Asleep by 11","obstacle":"Late calls","if_then":"If 10:30, then bed","extra":1}"#,
                for: request)
        }
        let draft = try await client.draftIntention(date: "2026-10-25", answers: try payload())
        XCTAssertEqual(draft, WeekIntentionDraft(thread: "Honesty", intention: "Asleep by 11", obstacle: "Late calls",
                                                 ifThen: "If 10:30, then bed"))
        XCTAssertFalse(draft.isEmpty)
    }

    func testAnEmptyReplyIsAnEmptyDraft() async throws {
        let client = makeClient { request in apiTestJSONResponse("{}", for: request) }
        let draft = try await client.draftIntention(date: "2026-10-25", answers: try payload())
        XCTAssertEqual(draft, WeekIntentionDraft(thread: nil, intention: nil, obstacle: nil, ifThen: nil))
        XCTAssertTrue(draft.isEmpty)
    }
}
