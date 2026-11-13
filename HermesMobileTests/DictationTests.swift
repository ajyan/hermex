import SwiftUI
import XCTest
@testable import HermesMobile

final class DictationSpliceTests: XCTestCase {
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

/// A mic the test speaks through.
@MainActor
final class FakeDictationListener: DictationListening {
    let engineName = "fake"
    var onEvent: ((DictationListenerEvent) -> Void)?
    var audio: Data? = Data([1, 2, 3])
    /// Words that settle only when the mic stops.
    var settlesOnStop: String?
    private(set) var skips = 0
    private(set) var isRunning = false

    func start(vocabulary: @escaping () async -> [String]) async throws { isRunning = true }

    func stop() async {
        isRunning = false
        if let settlesOnStop { onEvent?(.settled(settlesOnStop)) }
    }

    func cancel() { isRunning = false }
    func takeAudio(throughNow: Bool) -> Data? { audio }
    func skipLiveWords() { skips += 1 }

    func say(_ words: String) { onEvent?(.volatile(words)) }
    func settle(_ words: String) { onEvent?(.settled(words)) }
}

@MainActor
final class FakeDictationCursor: DictationCursor {
    var offset: Int?
    private(set) var placed: Int?

    func position(in text: String) -> Int? { offset }

    func write(_ edit: DictationDocument.Edit, from old: String, to new: String, cursor: Int) {
        placed = cursor
        offset = cursor
    }
}

/// Rewrites by upper-casing unless told otherwise, and keeps what it was asked.
final class DictationRecorder: DictationPolishing, @unchecked Sendable {
    var passages: [DictationPassage] = []
    var outcomes: [DictationOutcome] = []
    var rewrite: (DictationPassage) -> String? = { $0.heard.uppercased() }
    var onOutcome: (() -> Void)?

    func polish(_ passage: DictationPassage) async throws -> DictationPolish {
        passages.append(passage)
        guard let text = rewrite(passage) else { throw CancellationError() }
        return DictationPolish(text: text, id: "r\(passages.count)")
    }

    func report(_ outcome: DictationOutcome) async {
        outcomes.append(outcome)
        onOutcome?()
    }
}

@MainActor
final class DictationModelTests: XCTestCase {
    private final class Box { var text = "" }

    private let box = Box()
    private let listener = FakeDictationListener()
    private let cursor = FakeDictationCursor()
    private let recorder = DictationRecorder()

    private var binding: Binding<String> {
        Binding(get: { [box] in box.text }, set: { [box] in box.text = $0 })
    }

    private func model(polisher: (any DictationPolishing)? = nil, hasPolisher: Bool = true) -> DictationModel {
        let polisher: (any DictationPolishing)? = hasPolisher ? (polisher ?? recorder) : nil
        let listener = listener, cursor = cursor
        return DictationModel(services: DictationServices(
            polisher: { _ in polisher }, vocabulary: { _ in [] }, listener: { listener },
            fallbackListener: nil, cursor: cursor, mayRecord: { true }))
    }

    /// The keyboard changed the box: what the view's `onChange` does.
    private func type(_ text: String, into dictation: DictationModel) {
        box.text = text
        dictation.textChanged(text)
    }

    func testSpeechIsRewrittenOnStopAndOriginalPutsItBack() async {
        box.text = "Typed first."
        let dictation = model()
        await dictation.toggle(binding)?.value
        XCTAssertTrue(dictation.isListening)
        listener.say("um we should")
        XCTAssertEqual(box.text, "Typed first. um we should")
        listener.settle("um we should ship it")
        await dictation.toggle(binding)?.value

        XCTAssertEqual(box.text, "Typed first. UM WE SHOULD SHIP IT")
        XCTAssertEqual(recorder.passages.map(\.heard), ["um we should ship it"])
        XCTAssertEqual(recorder.passages.first?.before, "Typed first. ")
        XCTAssertNotNil(recorder.passages.first?.audio)
        XCTAssertTrue(dictation.canUndoTidy)
        XCTAssertFalse(dictation.isBusy)

        dictation.undoTidy()
        XCTAssertEqual(box.text, "Typed first. um we should ship it")
        XCTAssertFalse(dictation.canUndoTidy)
    }

    func testSpeechLandsAtTheCursorAndTheCursorFollowsIt() async {
        box.text = "Start end"
        cursor.offset = 5
        let dictation = model()
        await dictation.toggle(binding)?.value
        listener.say("in the middle")
        XCTAssertEqual(box.text, "Start in the middle end")
        XCTAssertEqual(cursor.placed, 19)
        XCTAssertEqual(cursor.placed, 19, "the cursor sits at the end of the words, before the joining space")
        listener.say("in the very middle")
        XCTAssertEqual(box.text, "Start in the very middle end")
    }

    func testFixingAWordWhileListeningKeepsTheFixAndSpeechGoesOn() async {
        let dictation = model()
        await dictation.toggle(binding)?.value
        listener.say("I met Alice today")
        type("I met Alex today", into: dictation)
        XCTAssertTrue(dictation.isListening, "typing doesn't stop the mic")
        XCTAssertEqual(listener.skips, 1)
        listener.say("at lunch")
        XCTAssertEqual(box.text, "I met Alex today at lunch")
        listener.settlesOnStop = "at lunch time"
        await dictation.toggle(binding)?.value

        XCTAssertEqual(box.text, "I MET ALEX TODAY AT LUNCH TIME")
        let edited = recorder.passages.first { $0.heard == "I met Alex today" }
        XCTAssertNotNil(edited)
        XCTAssertNil(edited?.audio, "an edited passage is rewritten from the edit, not the audio")
    }

    func testTypingElsewhereMovesSpeechToTheCursor() async {
        let dictation = model()
        await dictation.toggle(binding)?.value
        listener.say("first thought")
        type("first thought.\n", into: dictation)
        listener.say("second thought")
        XCTAssertEqual(box.text, "first thought.\nsecond thought")
    }

    func testLongSpeechIsSentInPassagesWhileTalking() async {
        let dictation = model()
        await dictation.toggle(binding)?.value
        let early = Array(repeating: "word", count: DictationModel.earlyPassageWords).joined(separator: " ")
        listener.settle(early)
        listener.settle("and the rest of it")
        await dictation.toggle(binding)?.value

        XCTAssertEqual(recorder.passages.map(\.heard), [early, "and the rest of it"])
        XCTAssertEqual(recorder.passages.map(\.sequence), [0, 1])
        XCTAssertEqual(recorder.passages.last?.before, early + " ")
        XCTAssertEqual(box.text, early.uppercased() + " AND THE REST OF IT")
    }

    func testAFailedOrMissingRewriterKeepsTheWordsAsHeard() async {
        recorder.rewrite = { _ in nil }
        let failing = model()
        await failing.toggle(binding)?.value
        listener.settle("we should ship it today")
        await failing.toggle(binding)?.value
        XCTAssertEqual(box.text, "we should ship it today")
        XCTAssertFalse(failing.canUndoTidy)

        box.text = ""
        let missing = model(hasPolisher: false)
        await missing.toggle(binding)?.value
        listener.settle("we should ship it today")
        await missing.toggle(binding)?.value
        XCTAssertEqual(box.text, "we should ship it today")
    }

    func testAnEditAfterTheTidyDropsOriginalAndIsReportedAsTheOutcome() async {
        let reported = expectation(description: "outcome reported")
        recorder.onOutcome = { reported.fulfill() }
        recorder.rewrite = { _ in "We should ship it Friday." }
        let dictation = model()
        await dictation.toggle(binding)?.value
        listener.settle("we should ship it friday")
        await dictation.toggle(binding)?.value
        XCTAssertEqual(box.text, "We should ship it Friday.")

        type("We should ship it Monday.", into: dictation)
        XCTAssertFalse(dictation.canUndoTidy)
        dictation.cancel()
        await fulfillment(of: [reported])
        XCTAssertEqual(recorder.outcomes.first?.final, "We should ship it Monday.")
        XCTAssertEqual(recorder.outcomes.first?.ids, ["r1"])
        XCTAssertEqual(recorder.outcomes.first?.undone, false)
    }

    func testCancelWhileListeningKeepsTheWordsAndRewritesNothing() async {
        let dictation = model()
        await dictation.toggle(binding)?.value
        listener.say("half a thought")
        dictation.cancel()
        XCTAssertEqual(box.text, "half a thought")
        XCTAssertFalse(dictation.isBusy)
        XCTAssertFalse(listener.isRunning)
        XCTAssertTrue(recorder.passages.isEmpty)
    }

    func testDoneWaitsForTheRewrite() async {
        let dictation = model()
        dictation.opened(binding, server: nil)
        await dictation.toggle(binding)?.value
        listener.settle("we should ship it today")
        await dictation.finish()
        XCTAssertEqual(box.text, "WE SHOULD SHIP IT TODAY")
        XCTAssertEqual(recorder.passages.count, 1, "untouched speech into an empty box is tidied once")
    }

    func testDoneTidiesTheWholeBoxOnlyWhenItWasTypedInto() async {
        box.text = "an older saved answer here"
        let dictation = model()
        dictation.opened(binding, server: nil)
        await dictation.finish()
        XCTAssertTrue(recorder.passages.isEmpty, "an unchanged answer is left alone")

        type("an older saved answer here plus typing", into: dictation)
        await dictation.finish()
        XCTAssertEqual(recorder.passages.map(\.heard), ["an older saved answer here plus typing"])
        XCTAssertEqual(box.text, "AN OLDER SAVED ANSWER HERE PLUS TYPING")
        XCTAssertTrue(dictation.canUndoTidy)
    }

    func testDictatingOntoASavedAnswerRewritesOnlyTheSpeech() async {
        box.text = "Saved words."
        let dictation = model()
        dictation.opened(binding, server: nil)
        await dictation.toggle(binding)?.value
        listener.settle("and some new speech here")
        await dictation.finish()
        XCTAssertEqual(box.text, "Saved words. AND SOME NEW SPEECH HERE")
        XCTAssertEqual(recorder.passages.count, 1)
    }
}

@MainActor
final class LocalModelDictationPolisherTests: XCTestCase {
    private struct Fixed: DictationPolishing {
        let text: String
        func polish(_ passage: DictationPassage) async throws -> DictationPolish { DictationPolish(text: text) }
    }

    private struct Down: Error {}

    func testTheLocalModelAnswerWins() async throws {
        let polisher = LocalModelDictationPolisher(fallback: Fixed(text: "on device")) { _, _ in DictationPolish(text: "local model", id: "r1") }
        let tidied = try await polisher.polish(DictationPassage(heard: "we should ship it today")).text
        XCTAssertEqual(tidied, "local model")
    }

    func testAFailedServerFallsBackToTheDevice() async throws {
        let polisher = LocalModelDictationPolisher(fallback: Fixed(text: "on device")) { _, _ in throw Down() }
        let tidied = try await polisher.polish(DictationPassage(heard: "we should ship it today")).text
        XCTAssertEqual(tidied, "on device")
    }

    func testAMissedDeadlineFallsBackToTheDevice() async throws {
        let polisher = LocalModelDictationPolisher(fallback: Fixed(text: "on device"), deadline: { _ in 0 }) { _, _ in
            try await Task.sleep(for: .seconds(60))
            return DictationPolish(text: "too late")
        }
        let tidied = try await polisher.polish(DictationPassage(heard: "we should ship it today")).text
        XCTAssertEqual(tidied, "on device")
    }

    func testWithoutADeviceModelTheServerErrorSurfaces() async {
        let polisher = LocalModelDictationPolisher(fallback: nil) { _, _ in throw Down() }
        do {
            _ = try await polisher.polish(DictationPassage(heard: "we should ship it today")).text
            XCTFail("expected the server error")
        } catch {
            XCTAssertTrue(error is Down)
        }
    }

    func testTheDeadlineGrowsWithThePassageUpToACap() {
        XCTAssertEqual(DictationPolisher.serverDeadline(for: DictationPassage(heard: "one two three")), 4.15, accuracy: 0.001)
        XCTAssertEqual(
            DictationPolisher.serverDeadline(for: DictationPassage(heard: "one two three", audio: Data([0]))),
            7.15, accuracy: 0.001)
        let long = Array(repeating: "word", count: 300).joined(separator: " ")
        XCTAssertEqual(DictationPolisher.serverDeadline(for: DictationPassage(heard: long)), 19, accuracy: 0.001)
        let huge = Array(repeating: "word", count: 2_000).joined(separator: " ")
        XCTAssertEqual(DictationPolisher.serverDeadline(for: DictationPassage(heard: huge)), 45)
    }
}
