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

    func testGoalCardDecodes() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"d","kind":"morning","cards":[
          {"id":"goal","type":"goal","goals":["nyc-marathon-2026"],"color":"wiki","fallback":"Nightly stretch 2/6","extra":1},
          {"id":"goal-2","type":"goal","goals":"nope"}]}
        """#)
        let card = deck.cards[0]
        XCTAssertEqual(card.type, .goal)
        XCTAssertEqual(card.goals, ["nyc-marathon-2026"])
        XCTAssertEqual(card.fallback, "Nightly stretch 2/6")
        XCTAssertTrue(card.takesText)
        XCTAssertFalse(card.takesFeedback)
        XCTAssertEqual(deck.cards[1].goals, [])
        XCTAssertEqual(DeckPalette.of(card).name, "Goals")
    }

    func testWeekAheadCardDecodesItsCommitmentsAndLastWeek() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"2026-10-18","kind":"weekly","cards":[
          {"id":"week-career","type":"week_ahead","goal":"career","title":"Next week · Land an AI role","color":"wiki",
           "start":"2026-10-19","fallback":"Next week: Outreach 6",
           "commitments":[{"id":"outreach","action":"Outreach","target":6,"skips":0,"unit":"item","was":5,
                           "reason":"Hit twice.","extra":{"x":1}},
                          {"action":"No id"},
                          {"id":"prep","action":"Prep session","target":5,"skips":1,"unit":"day","source":"prep.days",
                           "days":["mon"]}],
           "last_week":[{"id":"outreach","action":"Outreach","target":5,"skips":0,"unit":"item"}]}]}
        """#)
        let card = try XCTUnwrap(deck.cards.first)
        XCTAssertEqual(card.type, .weekAhead)
        XCTAssertEqual(card.goal, "career")
        XCTAssertEqual(card.start, "2026-10-19")
        XCTAssertEqual(card.weekCommitments.map(\.id), ["outreach", "prep"], "a malformed commitment is dropped alone")
        XCTAssertEqual(card.weekCommitments[0].was, 5)
        XCTAssertEqual(card.weekCommitments[0].reason, "Hit twice.")
        XCTAssertEqual(card.weekCommitments[1].source, "prep.days")
        XCTAssertEqual(card.weekCommitments[1].days, ["mon"])
        XCTAssertNil(card.weekCommitments[1].was)
        XCTAssertEqual(card.lastWeek.map(\.target), [5])
        XCTAssertFalse(card.takesFeedback)
        XCTAssertFalse(card.takesText)
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
    func testMissingFolderOrDeckIsNoDeck() async {
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

    /// A follow-up with a contact's number: "Text Sina" opens the phone's Messages sheet; only a
    /// sent text answers the card, and filing carries it to the server with no chat.
    @MainActor
    func testTextedFollowUpAnswersOnlyOnceSentAndFilesWithoutAChat() async throws {
        let deckJSON = #"{"date":"2026-10-04","kind":"morning","cards":[{"id":"followup-5","type":"decision","title":"Sina","ref":{"followup":5,"person":"Sina"},"actions":[{"id":"text","label":"Text Sina","message":{"to":"+15550001111","body":" Yo! How've you been? "}},{"id":"skip","label":"Not now"}]},{"id":"close","type":"close"}]}"#
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: deckJSON)
        client.filer = .success(BriefFileResponse(ok: true, summary: "Filed.", ran: [.init(step: "touch 5", ok: true)], agentSteps: []))
        let viewModel = makeViewModel(client)
        await viewModel.load()
        let card = viewModel.cards[0], text = try XCTUnwrap(card.actions.first)
        XCTAssertEqual(text.message, DeckMessage(to: "+15550001111", body: " Yo! How've you been? "))
        XCTAssertNil(viewModel.answer(for: card), "nothing is recorded until Messages reports the text went out")

        viewModel.markTexted(text, for: card)
        XCTAssertEqual(viewModel.answer(for: card)?.action, "text")
        XCTAssertEqual(viewModel.answer(for: card)?.text, "Yo! How've you been?")
        XCTAssertEqual(viewModel.answeredCount, 1)

        let result = await viewModel.file()
        XCTAssertEqual(result, .filed, "the vault logs the contact itself; no follow-up chat")
        XCTAssertTrue(client.sent.isEmpty)
        let answer = try XCTUnwrap(client.fileRequests.first?.answers.answers.first)
        XCTAssertEqual(answer.action, "text")
        XCTAssertEqual(answer.text, "Yo! How've you been?")
    }

    /// Words edited on the card are what the sheet opened with, so they're what filing records.
    @MainActor
    func testTextedFollowUpRecordsTheEditedWords() async throws {
        let deckJSON = #"{"date":"2026-10-04","kind":"morning","cards":[{"id":"followup-5","type":"decision","title":"Sina","ref":{"followup":5,"person":"Sina"},"actions":[{"id":"text","label":"Text Sina","message":{"to":"+15550001111","body":"Yo!"}}]},{"id":"close","type":"close"}]}"#
        store.setWorkspace("/vault", for: server)
        let viewModel = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: deckJSON))
        await viewModel.load()
        let card = viewModel.cards[0], text = try XCTUnwrap(card.actions.first)

        viewModel.markTexted(text, body: " Yo! Coffee Saturday? ", for: card)

        XCTAssertEqual(viewModel.answer(for: card)?.text, "Yo! Coffee Saturday?")
        XCTAssertEqual(viewModel.answer(for: card)?.action, "text")
    }

    func testTextActionWithoutABodyOrWithABadMessageStillDecodes() throws {
        let deck = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"f","type":"decision","actions":[{"id":"text","label":"Text Pat","message":{"to":"pat@example.com"}},{"id":"broken","label":"Broken","message":{"body":"no recipient"}},{"id":"skip","label":"Not now"}]}]}"#)
        let actions = try XCTUnwrap(deck.cards.first?.actions)
        XCTAssertEqual(actions.map(\.id), ["text", "skip"], "an action with a malformed message drops only itself")
        XCTAssertEqual(actions[0].message, DeckMessage(to: "pat@example.com", body: nil))
        XCTAssertNil(actions[1].message)
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

        XCTAssertEqual(client.fileRequests.count, 1, "the server filer is tried first")
        XCTAssertEqual(opened, .openSession("new-2"), "Filing gets its own session, not the one that read the deck")
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

    @MainActor
    func testServerFilerFilesWithoutAChatAndShowsItsReport() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        client.filer = .success(BriefFileResponse(
            ok: true, summary: " Filed 1 answer to the journal. ",
            ran: [.init(step: "journal", ok: true), .init(step: "goals", ok: false, error: "goals/ missing")],
            agentSteps: ["  "]))
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: viewModel.cards[1])

        let result = await viewModel.file()

        XCTAssertEqual(result, .filed)
        XCTAssertEqual(client.createdWorkspaces, ["/vault"], "only the reading session; filing opens no chat")
        XCTAssertTrue(client.sent.isEmpty)
        let request = try XCTUnwrap(client.fileRequests.first)
        XCTAssertEqual(request.date, "2026-10-04")
        XCTAssertEqual(request.kind, "morning")
        XCTAssertEqual(request.answers.answers.map(\.text), ["Ship it."])
        XCTAssertTrue(viewModel.isFiled)
        XCTAssertFalse(viewModel.hasChanges)
        XCTAssertEqual(viewModel.filing, .idle)
        XCTAssertEqual(viewModel.filedNote, DailyDeckFiledNote(summary: "Filed 1 answer to the journal.", failures: ["goals: goals/ missing"]))
        XCTAssertEqual(store.answers(for: server, date: "2026-10-04", kind: "morning"), [:])
    }

    @MainActor
    func testServerFilerWithAgentStepsOpensASessionForTheFollowUpsOnly() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        client.filer = .success(BriefFileResponse(ok: true, summary: "Filed.", agentSteps: ["Install the plugin", "Email Sam"]))
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: viewModel.cards[1])

        let result = await viewModel.file()

        XCTAssertEqual(result, .openSession("new-2"))
        XCTAssertEqual(client.sent.map(\.sessionID), ["new-2"])
        XCTAssertEqual(client.sent.first?.message, """
        Finish filing the 2026-10-04 morning brief. Do these follow-up steps in order, per followups/AGENTS.md:
        - Install the plugin
        - Email Sam
        """)
        XCTAssertTrue(viewModel.isFiled)
        XCTAssertEqual(store.session(for: server, date: "2026-10-04"), "new-2")
    }

    @MainActor
    func testServerFilerErrorFailsWithoutFallingBackToTheAgent() async {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        client.filer = .failure(BriefFileError(message: "Filing failed: bad kind"))
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: viewModel.cards[1])

        let result = await viewModel.file()

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.filing, .failed("Filing failed: bad kind"))
        XCTAssertTrue(client.sent.isEmpty, "no second filing through the agent")
        XCTAssertEqual(client.createdWorkspaces, ["/vault"])
        XCTAssertFalse(viewModel.isFiled)
        XCTAssertEqual(store.answers(for: server, date: "2026-10-04", kind: "morning")["advisor"]?.text, "Ship it.")
    }

    @MainActor
    func testServerFilerReportingNotOKFails() async {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        client.filer = .success(BriefFileResponse(ok: false, error: "journal locked"))
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: viewModel.cards[1])

        let result = await viewModel.file()

        XCTAssertNil(result)
        XCTAssertEqual(viewModel.filing, .failed("journal locked"))
        XCTAssertTrue(client.sent.isEmpty)
        XCTAssertFalse(viewModel.isFiled)
    }

    /// Holds the next filing at the server until `release` is called; `reached` is fulfilled once it gets there.
    private func holdFiling(_ client: ScriptedDailyDeckClient) -> (reached: XCTestExpectation, release: () -> Void) {
        let reached = expectation(description: "filing reached the server")
        let (gate, open) = AsyncStream<Void>.makeStream()
        client.fileGate = {
            reached.fulfill()
            for await _ in gate { break }
        }
        return (reached, { open.finish() })
    }

    @MainActor
    func testTextTypedWhileFilingStaysUnsent() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        client.filer = .success(BriefFileResponse(ok: true, summary: "Filed."))
        let viewModel = makeViewModel(client)
        await viewModel.load()
        let advisor = viewModel.cards[1]
        viewModel.setText("Ship it.", for: advisor)
        let (reached, release) = holdFiling(client)

        let filing = Task { await viewModel.file() }
        await fulfillment(of: [reached], timeout: 5)
        viewModel.setText("Ship it today.", for: advisor)
        release()
        let result = await filing.value

        XCTAssertEqual(result, .filed)
        XCTAssertEqual(client.fileRequests.first?.answers.answers.map(\.text), ["Ship it."])
        XCTAssertEqual(viewModel.filedAnswers?["advisor"]?.text, "Ship it.", "only what was sent is filed")
        XCTAssertTrue(viewModel.hasChanges, "the later edit still needs filing")
        XCTAssertEqual(store.answers(for: server, date: "2026-10-04", kind: "morning")["advisor"]?.text, "Ship it today.")
    }

    @MainActor
    func testOpeningAnotherDayWhileFilingLeavesThatDayAlone() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-03.morning.json", "2026-10-04.morning.json"], deck: Self.deckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: viewModel.cards[1])
        store.setAnswers(["book": DeckAnswer(card: "book", text: "Yesterday's draft.")], for: server, date: "2026-10-03", kind: "morning")
        let (reached, release) = holdFiling(client)

        let filing = Task { await viewModel.file() }
        await fulfillment(of: [reached], timeout: 5)
        await viewModel.show(date: "2026-10-03")
        release()
        let result = await filing.value

        XCTAssertEqual(result, .openSession("new-2"))
        XCTAssertEqual(client.renamed.last?.1, DailyDeckViewModel.sessionTitle(for: "2026-10-04"), "the session is named for the filed day")
        XCTAssertEqual(viewModel.date, "2026-10-03")
        XCTAssertFalse(viewModel.isFiled, "the day on screen was not filed")
        XCTAssertEqual(viewModel.answer(for: viewModel.cards[4])?.text, "Yesterday's draft.")
        XCTAssertEqual(store.answers(for: server, date: "2026-10-03", kind: "morning")["book"]?.text, "Yesterday's draft.")
        XCTAssertEqual(store.answers(for: server, date: "2026-10-04", kind: "morning"), [:], "the filed day's draft is cleared")
        XCTAssertEqual(viewModel.filing, .idle)
    }

    @MainActor
    func testReturningOnANewDayMovesTodaysBriefForward() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json", "2026-10-05.morning.json"], deck: Self.deckJSON)
        let clock = TestDeckClock(morning)
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store, now: { clock.now })
        await viewModel.load()
        let reads = client.readPaths.count

        await viewModel.refreshDay()
        XCTAssertEqual(client.readPaths.count, reads, "same day: nothing reloads")

        clock.now = morning.addingTimeInterval(24 * 60 * 60)
        await viewModel.refreshDay()

        XCTAssertEqual(viewModel.today, "2026-10-05")
        XCTAssertEqual(viewModel.date, "2026-10-05")
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(client.readPaths.last, "briefs/2026-10-05.morning.json")
    }

    @MainActor
    func testReturningOnANewDayKeepsAPastDayTheUserOpened() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-03.morning.json", "2026-10-04.morning.json"], deck: Self.deckJSON)
        let clock = TestDeckClock(morning)
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store, now: { clock.now })
        await viewModel.load()
        await viewModel.show(date: "2026-10-03")
        let reads = client.readPaths.count

        clock.now = morning.addingTimeInterval(24 * 60 * 60)
        await viewModel.refreshDay()

        XCTAssertEqual(viewModel.today, "2026-10-05")
        XCTAssertEqual(viewModel.date, "2026-10-03")
        XCTAssertEqual(client.readPaths.count, reads)
    }

    func testOneMalformedCardActionOrAnswerDropsOnlyItself() throws {
        let deck = try DailyDeck.decode("""
        {"date": "d", "kind": "morning", "cards": [
          {"id": "a", "type": "prompt"},
          {"type": "item", "title": "no id"},
          "not a card",
          {"id": "f", "type": "decision", "actions": [
            {"id": "answer", "label": "Answer", "input": "text"}, {"label": "no id"}, {"id": "skip", "label": "Skip"}]},
          {"id": "close", "type": "close"}
        ]}
        """)
        XCTAssertEqual(deck.cards.map(\.id), ["a", "f", "close"])
        XCTAssertEqual(deck.cards[1].actions.map(\.id), ["answer", "skip"])

        let answers = DeckAnswersFile.decodeAnswers("""
        {"version": 1, "answers": [
          {"card": "a", "text": "Ship it."},
          {"card": "b", "feedback": {"verdict": "meh"}},
          {"text": "no card"},
          {"card": "c", "feedback": {"verdict": "less"}}
        ]}
        """)
        XCTAssertEqual(answers.keys.sorted(), ["a", "c"])
        XCTAssertEqual(answers["a"]?.text, "Ship it.")
        XCTAssertEqual(answers["c"]?.feedback, DeckFeedback(verdict: .less), "missing reasons read as none")
    }

    func testBriefFileRequestCarriesTheAnswersPayloadInSnakeCase() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        let payload = DeckAnswersPayload(deck: deck, answers: ["advisor": DeckAnswer(card: "advisor", text: "Ship it.")], completedAt: morning)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(BriefFileRequest(date: payload.date, kind: payload.kind, answers: payload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["date"] as? String, "2026-10-04")
        XCTAssertEqual(object["kind"] as? String, "morning")
        let answers = try XCTUnwrap(object["answers"] as? [String: Any])
        XCTAssertNotNil(answers["completed_at"])
        XCTAssertEqual((answers["answers"] as? [[String: Any]])?.first?["text"] as? String, "Ship it.")
    }

    // MARK: - Card text

    func testCardsLeadWithTheQuoteOrTakeawayAndScrollIntoTheRest() throws {
        let deck = try DailyDeck.decode("""
        {"date": "d", "kind": "morning", "cards": [
          {"id": "q", "type": "reflect", "kind": "quote", "title": "Seneca", "body": "We suffer more in imagination.", "source": "Letters"},
          {"id": "b", "type": "reflect", "kind": "book", "title": "Outlive", "body": "Deep foundations.", "source": "Outlive by Peter Attia", "context": "Stability first."},
          {"id": "w", "type": "reflect", "kind": "wiki", "title": "Atomic Habits", "body": "Habits. Results are lagging measures of your inputs. Systems beat goals.", "why": "habit work"},
          {"id": "p", "type": "prompt", "voice": "Ted", "context": "Long check-in.", "question": "What is the one action?"},
          {"id": "e", "type": "reflect", "kind": "insight", "title": "Preparation shows respect"}
        ]}
        """)
        let quote = DeckCardText(deck.cards[0])
        XCTAssertEqual(quote.lead, "We suffer more in imagination.")
        XCTAssertEqual(quote.attribution, "Seneca, Letters")
        let book = DeckCardText(deck.cards[1])
        XCTAssertEqual(book.lead, "“Deep foundations.”")
        XCTAssertEqual(book.attribution, "Outlive by Peter Attia")
        XCTAssertEqual(book.detail, "Stability first.")
        let wiki = DeckCardText(deck.cards[2])
        XCTAssertEqual(wiki.lead, "Habits. Results are lagging measures of your inputs.", "a fragment pulls in the next sentence")
        XCTAssertEqual(wiki.attribution, "Atomic Habits")
        XCTAssertEqual(wiki.detail, "Systems beat goals.\n\nWhy you saved it: habit work")
        let prompt = DeckCardText(deck.cards[3])
        XCTAssertEqual(prompt.lead, "Long check-in.", "the advisor's whole message leads")
        XCTAssertEqual(prompt.attribution, "Ted")
        XCTAssertFalse(prompt.leadIsQuestion)
        XCTAssertEqual(DeckCardText(deck.cards[4]).lead, "Preparation shows respect", "no body: the title leads")
    }

    func testRecapEntriesDecodeAndReplaceThePlainBody() throws {
        let deck = try DailyDeck.decode(#"{"date":"d","kind":"weekly","cards":[{"id":"r","type":"item","kind":"recap","title":"How the week went","body":"Mon: ran","entries":[{"label":"Mon, Oct 5","text":"Ran."},{"text":"Untitled item"},{"label":7}]}]}"#)
        XCTAssertEqual(deck.cards[0].entries.map(\.text), ["Ran.", "Untitled item"], "a malformed entry is dropped alone")
        let good = try DailyDeck.decode(#"{"date":"d","kind":"weekly","cards":[{"id":"r","type":"item","kind":"recap","title":"How the week went","body":"Mon: ran","entries":[{"label":"Mon, Oct 5","text":"Ran."},{"text":"Untitled item"}]}]}"#)
        XCTAssertEqual(good.cards[0].entries.map(\.label), ["Mon, Oct 5", nil])
        let text = DeckCardText(good.cards[0])
        XCTAssertEqual(text.lead, "How the week went")
        XCTAssertNil(text.detail, "the list replaces the plain copy")
    }

    func testWrappedCardsDecodeTheirHighlightsPointsAndMeters() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"d","kind":"weekly","cards":[
          {"id":"headline","type":"headline","title":"Your week","lines":["Weekly review"],"recap":"You tapered and slept more.","entries":[{"label":"Fri, Oct 9","text":"You slept nine hours."},{"label":3}]},
          {"id":"theme-1","type":"item","kind":"theme","title":"Taper and rest","context":"You slept more.","body":"You slept more.\nFri: quote","entries":[{"label":"Fri, Oct 9","text":"“Slept nine hours.”"}]},
          {"id":"mood","type":"item","kind":"mood","title":"Energy and mood","body":"Tue: 4","points":[{"label":"Mon","energy":null,"mood":null,"note":""},{"label":"Tue","energy":8,"mood":7,"sleep":7.4,"quote":"Felt strong.","note":"a strong run"},{"label":"Wed","energy":"high"}]},
          {"id":"goals","type":"item","kind":"goals","title":"Your goals","color":"wiki","body":"x","meters":[{"group":"Marathon","label":"Stretch","done":7,"target":6},{"label":"bad"}]}
        ]}
        """#)
        XCTAssertEqual(deck.cards[0].recap, "You tapered and slept more.")
        XCTAssertEqual(deck.cards[0].entries.map(\.text), ["You slept nine hours."], "a malformed highlight is dropped alone")
        XCTAssertEqual(deck.cards[2].points.map(\.energy), [nil, 8], "a malformed point is dropped alone")
        XCTAssertEqual(deck.cards[2].points[1].sleep, 7.4)
        XCTAssertEqual(deck.cards[2].points[1].quote, "Felt strong.")
        XCTAssertEqual(deck.cards[3].meters.count, 1)
        XCTAssertEqual(deck.cards[3].meters[0].fraction, 1, "a meter never overfills")

        let theme = DeckCardText(deck.cards[1])
        XCTAssertEqual(theme.lead, "Taper and rest")
        XCTAssertEqual(theme.detail, "You slept more.", "a theme's summary, not its plain copy")
        XCTAssertNil(DeckCardText(deck.cards[2]).detail, "the chart replaces the plain copy")
        XCTAssertNil(DeckCardText(deck.cards[3]).detail, "the meters replace the plain copy")
        XCTAssertEqual(deck.cards.map { DeckPalette.of($0).name }, ["Today", "Theme", "Energy and mood", "Goals"])
        XCTAssertEqual(DeckPalette.of(try DailyDeck.decode(#"{"date":"d","kind":"weekly","cards":[{"id":"r","type":"item","kind":"recap"}]}"#).cards[0]).name, "Recap")
        XCTAssertEqual(DeckPalette.of(deck.cards[3]).colors, HermexPaper.wiki, "the goals card wears its goal's paper")
    }

    func testEveryCardKindHasItsOwnPaper() throws {
        let deck = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"1","type":"reflect","kind":"book"},{"id":"2","type":"reflect","kind":"wiki"},{"id":"3","type":"reflect","kind":"quote"},{"id":"4","type":"headline"}]}"#)
        XCTAssertEqual(deck.cards.map { DeckPalette.of($0).name }, ["Book highlight", "From your wiki", "Quote", "Today"])
    }

    // MARK: - Mandarin

    private static let mandarinDeckJSON = """
    {"date": "2026-10-19", "kind": "morning", "cards": [
      {"id": "mandarin", "type": "prompt", "kind": "mandarin", "files_to": "mandarin",
       "title": "Grandma asks how marathon training is going",
       "yesterday": {"said": "我上个周末跑了二十英里，很累但是好。", "natural": "我上个周末跑了二十英里，虽然很累，但感觉很好。",
                     "natural_pinyin": "Wǒ shàng ge zhōu mò pǎo le èr shí yīng lǐ.", "notes": ["虽然…但… joins it more naturally."]},
       "phrases": [{"hanzi": "最近怎么样？", "pinyin": "Zuì jìn zěn me yàng?", "en": "How have you been lately?"},
                   {"hanzi": "我在准备马拉松。", "pinyin": "Wǒ zài zhǔn bèi mǎ lā sōng.", "en": "I'm training for a marathon."},
                   {"hanzi": "不用担心。", "pinyin": "Bú yòng dān xīn.", "en": "Don't worry.", "review": true},
                   {"pinyin": "no characters, dropped"}],
       "question": "你跑步跑得怎么样了？", "question_pinyin": "Nǐ pǎo bù pǎo de zěn me yàng le?",
       "question_en": "How is your running going?", "reason": "Mandarin practice · 1 review due"}
    ]}
    """

    func testMandarinCardDecodesPhrasesAndYesterday() throws {
        let card = try DailyDeck.decode(Self.mandarinDeckJSON).cards[0]
        XCTAssertTrue(card.isMandarin)
        XCTAssertFalse(card.isLetter)
        XCTAssertEqual(card.phrases.map(\.hanzi), ["最近怎么样？", "我在准备马拉松。", "不用担心。"], "a phrase without characters is dropped")
        XCTAssertEqual(card.phrases.map(\.review), [false, false, true])
        XCTAssertEqual(card.yesterday?.notes.count, 1)
        XCTAssertEqual(card.yesterday?.naturalPinyin, "Wǒ shàng ge zhōu mò pǎo le èr shí yīng lǐ.")
        XCTAssertEqual(card.questionPinyin, "Nǐ pǎo bù pǎo de zěn me yàng le?")
        XCTAssertEqual(card.questionEn, "How is your running going?")
    }

    func testMandarinFieldsAreOptional() throws {
        let card = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"m","type":"prompt","kind":"mandarin","question":"你好吗？","yesterday":{"said":"x"}}]}"#).cards[0]
        XCTAssertTrue(card.isMandarin)
        XCTAssertEqual(card.phrases, [])
        XCTAssertNil(card.yesterday, "feedback without a natural version isn't shown")
        XCTAssertNil(card.questionPinyin)
        XCTAssertTrue(card.takesText)
    }

    func testMandarinCardWearsItsPaper() throws {
        let card = try DailyDeck.decode(Self.mandarinDeckJSON).cards[0]
        XCTAssertEqual(DeckPalette.of(card).name, "Mandarin practice")
        XCTAssertEqual(DeckPalette.of(card).colors, HermexPaper.mandarin)
        XCTAssertTrue(HermexPaper.all.contains(HermexPaper.mandarin))
    }

    // MARK: - Sleep

    private static let sleepDeckJSON = """
    {"date": "2026-10-04", "kind": "morning", "cards": [
      {"id": "sleep", "type": "sleep", "question": "How did you sleep?", "scale": ["Very poor", "Poor", "Fair", "Good", "Very good"],
       "sleep": {"headline": "8.5 h of 9 h needed", "lines": ["Asleep 10:31 pm · up 7:19 am"],
                 "nights": [{"day": "Sun", "hours": 7.6, "need": 9}, {"day": "Mon", "hours": null}, {"day": 3, "hours": "x"}],
                 "insight": "4 wake-ups against 2 on a usual night: a broken night.",
                 "parts": [{"label": "Wake-ups", "value": "4", "vs": "+2 vs avg"}, {"label": "Performance", "value": "90", "vs": null}, {"label": 5}]},
       "tags": [{"id": "late_meal", "label": "Late meal"}, {"id": "ill"}, {"id": "ill", "label": "Ill"}],
       "fallback": "How did you sleep? Last night: 8.5 h of 9 h needed.", "reason": "From your Garmin"},
      {"id": "close", "type": "close"}
    ]}
    """

    func testSleepCardDecodesItsScaleAndNumbersTolerantly() throws {
        let card = try DailyDeck.decode(Self.sleepDeckJSON).cards[0]
        XCTAssertEqual(card.type, .sleep)
        XCTAssertEqual(card.scale.count, 5)
        let sleep = try XCTUnwrap(card.sleep)
        XCTAssertEqual(sleep.headline, "8.5 h of 9 h needed")
        XCTAssertEqual(sleep.nights.map(\.day), ["Sun", "Mon", ""], "a malformed night keeps its place")
        XCTAssertEqual(sleep.nights.map(\.hours), [7.6, nil, nil])
        XCTAssertEqual(sleep.nights[0].need, 9)
        XCTAssertTrue(card.takesText)
        XCTAssertFalse(card.takesFeedback, "the deck's own check-in, not material it picked")
        XCTAssertEqual(DeckPalette.of(card).name, "Sleep")
        let text = DeckCardText(card)
        XCTAssertEqual(text.lead, "How did you sleep?")
        XCTAssertTrue(text.leadIsQuestion)
        let unsynced = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"sleep","type":"sleep","sleep":{"lines":["Garmin hasn't synced last night yet."]}}]}"#).cards[0]
        XCTAssertNil(unsynced.sleep?.headline)
        XCTAssertEqual(unsynced.sleep?.nights, [])
    }

    func testTheDadCardIsALetterPromptWithItsCountdown() throws {
        let json = #"""
        {"date": "2026-10-16", "kind": "morning", "cards": [
          {"id": "letter", "type": "prompt", "kind": "letter", "voice": "Dad", "title": "To her",
           "lines": ["92 days to go", "Due Jan 16 · 26 weeks along"],
           "question": "Tell her how you met her mom.", "alt_questions": ["Tell her about your dad."],
           "reason": "A letter for her · Her mom", "files_to": "letters"},
          {"id": "advisor", "type": "prompt", "voice": "Dad", "question": "What's the gap?"}
        ]}
        """#
        let cards = try DailyDeck.decode(json).cards
        let letter = cards[0]
        XCTAssertTrue(letter.isLetter)
        XCTAssertFalse(cards[1].isLetter, "a plain check-in stays a check-in")
        XCTAssertEqual(letter.lines, ["92 days to go", "Due Jan 16 · 26 weeks along"])
        XCTAssertTrue(letter.takesText)
        XCTAssertEqual(letter.altQuestions, ["Tell her about your dad."])
        XCTAssertEqual(DeckPalette.of(letter).name, "Letter to her")
        XCTAssertEqual(DeckPalette.of(letter).colors, HermexPaper.advisor, "the Dad advisor's paper")
        XCTAssertEqual(DeckPalette.of(cards[1]).name, "Check-in")
        let text = DeckCardText(letter)
        XCTAssertEqual(text.lead, "Tell her how you met her mom.")
        XCTAssertTrue(text.leadIsQuestion, "the prompt leads and isn't asked twice")
        XCTAssertEqual(text.attribution, "Dad")
    }

    func testARatingAloneAnswersTheSleepCardAndIsFiledAsSnakeCaseJSON() throws {
        let deck = try DailyDeck.decode(Self.sleepDeckJSON)
        let rated = DeckAnswer(card: "sleep", rating: 4)
        XCTAssertFalse(rated.isEmpty)
        XCTAssertTrue(rated.isAnswer(for: deck.cards[0]))
        let payload = DeckAnswersPayload(deck: deck, answers: ["sleep": rated], completedAt: morning)
        XCTAssertEqual(payload.answers, [rated])
        let json = try XCTUnwrap(try payload.message().components(separatedBy: "```json\n").last?.components(separatedBy: "\n```").first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((object["answers"] as? [[String: Any]])?.first?["rating"] as? Int, 4)
    }

    @MainActor
    func testRatingTheSleepCardTogglesAndCountsAsAnAnswer() async throws {
        store.setWorkspace("/vault", for: server)
        let model = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.sleepDeckJSON))
        await model.load()
        let card = try XCTUnwrap(model.cards.first)
        model.rate(2, for: card)
        XCTAssertEqual(model.answer(for: card)?.rating, 2)
        XCTAssertEqual(model.answeredCount, 1)
        model.rate(4, for: card)
        XCTAssertEqual(model.answer(for: card)?.rating, 4, "another rating replaces it")
        model.rate(4, for: card)
        XCTAssertNil(model.answer(for: card), "tapping the chosen rating clears it")
        XCTAssertEqual(model.answeredCount, 0)
    }

    func testSleepCardDecodesItsTagsPartsAndInsight() throws {
        let card = try DailyDeck.decode(Self.sleepDeckJSON).cards[0]
        XCTAssertEqual(card.tags.map(\.id), ["late_meal", "ill"], "a tag without a label is dropped")
        let sleep = try XCTUnwrap(card.sleep)
        XCTAssertEqual(sleep.insight, "4 wake-ups against 2 on a usual night: a broken night.")
        XCTAssertEqual(sleep.parts.map(\.label), ["Wake-ups", "Performance"], "a malformed part is dropped")
        XCTAssertEqual(sleep.parts[0].vs, "+2 vs avg")
        XCTAssertNil(sleep.parts[1].vs)
        let bare = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"sleep","type":"sleep","sleep":{}}]}"#).cards[0]
        XCTAssertEqual(bare.tags, [])
        XCTAssertNil(bare.sleep?.insight)
        XCTAssertEqual(bare.sleep?.parts, [])
    }

    @MainActor
    func testTaggingTheSleepCardTogglesFilesAndClears() async throws {
        store.setWorkspace("/vault", for: server)
        let model = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.sleepDeckJSON))
        await model.load()
        let card = try XCTUnwrap(model.cards.first)
        model.toggleTag("late_meal", for: card)
        XCTAssertEqual(model.answer(for: card)?.tags, ["late_meal"])
        XCTAssertEqual(model.answeredCount, 1, "a tag alone answers the card")
        model.rate(1, for: card)
        model.toggleTag("late_meal", for: card)
        XCTAssertEqual(model.answer(for: card), DeckAnswer(card: "sleep", rating: 1),
                       "untapping every tag leaves the answer as it was before, so it isn't an edit")
        model.toggleTag("ill", for: card)
        let deck = try DailyDeck.decode(Self.sleepDeckJSON)
        let payload = DeckAnswersPayload(deck: deck, answers: ["sleep": try XCTUnwrap(model.answer(for: card))], completedAt: morning)
        let json = try XCTUnwrap(try payload.message().components(separatedBy: "```json\n").last?.components(separatedBy: "\n```").first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((object["answers"] as? [[String: Any]])?.first?["tags"] as? [String], ["ill"])
        model.toggleTag("ill", for: card)
        model.rate(1, for: card)
        XCTAssertNil(model.answer(for: card), "no rating and no tags: nothing to file")
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

    @MainActor
    func testShowWithACardIDLandsOnThatCard() async {
        store.setWorkspace("/vault", for: server)
        let weekly = #"{"date":"2026-10-04","kind":"weekly","cards":[{"id":"headline","type":"headline"},{"id":"recap","type":"item"},{"id":"week-career","type":"week_ahead","goal":"career"},{"id":"close","type":"close"}]}"#
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.weekly.json"], deck: weekly)

        let viewModel = makeViewModel(client)
        await viewModel.show(date: "2026-10-04", kind: "weekly", cardID: "week-career")
        XCTAssertEqual(viewModel.index, 2)
        viewModel.index = 0
        await viewModel.show(date: "2026-10-04", kind: "weekly", cardID: "week-career")
        XCTAssertEqual(viewModel.index, 2, "the deck already on screen still moves to the card")

        let other = makeViewModel(client)
        await other.show(date: "2026-10-04", kind: "weekly", cardID: "week-gone")
        XCTAssertEqual(other.state, .ready)
        XCTAssertEqual(other.index, 0)
    }

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

    // MARK: - Diagrams

    static let diagramDeckJSON = """
    {"date": "2026-10-04", "kind": "morning", "cards": [
      {"id": "email", "type": "item", "kind": "email", "title": "api gateway", "ref": {"link": "email_ingest/summaries/api-gateway-summary.md"}},
      {"id": "pick-2", "type": "reflect", "kind": "media", "title": "Elasticsearch", "ref": {"link": "wiki/sources/elastic-search", "pool": "media:elastic-search"}},
      {"id": "quote", "type": "reflect", "kind": "quote", "title": "Marcus Aurelius", "ref": {"pool": "quote:abc"}}
    ]}
    """

    static let diagramIndexJSON = """
    {"version": 1, "diagrams": [
      {"topic": "api-gateway", "title": "API gateway", "keys": ["email_ingest/summaries/api-gateway-summary", "media:api-gateway"]},
      {"topic": "elasticsearch", "title": "Elasticsearch", "keys": ["media:elastic-search"]}
    ]}
    """

    @MainActor
    func testDiagramChipsComeFromTheVaultIndexAndFragmentsAreReadOnce() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.diagramDeckJSON)
        client.files[BriefDiagramIndex.path] = Self.diagramIndexJSON
        client.files["diagrams/api-gateway.html"] = "<title>API gateway</title><p>Router</p>"
        let viewModel = makeViewModel(client)

        await viewModel.load()

        let cards = viewModel.cards
        XCTAssertEqual(viewModel.diagram(for: cards[0])?.topic, "api-gateway", "an email card matches by its link")
        XCTAssertEqual(viewModel.diagram(for: cards[1])?.topic, "elasticsearch", "a pool card matches by its pool key")
        XCTAssertNil(viewModel.diagram(for: cards[2]))

        let entry = try XCTUnwrap(viewModel.diagram(for: cards[0]))
        let first = try await viewModel.diagramFragment(entry)
        let second = try await viewModel.diagramFragment(entry)
        XCTAssertEqual(first, "<title>API gateway</title><p>Router</p>")
        XCTAssertEqual(second, first)
        XCTAssertEqual(client.readPaths.filter { $0 == "diagrams/api-gateway.html" }.count, 1)
    }

    @MainActor
    func testAVaultWithoutDiagramsShowsNoChips() async throws {
        let viewModel = try await loadedViewModel(Self.diagramDeckJSON)
        XCTAssertTrue(viewModel.cards.allSatisfy { viewModel.diagram(for: $0) == nil })
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

    /// The lead sizes the Daily Deck and Brain review bites share.
    func testLeadStyleShrinksAsTheLeadGrows() {
        XCTAssertEqual(DeckCardText.leadStyle(length: 900, isQuote: true), .title)
        XCTAssertEqual(DeckCardText.leadStyle(length: 220, isQuote: false), .title2)
        XCTAssertEqual(DeckCardText.leadStyle(length: 221, isQuote: false), .title3)
        XCTAssertEqual(DeckCardText.leadStyle(length: 480, isQuote: false), .title3)
        XCTAssertEqual(DeckCardText.leadStyle(length: 481, isQuote: false), .body)
    }
}

/// `APIClient.fileBrief` against `URLProtocol` mocks.
final class BriefFileHTTPTests: APIClientTestCase {
    private var request: BriefFileRequest {
        BriefFileRequest(date: "2026-10-04", kind: "morning", answers: DeckAnswersPayload(
            deck: try! DailyDeck.decode(#"{"date":"2026-10-04","kind":"morning","cards":[]}"#),
            answers: [:], completedAt: Date(timeIntervalSince1970: 0)))
    }

    func testPostsAndDecodesTolerantly() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/brief/file")
            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["date"] as? String, "2026-10-04")
            XCTAssertEqual((body["answers"] as? [String: Any])?["kind"] as? String, "morning")
            return apiTestJSONResponse(
                #"{"ok":true,"summary":"Filed.","ran":[{"step":"journal","ok":false,"error":"x"},{"step":7}],"agent_steps":["Email Sam"],"extra":1}"#,
                for: request)
        }
        let response = try await client.fileBrief(request)
        XCTAssertEqual(response?.summary, "Filed.")
        XCTAssertEqual(response?.agentSteps, ["Email Sam"])
        XCTAssertEqual(response?.ran, [.init(step: "journal", ok: false, error: "x"), .init(step: nil, ok: nil)])
    }

    func testNotFoundMeansNoFiler() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"error":"unavailable"}"#, for: request, status: 404)
        }
        let response = try await client.fileBrief(request)
        XCTAssertNil(response)
    }

    func testServerErrorCarriesTheServersMessage() async {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"error":"brain CLI exited 2"}"#, for: request, status: 500)
        }
        do {
            _ = try await client.fileBrief(request)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? BriefFileError, BriefFileError(message: "Filing failed: brain CLI exited 2"))
        }
    }
}

/// A clock the test moves by hand.
final class TestDeckClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
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
    /// The server filer's answer; nil (the default) is a server without one.
    var filer: Result<BriefFileResponse?, Error> = .success(nil)
    /// Runs inside `fileBrief` before it answers, to hold a filing in flight.
    var fileGate: (@Sendable () async -> Void)?
    private(set) var fileRequests: [BriefFileRequest] = []
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

    func fileBrief(_ request: BriefFileRequest) async throws -> BriefFileResponse? {
        fileRequests.append(request)
        await fileGate?()
        return try filer.get()
    }
}

final class DailyBriefReminderTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testEightOClockRepeatsAndAWeekOfNineOClockRemindersFollow() {
        let plan = DailyBriefReminder.plan(now: at(8, 7), openedOn: nil, calendar: calendar)
        XCTAssertEqual(plan.first, .init(id: "dailyBrief.ready", components: DateComponents(hour: 8, minute: 0), repeats: true, isReminder: false))
        let reminders = plan.filter(\.isReminder)
        XCTAssertEqual(reminders.map(\.id).first, "dailyBrief.reminder.2026-10-08")
        XCTAssertEqual(reminders.count, 7)
        XCTAssertTrue(reminders.allSatisfy { !$0.repeats && $0.components.hour == 9 && $0.components.minute == 0 })
    }

    func testOpeningTodaysBriefSkipsOnlyTodaysReminder() {
        let plan = DailyBriefReminder.plan(now: at(8, 8, 30), openedOn: "2026-10-08", calendar: calendar)
        XCTAssertEqual(plan.dropFirst().map(\.id).first, "dailyBrief.reminder.2026-10-09")
        XCTAssertEqual(plan.filter(\.isReminder).count, 6)
        XCTAssertEqual(plan.compactMap(\.review), [.init(date: "2026-10-11", kind: "weekly")], "Sunday's review")
    }

    func testAfterNineTodaysReminderIsPast() {
        let plan = DailyBriefReminder.plan(now: at(8, 9, 30), openedOn: nil, calendar: calendar)
        XCTAssertEqual(plan.dropFirst().map(\.id).first, "dailyBrief.reminder.2026-10-09")
    }

    func testDailyBriefDeepLinkRoundTrips() throws {
        let url = try XCTUnwrap(HermesDeepLink.dailyBriefURL)
        XCTAssertTrue(HermesDeepLink.isDailyBriefURL(url))
        XCTAssertFalse(HermesDeepLink.isNewChatURL(url))
        XCTAssertTrue(DailyBriefReminder.isDailyBrief(["dailyBrief": true]))
        XCTAssertFalse(DailyBriefReminder.isDailyBrief([:]))
    }
}

final class DeckReviewTests: XCTestCase {
    func testReviewsAreFoundInBriefsAndLabelled() {
        let reviews = DeckReview.all(in: [
            "2026-10-04.weekly.json", "2026-10-04.weekly.answers.json", "2026-10-11.weekly.json",
            "2026-09-30.monthly.json", "2026-10-09.morning.json"
        ])
        XCTAssertEqual(reviews.map(\.id), ["2026-10-11.weekly", "2026-10-04.weekly", "2026-09-30.monthly"])
        XCTAssertEqual(reviews.map(\.isFiled), [false, true, false])
        XCTAssertEqual(reviews[1].label, "Week ending Oct 4")
        XCTAssertEqual(reviews[2].label, "September review")
    }

    func testReviewNotificationsComeOnSundaysAndTheFirstAndOpenTheirDeck() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 7))!
        let reviews = DailyBriefReminder.plan(now: friday, openedOn: nil, calendar: calendar).compactMap(\.review)
        XCTAssertEqual(reviews, [
            .init(date: "2026-11-01", kind: "weekly"),
            .init(date: "2026-10-31", kind: "monthly")
        ], "Sunday Nov 1 is both a Sunday and the 1st")
        let url = try XCTUnwrap(DailyBriefReminder.url(for: ["dailyBrief": true, "date": "2026-11-01", "kind": "weekly"]))
        XCTAssertTrue(HermesDeepLink.isDailyBriefURL(url))
        XCTAssertEqual(HermesDeepLink.dailyBriefDeck(from: url)?.date, "2026-11-01")
        XCTAssertNil(HermesDeepLink.dailyBriefDeck(from: try XCTUnwrap(HermesDeepLink.dailyBriefURL)))
    }

    @MainActor
    func testAReviewOpensWithItsOwnTitleAndPaths() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeckReviewTests.\(UUID().uuidString)"))
        let server = URL(string: "https://brain.example.test")!
        let store = DailyDeckStore(defaults: defaults)
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.weekly.json", "2026-10-09.morning.json"],
                                             deck: #"{"date":"2026-10-04","kind":"weekly","cards":[{"id":"q-proud","type":"prompt","question":"Proud?"},{"id":"close","type":"close"}]}"#)
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store, now: { Date(timeIntervalSince1970: 1_791_600_000) })
        await viewModel.show(date: "2026-10-04", kind: "weekly")
        XCTAssertEqual(viewModel.state, .ready)
        XCTAssertEqual(viewModel.title, "Weekly Review")
        XCTAssertTrue(client.readPaths.contains("briefs/2026-10-04.weekly.json"))
        viewModel.setText("Ran 18 miles.", for: viewModel.cards[0])
        _ = await viewModel.file()
        XCTAssertTrue(client.sent.last?.message.contains("`bin/brain brief file 2026-10-04 weekly`") == true)
        XCTAssertEqual(DailyDeckViewModel.sessionTitle(for: "2026-10-04", kind: "weekly"), "Weekly Review · Oct 4")
    }

    // MARK: - Opener

    func testHeadlineDecodesTheRecapOfYesterdayAndIgnoresABlankOne() throws {
        let deck = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"headline","type":"headline","title":"T","recap":"You ran 21 miles."},{"id":"x","type":"headline","recap":"  "}]}"#)
        XCTAssertEqual(deck.cards[0].recap, "You ran 21 miles.")
        XCTAssertNil(deck.cards[1].recap)
    }
}

final class CardFanTests: XCTestCase {
    func testFanFitsTheStackAndCentersOnTheMiddleCard() {
        let width: CGFloat = 360
        for count in [2, 5, 10, 14] {
            let first = CardFan.spot(of: 0, count: count, width: width, picked: 0)
            let last = CardFan.spot(of: count - 1, count: count, width: width, picked: 0)
            XCTAssertLessThanOrEqual(last.x - first.x, width * 0.7 + 0.001, "\(count) cards fit the stack")
            XCTAssertEqual(first.x, -last.x, accuracy: 0.001, "the fan is centered")
            XCTAssertEqual(first.degrees, -last.degrees, accuracy: 0.001, "the ends turn the same amount")
        }
    }

    func testAFingerPicksTheCardUnderItAndClampsToTheEnds() {
        let width: CGFloat = 360, count = 10
        let spacing = CardFan.spacing(count: count, width: width)
        for position in 0..<count {
            let x = width / 2 + CardFan.spot(of: position, count: count, width: width, picked: 0).x
            XCTAssertEqual(CardFan.index(atX: x, count: count, width: width), position)
            XCTAssertEqual(CardFan.index(atX: x + spacing * 0.4, count: count, width: width), position)
        }
        XCTAssertEqual(CardFan.index(atX: -500, count: count, width: width), 0)
        XCTAssertEqual(CardFan.index(atX: 5000, count: count, width: width), count - 1)
        XCTAssertEqual(CardFan.index(atX: 200, count: 1, width: width), 0)
    }

    func testThePickedCardRisesAboveTheRest() {
        let count = 6
        let picked = CardFan.spot(of: 4, count: count, width: 360, picked: 4)
        let resting = CardFan.spot(of: 4, count: count, width: 360, picked: 1)
        XCTAssertTrue(picked.isPicked)
        XCTAssertFalse(resting.isPicked)
        XCTAssertLessThan(picked.y, resting.y, "the picked card lifts")
        XCTAssertGreaterThan(picked.scale, resting.scale)
        for position in 0..<count where position != 4 {
            XCTAssertGreaterThan(picked.zIndex, CardFan.spot(of: position, count: count, width: 360, picked: 4).zIndex)
        }
    }
}

final class DeckCardSourceTests: XCTestCase {
    private func card(_ json: String) throws -> DeckCard {
        try JSONDecoder().decode(DeckCard.self, from: Data(json.utf8))
    }

    func testACardReadsItsVaultLinkAndOpensThatBrainPage() throws {
        let wiki = try card(#"{"id": "w", "type": "reflect", "kind": "wiki", "ref": {"link": "wiki/nyc-marathon", "pool": "wiki:nyc-marathon"}}"#)
        XCTAssertEqual(wiki.link, "wiki/nyc-marathon")
        XCTAssertEqual(wiki.sourceRoute, .page(.wiki, "wiki/nyc-marathon.md"))
        XCTAssertEqual(DeckCard.openTitle(for: try XCTUnwrap(wiki.sourceRoute)), "Open the page")
    }

    func testEachVaultFolderOpensItsModule() {
        XCTAssertEqual(DeckCard.brainRoute(forLink: "journal/2025/10-October/2025-10-10"),
                       .page(.journal, "journal/2025/10-October/2025-10-10.md"))
        XCTAssertEqual(DeckCard.brainRoute(forLink: "email_ingest/summaries/america-summary.md"),
                       .page(.articles, "email_ingest/summaries/america-summary.md"))
        XCTAssertEqual(DeckCard.brainRoute(forLink: "wiki/sources/agent-complexity-ladder"),
                       .page(.wiki, "wiki/sources/agent-complexity-ladder.md"))
        XCTAssertEqual(DeckCard.brainRoute(forLink: "crm/contacts/alex"), .page(.people, "crm/contacts/alex.md"))
        XCTAssertEqual(DeckCard.brainRoute(forLink: "daughter/letters/2026-10-15.md"),
                       .page(.letters, "daughter/letters/2026-10-15.md"))
        XCTAssertNil(DeckCard.brainRoute(forLink: "briefs/2026-10-15.morning.json"), "not a Brain folder")
    }

    func testPooledMaterialWithoutAPageHasNoSource() throws {
        let book = try card(#"{"id": "b", "type": "reflect", "kind": "book", "ref": {"link": null, "pool": "book:a76c4922f1b4"}}"#)
        XCTAssertNil(book.link)
        XCTAssertNil(book.sourceRoute)
        let followUp = try card(#"{"id": "f", "type": "decision", "ref": {"followup": 4, "key": "thread:f27b25f4cce6"}}"#)
        XCTAssertNil(followUp.sourceRoute)
        let bare = try card(#"{"id": "c", "type": "close"}"#)
        XCTAssertNil(bare.link)
    }

    func testADiagramMatchesALinkOrPoolKeyAndIgnoresUnsafeTopics() throws {
        let index = BriefDiagramIndex.decode(#"""
        {"diagrams": [
          {"topic": "kafka", "title": "Kafka", "keys": ["wiki/sources/kafka", "media:kafka"]},
          {"topic": "../secrets", "keys": ["media:redis"]},
          {"title": "no topic", "keys": ["media:x"]}
        ]}
        """#)
        XCTAssertEqual(index.diagrams.map(\.topic), ["kafka"], "a topic that isn't a plain file name is dropped")
        XCTAssertEqual(index.diagrams.first?.fragmentPath, "diagrams/kafka.html")

        let byLink = try card(#"{"id": "a", "type": "reflect", "ref": {"link": "/wiki/sources/kafka.md"}}"#)
        let byPool = try card(#"{"id": "b", "type": "reflect", "ref": {"link": null, "pool": "MEDIA:kafka"}}"#)
        let unsafe = try card(#"{"id": "c", "type": "reflect", "ref": {"pool": "media:redis"}}"#)
        let bare = try card(#"{"id": "d", "type": "close"}"#)
        XCTAssertEqual(byPool.pool, "MEDIA:kafka")
        XCTAssertEqual(index.diagram(for: byLink)?.topic, "kafka")
        XCTAssertEqual(index.diagram(for: byPool)?.topic, "kafka")
        XCTAssertNil(index.diagram(for: unsafe))
        XCTAssertNil(index.diagram(for: bare))
        XCTAssertEqual(BriefDiagramIndex.decode("not json"), .empty)
    }
}
