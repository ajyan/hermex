import XCTest
@testable import HermesMobile

/// The style signals filed beside a deck's answers (`DeckSignals`): what tools/style_learn.py learns from.
final class DeckSignalsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let server = URL(string: "https://brain.example.test")!
    private let morning = Date(timeIntervalSince1970: 1_791_100_000)

    override func setUp() {
        super.setUp()
        suiteName = "DeckSignalsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    static let deckJSON = """
    {"date": "2026-10-04", "kind": "morning", "cards": [
      {"id": "headline", "type": "headline", "title": "Today"},
      {"id": "book", "type": "reflect", "kind": "book", "title": "Four Thousand Weeks", "question": "First?"},
      {"id": "wiki", "type": "reflect", "kind": "wiki", "title": "Systems", "question": "Own?"},
      {"id": "close", "type": "close"}
    ]}
    """

    private func json(_ payload: DeckAnswersPayload) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(payload)) as? [String: Any])
    }

    func testPayloadOmitsEmptySignals() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        let body = try json(DeckAnswersPayload(deck: deck, answers: [:], signals: DeckSignals(), completedAt: morning))
        for key in ["style", "usage", "pick", "undo"] {
            XCTAssertNil(body[key], "\(key) is left out when empty")
        }
    }

    func testPayloadEncodesSignalsInDeckOrder() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        var signals = DeckSignals()
        signals.style["wiki"] = DeckStyleMark(chips: ["jargon"])
        signals.style["book"] = DeckStyleMark(chips: ["too-long", "voice"], note: "plainer")
        signals.usage["book"] = DeckUsage(seconds: 12.5, reachedEnd: true, opened: ["map"], answerChars: 40)
        signals.pick = DeckPick(card: "wiki", chose: "b")
        signals.undo = ["wiki.length.shorter"]
        let body = try json(DeckAnswersPayload(deck: deck, answers: [:], signals: signals, completedAt: morning))

        let style = try XCTUnwrap(body["style"] as? [[String: Any]])
        XCTAssertEqual(style.map { $0["card"] as? String }, ["book", "wiki"])
        XCTAssertEqual(style.first?["chips"] as? [String], ["too-long", "voice"])
        XCTAssertEqual(style.first?["note"] as? String, "plainer")
        let usage = try XCTUnwrap((body["usage"] as? [[String: Any]])?.first)
        XCTAssertEqual(usage["reached_end"] as? Bool, true)
        XCTAssertEqual(usage["answer_chars"] as? Int, 40)
        XCTAssertEqual(usage["opened"] as? [String], ["map"])
        XCTAssertEqual(body["pick"] as? [String: String], ["card": "wiki", "chose": "b"])
        XCTAssertEqual(body["undo"] as? [String], ["wiki.length.shorter"])
    }

    func testSignalsPersistPerDeck() {
        let store = DailyDeckStore(defaults: defaults)
        var first = DeckSignals()
        first.undo = ["wiki.length.shorter"]
        var second = DeckSignals()
        second.style["book"] = DeckStyleMark(chips: ["too-thin"])
        store.setSignals(first, for: server, date: "2026-10-03", kind: "morning")
        store.setSignals(second, for: server, date: "2026-10-04", kind: "morning")
        XCTAssertEqual(store.signals(for: server, date: "2026-10-03", kind: "morning"), first)
        XCTAssertEqual(store.signals(for: server, date: "2026-10-04", kind: "morning"), second)
        store.setSignals(DeckSignals(), for: server, date: "2026-10-03", kind: "morning")
        XCTAssertTrue(store.signals(for: server, date: "2026-10-03", kind: "morning").isEmpty)
    }

    func testFiledSignalsReadBack() {
        let filed = """
        {"version": 1, "answers": [], "style": [{"card": "book", "chips": ["too-long"]}, {"bad": 1}],
         "usage": [{"card": "book", "seconds": 9, "reached_end": false, "opened": [], "answer_chars": 0}],
         "pick": {"card": "wiki", "chose": "a"}, "undo": ["wiki.length.shorter"]}
        """
        let signals = DeckAnswersFile.decodeSignals(filed)
        XCTAssertEqual(signals.style, ["book": DeckStyleMark(chips: ["too-long"])], "a malformed row drops alone")
        XCTAssertEqual(signals.usage["book"]?.seconds, 9)
        XCTAssertEqual(signals.pick, DeckPick(card: "wiki", chose: "a"))
        XCTAssertEqual(signals.undo, ["wiki.length.shorter"])
        XCTAssertTrue(DeckAnswersFile.decodeSignals("{not json").isEmpty)
    }
}
