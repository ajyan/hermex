import XCTest
import Foundation
@testable import HermesMobile

final class DailyDeckTests: XCTestCase {
    private let server = URL(string: "https://brain.example.test")!
    private let otherServer = URL(string: "https://other.example.test")!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DailyDeckTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var store: DailyDeckStore { DailyDeckStore(defaults: defaults) }

    /// 2026-10-04 09:00 in the device's calendar, so `DailyDeckPaths.day` is stable.
    private var morning: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9))!
    }

    // MARK: - Decoding

    func testDecodesEveryCardTypeAndToleratesUnknownTypesAndFields() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        XCTAssertEqual(deck.date, "2026-10-04")
        XCTAssertEqual(deck.cards.map(\.type), [.headline, .prompt, .decision, .reflect, .item, .unknown("poll"), .close])
        XCTAssertEqual(deck.cards[1].question, "What is the one action today?")
        XCTAssertEqual(deck.cards[2].actions.map(\.id), ["answer", "skip"])
        XCTAssertTrue(deck.cards[2].actions[0].takesText)
        XCTAssertEqual(deck.cards[4].itemKind, "book")
        XCTAssertEqual(deck.cards[5].fallback, "A newer card")
        XCTAssertEqual(deck.cards[6].lines, [])
    }

    func testCardWithWrongFieldTypesStillDecodes() throws {
        let deck = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"x","type":"item","title":7,"lines":"no"}]}"#)
        XCTAssertNil(deck.cards[0].title)
        XCTAssertEqual(deck.cards[0].lines, [])
    }

    // MARK: - Payload

    func testPayloadKeepsDeckOrderDropsEmptyAnswersAndTrimsText() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        let answers: [String: DeckAnswer] = [
            "book": DeckAnswer(card: "book", text: "It does."),
            "advisor": DeckAnswer(card: "advisor", text: "  Ship it.\n"),
            "media-1": DeckAnswer(card: "media-1", text: "   "),
            "followup-3": DeckAnswer(card: "followup-3", action: "skip")
        ]
        let unfinished = DeckAnswersPayload(deck: deck, answers: ["followup-3": DeckAnswer(card: "followup-3", action: "answer")], completedAt: morning)
        XCTAssertEqual(unfinished.answers, [], "Answer chosen with no text says nothing")
        let payload = DeckAnswersPayload(deck: deck, answers: answers, completedAt: morning)
        XCTAssertEqual(payload.answers.map(\.card), ["advisor", "followup-3", "book"])
        XCTAssertEqual(payload.answers[0].text, "Ship it.")
    }

    func testMessageNamesTheFileAndCommandAndCarriesSnakeCaseJSON() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        let payload = DeckAnswersPayload(deck: deck, answers: ["advisor": DeckAnswer(card: "advisor", text: "Ship it.")], completedAt: morning)
        let message = try payload.message()
        XCTAssertTrue(message.contains("briefs/2026-10-04.morning.answers.json"))
        XCTAssertTrue(message.contains("`bin/brain brief file 2026-10-04 morning`"))
        let json = try XCTUnwrap(message.components(separatedBy: "```json\n").last?.components(separatedBy: "\n```").first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNotNil(object["completed_at"])
        XCTAssertEqual((object["answers"] as? [[String: Any]])?.first?["text"] as? String, "Ship it.")
    }

    // MARK: - Store

    func testStoreIsPerServerAndRemoveClearsOnlyThatServer() {
        store.setWorkspace("/vault", for: server)
        store.setSession("s1", for: server, date: "2026-10-04")
        store.setWorkspace("/elsewhere", for: otherServer)

        XCTAssertEqual(store.session(for: server, date: "2026-10-04"), "s1")
        XCTAssertNil(store.session(for: otherServer, date: "2026-10-04"))

        store.remove(for: server)
        XCTAssertNil(store.workspace(for: server))
        XCTAssertNil(store.session(for: server, date: "2026-10-04"))
        XCTAssertEqual(store.workspace(for: otherServer), "/elsewhere")
    }

    func testStoreKeepsDraftsPerDeckForAWeekAndOneDaysSession() {
        store.setAnswers(["a": DeckAnswer(card: "a", text: "x")], for: server, date: "2026-10-03", kind: "morning")
        store.setAnswers(["b": DeckAnswer(card: "b", text: "y")], for: server, date: "2026-10-04", kind: "morning")
        XCTAssertEqual(store.answers(for: server, date: "2026-10-03", kind: "morning")["a"]?.text, "x")
        XCTAssertEqual(store.answers(for: server, date: "2026-10-04", kind: "morning")["b"]?.text, "y")

        for day in 5...12 {
            store.setAnswers(["c": DeckAnswer(card: "c", text: "\(day)")], for: server, date: String(format: "2026-10-%02d", day), kind: "morning")
        }
        XCTAssertEqual(store.answers(for: server, date: "2026-10-05", kind: "morning"), [:], "older than the last 7 decks")
        XCTAssertEqual(store.answers(for: server, date: "2026-10-12", kind: "morning")["c"]?.text, "12")

        store.setSession("s3", for: server, date: "2026-10-03")
        store.setSession("s4", for: server, date: "2026-10-04")
        XCTAssertNil(store.session(for: server, date: "2026-10-03"))
    }

    // MARK: - View model

    @MainActor
    func testFirstLoadAdoptsTheOnlyWorkspaceCreatesANamedSessionAndShowsTheDeck() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        let viewModel = makeViewModel(client)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(viewModel.cards.count, 7)
        XCTAssertEqual(client.createdWorkspaces, ["/vault"])
        XCTAssertEqual(client.renamed.first?.0, "new-1")
        XCTAssertTrue(client.renamed.first?.1.hasPrefix("Daily Brief · ") == true)
        XCTAssertEqual(store.workspace(for: server), "/vault")
        XCTAssertEqual(store.session(for: server, date: "2026-10-04"), "new-1")
    }

    @MainActor
    func testSeveralWorkspacesAskTheUserToChoose() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/a", "/b"], names: [], deck: Self.deckJSON)
        let viewModel = makeViewModel(client)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .needsWorkspace(["/a", "/b"]))
        XCTAssertTrue(client.createdWorkspaces.isEmpty)
    }

    @MainActor
    func testRemembersTodaysSessionAndReplacesItOnceWhenTheServerLostIt() async {
        store.setWorkspace("/vault", for: server)
        store.setSession("gone", for: server, date: "2026-10-04")
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        client.vanished = ["gone"]
        let viewModel = makeViewModel(client)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(client.listedSessions, ["gone", "new-1"])
        XCTAssertEqual(store.session(for: server, date: "2026-10-04"), "new-1")
    }

    @MainActor
    func testMissingFolderOrDeckIsNoDeckAndAnAnswersFileIsFiled() async {
        store.setWorkspace("/vault", for: server)

        let noFolder = ScriptedDailyDeckClient(workspaces: [], names: nil, deck: Self.deckJSON)
        let first = makeViewModel(noFolder)
        await first.load()
        XCTAssertEqual(first.state, .noDeck)

        let otherDay = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-03.morning.json"], deck: Self.deckJSON)
        let second = makeViewModel(otherDay)
        await second.load()
        XCTAssertEqual(second.state, .noDeck)

    }

    @MainActor
    func testAFiledDeckReopensWithItsAnswersAndTracksEdits() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json", "2026-10-04.morning.answers.json"], deck: Self.deckJSON)
        client.files["briefs/2026-10-04.morning.answers.json"] = """
        {"version": 1, "date": "2026-10-04", "kind": "morning", "completed_at": "x",
         "answers": [{"card": "advisor", "text": "Ship it."}, {"card": "followup-3", "action": "skip"}]}
        """
        let viewModel = makeViewModel(client)
        await viewModel.load()

        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertTrue(viewModel.isFiled)
        XCTAssertFalse(viewModel.hasChanges)
        XCTAssertEqual(viewModel.answer(for: viewModel.cards[1])?.text, "Ship it.")

        viewModel.setText("Ship it today.", for: viewModel.cards[1])
        XCTAssertTrue(viewModel.hasChanges)
        viewModel.setText("Ship it.", for: viewModel.cards[1])
        XCTAssertFalse(viewModel.hasChanges, "back to what was filed")

        viewModel.setText("Ship it today.", for: viewModel.cards[1])
        let reopened = makeViewModel(client)
        await reopened.load()
        XCTAssertEqual(reopened.answer(for: reopened.cards[1])?.text, "Ship it today.", "unsent edits win over the filed copy")

        _ = await reopened.file()
        XCTAssertTrue(client.sent.last?.message.hasPrefix("File my edits to the 2026-10-04 morning brief") == true)
        XCTAssertFalse(reopened.hasChanges)
    }

    @MainActor
    func testPastDaysAreListedNewestFirstAndOpenable() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: [
            "2026-10-02.morning.json", "2026-10-04.morning.json", "2026-10-03.morning.json",
            "2026-10-03.morning.answers.json", "2026-10-03.morning.filed.json", "notes.md"
        ], deck: Self.deckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        XCTAssertEqual(viewModel.availableDates, ["2026-10-04", "2026-10-03", "2026-10-02"])
        XCTAssertFalse(viewModel.isFiled)

        await viewModel.show(date: "2026-10-03")
        XCTAssertEqual(viewModel.date, "2026-10-03")
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertTrue(viewModel.isFiled)
        XCTAssertEqual(client.listedSessions, ["new-1", "new-1"], "the reading session is reused for other days")
        XCTAssertTrue(client.readPaths.contains("briefs/2026-10-03.morning.answers.json"))
    }

    @MainActor
    func testAnswersSurviveANewViewModelAndToggleOff() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        let decision = viewModel.cards[2], answer = decision.actions[0], skip = decision.actions[1]

        viewModel.choose(answer, for: decision)
        XCTAssertEqual(viewModel.answeredCount, 0, "Answer with no text says nothing yet")
        viewModel.setText("Enough as-is.", for: decision)
        XCTAssertEqual(viewModel.answeredCount, 1)
        viewModel.choose(skip, for: decision)
        XCTAssertNil(viewModel.answer(for: decision)?.text, "Skip drops the typed answer")
        viewModel.choose(skip, for: decision)  // second tap clears it
        XCTAssertNil(viewModel.answer(for: decision))
        viewModel.setText("Still true.", for: viewModel.cards[3])

        let reopened = makeViewModel(client)
        await reopened.load()
        XCTAssertEqual(reopened.answer(for: reopened.cards[3])?.text, "Still true.")
    }

    func testFollowUpsShareOnePageWhereTheFirstOneSat() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        let extra = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"a","type":"prompt"},{"id":"f1","type":"decision"},{"id":"b","type":"reflect"},{"id":"f2","type":"decision"},{"id":"close","type":"close"}]}"#)
        XCTAssertEqual(DeckPage.pages(for: extra.cards).map(\.id), ["a", "followups-f1", "b", "close"])
        guard case .followUps(let cards) = DeckPage.pages(for: extra.cards)[1] else { return XCTFail("Expected follow-ups") }
        XCTAssertEqual(cards.map(\.id), ["f1", "f2"])
        XCTAssertEqual(DeckPage.pages(for: deck.cards).count, deck.cards.count)
    }

    @MainActor
    func testFilingSendsOneMessageInAFreshSessionAndClearsTheDraft() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: viewModel.cards[1])

        let opened = await viewModel.file()

        XCTAssertEqual(opened, "new-2", "Filing gets its own session, not the one that read the deck")
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertTrue(viewModel.isFiled, "the filed deck stays open to reread")
        XCTAssertEqual(client.sent.map(\.sessionID), ["new-2"])
        XCTAssertEqual(store.session(for: server, date: "2026-10-04"), "new-2")
        XCTAssertEqual(viewModel.sessionID, "new-2")
        XCTAssertEqual(client.sent.first?.workspace, "/vault")
        XCTAssertTrue(client.sent.first?.message.contains("\"text\" : \"Ship it.\"") == true)
        XCTAssertEqual(store.answers(for: server, date: "2026-10-04", kind: "morning"), [:])
    }

    @MainActor
    func testFailedFilingKeepsTheAnswersAndReportsTheError() async {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        client.sendError = APIError.http(statusCode: 500, body: nil)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: viewModel.cards[1])

        let opened = await viewModel.file()

        XCTAssertNil(opened)
        XCTAssertEqual(viewModel.state, .ready)
        guard case .failed = viewModel.filing else { return XCTFail("Expected a failed filing") }
        XCTAssertEqual(store.answers(for: server, date: "2026-10-04", kind: "morning")["advisor"]?.text, "Ship it.")
    }

    // MARK: - Not for Me and questions

    func testDecodesReasonAndAlternativeQuestions() throws {
        let deck = try DailyDeck.decode(Self.feedbackDeckJSON)
        XCTAssertEqual(deck.cards[1].reason, "Fits today's thread")
        XCTAssertEqual(deck.cards[1].altQuestions, ["Second?", "Third?"])
        XCTAssertEqual(deck.cards[2].altQuestions, [])
        XCTAssertEqual(deck.cards.map(\.takesFeedback), [false, true, true, false])
    }

    @MainActor
    func testRegenerateStepsThroughTheQuestionsAndWrapsBackToTheCardsOwn() async throws {
        let viewModel = try await loadedViewModel(Self.feedbackDeckJSON)
        let card = viewModel.cards[1]

        viewModel.regenerateQuestion(for: card)
        XCTAssertEqual(viewModel.question(for: card), "Second?")
        viewModel.regenerateQuestion(for: card)
        XCTAssertEqual(viewModel.question(for: card), "Third?")
        viewModel.regenerateQuestion(for: card)
        XCTAssertEqual(viewModel.question(for: card), "First?")
        XCTAssertNil(viewModel.answer(for: card), "back to the card's own question leaves nothing to file")
    }

    @MainActor
    func testOwnQuestionIsFiledWithTheAnswerAndClearsWhenEmpty() async throws {
        let viewModel = try await loadedViewModel(Self.feedbackDeckJSON)
        let card = viewModel.cards[2]

        viewModel.setOwnQuestion("  What would I build?  ", for: card)
        XCTAssertEqual(viewModel.question(for: card), "What would I build?")
        XCTAssertEqual(viewModel.answeredCount, 0, "a question alone isn't an answer")
        viewModel.setText("A running app.", for: card)
        let payload = DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: ["wiki": try XCTUnwrap(viewModel.answer(for: card))], completedAt: morning)
        XCTAssertEqual(payload.answers.first?.question, "What would I build?")

        viewModel.setOwnQuestion(" ", for: card)
        XCTAssertEqual(viewModel.question(for: card), "Own?")
    }

    @MainActor
    func testNotForMeHidesTheCardFilesTheFeedbackAndUndoBringsItBack() async throws {
        let viewModel = try await loadedViewModel(Self.feedbackDeckJSON)
        let book = viewModel.cards[1]
        viewModel.index = 1
        viewModel.setText("Half a thought", for: book)

        viewModel.dismiss(book, feedback: DeckFeedback(verdict: .less, reasons: ["topic"], note: "  stale  "))

        XCTAssertEqual(viewModel.visiblePages.map(\.id), ["headline", "wiki", "close"])
        XCTAssertEqual(viewModel.currentPage?.id, "wiki", "the next card takes its place")
        XCTAssertEqual(viewModel.skippedCount, 1)
        XCTAssertEqual(viewModel.answeredCount, 1, "its text is kept")
        let feedback = try XCTUnwrap(viewModel.answer(for: book)?.feedback)
        XCTAssertEqual(feedback, DeckFeedback(verdict: .less, reasons: ["topic"], note: "stale"))
        let message = try DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: ["book": try XCTUnwrap(viewModel.answer(for: book))], completedAt: morning).message()
        XCTAssertTrue(message.contains("\"verdict\" : \"less\""))

        viewModel.undoDismissal()
        XCTAssertNil(viewModel.lastDismissal)
        XCTAssertEqual(viewModel.currentPage?.id, "book")
        XCTAssertEqual(viewModel.answer(for: book), DeckAnswer(card: "book", text: "Half a thought"))
    }

    @MainActor
    func testFeedbackAloneIsFiledAndRestoreSkippedBringsEveryCardBack() async throws {
        let viewModel = try await loadedViewModel(Self.feedbackDeckJSON)
        viewModel.index = 2
        viewModel.dismiss(viewModel.cards[2], feedback: DeckFeedback(verdict: .skip))
        XCTAssertEqual(viewModel.currentPage?.id, "close", "dismissing the last card before close lands on close")
        viewModel.dismiss(viewModel.cards[1], feedback: DeckFeedback(verdict: .skip))
        XCTAssertEqual(viewModel.answeredCount, 0)
        XCTAssertTrue(viewModel.hasChanges)
        let payload = DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: viewModel.answers, completedAt: morning)
        XCTAssertEqual(payload.answers.map(\.card), ["book", "wiki"])

        viewModel.restoreSkipped()
        XCTAssertEqual(viewModel.skippedCount, 0)
        XCTAssertEqual(viewModel.visiblePages.count, 4)
        XCTAssertEqual(viewModel.answers, [:])
    }

    @MainActor
    private func loadedViewModel(_ json: String) async throws -> DailyDeckViewModel {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: json)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .ready)
        return viewModel
    }

    static let feedbackDeckJSON = """
    {"date": "2026-10-04", "kind": "morning", "cards": [
      {"id": "headline", "type": "headline", "title": "Rest is part of the training"},
      {"id": "book", "type": "reflect", "kind": "book", "title": "Four Thousand Weeks", "body": "A quote.",
       "question": "First?", "alt_questions": ["Second?", "Third?"], "reason": "Fits today's thread"},
      {"id": "wiki", "type": "reflect", "kind": "on_this_day", "title": "Oct 8, 2025", "question": "Own?"},
      {"id": "close", "type": "close"}
    ]}
    """

    // MARK: - Journal calendar

    func testMonthGridPadsToTheFirstWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1  // Sunday
        let grid = DailyDeckJournal.grid(year: 2026, month: 10, calendar: calendar)  // Oct 1 2026 is a Thursday
        XCTAssertEqual(grid.prefix(5).map { $0 }, [nil, nil, nil, nil, 1])
        XCTAssertEqual(grid.compactMap { $0 }.count, 31)
        calendar.firstWeekday = 2  // Monday
        XCTAssertEqual(DailyDeckJournal.grid(year: 2026, month: 10, calendar: calendar).prefix(4).map { $0 }, [nil, nil, nil, 1])
    }

    func testReadableEntryDropsFrontMatterAndAgentMarkers() {
        let text = "---\ntype: journal\n---\n# 2026-10-05\n\n<!-- brain:briefing generated=x -->\nGood morning.\n<!-- brain:deck 2026-10-05 morning -->\n- Ship it."
        XCTAssertEqual(DailyDeckJournal.readable(text), "# 2026-10-05\n\nGood morning.\n- Ship it.")
    }

    func testFiledDaysComeFromAnswersFiles() {
        XCTAssertEqual(DailyDeckViewModel.filedDates(in: ["2026-10-04.morning.json", "2026-10-04.morning.answers.json",
                                                         "2026-10-05.morning.json", "2026-10-05.morning.filed.json"], kind: "morning"),
                       ["2026-10-04"])
    }

    @MainActor
    func testJournalDaysFindTheMonthFolderAndEntry() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        client.listings["journal/2026"] = ["03-March", "10-October"]
        client.listings["journal/2026/10-October"] = ["2026-10-01.md", "2026-10-04.md", "notes.txt"]
        client.files["journal/2026/10-October/2026-10-04.md"] = "# 2026-10-04\n<!-- brain:deck x -->\n- Ran."
        let viewModel = makeViewModel(client)
        await viewModel.load()

        let days = await viewModel.journalDays(year: 2026, month: 10)
        XCTAssertEqual(days, ["2026-10-01", "2026-10-04"])
        let none = await viewModel.journalDays(year: 2026, month: 11)
        XCTAssertEqual(none, [])
        let entry = try await viewModel.journalEntry(for: "2026-10-04")
        XCTAssertEqual(entry, "# 2026-10-04\n- Ran.")
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(_ client: ScriptedDailyDeckClient) -> DailyDeckViewModel {
        let now = morning
        return DailyDeckViewModel(server: server, client: client, store: store, now: { now })
    }

    static let deckJSON = """
    {"version": 1, "date": "2026-10-04", "kind": "morning", "generated_at": "2026-10-04T08:00:00-04:00",
     "advisor": "Ted", "future_field": {"x": 1},
     "cards": [
      {"id": "headline", "type": "headline", "title": "Sun, Oct 4", "lines": ["Advisor: Ted"]},
      {"id": "advisor", "type": "prompt", "voice": "Ted", "context": "Believe.", "question": "What is the one action today?", "files_to": "thoughts"},
      {"id": "followup-3", "type": "decision", "ref": {"followup": 3, "key": "thread:b"}, "title": "Install it?",
       "actions": [{"id": "answer", "label": "Answer", "input": "text"}, {"id": "skip", "label": "Skip", "command": "skip 3"}]},
      {"id": "media-1", "type": "reflect", "ref": {"link": "x"}, "title": "Mental load", "question": "What do you think now?"},
      {"id": "book", "type": "item", "kind": "book", "title": "A Book", "body": "A quote."},
      {"id": "poll", "type": "poll", "fallback": "A newer card"},
      {"id": "close", "type": "close"}
     ]}
    """
}

/// A scripted server: one workspace list, one `briefs/` listing, one deck body.
final class ScriptedDailyDeckClient: DailyDeckDataClient, @unchecked Sendable {
    struct Sent { let sessionID: String; let message: String; let workspace: String }

    let workspaces: [String]
    /// Names in `briefs/`; nil means the folder is missing (404).
    let names: [String]?
    let deck: String
    var vanished: Set<String> = []
    var sendError: Error?
    /// Bodies by path; anything else reads as `deck`.
    var files: [String: String] = [:]
    /// Folder listings other than `briefs/`.
    var listings: [String: [String]] = [:]
    private(set) var createdWorkspaces: [String] = []
    private(set) var renamed: [(String, String)] = []
    private(set) var listedSessions: [String] = []
    private(set) var readPaths: [String] = []
    private(set) var sent: [Sent] = []

    init(workspaces: [String], names: [String]?, deck: String) {
        self.workspaces = workspaces
        self.names = names
        self.deck = deck
    }

    func workspacePaths() async throws -> [String] { workspaces }

    func createSession(workspace: String) async throws -> String {
        createdWorkspaces.append(workspace)
        return "new-\(createdWorkspaces.count)"
    }

    func renameSession(id: String, title: String) async throws { renamed.append((id, title)) }

    func entryNames(sessionID: String, path: String) async throws -> [String] {
        if let listing = listings[path] { return listing }
        if path != DailyDeckPaths.directory { throw APIError.http(statusCode: 404, body: #"{"error": "Not a directory"}"#) }
        listedSessions.append(sessionID)
        if vanished.contains(sessionID) { throw APIError.http(statusCode: 404, body: #"{"error": "Session not found"}"#) }
        guard let names else { throw APIError.http(statusCode: 404, body: #"{"error": "Not a directory"}"#) }
        return names
    }

    func fileContent(sessionID: String, path: String) async throws -> String {
        readPaths.append(path)
        return files[path] ?? deck
    }

    func startChat(sessionID: String, message: String, workspace: String) async throws {
        if let sendError { throw sendError }
        sent.append(Sent(sessionID: sessionID, message: message, workspace: workspace))
    }
}
