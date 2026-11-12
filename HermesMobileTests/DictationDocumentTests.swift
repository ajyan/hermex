import XCTest
@testable import HermesMobile

final class DictationDocumentTests: XCTestCase {
    func testWordsLandAtTheCursorWithJoiningSpaces() {
        var document = DictationDocument(text: "Hello world", cursor: 5)
        document.hear(settled: "", volatile: "big")
        XCTAssertEqual(document.text, "Hello big world")
        document.hear(settled: "big wide", volatile: "open")
        XCTAssertEqual(document.text, "Hello big wide open world")
        XCTAssertEqual(document.liveWords, "big wide open")
    }

    func testWithNoCursorWordsGoOnTheEnd() {
        var document = DictationDocument(text: "Typed first.")
        document.hear(settled: "", volatile: "then this")
        XCTAssertEqual(document.text, "Typed first. then this")
    }

    func testACutPassageKeepsItsPlaceWhileSpeechGoesOn() throws {
        var document = DictationDocument(text: "Start end", cursor: 5)
        document.hear(settled: "one two", volatile: "three")
        let piece = try XCTUnwrap(document.cut())
        XCTAssertEqual(document.text(of: piece.id), "one two")
        document.hear(settled: "", volatile: "three four")
        XCTAssertEqual(document.text, "Start one two three four end")
        XCTAssertEqual(document.text(of: piece.id), "one two")
        XCTAssertEqual(document.context(before: piece.id), "Start ")
    }

    func testACutWithNothingStillChangingKeepsTheSpaceBeforeTheRest() throws {
        var document = DictationDocument(text: "Start end", cursor: 6)
        document.hear(settled: "one", volatile: "")
        _ = try XCTUnwrap(document.cut())
        document.hear(settled: "", volatile: "")
        XCTAssertEqual(document.text, "Start one end")
    }

    func testAnEditInsideTheLiveWordsMakesThemAPassageAndSpeechGoesOnAfter() throws {
        var document = DictationDocument(text: "")
        document.hear(settled: "", volatile: "I met Alice today")
        let adopted = document.adopt("I met Alex today")
        guard case .sealed(let piece) = adopted.live else { return XCTFail("expected the live words to be sealed") }
        XCTAssertEqual(document.text(of: piece.id), "I met Alex today")
        XCTAssertTrue(document.isInStretch(adopted.editEnd))
        document.hear(settled: "", volatile: "at lunch")
        XCTAssertEqual(document.text, "I met Alex today at lunch")
    }

    func testTypingAfterTheLiveWordsLeavesThemAndEndsOutsideTheStretch() {
        var document = DictationDocument(text: "")
        document.hear(settled: "", volatile: "hello there")
        let adopted = document.adopt("hello there!")
        XCTAssertEqual(adopted.live, .unchanged)
        XCTAssertFalse(document.isInStretch(adopted.editEnd))
        let piece = document.move(to: adopted.editEnd)
        XCTAssertEqual(piece.flatMap { document.text(of: $0.id) }, "hello there")
        document.hear(settled: "", volatile: "and more")
        XCTAssertEqual(document.text, "hello there! and more")
    }

    func testAnEditBeforeAPassageMovesItAndOneInsideGrowsIt() throws {
        var document = DictationDocument(text: "")
        document.hear(settled: "we ship friday", volatile: "")
        let piece = try XCTUnwrap(document.cut())
        document.adopt("Note: we ship friday")
        XCTAssertEqual(document.text(of: piece.id), "we ship friday")
        document.adopt("Note: we ship on friday")
        XCTAssertEqual(document.text(of: piece.id), "we ship on friday")
        XCTAssertEqual(document.dictated, "we ship on friday")
    }

    func testARewriteReplacesAPassageOnlyWhileItReadsAsSent() throws {
        var document = DictationDocument(text: "Before. After.", cursor: 7)
        document.hear(settled: "um first thing", volatile: "")
        let first = try XCTUnwrap(document.cut())
        document.hear(settled: "second thing", volatile: "")
        let second = try XCTUnwrap(document.seal())
        XCTAssertTrue(document.rewrite(first.id, expecting: "um first thing", with: "First thing."))
        XCTAssertEqual(document.text, "Before. First thing. second thing After.")
        XCTAssertEqual(document.text(of: second.id), "second thing")
        XCTAssertFalse(document.rewrite(second.id, expecting: "something else", with: "Nope."))
        XCTAssertTrue(document.rewrite(second.id, expecting: "second thing", with: "Second thing."))
        XCTAssertEqual(document.text, "Before. First thing. Second thing. After.")
    }

    func testAnEditCarriesTheCursorWithTheWordsItFollows() {
        let edit = DictationDocument.Edit(at: 6, removed: 3, inserted: 8)
        XCTAssertEqual(edit.moved(2), 2)
        XCTAssertEqual(edit.moved(9), 14)
        XCTAssertEqual(edit.moved(12), 17)
        XCTAssertEqual(edit.moved(7), 14)
    }

    func testSkippedWordsAreLeftOutUntilTheStretchEnds() {
        var skip = DictationWordSkip()
        skip.skip("I met Alice")
        XCTAssertEqual(skip.strip("I met Alice at lunch"), "at lunch")
        skip.reset()
        XCTAssertEqual(skip.strip("a new sentence"), "a new sentence")
    }

    func testAudioIsTakenInPassagesAsWAV() throws {
        let store = DictationAudioStore(sampleRate: 16_000)
        store.append([Int16](repeating: 7, count: 16_000))
        XCTAssertNil(store.take(through: 1_000), "too short to send")
        let first = try XCTUnwrap(store.take(through: 8_000))
        XCTAssertEqual(first.count, 44 + 8_000 * 2)
        XCTAssertEqual(String(decoding: first.prefix(4), as: UTF8.self), "RIFF")
        let rest = try XCTUnwrap(store.take(through: nil))
        XCTAssertEqual(rest.count, 44 + 8_000 * 2)
        XCTAssertNil(store.take(through: nil))
        XCTAssertEqual(store.total, 16_000)
    }
}
