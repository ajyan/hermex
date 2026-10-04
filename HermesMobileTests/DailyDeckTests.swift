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
            "book": DeckAnswer(card: "book", reaction: .resonates),
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

    func testStoreKeepsOnlyTheLatestDecksAnswersAndOneDaysSession() {
        store.setAnswers(["a": DeckAnswer(card: "a", text: "x")], for: server, date: "2026-10-03", kind: "morning")
        store.setAnswers(["b": DeckAnswer(card: "b", text: "y")], for: server, date: "2026-10-04", kind: "morning")
        XCTAssertEqual(store.answers(for: server, date: "2026-10-03", kind: "morning"), [:])
        XCTAssertEqual(store.answers(for: server, date: "2026-10-04", kind: "morning")["b"]?.text, "y")

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

        let filed = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json", "2026-10-04.morning.answers.json"], deck: Self.deckJSON)
        let third = makeViewModel(filed)
        await third.load()
        XCTAssertEqual(third.state, .filed)
        XCTAssertEqual(filed.readPaths, [])
    }

    @MainActor
    func testAnswersSurviveANewViewModelAndToggleOff() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        let decision = viewModel.cards[2], book = viewModel.cards[4]

        viewModel.choose(decision.actions[1], for: decision)
        viewModel.react(.resonates, for: book)
        viewModel.react(.resonates, for: book)  // second tap clears it
        XCTAssertEqual(viewModel.answeredCount, 1)

        let reopened = makeViewModel(client)
        await reopened.load()
        XCTAssertEqual(reopened.answer(for: decision)?.action, "skip")
        XCTAssertNil(reopened.answer(for: book))
    }

    @MainActor
    func testFilingSendsOneMessageToTodaysSessionAndClearsTheDraft() async throws {
        store.setWorkspace("/vault", for: server)
        let client = ScriptedDailyDeckClient(workspaces: [], names: ["2026-10-04.morning.json"], deck: Self.deckJSON)
        let viewModel = makeViewModel(client)
        await viewModel.load()
        viewModel.setText("Ship it.", for: viewModel.cards[1])

        let opened = await viewModel.file()

        XCTAssertEqual(opened, "new-1")
        XCTAssertEqual(viewModel.state, .filed)
        XCTAssertEqual(client.sent.map(\.sessionID), ["new-1"])
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
        listedSessions.append(sessionID)
        if vanished.contains(sessionID) { throw APIError.http(statusCode: 404, body: #"{"error": "Session not found"}"#) }
        guard let names else { throw APIError.http(statusCode: 404, body: #"{"error": "Not a directory"}"#) }
        return names
    }

    func fileContent(sessionID: String, path: String) async throws -> String {
        readPaths.append(path)
        return deck
    }

    func startChat(sessionID: String, message: String, workspace: String) async throws {
        if let sendError { throw sendError }
        sent.append(Sent(sessionID: sessionID, message: message, workspace: workspace))
    }
}
