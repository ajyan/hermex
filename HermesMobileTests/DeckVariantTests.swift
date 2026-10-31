import XCTest
@testable import HermesMobile

/// The day's variant card (`DeckVariant`): one card written two ways, picked between on the close card.
final class DeckVariantTests: XCTestCase {
    static let deckJSON = """
    {"date": "2026-10-04", "kind": "morning", "cards": [
      {"id": "pick-1", "type": "reflect", "kind": "wiki", "title": "Loops", "context": "Short one.",
       "variant": {"dimension": "length", "shown": "b",
                   "a": {"dir": "fuller", "context": "One. Two. Three."},
                   "b": {"dir": "shorter", "context": "Short one."}}},
      {"id": "email", "type": "item", "kind": "email", "title": "Life",
       "variant": {"dimension": "structure", "a": {"dir": "parts"}, "b": {"dir": "gist"}}},
      {"id": "close", "type": "close"}
    ]}
    """

    func testDecodesVariant() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        let variant = try XCTUnwrap(deck.cards[0].variant)
        XCTAssertEqual(variant.dimension, "length")
        XCTAssertEqual(variant.shown, "b")
        XCTAssertEqual(variant.a.dir, "fuller")
        XCTAssertEqual(variant.a.context, "One. Two. Three.")
        XCTAssertEqual(variant.b.context, "Short one.")
    }

    func testMalformedVariantIsNil() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        XCTAssertNil(deck.cards[1].variant, "no shown face: the variant drops, the card stays")
        XCTAssertEqual(deck.cards[1].title, "Life")
    }

    func testPreviewsDropTheSharedStart() throws {
        let gist = #"{"label": "The gist", "text": "G."}"#, why = #"{"label": "Why it matters", "text": "W."}"#
        let variant = try JSONDecoder().decode(DeckVariant.self, from: Data("""
        {"dimension": "structure", "shown": "a",
         "a": {"dir": "parts", "entries": [\(gist), {"label": "Idea", "text": "I."}, \(why)]},
         "b": {"dir": "gist", "entries": [\(gist), \(why)]}}
        """.utf8))
        XCTAssertEqual(variant.previews.a, "…\nIdea: I.\nWhy it matters: W.")
        XCTAssertEqual(variant.previews.b, "…\nWhy it matters: W.")
        let quotes = try JSONDecoder().decode(DeckVariant.self, from: Data(#"""
        {"dimension": "quotes", "shown": "b",
         "a": {"dir": "verbatim", "piece": {"steps": [{"claim": "S."}], "quotes": [{"text": "Q."}]}},
         "b": {"dir": "summary", "piece": {"steps": [{"claim": "S."}], "quotes": []}}}
        """#.utf8))
        XCTAssertEqual(quotes.previews.a, "…\n“Q.”")
        XCTAssertEqual(quotes.previews.b, "… and nothing more")
        let length = try XCTUnwrap(DailyDeck.decode(Self.deckJSON).cards[0].variant)
        XCTAssertEqual(length.previews.a, "One. Two. Three.", "nothing shared: each face whole")
    }

    func testFacePreview() throws {
        let entries = try JSONDecoder().decode([DeckEntry].self, from: Data(#"""
        [{"label": "The gist", "text": "G."}, {"text": "Plain."}]
        """#.utf8))
        XCTAssertEqual(DeckFace(dir: "parts", context: nil, entries: entries, piece: nil).preview, "The gist: G.\nPlain.")
        let piece = DeckPiece(meta: nil, steps: [.init(name: nil, claim: "First.", span: nil)],
                              quotes: [.init(text: "Said it.", at: nil)])
        XCTAssertEqual(DeckFace(dir: "verbatim", context: nil, entries: nil, piece: piece).preview, "1. First.\n“Said it.”")
        XCTAssertEqual(DeckFace(dir: "shorter", context: "Short.", entries: nil, piece: nil).preview, "Short.")
    }

    private static let questionVariant = """
    {"dimension": "question", "approach": "own-example", "shown": "a",
     "a": {"dir": "current", "question": "What did you notice?"},
     "b": {"dir": "own-example", "question": "Where did this show up in your week?"}}
    """

    func testQuestionFacePreviewIsTheQuestion() throws {
        let variant = try JSONDecoder().decode(DeckVariant.self, from: Data(Self.questionVariant.utf8))
        XCTAssertEqual(variant.dimension, "question")
        XCTAssertEqual(variant.a.question, "What did you notice?")
        XCTAssertEqual(variant.a.preview, "What did you notice?")
        XCTAssertEqual(DeckFace(dir: "current", context: "Ctx.", entries: nil, piece: nil, question: "Why?").preview, "Why?", "the question comes first")
        XCTAssertNil(variant.a.context)
        let old = try XCTUnwrap(DailyDeck.decode(Self.deckJSON).cards[0].variant)
        XCTAssertNil(old.a.question, "old variants have no question and still preview their context")
        XCTAssertEqual(old.a.preview, "One. Two. Three.")
    }

    func testVariantPreviewsShowBothQuestionsWhole() throws {
        let variant = try JSONDecoder().decode(DeckVariant.self, from: Data(Self.questionVariant.utf8))
        XCTAssertEqual(variant.previews.a, "What did you notice?")
        XCTAssertEqual(variant.previews.b, "Where did this show up in your week?")
        let same = try JSONDecoder().decode(DeckVariant.self, from: Data("""
        {"dimension": "question", "shown": "a",
         "a": {"dir": "current", "question": "Same?"}, "b": {"dir": "x", "question": "Same?"}}
        """.utf8))
        XCTAssertEqual(same.previews.a, "Same?", "a question is never trimmed to a bare ellipsis")
        XCTAssertEqual(same.previews.b, "Same?")
    }
}
