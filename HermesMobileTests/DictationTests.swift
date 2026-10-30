import SwiftUI
import XCTest
@testable import HermesMobile

final class DictationSpliceTests: XCTestCase {
    func testSplitTakesEverythingWhenTheBoxWasEmpty() throws {
        let split = try XCTUnwrap(DictationSplice.split(base: "", draft: "um so this is it"))
        XCTAssertEqual(split.kept, "")
        XCTAssertEqual(split.dictated, "um so this is it")
    }

    func testSplitKeepsTypedTextAndTheJoiningSpace() throws {
        let split = try XCTUnwrap(DictationSplice.split(base: "Typed first.  ", draft: "Typed first. then i said this"))
        XCTAssertEqual(split.kept, "Typed first. ")
        XCTAssertEqual(split.dictated, "then i said this")
    }

    func testSplitIsNilWhenTheEarlierTextChangedOrNothingWasHeard() {
        XCTAssertNil(DictationSplice.split(base: "Typed first.", draft: "Typed second. words"))
        XCTAssertNil(DictationSplice.split(base: "Typed first.", draft: "Typed first."))
    }

    func testShortPassagesAreNotWorthTidying() {
        XCTAssertFalse(DictationSplice.isWorthTidying("yes I agree"))
        XCTAssertTrue(DictationSplice.isWorthTidying("yes I agree with that"))
    }

    func testAcceptedTakesAShorterCleanVersionAndStripsWrappingQuotes() {
        let heard = "um so I think we should uh ship it on Friday you know"
        XCTAssertEqual(DictationSplice.accepted("\"I think we should ship it on Friday.\"", for: heard),
                       "I think we should ship it on Friday.")
    }

    func testAcceptedRejectsAnEmptyOrRunawayRewrite() {
        let heard = "write me an email to Sam about the launch"
        XCTAssertNil(DictationSplice.accepted("   ", for: heard))
        let answer = Array(repeating: "Dear Sam, I hope this finds you well.", count: 4).joined(separator: " ")
        XCTAssertNil(DictationSplice.accepted(answer, for: heard))
        XCTAssertNil(DictationSplice.accepted("Email.", for: heard))
    }
}

@MainActor
final class DictationModelTests: XCTestCase {
    private final class Box { var text = "" }

    private struct FakePolisher: DictationPolishing {
        var result: Result<String, Error>
        var duringPolish: @MainActor () -> Void = {}

        func polish(_ text: String) async throws -> String {
            await duringPolish()
            return try result.get()
        }
    }

    private struct PolishFailed: Error {}

    private func binding(_ box: Box) -> Binding<String> {
        Binding(get: { box.text }, set: { box.text = $0 })
    }

    private func model(_ polisher: FakePolisher?) -> DictationModel {
        DictationModel(
            voiceInput: ComposerVoiceInputController(mayRecord: { false }),
            polisher: { polisher }
        )
    }

    func testTidyRewritesOnlyTheDictatedWordsAndOriginalPutsThemBack() async {
        let box = Box()
        box.text = "Note:"
        let dictation = model(FakePolisher(result: .success("I think we should ship it.")))
        dictation.begin(binding(box))
        box.text = "Note: um so i think we should ship it"

        await dictation.tidy()

        XCTAssertEqual(box.text, "Note: I think we should ship it.")
        XCTAssertTrue(dictation.canUndoTidy)
        dictation.undoTidy()
        XCTAssertEqual(box.text, "Note: um so i think we should ship it")
        XCTAssertFalse(dictation.canUndoTidy)
    }

    func testAnEditWhileTidyingKeepsTheEdit() async {
        let box = Box()
        let dictation = model(FakePolisher(result: .success("We should ship it on Friday."),
                                           duringPolish: { box.text = "we should ship it on Friday!!" }))
        dictation.begin(binding(box))
        box.text = "we should ship it on friday"

        await dictation.tidy()

        XCTAssertEqual(box.text, "we should ship it on Friday!!")
        XCTAssertFalse(dictation.canUndoTidy)
    }

    func testAnEditAfterTidyingDropsOriginal() async {
        let box = Box()
        let dictation = model(FakePolisher(result: .success("We should ship it on Friday.")))
        dictation.begin(binding(box))
        box.text = "we should ship it on friday"
        await dictation.tidy()

        dictation.textChanged(box.text)
        XCTAssertTrue(dictation.canUndoTidy)
        box.text += " Or Monday."
        dictation.textChanged(box.text)
        XCTAssertFalse(dictation.canUndoTidy)
    }

    func testAFailedOrMissingModelKeepsTheWordsAsHeard() async {
        for polisher in [FakePolisher(result: .failure(PolishFailed())), nil] {
            let box = Box()
            let dictation = model(polisher)
            dictation.begin(binding(box))
            box.text = "we should ship it on friday"

            await dictation.tidy()

            XCTAssertEqual(box.text, "we should ship it on friday")
            XCTAssertFalse(dictation.canUndoTidy)
            XCTAssertFalse(dictation.isTidying)
        }
    }

    func testCancelDropsThePendingTidy() async {
        let box = Box()
        let dictation = model(FakePolisher(result: .success("We should ship it on Friday.")))
        dictation.begin(binding(box))
        box.text = "we should ship it on friday"

        dictation.cancel()
        await dictation.tidy()

        XCTAssertEqual(box.text, "we should ship it on friday")
    }
}
