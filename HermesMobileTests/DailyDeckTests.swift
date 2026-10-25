import XCTest
import Foundation
import AVFoundation
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

    func testMorningChecksDecodeTolerantly() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"2026-10-04","kind":"morning","cards":[],"checks":[
          {"card":"q1","part":"question","defect":"judge:on_idea","action":"kept","extra":1},
          {"card":"b1","part":7,"defect":"empty"},
          {"part":"card","action":"ok"},
          "junk"
        ]}
        """#)
        XCTAssertEqual(deck.checks.map(\.card), ["q1", "b1"], "a check without its card is dropped, never the deck")
        XCTAssertTrue(deck.checks[0].judgeFailed)
        XCTAssertEqual(deck.checks[0].action, "kept")
        XCTAssertNil(deck.checks[1].part, "a wrong-typed field reads as missing")
        XCTAssertFalse(deck.checks[1].judgeFailed, "only a `judge:` defect is the judge's")
        XCTAssertEqual(try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[]}"#).checks, [])
        XCTAssertEqual(try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[],"checks":"x"}"#).checks, [])
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

    func testAskCardDecodes() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"2026-10-19","kind":"morning","cards":[
          {"id":"ask","type":"ask","title":"Today's Ask","reason":"From your job search",
           "fallback":"Apply: Harvey — Applied AI Engineer · Ramp — Applied AI Engineer"}]}
        """#)
        let card = deck.cards[0]
        XCTAssertEqual(card.type, .ask)
        XCTAssertEqual(card.fallback, "Apply: Harvey — Applied AI Engineer · Ramp — Applied AI Engineer")
        XCTAssertFalse(card.takesText)
        XCTAssertFalse(card.takesFeedback)
        XCTAssertEqual(DeckPalette.of(card).name, "Today's Ask")
    }

    // MARK: - What changed

    func testChangesCardDecodes() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"2026-10-18","kind":"weekly","cards":[
          {"id":"changes","type":"changes","title":"What changed","rows":[
            {"id":"fb-1","said":"The deck keeps asking the same question","change":"Rotate deck questions","state":"shipped","recurred":0,"undoable":true},
            {"id":"fb-2","said":"Mandarin audio too fast","change":"Slow Mandarin playback","state":"recurred","recurred":2,"undoable":false,"extra":{"x":1}},
            {"said":"No id, dropped"},
            {"id":"fb-3","said":"x","change":"y","state":"teleported"},
            {"id":"fb-4","state":"reverted"}]}]}
        """#)
        let card = try XCTUnwrap(deck.cards.first)
        XCTAssertEqual(card.type, .changes)
        XCTAssertEqual(card.title, "What changed")
        XCTAssertEqual(card.rows.map(\.id), ["fb-1", "fb-2", "fb-3", "fb-4"], "a row without an id is dropped alone")
        XCTAssertEqual(card.rows[0].said, "The deck keeps asking the same question")
        XCTAssertEqual(card.rows[0].change, "Rotate deck questions")
        XCTAssertEqual(card.rows[0].state, .shipped)
        XCTAssertEqual(card.rows[0].undoable, true)
        XCTAssertEqual(card.rows[1].state, .recurred)
        XCTAssertEqual(card.rows[1].recurred, 2)
        XCTAssertEqual(card.rows[2].state, .unknown("teleported"))
        XCTAssertNil(card.rows[2].undoable)
        XCTAssertEqual(card.rows[3].said, "")
        XCTAssertFalse(card.takesFeedback)
        XCTAssertFalse(card.takesText)
        XCTAssertEqual(DeckPalette.of(card).name, "What changed")
    }

    func testChangeRowStateLabels() throws {
        func row(_ state: String, recurred: Int? = nil) throws -> DeckChangeRow {
            var object: [String: Any] = ["id": "fb", "said": "s", "change": "c", "state": state]
            if let recurred { object["recurred"] = recurred }
            return try JSONDecoder().decode(DeckChangeRow.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(try row("shipped").state.label(recurred: nil), "Shipped")
        XCTAssertEqual(try row("merged").state.label(recurred: nil), "Merged")
        XCTAssertEqual(try row("held").state.label(recurred: nil), "Held")
        XCTAssertEqual(try row("recurred", recurred: 3).state.label(recurred: 3), "Recurred ×3")
        XCTAssertEqual(try row("recurred").state.label(recurred: nil), "Recurred")
        XCTAssertEqual(try row("reverted").state.label(recurred: nil), "Undone")
    }

    func testChangesCardMissingRowsDecodes() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"d","kind":"weekly","cards":[{"id":"changes","type":"changes","title":"What changed"},
                                             {"id":"changes-2","type":"changes","rows":"nope"}]}
        """#)
        XCTAssertEqual(deck.cards.map(\.type), [.changes, .changes])
        XCTAssertEqual(deck.cards[0].rows, [])
        XCTAssertEqual(deck.cards[1].rows, [])
    }

    func testOlderTypeStaysUnknown() throws {
        let deck = try DailyDeck.decode(#"{"date":"d","kind":"weekly","cards":[{"id":"c","type":"changes_v2","rows":[]}]}"#)
        XCTAssertEqual(deck.cards[0].type, .unknown("changes_v2"))
    }

    @MainActor
    func testUndoChangePostsUndoAndFlipsRow() async throws {
        let feedback = DeckFeedbackStub()
        let viewModel = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: [], deck: Self.deckJSON), feedback: feedback)
        let row = try Self.changeRow(id: "fb-1", state: "shipped", undoable: true)
        XCTAssertTrue(viewModel.canUndo(row))

        await viewModel.undoChange(row)

        let decisions = await feedback.decisions
        XCTAssertEqual(decisions.map(\.id), ["fb-1"])
        XCTAssertEqual(decisions.map(\.decision), [.undo])
        XCTAssertEqual(viewModel.changeState(row), .reverted)
        XCTAssertFalse(viewModel.canUndo(row), "an undone row offers no second Undo")
        XCTAssertNil(viewModel.changeErrors[row.id])
        XCTAssertNil(viewModel.undoingChangeID)
    }

    @MainActor
    func testUndoChange409ShowsMessage() async throws {
        let feedback = DeckFeedbackStub()
        await feedback.fail(with: APIError.http(statusCode: 409, body: #"{"error": "The vault has uncommitted edits to tools/deck_pool.py.", "revert_sha": "abc123"}"#))
        let viewModel = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: [], deck: Self.deckJSON), feedback: feedback)
        let row = try Self.changeRow(id: "fb-1", state: "shipped", undoable: true)

        await viewModel.undoChange(row)

        XCTAssertEqual(viewModel.changeErrors["fb-1"], "The vault has uncommitted edits to tools/deck_pool.py.")
        XCTAssertEqual(viewModel.changeState(row), .shipped, "nothing changes until the server says so")
        XCTAssertTrue(viewModel.canUndo(row))
    }

    @MainActor
    func testUndoChangeConflictSayingRevertedFlipsTheRowWithoutAStatusField() async throws {
        let feedback = DeckFeedbackStub()
        await feedback.fail(with: APIError.http(statusCode: 409, body: #"{"error": "cannot go from reverted to reverted"}"#))
        let viewModel = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: [], deck: Self.deckJSON), feedback: feedback)
        let row = try Self.changeRow(id: "fb-1", state: "shipped", undoable: true)

        await viewModel.undoChange(row)

        XCTAssertEqual(viewModel.changeState(row), .reverted)
        XCTAssertEqual(viewModel.changeNotices["fb-1"], "Already undone")
        XCTAssertNil(viewModel.changeErrors["fb-1"], "not shown as a failure")
        XCTAssertFalse(viewModel.canUndo(row))
    }

    @MainActor
    func testUndoChangeOtherFailureShowsGenericMessage() async throws {
        let feedback = DeckFeedbackStub()
        await feedback.fail(with: APIError.http(statusCode: 500, body: nil))
        let viewModel = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: [], deck: Self.deckJSON), feedback: feedback)
        let row = try Self.changeRow(id: "fb-1", state: "shipped", undoable: true)

        await viewModel.undoChange(row)

        XCTAssertEqual(viewModel.changeErrors["fb-1"], "Couldn't undo that. Try again.")
        XCTAssertEqual(viewModel.changeState(row), .shipped)
    }

    @MainActor
    func testRowThatIsNotUndoableIsNotSent() async throws {
        let feedback = DeckFeedbackStub()
        let viewModel = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: [], deck: Self.deckJSON), feedback: feedback)
        let row = try Self.changeRow(id: "fb-2", state: "merged", undoable: false)

        XCTAssertFalse(viewModel.canUndo(row))
        await viewModel.undoChange(row)

        let decisions = await feedback.decisions
        XCTAssertTrue(decisions.isEmpty)
    }

    static func changeRow(id: String, state: String, undoable: Bool) throws -> DeckChangeRow {
        let object: [String: Any] = ["id": id, "said": "Note", "change": "Change", "state": state, "recurred": 0, "undoable": undoable]
        return try JSONDecoder().decode(DeckChangeRow.self, from: JSONSerialization.data(withJSONObject: object))
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

    // MARK: - The week's question

    func testSectionCardDecodesAndIsNotAnswerable() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"2026-11-25","kind":"morning","cards":[
          {"id":"week","type":"section","title":"What does being a father ask of you?",
           "lines":["This week · Being a father","Day 3 · 4 answers so far"],
           "recap":"Oct 31: “Work hard on things you chose.”",
           "ref":{"link":"wiki/views/fatherhood"},
           "week":{"area":"fatherhood","question":"What does being a father ask of you?","monday":"2026-11-23"}}]}
        """#)
        let card = try XCTUnwrap(deck.cards.first)
        XCTAssertEqual(card.type, .section)
        XCTAssertEqual(card.title, "What does being a father ask of you?")
        XCTAssertEqual(card.lines, ["This week · Being a father", "Day 3 · 4 answers so far"])
        XCTAssertEqual(card.recap, "Oct 31: “Work hard on things you chose.”")
        XCTAssertEqual(card.link, "wiki/views/fatherhood")
        XCTAssertEqual(card.sourceRoute, .page(.wiki, "wiki/views/fatherhood.md"))
        XCTAssertEqual(DeckCard.openTitle(for: try XCTUnwrap(card.sourceRoute)), "Open the page")
        XCTAssertFalse(card.takesText)
        XCTAssertFalse(card.takesFeedback)
        XCTAssertEqual(card.sectionSpokenLabel, "This week, Being a father, What does being a father ask of you?")
        XCTAssertEqual(DeckPalette.of(card).colors, DeckPalette.opener.colors, "the divider wears the opener's paper")
        XCTAssertEqual(DeckPalette.of(card).name, "This week")
    }

    func testSectionDecodesIntentionLine() throws {
        let card = try XCTUnwrap(DailyDeck.decode(#"""
        {"date":"d","kind":"morning","cards":[
          {"id":"week","type":"section","title":"Q","intention":{"text":"Send five asks","if_then":"If it is 9am, then I write."}},
          {"id":"week2","type":"section","title":"Q","intention":{"text":"Rest"}},
          {"id":"week3","type":"section","title":"Q","intention":"nope"}]}
        """#).cards.first)
        XCTAssertEqual(card.intention, DeckIntentionLine(text: "Send five asks", ifThen: "If it is 9am, then I write."))
        XCTAssertEqual(card.intention?.line, "Your intention: Send five asks \u{b7} If it is 9am, then I write.")
        let deck = try DailyDeck.decode(#"""
        {"date":"d","kind":"morning","cards":[
          {"id":"week2","type":"section","title":"Q","intention":{"text":"Rest"}},
          {"id":"week3","type":"section","title":"Q","intention":"nope"},
          {"id":"week4","type":"section","title":"Q","intention":{"text":"  ","if_then":"x"}},
          {"id":"week5","type":"section","title":"Q"},
          {"id":"week6","type":"section","title":"Q","intention":{"text":"Rest","if_then":4}}]}
        """#)
        XCTAssertEqual(deck.cards[0].intention?.line, "Your intention: Rest")
        XCTAssertNil(deck.cards[1].intention)
        XCTAssertNil(deck.cards[2].intention, "no text, no line")
        XCTAssertNil(deck.cards[3].intention)
        XCTAssertEqual(deck.cards[4].intention?.line, "Your intention: Rest", "a mistyped if_then drops only itself")
    }

    func testSectionCardWithNoLinkOrRecapDecodes() throws {
        let card = try XCTUnwrap(DailyDeck.decode(#"""
        {"date":"d","kind":"morning","cards":[{"id":"week","type":"section","title":"Q","lines":["This week · Money","No sources fit today"]}]}
        """#).cards.first)
        XCTAssertEqual(card.type, .section)
        XCTAssertNil(card.recap)
        XCTAssertNil(card.sourceRoute)
        XCTAssertEqual(card.lines.last, "No sources fit today")
    }

    func testOpenerSplitsTodayAndThisWeek() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"d","kind":"morning","cards":[
          {"id":"open","type":"headline","title":"Today"},
          {"id":"t1","type":"prompt"},{"id":"f1","type":"decision"},{"id":"t2","type":"reflect"},{"id":"f2","type":"decision"},
          {"id":"week","type":"section","title":"Q"},
          {"id":"w1","type":"reflect","kind":"journal"},{"id":"w2","type":"reflect","kind":"crm"},
          {"id":"close","type":"close"}]}
        """#)
        let acts = DeckCardView.acts(DeckPage.pages(for: deck.cards))
        XCTAssertEqual(acts.today.map(\.id), ["t1", "followups-f1", "t2"], "follow-ups are one page; the opener is not listed")
        XCTAssertEqual(acts.week.map(\.id), ["w1", "w2"], "the divider and close are not listed")
        // The opener is never listed, and a deck with no section is all one act.
        let plain = DeckCardView.acts(DeckPage.pages(for: try DailyDeck.decode(Self.deckJSON).cards))
        XCTAssertEqual(plain.today.count, 5)
        XCTAssertTrue(plain.week.isEmpty)
    }

    func testOpenerCountsThreeTodayAndTwoThisWeek() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"d","kind":"morning","cards":[
          {"id":"a","type":"prompt"},{"id":"b","type":"reflect"},{"id":"c","type":"reflect"},
          {"id":"week","type":"section"},
          {"id":"d","type":"reflect"},{"id":"e","type":"reflect"},{"id":"close","type":"close"}]}
        """#)
        let acts = DeckCardView.acts(DeckPage.pages(for: deck.cards))
        XCTAssertEqual(acts.today.count, 3)
        XCTAssertEqual(acts.week.count, 2)
    }

    private static let weekDeckJSON = #"""
    {"date":"2026-10-04","kind":"morning","cards":[
      {"id":"open","type":"headline","title":"Today"},
      {"id":"t1","type":"prompt","question":"Today?"},
      {"id":"week","type":"section","title":"Q0?","question":"Q0?","alt_questions":["Q1?","Q2?"],
       "lines":["This week · AI"],"week":{"area":"ai","question":"Q0?","monday":"2026-10-26","variant":0,"questions":["Q0?","Q1?","Q2?"]}},
      {"id":"week-0-1","type":"reflect","kind":"journal","week":{"area":"ai","question":"Q0?","monday":"2026-10-26","variant":0}},
      {"id":"week-0-2","type":"reflect","kind":"crm","week":{"area":"ai","question":"Q0?","monday":"2026-10-26","variant":0}},
      {"id":"week-1-1","type":"reflect","kind":"journal","week":{"area":"ai","question":"Q1?","monday":"2026-10-26","variant":1}},
      {"id":"week-2-1","type":"reflect","kind":"journal","week":{"area":"ai","question":"Q2?","monday":"2026-10-26","variant":2}},
      {"id":"close","type":"close"}]}
    """#

    func testWeekSourceCardsDecodeTheirVariant() throws {
        let deck = try DailyDeck.decode(Self.weekDeckJSON)
        XCTAssertEqual(deck.cards.map(\.weekVariant), [nil, nil, 0, 0, 0, 1, 2, nil])
        XCTAssertEqual(deck.cards[2].altQuestions, ["Q1?", "Q2?"])
    }

    @MainActor
    func testNewQuestionStepsTheWeekVariantAndSwapsTheSourceCards() async throws {
        let viewModel = try await loadedViewModel(Self.weekDeckJSON)
        let section = try XCTUnwrap(viewModel.cards.first { $0.type == .section })
        let ids = { viewModel.visiblePages.map(\.id) }
        XCTAssertEqual(viewModel.weekVariant, 0)
        XCTAssertEqual(ids(), ["open", "t1", "week", "week-0-1", "week-0-2", "close"])

        viewModel.index = 2
        viewModel.regenerateQuestion(for: section)
        XCTAssertEqual(viewModel.weekVariant, 1)
        XCTAssertEqual(viewModel.question(for: section), "Q1?")
        XCTAssertEqual(ids(), ["open", "t1", "week", "week-1-1", "close"])
        XCTAssertEqual(viewModel.currentPage?.id, "week", "the divider stays on screen")
        let acts = DeckCardView.acts(viewModel.visiblePages)
        XCTAssertEqual(acts.week.map(\.id), ["week-1-1"], "the opener lists the shown question's cards")
        XCTAssertEqual(acts.today.map(\.id), ["t1"])

        viewModel.regenerateQuestion(for: section)
        XCTAssertEqual(viewModel.weekVariant, 2)
        XCTAssertEqual(ids(), ["open", "t1", "week", "week-2-1", "close"])
        viewModel.regenerateQuestion(for: section)
        XCTAssertEqual(viewModel.weekVariant, 0, "wraps back to the first question")
        XCTAssertEqual(ids(), ["open", "t1", "week", "week-0-1", "week-0-2", "close"])
        XCTAssertNil(viewModel.answer(for: section))
    }

    @MainActor
    func testWeekSectionAnswerIsFiledWithoutCountingAsAnAnsweredCard() async throws {
        let viewModel = try await loadedViewModel(Self.weekDeckJSON)
        let section = try XCTUnwrap(viewModel.cards.first { $0.type == .section })
        viewModel.regenerateQuestion(for: section)
        viewModel.setNote("  Too abstract.  ", for: section)
        XCTAssertEqual(viewModel.answeredCount, 0, "the divider is not an answered card")
        XCTAssertTrue(viewModel.hasChanges)

        let payload = DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: viewModel.answers, completedAt: morning)
        XCTAssertEqual(payload.answers.map(\.card), ["week"])
        XCTAssertEqual(payload.answers.first?.question, "Q1?")
        XCTAssertEqual(payload.answers.first?.text, "Too abstract.")

        viewModel.setNote("   ", for: section)
        let blank = DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: viewModel.answers, completedAt: morning)
        XCTAssertNil(blank.answers.first?.text, "a blank note files as none")
        XCTAssertEqual(blank.answers.first?.question, "Q1?")
        viewModel.setNote("", for: section)
        XCTAssertNil(viewModel.answer(for: section)?.text, "an emptied field clears it")
        viewModel.regenerateQuestion(for: section)
        viewModel.regenerateQuestion(for: section)
        XCTAssertNil(viewModel.answer(for: section))
    }

    @MainActor
    func testWeekNoteKeepsALeadingSpaceWhileTypingAndFilesTrimmed() async throws {
        let viewModel = try await loadedViewModel(Self.weekDeckJSON)
        let section = try XCTUnwrap(viewModel.cards.first { $0.type == .section })
        viewModel.setNote(" ", for: section)
        XCTAssertEqual(viewModel.answer(for: section)?.text, " ", "the space typed first stays in the field")
        let blank = DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: viewModel.answers, completedAt: morning)
        XCTAssertTrue(blank.answers.isEmpty)

        viewModel.setNote(" Too abstract ", for: section)
        XCTAssertEqual(viewModel.answer(for: section)?.text, " Too abstract ")
        let payload = DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: viewModel.answers, completedAt: morning)
        XCTAssertEqual(payload.answers.map(\.card), ["week"])
        XCTAssertEqual(payload.answers.first?.text, "Too abstract")
    }

    func testDividerSecondLineFollowsTheShownQuestion() {
        let lines = ["This week · AI", "Day 3 · 2 answers so far"]
        XCTAssertEqual(DailyDeckViewModel.sectionLines(lines, variant: 0, hasSources: true, date: "2026-10-28"), lines,
                       "the original question keeps the vault's line")
        XCTAssertEqual(DailyDeckViewModel.sectionLines(lines, variant: 1, hasSources: true, date: "2026-10-28"),
                       ["This week · AI", "Day 3"], "the answer count is the original question's")
        XCTAssertEqual(DailyDeckViewModel.sectionLines(lines, variant: 2, hasSources: false, date: "2026-10-28"),
                       ["This week · AI", "No sources fit today"])
        let none = ["This week · AI", "No sources fit today"]
        XCTAssertEqual(DailyDeckViewModel.sectionLines(none, variant: 0, hasSources: false, date: "2026-10-28"), none)
        XCTAssertEqual(DailyDeckViewModel.sectionLines(none, variant: 1, hasSources: true, date: "2026-10-28"),
                       ["This week · AI", "Day 3"], "a Wednesday, counted from the deck's date")
        XCTAssertEqual(DailyDeckViewModel.sectionLines(none, variant: 1, hasSources: true, date: "2026-11-01"),
                       ["This week · AI", "Day 7"])
        XCTAssertEqual(DailyDeckViewModel.sectionLines(none, variant: 1, hasSources: true, date: "bad"), ["This week · AI"])
        XCTAssertEqual(DailyDeckViewModel.sectionLines(["This week · AI"], variant: 1, hasSources: false, date: "2026-10-28"),
                       ["This week · AI"])
    }

    @MainActor
    func testDividerLinesSwapWithTheQuestion() async throws {
        let json = Self.weekDeckJSON
            .replacingOccurrences(of: #""lines":["This week · AI"]"#, with: #""lines":["This week · AI","Day 1 · 1 answer so far"]"#)
            .replacingOccurrences(of: #","alt_questions":["Q1?","Q2?"]"#, with: #","alt_questions":["Q1?","Q2?","Q3?"]"#)
        let viewModel = try await loadedViewModel(json)
        let section = try XCTUnwrap(viewModel.cards.first { $0.type == .section })
        XCTAssertEqual(viewModel.sectionLines(for: section), ["This week · AI", "Day 1 · 1 answer so far"])
        viewModel.regenerateQuestion(for: section)
        XCTAssertEqual(viewModel.sectionLines(for: section), ["This week · AI", "Day 1"])
        viewModel.regenerateQuestion(for: section)
        viewModel.regenerateQuestion(for: section)
        XCTAssertEqual(viewModel.question(for: section), "Q3?")
        XCTAssertEqual(viewModel.sectionLines(for: section), ["This week · AI", "No sources fit today"],
                       "Q3? has no source cards")
        viewModel.regenerateQuestion(for: section)
        XCTAssertEqual(viewModel.sectionLines(for: section), ["This week · AI", "Day 1 · 1 answer so far"])
    }

    @MainActor
    func testWeekNoteAloneIsFiled() async throws {
        let viewModel = try await loadedViewModel(Self.weekDeckJSON)
        let section = try XCTUnwrap(viewModel.cards.first { $0.type == .section })
        viewModel.setNote("Keep this one.", for: section)
        let payload = DeckAnswersPayload(deck: try XCTUnwrap(viewModel.deck), answers: viewModel.answers, completedAt: morning)
        XCTAssertEqual(payload.answers.map(\.card), ["week"])
        XCTAssertNil(payload.answers.first?.question)
        XCTAssertEqual(viewModel.answeredCount, 0)
    }

    @MainActor
    func testDeckWithoutWeekVariantsIsUnchanged() async throws {
        let viewModel = try await loadedViewModel(Self.feedbackDeckJSON)
        XCTAssertEqual(viewModel.weekVariant, 0)
        XCTAssertEqual(viewModel.visiblePages.count, 4)
        // A section with no alternatives and week cards with no variant stay as they were.
        let plain = try await loadedViewModel(#"""
        {"date":"2026-10-04","kind":"morning","cards":[{"id":"week","type":"section","title":"Q"},{"id":"w1","type":"reflect"}]}
        """#)
        XCTAssertEqual(plain.visiblePages.map(\.id), ["week", "w1"])
        // Week cards in a deck with no divider are all shown.
        let noDivider = try await loadedViewModel(#"""
        {"date":"2026-10-04","kind":"morning","cards":[
          {"id":"a","type":"reflect","week":{"variant":0}},{"id":"b","type":"reflect","week":{"variant":1}}]}
        """#)
        XCTAssertEqual(noDivider.visiblePages.map(\.id), ["a", "b"])
    }

    func testViewTakeDecisionKeepsEntriesContextAndTextActions() throws {
        let card = try XCTUnwrap(DailyDeck.decode(#"""
        {"date":"2026-11-29","kind":"weekly","cards":[
          {"id":"view-take","type":"decision","kind":"view_take","title":"What does being a father ask of you?",
           "lines":["This week · Being a father"],
           "entries":[{"label":"Tue · Dr K","text":"Be present."},{"label":"Thu · Notes","text":"Slow down."}],
           "body":"Four answers.","context":"Last time (Oct 31): “Work hard on things you chose.”",
           "question":"Your take, in a sentence",
           "actions":[{"id":"open","label":"Still open","input":"text"},{"id":"settled","label":"Settled","input":"text"}],
           "week":{"area":"fatherhood","question":"Q","monday":"2026-11-23"}}]}
        """#).cards.first)
        XCTAssertEqual(card.type, .decision)
        XCTAssertEqual(card.lines, ["This week · Being a father"])
        XCTAssertEqual(card.entries.map(\.label), ["Tue · Dr K", "Thu · Notes"])
        XCTAssertEqual(card.context, "Last time (Oct 31): “Work hard on things you chose.”")
        XCTAssertEqual(card.question, "Your take, in a sentence")
        XCTAssertEqual(card.actions.map(\.label), ["Still open", "Settled"])
        XCTAssertTrue(card.actions.allSatisfy(\.takesText))
        XCTAssertEqual(card.answerPrompt(chosen: "settled"), "Your take, in a sentence")
        XCTAssertEqual(card.answerPrompt(chosen: "edit"), "Your version")
        let plain = try XCTUnwrap(DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"f","type":"decision"}]}"#).cards.first)
        XCTAssertEqual(plain.answerPrompt(chosen: "answer"), "Your answer")
    }

    func testWeekSourceKindsWearExistingPapers() throws {
        func palette(_ kind: String) throws -> DeckPalette {
            DeckPalette.of(try XCTUnwrap(DailyDeck.decode(
                #"{"date":"d","kind":"morning","cards":[{"id":"x","type":"reflect","kind":"\#(kind)","title":"T"}]}"#).cards.first))
        }
        let journal = try palette("journal")
        XCTAssertEqual(journal, DeckPalette.journal)
        XCTAssertEqual(journal.name, "Your journal", "a week's journal entry is not the year-ago card")
        XCTAssertEqual(journal.colors, HermexPaper.past)
        let yearAgo = try palette("on_this_day")
        XCTAssertEqual(yearAgo.name, "A year ago")
        XCTAssertEqual(yearAgo.colors, journal.colors, "same journal paper")
        let crm = try palette("crm")
        XCTAssertEqual(crm, DeckPalette.people)
        XCTAssertNotEqual(crm.name, DeckPalette.followUps.name, "a person's card is not the follow-ups page")
        XCTAssertEqual(crm.colors, DeckPalette.followUps.colors, "same plain paper")
        let email = try palette("email")
        XCTAssertEqual(email, DeckPalette.plain)
        XCTAssertEqual(email.colors, try palette("nonsense").colors, "email reads like the inbox item card: the plain paper")
    }

    func testJournalWeekCardsLeadInTheSerifLikeTheYearAgoCard() throws {
        let cards = try DailyDeck.decode(#"""
        {"date":"d","kind":"morning","cards":[{"id":"j","type":"reflect","kind":"journal"},
          {"id":"y","type":"reflect","kind":"on_this_day"},{"id":"w","type":"reflect","kind":"wiki"}]}
        """#).cards
        let lead = "Read to her for an hour."
        XCTAssertEqual(DeckCardText.leadFont(for: cards[0], lead: lead), DeckCardText.leadFont(for: cards[1], lead: lead))
        XCTAssertNotEqual(DeckCardText.leadFont(for: cards[0], lead: lead), DeckCardText.leadFont(for: cards[2], lead: lead))
    }

    func testTheSundayQuestionIsItsOwnPageNotAFollowUp() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"2026-11-01","kind":"weekly","cards":[
          {"id":"headline","type":"headline","title":"Week of Oct 26"},
          {"id":"view-take","type":"decision","kind":"view_take","title":"Is the model the product?",
           "lines":["This week · AI & the industry"],
           "entries":[{"label":"Wed · Dr K","text":"Maybe."}],"body":"Wed · Dr K: Maybe.",
           "actions":[{"id":"open","label":"Still open","input":"text"},{"id":"settled","label":"Settled","input":"text"}]},
          {"id":"view-next","type":"prompt","question":"A new question?"},
          {"id":"close","type":"close"}]}
        """#)
        let pages = DeckPage.pages(for: deck.cards)
        XCTAssertEqual(pages.map(\.id), ["headline", "view-take", "view-next", "close"], "no follow-ups page")
        guard case .card(let take) = pages[1] else { return XCTFail("Expected the question's own page") }
        XCTAssertTrue(take.isViewTake)
        XCTAssertFalse(take.isFollowUp)
        XCTAssertTrue(pages[1].answersInPlace, "its answer box needs the keyboard inset")
        XCTAssertEqual(DeckAheadRow.title(pages[1]), "Is the model the product?")
        let palette = DeckPalette.of(pages[1])
        XCTAssertEqual(palette, DeckPalette.weekQuestion)
        XCTAssertEqual(palette.name, "This week's question")
        XCTAssertNotEqual(palette.name, DeckPalette.followUps.name)
        XCTAssertNil(take.decisionBody, "the entries are drawn; their plain copy is not shown again")
        let empty = try XCTUnwrap(DailyDeck.decode(#"""
        {"date":"d","kind":"weekly","cards":[{"id":"view-take","type":"decision","kind":"view_take","title":"Q",
          "body":"No answers this week."}]}
        """#).cards.first)
        XCTAssertEqual(empty.decisionBody, "No answers this week.")
    }

    func testTheSundayQuestionKeepsItsOwnPageInAV2WeeklyReview() throws {
        let deck = try DailyDeck.decode(#"""
        {"version":2,"date":"2026-11-01","kind":"weekly","cards":[
          {"id":"cover","type":"cover","title":"The week you tapered"},
          {"id":"story","type":"story","chapter":"remember","draft":"You tapered."},
          {"id":"view-take","type":"decision","kind":"view_take","chapter":"steer","title":"Is the model the product?",
           "actions":[{"id":"open","label":"Still open","input":"text"},{"id":"settled","label":"Settled","input":"text"}]},
          {"id":"view-steer","type":"prompt","chapter":"steer","question":"Keep the question or change it?","files_to":"steer"},
          {"id":"close","type":"close","title":"Seal the week"}]}
        """#)
        let pages = DeckPage.pages(for: deck.cards)
        XCTAssertEqual(pages.map(\.id), ["cover", "story", "view-take", "view-steer", "close"], "no follow-ups page")
        XCTAssertEqual(DeckAheadRow.title(pages[2]), "Is the model the product?")
        let take = DeckPalette.of(pages[2], inV2Weekly: true)
        XCTAssertEqual(take, DeckPalette.weekQuestion, "the week's paper doesn't take over the question's page")
        XCTAssertEqual(take.name, "This week's question")
        XCTAssertTrue(pages[2].answersInPlace)
        XCTAssertEqual(DeckPalette.of(pages[3], inV2Weekly: true), DeckPalette.week, "a chaptered prompt wears the week's paper")
        XCTAssertEqual(DeckPalette.of(pages[4], inV2Weekly: true), DeckPalette.week)
    }

    func testFollowUpsStillGatherBesideTheSundayQuestion() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"d","kind":"weekly","cards":[{"id":"f1","type":"decision","title":"Sam"},
          {"id":"view-take","type":"decision","kind":"view_take","title":"Q"},{"id":"f2","type":"decision","title":"Pat"}]}
        """#)
        let pages = DeckPage.pages(for: deck.cards)
        XCTAssertEqual(pages.map(\.id), ["followups-f1", "view-take"])
        guard case .followUps(let cards) = pages[0] else { return XCTFail("Expected follow-ups") }
        XCTAssertEqual(cards.map(\.id), ["f1", "f2"])
        XCTAssertEqual(DeckAheadRow.title(pages[0]), "2 follow-ups")
        XCTAssertEqual(cards[0].decisionBody, nil)
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

    @MainActor
    func testMandarinSpeakerPlaysAndStopsOnASecondTap() {
        let synth = MandarinSpySynthesizer()
        let session = MandarinSpySession()
        let speaker = MandarinSpeaker(synthesizer: synth, audioSession: session)
        speaker.toggle("你好")
        XCTAssertEqual(session.activations, 1, "playback sets up the Listen session, so it isn't stuck on the earpiece")
        XCTAssertEqual(synth.spoken.map(\.speechString), ["你好"])
        XCTAssertEqual(synth.spoken.first?.rate, AVSpeechUtteranceDefaultSpeechRate * 0.85)
        XCTAssertEqual(speaker.speaking, "你好")
        speaker.toggle("你好")
        XCTAssertEqual(synth.stops, 1)
        XCTAssertNil(speaker.speaking, "a second tap stops it")
        XCTAssertEqual(synth.spoken.count, 1)
        XCTAssertEqual(session.deactivations, 1)
    }

    @MainActor
    func testMandarinSpeakerSwitchesPhrasesAndClearsWhenDone() {
        let synth = MandarinSpySynthesizer()
        let session = MandarinSpySession()
        let speaker = MandarinSpeaker(synthesizer: synth, audioSession: session)
        speaker.toggle("你好")
        speaker.toggle("谢谢")
        XCTAssertEqual(synth.stops, 1, "the first phrase stops before the next plays")
        XCTAssertEqual(speaker.speaking, "谢谢")
        speaker.utteranceEnded(ObjectIdentifier(synth.spoken[0]))
        XCTAssertEqual(speaker.speaking, "谢谢", "a stale finish leaves the playing phrase alone")
        speaker.utteranceEnded(ObjectIdentifier(synth.spoken[1]))
        XCTAssertNil(speaker.speaking)
        XCTAssertEqual(session.activations, session.deactivations, "every playback hands the session back")
    }

    func testMandarinQuestionFollowsTheOneHeAsked() throws {
        let card = try DailyDeck.decode(Self.mandarinDeckJSON).cards[0]
        let own = card.mandarinQuestion(asked: "你今天怎么样？")
        XCTAssertEqual(own.hanzi, "你今天怎么样？")
        XCTAssertNil(own.pinyin, "the deck's pinyin belongs to the deck's question")
        XCTAssertNil(own.english)
        let deck = card.mandarinQuestion(asked: try XCTUnwrap(card.question))
        XCTAssertEqual(deck.pinyin, card.questionPinyin)
        XCTAssertEqual(deck.english, card.questionEn)
    }

    // MARK: - Sleep

    private static let sleepDeckJSON = """
    {"date": "2026-10-04", "kind": "morning", "cards": [
      {"id": "sleep", "type": "sleep", "question": "How did you sleep?", "scale": ["Very poor", "Poor", "Fair", "Good", "Very good"],
       "sleep": {"headline": "8.5 h of 9 h needed", "lines": ["Asleep 10:31 pm · up 7:19 am"],
                 "nights": [{"day": "Sun", "hours": 7.6, "need": 9, "hrv": 92}, {"day": "Mon", "hours": null}, {"day": 3, "hours": "x"}],
                 "insight": "4 wake-ups against 2 on a usual night: a broken night.",
                 "tiles": [{"label": "Wake-ups", "value": "4", "note": "usually 2 · 54 min awake"}, {"label": "Asleep", "value": "11:05 pm", "note": null}, {"label": 5}],
                 "coach": {"name": "Dr. Mara Quinn", "text": "Finish dinner by 7:30 pm."},
                 "hrv_band": [85, 104], "hrv_status": "balanced"},
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

    func testAtlasQuestionsFromLastNightWearTheirOwnMarkAndLeadWithTheTitle() throws {
        let json = #"""
        {"date": "2026-10-25", "kind": "morning", "cards": [
          {"id": "dream-2", "type": "prompt", "kind": "dream", "voice": "Atlas", "context": "Diagrams",
           "question": "Is the diagram skill still a goal, or is it parked?",
           "reason": "From Atlas's review of Sat, Oct 24", "files_to": "dream",
           "ref": {"link": "dreams/2026-10-24.md", "n": 2}},
          {"id": "advisor", "type": "prompt", "voice": "Ted", "question": "What's the one thing?"}
        ]}
        """#
        let cards = try DailyDeck.decode(json).cards
        let dream = cards[0]
        XCTAssertTrue(dream.isDream)
        XCTAssertFalse(cards[1].isDream, "a plain check-in stays a check-in")
        XCTAssertTrue(dream.takesText)
        XCTAssertEqual(DeckPalette.of(dream).name, "Atlas asks")
        XCTAssertEqual(DeckPalette.of(dream).colors, HermexPaper.plain, "Atlas's own cards wear the plain paper")
        XCTAssertEqual(DeckPalette.of(cards[1]).name, "Check-in")
        let text = DeckCardText(dream)
        XCTAssertEqual(text.lead, "Diagrams", "the short title leads; the question follows it")
        XCTAssertFalse(text.leadIsQuestion)
        XCTAssertEqual(text.attribution, "Atlas")
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

    func testTheWorkEthicCardIsRatedByTraitNotTyped() throws {
        let deck = try DailyDeck.decode(Self.selfRatingDeckJSON)
        let rating = deck.cards[0], other = deck.cards[1]
        XCTAssertEqual(rating.selfRatings, ["Consistency", "Intensity", "Focus", "Boredom tolerance", "Sacrifice"])
        XCTAssertFalse(rating.takesText, "the picker replaces the reflection box")
        XCTAssertNil(other.selfRatings)
        XCTAssertTrue(other.takesText)
    }

    func testSelfRatingTextReadsTypedScoresAndWritesThemInTraitOrder() {
        let traits = ["Consistency", "Intensity", "Focus", "Boredom tolerance", "Sacrifice"]
        let typed = DeckSelfRatings.scores(in: "Consistency8, intensity 6, focus 5, boredom tolerance 3, sacrifice 4", traits: traits)
        XCTAssertEqual(typed, ["Consistency": 8, "Intensity": 6, "Focus": 5, "Boredom tolerance": 3, "Sacrifice": 4])
        XCTAssertEqual(DeckSelfRatings.scores(in: "Consistency: 10, focus: 1", traits: traits), ["Consistency": 10, "Focus": 1])
        XCTAssertEqual(DeckSelfRatings.text(typed, traits: traits),
                       "Consistency: 8, intensity: 6, focus: 5, boredom tolerance: 3, sacrifice: 4")
        XCTAssertEqual(DeckSelfRatings.text(["Focus": 7], traits: traits), "focus: 7")
        XCTAssertNil(DeckSelfRatings.text([:], traits: traits))
    }

    @MainActor
    func testRatingTraitsBuildsTheAnswerAndClearingThemAllDropsIt() async throws {
        store.setWorkspace("/vault", for: server)
        let model = makeViewModel(ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.selfRatingDeckJSON))
        await model.load()
        let card = try XCTUnwrap(model.cards.first { $0.id == "q-hormozi" })
        model.rateTrait("Intensity", 6, for: card)
        model.rateTrait("Consistency", 8, for: card)
        XCTAssertEqual(model.answer(for: card)?.text, "Consistency: 8, intensity: 6")
        XCTAssertEqual(model.traitScores(for: card), ["Consistency": 8, "Intensity": 6])
        model.rateTrait("Consistency", 9, for: card)
        XCTAssertEqual(model.answer(for: card)?.text, "Consistency: 9, intensity: 6", "another score replaces it")
        model.rateTrait("Consistency", 9, for: card)
        XCTAssertEqual(model.answer(for: card)?.text, "intensity: 6", "tapping the chosen score clears it")
        model.rateTrait("Intensity", 6, for: card)
        XCTAssertNil(model.answer(for: card), "no scores, no answer")
        model.rateTrait("Focus", 5, for: card)
        let deck = try DailyDeck.decode(Self.selfRatingDeckJSON)
        let payload = DeckAnswersPayload(deck: deck, answers: ["q-hormozi": try XCTUnwrap(model.answer(for: card))], completedAt: morning)
        XCTAssertEqual(payload.answers.first?.text, "focus: 5", "filed as text, like a typed answer")
    }

    func testSleepCardDecodesItsTagsTilesCoachAndHRV() throws {
        let card = try DailyDeck.decode(Self.sleepDeckJSON).cards[0]
        XCTAssertEqual(card.tags.map(\.id), ["late_meal", "ill"], "a tag without a label is dropped")
        let sleep = try XCTUnwrap(card.sleep)
        XCTAssertEqual(sleep.insight, "4 wake-ups against 2 on a usual night: a broken night.")
        XCTAssertEqual(sleep.tiles.map(\.label), ["Wake-ups", "Asleep"], "a malformed tile is dropped")
        XCTAssertEqual(sleep.tiles[0].note, "usually 2 · 54 min awake")
        XCTAssertNil(sleep.tiles[1].note)
        XCTAssertEqual(sleep.coach, DeckSleepCoach(name: "Dr. Mara Quinn", text: "Finish dinner by 7:30 pm."))
        XCTAssertEqual(sleep.hrvBand, 85...104)
        XCTAssertEqual(sleep.hrvStatus, "balanced")
        XCTAssertEqual(sleep.nights.map(\.hrv), [92, nil, nil])
        let bare = try DailyDeck.decode(#"{"date":"d","kind":"morning","cards":[{"id":"sleep","type":"sleep","sleep":{"hrv_band":[104,85],"coach":{"name":"x"}}}]}"#).cards[0]
        XCTAssertEqual(bare.tags, [])
        XCTAssertNil(bare.sleep?.insight)
        XCTAssertEqual(bare.sleep?.tiles, [])
        XCTAssertNil(bare.sleep?.coach, "a note without text is dropped")
        XCTAssertNil(bare.sleep?.hrvBand, "a backwards range is dropped")
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

    // MARK: - Style signals

    @MainActor
    func testToggleStyleTwiceClears() async throws {
        let viewModel = try await loadedViewModel(Self.feedbackDeckJSON)
        let book = try XCTUnwrap(viewModel.cards.first { $0.id == "book" })
        viewModel.toggleStyle(.tooLong, on: book)
        viewModel.toggleStyle(.voice, on: book)
        viewModel.setStyleNote("  say it plainly ", on: book)
        XCTAssertEqual(viewModel.signals.style["book"], DeckStyleMark(chips: ["too-long", "voice"], note: "say it plainly"))
        XCTAssertEqual(store.signals(for: server, date: "2026-10-04", kind: "morning"), viewModel.signals, "kept as a draft")
        viewModel.setStyleNote("", on: book)
        XCTAssertEqual(viewModel.signals.style["book"]?.note, "say it plainly", "reopening the sheet with an empty note keeps his words")
        viewModel.toggleStyle(.tooLong, on: book)
        viewModel.toggleStyle(.voice, on: book)
        XCTAssertTrue(viewModel.signals.isEmpty)
    }

    @MainActor
    func testFilingSendsSignalsAndUsageAloneIsNoChange() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.feedbackDeckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        let book = try XCTUnwrap(viewModel.cards.first { $0.id == "book" })
        viewModel.toggleStyle(.jargon, on: book)
        _ = await viewModel.file()
        XCTAssertEqual(client.fileRequests.first?.answers.style, [DeckSignalRows.Style(card: "book", chips: ["jargon"], note: nil)])
        XCTAssertFalse(viewModel.hasChanges)
        viewModel.choose("a", on: book)
        XCTAssertTrue(viewModel.hasChanges, "a pick after filing asks to file again")
    }

    @MainActor
    func testUndoAfterFilingMarksChanges() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.feedbackDeckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: try XCTUnwrap(viewModel.cards.first { $0.id == "book" }))
        _ = await viewModel.file()
        XCTAssertFalse(viewModel.hasChanges)
        viewModel.undoLearned("wiki.length.shorter")
        XCTAssertTrue(viewModel.hasChanges, "the close card offers to file the undo")
        XCTAssertEqual(viewModel.signals.undo, ["wiki.length.shorter"])
        viewModel.undoLearned("wiki.length.shorter")
        XCTAssertFalse(viewModel.hasChanges)
        XCTAssertEqual(viewModel.signals.undo, [])
    }

    @MainActor
    func testVariantCardAndPick() async throws {
        let viewModel = try await loadedViewModel(DeckVariantTests.deckJSON)
        let card = try XCTUnwrap(viewModel.variantCard)
        XCTAssertEqual(card.id, "pick-1", "the first card with a variant")
        viewModel.choose("b", on: card)
        XCTAssertEqual(viewModel.signals.pick, DeckPick(card: "pick-1", chose: "b"))
        viewModel.choose("a", on: card)
        XCTAssertEqual(viewModel.signals.pick, DeckPick(card: "pick-1", chose: "a"), "choosing the other face replaces it")
        viewModel.choose("a", on: card)
        XCTAssertNil(viewModel.signals.pick, "choosing it again clears the pick")
    }

    @MainActor
    func testUsageFoldsIntoSignals() async throws {
        let viewModel = try await loadedViewModel(Self.feedbackDeckJSON)
        viewModel.screenAppeared()
        viewModel.index = 1
        viewModel.showCard(viewModel.currentCardID)
        viewModel.reachedEnd("book")
        viewModel.reachedEnd("wiki")  // not on screen: ignored
        viewModel.opened("map", on: "book")
        viewModel.opened("map", on: "book")
        viewModel.opened("source", on: "book")
        viewModel.showCard(nil)
        let usage = try XCTUnwrap(viewModel.signals.usage["book"])
        XCTAssertTrue(usage.reachedEnd)
        XCTAssertEqual(usage.opened, ["map", "source"])
        XCTAssertGreaterThanOrEqual(usage.seconds, 0)
        XCTAssertNil(viewModel.signals.usage["wiki"])
    }

    @MainActor
    func testFiledUsageCarriesAnswerLength() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.feedbackDeckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        let book = try XCTUnwrap(viewModel.cards.first { $0.id == "book" })
        viewModel.showCard("book")
        viewModel.opened("map", on: "book")  // the test clock stands still, so time alone makes no usage row
        viewModel.setText("Twelve chars", for: book)
        viewModel.showCard(nil)
        _ = await viewModel.file()
        XCTAssertEqual(client.fileRequests.first?.answers.usage?.first?.answerChars, 12)
    }

    @MainActor
    func testReachedEndCountsTheCardOnScreenWhateverOrderTheViewsReport() async throws {
        let viewModel = try await loadedViewModel(Self.feedbackDeckJSON)
        viewModel.reachedEnd("book")  // drawn as the next card under the headline: ignored
        XCTAssertNil(viewModel.signals.usage["book"])
        viewModel.index = 1  // swiped to it; the card view re-reports its end before the deck view calls showCard
        viewModel.reachedEnd("book")
        XCTAssertEqual(viewModel.signals.usage["book"]?.reachedEnd, true)
    }

    @MainActor
    func testTheClockRunsWhileTheDeckOrItsOpenCardIsOnScreen() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.feedbackDeckJSON)
        var clock = morning
        let viewModel = DailyDeckViewModel(server: server, client: client, store: store, now: { clock })
        await viewModel.load()
        viewModel.screenAppeared()
        viewModel.index = 1
        viewModel.showCard(viewModel.currentCardID)
        clock += 10
        viewModel.screenAppeared()     // the card opens full screen
        viewModel.screenDisappeared()  // the deck under it goes away
        clock += 20
        viewModel.scenePhaseChanged(active: false)
        clock += 600                   // backgrounded
        viewModel.scenePhaseChanged(active: true)
        clock += 5
        viewModel.screenDisappeared()  // the open card closes...
        clock += 100                   // ...and nothing shows the deck (another tab)
        viewModel.screenAppeared()
        clock += 5
        viewModel.showCard(nil)
        XCTAssertEqual(viewModel.signals.usage["book"]?.seconds, 40)
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

    private func pieceCard(_ json: String) throws -> DeckCard {
        try JSONDecoder().decode(DeckCard.self, from: Data(json.utf8))
    }

    func testAPieceCardDecodesItsArgumentAndLeadsWithTheHeadline() throws {
        let item = try pieceCard("""
        {"id": "youtube", "type": "item", "kind": "youtube", "title": "RAG isn't dead.", "source": "Learn RAG · 3 hours · 15 parts",
         "context": "How it gets there.", "body": null,
         "piece": {"map": "rag", "meta": "3 hours · 15 parts",
                   "steps": [{"name": "Basics", "claim": "Index, fetch, prompt.", "span": "Parts 1–2 · from 0:00"},
                             {"claim": "  "}, {"claim": "Grade what came back."}, {"nope": 1}],
                   "quotes": [{"text": "RAG is not dead but it will change", "at": "Part 14 · ~2:36"}, {"text": ""}]}}
        """)
        let piece = try XCTUnwrap(item.piece)
        XCTAssertEqual(piece.steps.map(\.claim), ["Index, fetch, prompt.", "Grade what came back."], "blank and broken steps drop")
        XCTAssertEqual(piece.steps[0].span, "Parts 1–2 · from 0:00")
        XCTAssertNil(piece.steps[1].span)
        XCTAssertEqual(piece.quotes.map(\.text), ["RAG is not dead but it will change"])
        let text = DeckCardText(item)
        XCTAssertEqual(text.lead, "RAG isn't dead.")
        XCTAssertEqual(text.attribution, "Learn RAG · 3 hours · 15 parts")
        XCTAssertEqual(text.detail, "How it gets there.")

        let noSteps = try pieceCard(#"{"id": "x", "type": "item", "piece": {"steps": [], "quotes": [{"text": "q"}]}}"#)
        XCTAssertNil(noSteps.piece, "a piece with no argument isn't drawn")
    }

    func testAMapEntryIsLabelledAsAMap() throws {
        let index = BriefDiagramIndex.decode("""
        {"version": 1, "diagrams": [
          {"topic": "map-rag", "title": "The map: RAG", "kind": "map", "keys": ["video:rag"]},
          {"topic": "kafka", "title": "Kafka", "keys": ["media:kafka"]}
        ]}
        """)
        XCTAssertEqual(index.diagrams.map(\.isMap), [true, false])
        let pick = try pieceCard(#"{"id": "pick-1", "type": "reflect", "ref": {"pool": "video:rag"}}"#)
        XCTAssertEqual(index.diagram(for: pick)?.topic, "map-rag")
    }

    func testAPieceCardShowsItsMapThenItsTopicDiagram() throws {
        let index = BriefDiagramIndex.decode("""
        {"version": 1, "diagrams": [
          {"topic": "rag-pipeline", "title": "RAG pipeline", "keys": ["video:rag", "media:other"]},
          {"topic": "rag-2", "title": "Another", "keys": ["video:rag"]},
          {"topic": "map-rag", "title": "The map: RAG", "kind": "map", "keys": ["video:rag"]}
        ]}
        """)
        let pick = try pieceCard(#"{"id": "pick-1", "type": "reflect", "ref": {"pool": "video:rag"}}"#)
        XCTAssertEqual(index.diagrams(for: pick).map(\.topic), ["map-rag", "rag-pipeline"], "the map, then one diagram")
        let other = try pieceCard(#"{"id": "pick-2", "type": "reflect", "ref": {"pool": "media:other"}}"#)
        XCTAssertEqual(index.diagrams(for: other).map(\.topic), ["rag-pipeline"])
    }

    @MainActor
    func testAVaultWithoutDiagramsShowsNoChips() async throws {
        let viewModel = try await loadedViewModel(Self.diagramDeckJSON)
        XCTAssertTrue(viewModel.cards.allSatisfy { viewModel.diagram(for: $0) == nil })
    }

    // MARK: - Helpers

    @MainActor
    private func makeViewModel(_ client: ScriptedDailyDeckClient, feedback: (any FeedbackDataClient)? = nil) -> DailyDeckViewModel {
        let now = morning
        return DailyDeckViewModel(server: server, client: client, store: store, feedback: feedback, now: { now })
    }

    static let selfRatingDeckJSON = """
    {"version": 1, "date": "2026-10-04", "kind": "morning", "cards": [
      {"id": "q-hormozi", "type": "prompt", "question": "Rate yourself 1–10 on consistency, intensity, focus, boredom tolerance, and sacrifice."},
      {"id": "q-week", "type": "prompt", "question": "What went well this week?"}
    ]}
    """

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

/// A stale What changed card's Undo against `URLProtocol` mocks: the server's transition 409.
final class DeckUndoHTTPTests: APIClientTestCase {
    @MainActor
    private func undo(answering body: String) async throws -> (DailyDeckViewModel, DeckChangeRow) {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/feedback/fb-1/decision")
            return apiTestJSONResponse(body, for: request, status: 409)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DeckUndoHTTPTests.\(UUID().uuidString)"))
        let viewModel = DailyDeckViewModel(
            server: URL(string: "https://example.test")!,
            client: ScriptedDailyDeckClient(workspaces: [], names: [], deck: DailyDeckTests.deckJSON),
            store: DailyDeckStore(defaults: defaults),
            feedback: APIClientFeedbackAdapter(apiClient: client))
        let row = try DailyDeckTests.changeRow(id: "fb-1", state: "shipped", undoable: true)
        await viewModel.undoChange(row)
        return (viewModel, row)
    }

    @MainActor
    func testAlreadyUndoneSaysSoAndFlipsTheRow() async throws {
        let (viewModel, row) = try await undo(answering: #"{"error": "cannot go from reverted to reverted", "status": "reverted"}"#)

        XCTAssertEqual(viewModel.changeNotices["fb-1"], "Already undone")
        XCTAssertNil(viewModel.changeErrors["fb-1"], "the raw transition error never shows")
        XCTAssertEqual(viewModel.changeState(row), .reverted)
        XCTAssertFalse(viewModel.canUndo(row))
    }

    @MainActor
    func testAnotherConflictStillShowsTheServersReason() async throws {
        let (viewModel, row) = try await undo(answering: #"{"error": "The vault has uncommitted edits to tools/deck_pool.py.", "status": "shipped"}"#)

        XCTAssertEqual(viewModel.changeErrors["fb-1"], "The vault has uncommitted edits to tools/deck_pool.py.")
        XCTAssertNil(viewModel.changeNotices["fb-1"])
        XCTAssertEqual(viewModel.changeState(row), .shipped)
        XCTAssertTrue(viewModel.canUndo(row))
    }
}

/// A clock the test moves by hand.
/// The feedback API as the What changed card uses it: decisions only.
actor DeckFeedbackStub: FeedbackDataClient {
    struct Decided: Sendable {
        let id: String
        let decision: FeedbackDecision
    }

    private(set) var decisions: [Decided] = []
    private var decisionError: Error?

    func fail(with error: Error) { decisionError = error }

    func list() async throws -> [FeedbackEntry] { [] }
    func plan(id: String) async throws -> FeedbackPlan { FeedbackPlan(markdown: "") }
    func create(_ body: FeedbackCreate) async throws -> FeedbackEntry { throw APIError.http(statusCode: 500, body: nil) }

    func decide(id: String, _ decision: FeedbackDecision) async throws -> FeedbackEntry {
        decisions.append(Decided(id: id, decision: decision))
        if let decisionError { throw decisionError }
        return try FeedbackDecoding.decode(FeedbackEntry.self, from: Data(#"{"id":"\#(id)","status":"reverted"}"#.utf8))
    }

    func isAvailable() async -> Bool { true }
}

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
    /// What `uploadWeekPhoto` does; succeeds by default.
    var photoUpload: Result<Void, Error> = .success(())
    /// What `deleteWeekPhoto` does; succeeds by default.
    var photoDelete: Result<Void, Error> = .success(())
    private(set) var uploadedPhotos: [(weekEnding: String, jpeg: Data)] = []
    private(set) var deletedPhotos: [String] = []
    /// Bytes `rawFile` returns by path; a path not here is a 404.
    var rawFiles: [String: Data] = [:]
    /// Bodies by path; anything else reads as `deck`.
    var files: [String: String] = [:]
    /// Folder listings other than `briefs/`.
    var listings: [String: [String]] = [:]
    /// Errors a listing throws instead, by path.
    var listingErrors: [String: Error] = [:]
    private(set) var createdWorkspaces: [String] = []
    private(set) var renamed: [(String, String)] = []
    private(set) var listedSessions: [String] = []
    private(set) var readPaths: [String] = []
    private let readLock = NSLock()
    private(set) var sent: [Sent] = []
    /// What `draftIntention` answers; an empty draft (the route's `{}`) by default.
    var intentionDraft: Result<WeekIntentionDraft, Error> = .success(WeekIntentionDraft())
    /// Runs inside `draftIntention` before it answers, to hold a draft in flight.
    var intentionGate: (@Sendable () async -> Void)?
    private(set) var intentionRequests: [(date: String, answers: DeckAnswersPayload)] = []
    /// The Goals server's today, sent back as `as_of`.
    var serverToday: Result<String, Error> = .success("2026-10-25")
    /// What `confirmWeek` does; succeeds by default.
    var weekConfirm: Result<Void, Error> = .success(())
    /// Runs inside `confirmWeek` before it answers, to hold a confirm in flight.
    var confirmGate: (@Sendable () async -> Void)?
    private(set) var weekRequests: [GoalWeekRequest] = []

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
        if let error = listingErrors[path] { throw error }
        if let listing = listings[path] { return listing }
        if path != DailyDeckPaths.directory { throw APIError.http(statusCode: 404, body: #"{"error": "Not a directory"}"#) }
        listedSessions.append(sessionID)
        if vanished.contains(sessionID) { throw APIError.http(statusCode: 404, body: #"{"error": "Session not found"}"#) }
        guard let names else { throw APIError.http(statusCode: 404, body: #"{"error": "Not a directory"}"#) }
        return names
    }

    func fileContent(sessionID: String, path: String) async throws -> String {
        // Week records are read concurrently.
        readLock.withLock { readPaths.append(path) }
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

    func rawFile(sessionID: String, path: String) async throws -> Data {
        guard let data = rawFiles[path] else { throw APIError.http(statusCode: 404, body: nil) }
        return data
    }

    func uploadWeekPhoto(weekEnding: String, jpeg: Data) async throws {
        uploadedPhotos.append((weekEnding, jpeg))
        try photoUpload.get()
    }

    func deleteWeekPhoto(weekEnding: String) async throws {
        deletedPhotos.append(weekEnding)
        try photoDelete.get()
    }

    func draftIntention(date: String, answers: DeckAnswersPayload) async throws -> WeekIntentionDraft {
        intentionRequests.append((date, answers))
        await intentionGate?()
        try Task.checkCancellation()  // as `URLSession` does when the caller's task is cancelled
        return try intentionDraft.get()
    }

    func goalsToday() async throws -> String { try serverToday.get() }

    func confirmWeek(_ request: GoalWeekRequest) async throws {
        weekRequests.append(request)
        await confirmGate?()
        try weekConfirm.get()
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

    func testAWeekOfHalfPastSevenNotificationsAndEightOClockRemindersFollow() {
        let plan = DailyBriefReminder.plan(now: at(8, 5), filedOn: nil, calendar: calendar)
        let ready = plan.filter { !$0.isReminder && $0.review == nil }
        let reminders = plan.filter(\.isReminder)
        XCTAssertEqual(ready.first, .init(id: "dailyBrief.ready.2026-10-08",
                                          components: DateComponents(year: 2026, month: 10, day: 8, hour: 7, minute: 30),
                                          repeats: false, isReminder: false))
        XCTAssertEqual(reminders.map(\.id).first, "dailyBrief.reminder.2026-10-08")
        XCTAssertEqual([ready.count, reminders.count], [7, 7])
        XCTAssertTrue(ready.allSatisfy { !$0.repeats && $0.components.hour == 7 && $0.components.minute == 30 })
        XCTAssertTrue(reminders.allSatisfy { !$0.repeats && $0.components.hour == 8 && $0.components.minute == 0 })
    }

    func testFilingTodaysBriefSkipsOnlyTodaysNotifications() {
        let plan = DailyBriefReminder.plan(now: at(8, 6, 30), filedOn: "2026-10-08", calendar: calendar)
        XCTAssertEqual(plan.filter { !$0.isReminder && $0.review == nil }.map(\.id).first, "dailyBrief.ready.2026-10-09")
        XCTAssertEqual(plan.filter(\.isReminder).map(\.id).first, "dailyBrief.reminder.2026-10-09")
        XCTAssertEqual(plan.filter(\.isReminder).count, 6)
        XCTAssertEqual(plan.compactMap(\.review), [.init(date: "2026-10-11", kind: "weekly")], "Sunday's review")
    }

    func testUnfiledAtQuarterToEightOnlyTodaysReminderIsLeft() {
        let plan = DailyBriefReminder.plan(now: at(8, 7, 45), filedOn: nil, calendar: calendar)
        XCTAssertEqual(plan.filter { !$0.isReminder && $0.review == nil }.map(\.id).first, "dailyBrief.ready.2026-10-09")
        XCTAssertEqual(plan.filter(\.isReminder).map(\.id).first, "dailyBrief.reminder.2026-10-08")
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
        let reviews = DailyBriefReminder.plan(now: friday, filedOn: nil, calendar: calendar).compactMap(\.review)
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

private final class MandarinSpySynthesizer: ChatSpeechSynthesizing {
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking = false
    var isPaused = false
    private(set) var spoken: [AVSpeechUtterance] = []
    private(set) var stops = 0

    func speak(_ utterance: AVSpeechUtterance) {
        spoken.append(utterance)
        isSpeaking = true
    }

    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops += 1
        isSpeaking = false
        return true
    }
}

private final class MandarinSpySession: ListenAudioSessionControlling {
    private(set) var activations = 0
    private(set) var deactivations = 0
    func activate() { activations += 1 }
    func deactivate() { deactivations += 1 }
}

/// A scripted Mandarin API: answers and recalls succeed with what's queued, or throw.
private final class FakeMandarinClient: MandarinPracticeClient, @unchecked Sendable {
    var answers: [MandarinAnswerRequest] = []
    var recalls: [MandarinRecallRequest] = []
    var answerResult: Result<MandarinAnswerResponse, Error> = .success(MandarinAnswerResponse(feedback: nil))
    var recallFails = false

    func answer(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse {
        answers.append(request)
        return try answerResult.get()
    }

    func recall(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse {
        recalls.append(request)
        if recallFails { throw URLError(.notConnectedToInternet) }
        return try JSONDecoder().decode(MandarinRecallResponse.self, from: Data(#"{"ok":true,"progress":{"phrases":9}}"#.utf8))
    }

    var preps: [MandarinCallPrepRequest] = []
    var afters: [MandarinCallAfterRequest] = []
    var callResult: Result<MandarinCallResponse, Error> = .success(MandarinCallResponse(items: []))

    func callPrep(_ request: MandarinCallPrepRequest) async throws -> MandarinCallResponse {
        preps.append(request)
        return try callResult.get()
    }

    func callAfter(_ request: MandarinCallAfterRequest) async throws -> MandarinCallResponse {
        afters.append(request)
        return try callResult.get()
    }
}

@MainActor
final class MandarinPracticeTests: XCTestCase {
    private static let deckJSON = """
    {"date": "2026-10-25", "kind": "morning", "cards": [
      {"id": "mandarin", "type": "prompt", "kind": "mandarin", "title": "Dad asks about the job search",
       "yesterday": {"said": "我要继续喝很多水，休息早一点。", "natural": "我要多喝水，早一点休息。",
                     "fixes": [{"said": "休息早一点", "natural": "早一点休息", "natural_pinyin": "zǎo yì diǎn xiū xi",
                                "en": "rest earlier", "why": "Time words go before the verb."},
                               {"said": "bad"}],
                     "gaps": [{"en": "anxious", "hanzi": "紧张", "pinyin": "jǐn zhāng", "build": "tight + stretched"}],
                     "pattern": {"pattern": "因为…所以…", "en": "Reason, then result."}},
       "phrases": [{"hanzi": "还不错", "en": "Not bad"}, {"hanzi": "在等消息", "en": ""}],
       "recall": [{"hanzi": "宝宝一月份出生。", "en": "The baby is due in January.", "source": "lesson"},
                  {"hanzi": "紧张", "en": "anxious", "source": "gap"}],
       "pattern": {"id": "stpvo", "name": "Time and place before the verb", "form": "我 + 昨天 + 在家 + 看书", "en": "Who, when, where."},
       "progress": {"phrases": 36, "used_week": 6, "english_now": 1.2, "english_before": 2.8},
       "question": "你找工作找得怎么样了？"}
    ]}
    """

    private var defaults: UserDefaults!
    private let server = URL(string: "https://hermes.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "MandarinPracticeTests.\(UUID().uuidString)")
    }

    private func card(_ json: String = deckJSON) throws -> DeckCard { try DailyDeck.decode(json).cards[0] }

    private func practice(_ card: DeckCard, client: FakeMandarinClient?) -> MandarinPractice {
        MandarinPractice(card: card, date: "2026-10-25", server: server, client: client,
                         store: MandarinPracticeStore(defaults: defaults))
    }

    func testCardDecodesRecallPatternProgressAndStructuredFeedback() throws {
        let card = try card()
        XCTAssertEqual(card.recall.map(\.source), ["lesson", "gap"])
        XCTAssertNil(card.phrases[1].en, "an empty English cue is no cue")
        XCTAssertEqual(card.pattern?.form, "我 + 昨天 + 在家 + 看书")
        XCTAssertEqual(card.progress, DeckMandarinProgress(phrases: 36, usedWeek: 6, englishNow: 1.2, englishBefore: 2.8))
        XCTAssertEqual(card.yesterday?.fixes.map(\.natural), ["早一点休息"], "a fix without its natural words is dropped")
        XCTAssertEqual(card.yesterday?.gaps.first?.build, "tight + stretched")
        XCTAssertEqual(card.yesterday?.pattern?.pattern, "因为…所以…")
    }

    func testStepsStartAtTheFixAndMoveOnAsEachIsDone() async throws {
        let client = FakeMandarinClient()
        let practice = practice(try card(), client: client)
        XCTAssertEqual(practice.steps, [.fix, .recall, .talk])
        XCTAssertEqual(practice.step, .fix)
        XCTAssertEqual(practice.currentFix?.said, "休息早一点")
        practice.nextFix()
        XCTAssertEqual(practice.step, .recall)
        await practice.recall(try XCTUnwrap(practice.currentRecall), got: true)
        XCTAssertEqual(practice.currentRecall?.hanzi, "紧张")
        XCTAssertEqual(practice.progress?.phrases, 9, "a recall brings the server's progress back")
        await practice.recall(try XCTUnwrap(practice.currentRecall), got: false)
        XCTAssertEqual(practice.step, .talk)
        XCTAssertEqual(client.recalls.map(\.got), [true, false])
        XCTAssertEqual(practice.record.recalled, ["宝宝一月份出生。": true, "紧张": false])
    }

    func testAFailedRecallStaysOnThePhrase() async throws {
        let client = FakeMandarinClient()
        client.recallFails = true
        let practice = practice(try card(), client: client)
        let phrase = try XCTUnwrap(practice.currentRecall)
        await practice.recall(phrase, got: true)
        XCTAssertEqual(practice.currentRecall, phrase, "nothing counts until the server has it")
        XCTAssertNotNil(practice.recallError)
    }

    func testAnswerBringsFeedbackOnceAndAgainOnlyForNewWords() async throws {
        let client = FakeMandarinClient()
        let feedback = try JSONDecoder().decode(MandarinAnswerResponse.self, from: Data(#"""
        {"feedback": {"natural": "我最近面试了三家公司，有点紧张，不过感觉还不错。"}, "used": ["还不错"], "progress": {"phrases": 38}}
        """#.utf8))
        client.answerResult = .success(feedback)
        let practice = practice(try card(), client: client)
        await practice.submit("  我最近面试了三家公司，有一点anxious，可是还不错  ", question: nil)
        XCTAssertEqual(practice.result, feedback)
        XCTAssertEqual(practice.answering, .idle)
        XCTAssertEqual(practice.progress?.phrases, 38)
        XCTAssertTrue(practice.isDone(.talk))
        await practice.submit("我最近面试了三家公司，有一点anxious，可是还不错", question: nil)
        XCTAssertEqual(client.answers.count, 1, "the same answer isn't sent twice")
        await practice.submit("我最近面试了三家公司。", question: "你好吗？")
        XCTAssertEqual(client.answers.map(\.question), [nil, "你好吗？"])
    }

    func testAnswerWithoutFeedbackOrServerCanBeTriedAgain() async throws {
        let client = FakeMandarinClient()
        client.answerResult = .failure(URLError(.timedOut))
        let practice = practice(try card(), client: client)
        await practice.submit("还不错", question: nil)
        XCTAssertEqual(practice.answering, .failed("Couldn't reach the server. Try again."))
        XCTAssertNil(practice.result)
        client.answerResult = .success(MandarinAnswerResponse(feedback: nil))
        await practice.retry()
        XCTAssertEqual(practice.answering, .idle)
        XCTAssertNil(practice.result?.feedback, "no feedback yet: tomorrow's card brings it")
        await practice.retry()
        XCTAssertEqual(client.answers.count, 3, "an answer without feedback can be sent again")
    }

    func testThePracticeResumesForTheSameServerAndDayOnly() async throws {
        let card = try card()
        let first = practice(card, client: FakeMandarinClient())
        first.nextFix()
        await first.recall(try XCTUnwrap(first.currentRecall), got: true)
        let again = practice(card, client: FakeMandarinClient())
        XCTAssertEqual(again.step, .recall)
        XCTAssertEqual(again.currentRecall?.hanzi, "紧张")
        let other = MandarinPractice(card: card, date: "2026-10-25", server: URL(string: "https://other.example")!,
                                     client: nil, store: MandarinPracticeStore(defaults: defaults))
        XCTAssertEqual(other.step, .fix, "another server starts fresh")
    }

    func testACardWithoutYesterdayOrRecallStartsAtTalk() throws {
        let card = try card(#"{"date":"d","kind":"morning","cards":[{"id":"m","type":"prompt","kind":"mandarin","question":"你好吗？"}]}"#)
        let practice = practice(card, client: nil)
        XCTAssertEqual(practice.steps, [.talk])
        XCTAssertEqual(practice.step, .talk)
    }

    func testCallPrepIsAskedOncePerRelativeAndKept() async throws {
        let client = FakeMandarinClient()
        let item = MandarinCallItem(en: "I had three interviews", hanzi: "我这个星期面试了三次", pinyin: "Wǒ")
        client.callResult = .success(MandarinCallResponse(items: [item]))
        let practice = practice(try card(), client: client)
        await practice.prepareCall("mom")
        await practice.prepareCall("mom")
        XCTAssertEqual(client.preps.map(\.who), ["mom"], "the day's prep for Mom is kept")
        XCTAssertEqual(practice.record.callPrep["mom"], [item])
        XCTAssertNil(practice.callLoading)
        let again = self.practice(try card(), client: client)
        XCTAssertEqual(again.record.callPrep["mom"], [item], "it's still there when the card comes back")
    }

    func testAnEmptyOrFailedPrepSaysSoAndKeepsNothing() async throws {
        let client = FakeMandarinClient()
        let practice = practice(try card(), client: client)
        await practice.prepareCall("dad")
        XCTAssertEqual(practice.callError, "Nothing came back. Try again.")
        client.callResult = .failure(URLError(.timedOut))
        await practice.prepareCall("dad")
        XCTAssertEqual(practice.callError, "Couldn't reach the server. Try again.")
        XCTAssertNil(practice.record.callPrep["dad"])
    }

    func testAfterTheCallPhrasesAreKeptAndAFailureKeepsHisWords() async throws {
        let client = FakeMandarinClient()
        let phrase = MandarinCallItem(en: "the due date moved", hanzi: "预产期改了", pinyin: nil)
        client.callResult = .success(MandarinCallResponse(items: [phrase], progress: DeckMandarinProgress(
            phrases: 40, usedWeek: nil, englishNow: nil, englishBefore: nil)))
        let practice = practice(try card(), client: client)
        let saved = await practice.saveAfterCall("  the due date moved  ")
        XCTAssertTrue(saved)
        XCTAssertEqual(client.afters.map(\.text), ["the due date moved"])
        XCTAssertEqual(practice.record.callPhrases, [phrase])
        XCTAssertEqual(practice.progress?.phrases, 40)
        client.callResult = .failure(URLError(.timedOut))
        let failed = await practice.saveAfterCall("I'm nervous about the race")
        XCTAssertFalse(failed, "the sheet keeps his words to try again")
        XCTAssertEqual(practice.record.callPhrases, [phrase])
    }

    func testCallResponseReadsItemsOrPhrases() throws {
        let prep = try JSONDecoder().decode(MandarinCallResponse.self, from: Data(#"{"items":[{"en":"a","hanzi":"好"},{"en":"no hanzi"}]}"#.utf8))
        XCTAssertEqual(prep.items.map(\.hanzi), ["好"])
        let after = try JSONDecoder().decode(MandarinCallResponse.self, from: Data(#"{"phrases":[{"en":"b","hanzi":"对"}],"progress":{"phrases":3}}"#.utf8))
        XCTAssertEqual(after.items.map(\.hanzi), ["对"])
        XCTAssertEqual(after.progress?.phrases, 3)
    }

    func testProgressLine() {
        XCTAssertEqual(MandarinProgressLine.text(DeckMandarinProgress(phrases: 36, usedWeek: 6, englishNow: 1.2, englishBefore: 3)),
                       "36 phrases · 6 used this week · English per answer 3 → 1.2")
        XCTAssertEqual(MandarinProgressLine.text(DeckMandarinProgress(phrases: 1, usedWeek: nil, englishNow: nil, englishBefore: nil)),
                       "1 phrase")
        XCTAssertNil(MandarinProgressLine.text(DeckMandarinProgress(phrases: nil, usedWeek: nil, englishNow: nil, englishBefore: nil)))
    }
}
