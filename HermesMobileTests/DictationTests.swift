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
            polisher: { _ in polisher }
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

    func testAKeyboardEditIsNeverOverwrittenByTheRecognizer() {
        let box = Box()
        let dictation = model(nil)
        dictation.begin(binding(box))
        dictation.heard("um so i think")
        XCTAssertEqual(box.text, "um so i think")

        box.text = "So I think"
        dictation.textChanged(box.text)
        dictation.heard("um so i think we should")
        XCTAssertEqual(box.text, "So I think we should", "only the new words go on the end")

        dictation.heard("um so I think we should ship")
        XCTAssertEqual(box.text, "So I think we should", "a revised draft that no longer extends the last one is dropped")
    }

    func testFinishTidiesWhatWasDictatedOnce() async {
        let box = Box()
        var polishes = 0
        let dictation = model(FakePolisher(result: .success("I think we should ship it."),
                                           duringPolish: { polishes += 1 }))
        dictation.begin(binding(box))
        dictation.heard("um so i think we should ship it")

        dictation.voiceStateChanged()
        await dictation.finish()

        XCTAssertEqual(box.text, "I think we should ship it.")
        XCTAssertEqual(polishes, 1, "the recognizer going idle and Done both ask, and the tidy runs once")
        XCTAssertFalse(dictation.isBusy)
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

@MainActor
final class DictationEarlyTidyTests: XCTestCase {
    private final class Box { var text = "" }

    /// Tidies by capitalizing every word, and records each passage it was given.
    private final class Recorder: DictationPolishing {
        var passages: [String] = []
        func polish(_ text: String) async throws -> String {
            await MainActor.run { passages.append(text) }
            return text.capitalized
        }
    }

    private func words(_ count: Int, _ word: String) -> String {
        Array(repeating: word, count: count).joined(separator: " ")
    }

    private func start(_ box: Box, _ recorder: Recorder) -> DictationModel {
        let dictation = DictationModel(
            voiceInput: ComposerVoiceInputController(mayRecord: { false }),
            polisher: { _ in recorder }
        )
        dictation.begin(Binding(get: { box.text }, set: { box.text = $0 }))
        return dictation
    }

    func testFinishedPassagesAreTidiedWhileTalkingAndStopTidiesOnlyTheRest() async {
        let box = Box()
        box.text = "Earlier."
        let recorder = Recorder()
        let dictation = start(box, recorder)
        let first = words(25, "one")
        let second = words(6, "two")

        dictation.committedChanged(first)
        box.text = "Earlier. \(first) \(second)"
        await dictation.tidy()

        // The last words can reach the model before the early passage; only the assembly order matters.
        XCTAssertEqual(recorder.passages.sorted(), [first, second].sorted())
        XCTAssertEqual(box.text, "Earlier. \(first.capitalized) \(second.capitalized)")
        dictation.undoTidy()
        XCTAssertEqual(box.text, "Earlier. \(first) \(second)")
    }

    func testShortFinishedSegmentsWaitUntilTheyAddUp() async {
        let box = Box()
        let recorder = Recorder()
        let dictation = start(box, recorder)
        let a = words(10, "a"), b = words(20, "b")

        dictation.committedChanged(a)
        dictation.committedChanged("\(a) \(b)")
        box.text = "\(a) \(b) end"
        await dictation.tidy()

        XCTAssertEqual(recorder.passages, ["\(a) \(b)"])
        XCTAssertEqual(box.text, "\(a) \(b)".capitalized + " end")
    }

    func testAnEditOverTheEarlyWordsTidiesTheWholeDictationOnce() async {
        let box = Box()
        let recorder = Recorder()
        let dictation = start(box, recorder)
        let first = words(25, "one")

        dictation.committedChanged(first)
        box.text = "changed \(first) more words here"
        await dictation.tidy()

        XCTAssertTrue(recorder.passages.contains("changed \(first) more words here"))
        XCTAssertEqual(box.text, "changed \(first) more words here".capitalized)
    }
}

@MainActor
final class LocalModelDictationPolisherTests: XCTestCase {
    private struct Fixed: DictationPolishing {
        let text: String
        func polish(_ text: String) async throws -> String { self.text }
    }

    private struct Down: Error {}

    func testTheLocalModelAnswerWins() async throws {
        let polisher = LocalModelDictationPolisher(fallback: Fixed(text: "on device")) { _, _ in "local model" }
        let tidied = try await polisher.polish("we should ship it")
        XCTAssertEqual(tidied, "local model")
    }

    func testAFailedServerFallsBackToTheDevice() async throws {
        let polisher = LocalModelDictationPolisher(fallback: Fixed(text: "on device")) { _, _ in throw Down() }
        let tidied = try await polisher.polish("we should ship it")
        XCTAssertEqual(tidied, "on device")
    }

    func testAMissedDeadlineFallsBackToTheDevice() async throws {
        let polisher = LocalModelDictationPolisher(fallback: Fixed(text: "on device"), deadline: { _ in 0 }) { _, _ in
            try await Task.sleep(for: .seconds(60))
            return "too late"
        }
        let tidied = try await polisher.polish("we should ship it")
        XCTAssertEqual(tidied, "on device")
    }

    func testWithoutADeviceModelTheServerErrorSurfaces() async {
        let polisher = LocalModelDictationPolisher(fallback: nil) { _, _ in throw Down() }
        do {
            _ = try await polisher.polish("we should ship it")
            XCTFail("expected the server error")
        } catch {
            XCTAssertTrue(error is Down)
        }
    }

    func testTheDeadlineGrowsWithThePassageUpToACap() {
        XCTAssertEqual(DictationPolisher.serverDeadline(for: "one two three"), 4.15, accuracy: 0.001)
        let long = Array(repeating: "word", count: 300).joined(separator: " ")
        XCTAssertEqual(DictationPolisher.serverDeadline(for: long), 19, accuracy: 0.001)
        let huge = Array(repeating: "word", count: 2_000).joined(separator: " ")
        XCTAssertEqual(DictationPolisher.serverDeadline(for: huge), 45)
    }
}
