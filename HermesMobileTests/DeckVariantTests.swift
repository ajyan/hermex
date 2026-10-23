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
}
