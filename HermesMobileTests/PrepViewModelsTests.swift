import XCTest
import Foundation
import SwiftUI
import UIKit
@testable import HermesMobile

private final class FakePrepClient: PrepDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _attempts: [PrepAttemptRequest] = []

    var homeResults: [Result<PrepHome, Error>] = []
    var todayResults: [Result<PrepRun, Error>] = []
    var mapResults: [Result<PrepTrackMap, Error>] = []
    var attemptResults: [Result<PrepAttemptResult, Error>] = []

    /// When set, `attempt` signals `started` and then waits on `release`.
    var gate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

    /// Same, for `home()`.
    var homeGate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

    var log: [String] { lock.withLock { _log } }
    var attempts: [PrepAttemptRequest] { lock.withLock { _attempts } }

    private func next<T>(_ name: String, _ queue: inout [Result<T, Error>]) throws -> T {
        lock.lock(); defer { lock.unlock() }
        _log.append(name)
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        return try (queue.count > 1 ? queue.removeFirst() : queue[0]).get()
    }

    func home() async throws -> PrepHome {
        if let homeGate {
            homeGate.started.yield()
            for await _ in homeGate.release { break }
        }
        return try next("home", &homeResults)
    }
    func today() async throws -> PrepRun { try next("today", &todayResults) }
    func map(track: String) async throws -> PrepTrackMap { try next("map:\(track)", &mapResults) }

    func attempt(_ r: PrepAttemptRequest) async throws -> PrepAttemptResult {
        lock.withLock { _attempts.append(r) }
        if let gate {
            gate.started.yield()
            for await _ in gate.release { break }
        }
        return try next("attempt", &attemptResults)
    }
}

@MainActor
final class PrepViewModelsTests: XCTestCase {
    func testCodeExpandedHeightHugsContentUpToCap() {
        XCTAssertEqual(PrepCode.expandedHeight(natural: 80, cap: 300), 80)
        XCTAssertEqual(PrepCode.expandedHeight(natural: 500, cap: 300), 300)
    }

    func testCodeCanExpandNeedsExampleOrLongSummary() {
        XCTAssertFalse(PrepCode.canExpand(summary: "Short", example: ""))
        XCTAssertFalse(PrepCode.canExpand(summary: String(repeating: "a", count: 140), example: ""))
        XCTAssertTrue(PrepCode.canExpand(summary: String(repeating: "a", count: 141), example: ""))
        XCTAssertTrue(PrepCode.canExpand(summary: "", example: "x = 1"))
    }

    func testCodeClampedIndentCapsAtHalfWidth() {
        XCTAssertEqual(PrepCode.clampedIndent(20, width: 300), 20)
        XCTAssertEqual(PrepCode.clampedIndent(400, width: 300), 150)
    }

    func testCodeSplitCountsLeadingSpaces() {
        let parts = PrepCode.split("    return x")
        XCTAssertEqual(parts.indent, 4)
        XCTAssertEqual(parts.text, "return x")
    }

    func testCodeSplitCountsTabsAsFourSpaces() {
        let parts = PrepCode.split("\t  if x:")
        XCTAssertEqual(parts.indent, 6)
        XCTAssertEqual(parts.text, "if x:")
    }

    func testCodeSplitKeepsInnerSpacesAndTrailingText() {
        let parts = PrepCode.split("a  =  b ")
        XCTAssertEqual(parts.indent, 0)
        XCTAssertEqual(parts.text, "a  =  b ")
    }

    func testCodeSplitOfBlankLine() {
        let parts = PrepCode.split("   ")
        XCTAssertEqual(parts.indent, 3)
        XCTAssertEqual(parts.text, "")
    }

    func testCodeWordsRoundTrip() {
        let text = "for i in  range(n):"
        XCTAssertEqual(PrepCode.words(text).joined(), text)
        XCTAssertEqual(PrepCode.words("a b"), ["a ", "b"])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! PrepDecoding.decode(type, from: Data(json.utf8))
    }

    private func rep(_ index: Int, drill: String = "approach", extra: String = "") -> String {
        #"{"index": \#(index), "block": "new", "drill": "\#(drill)", "item": {"id": "dsa.\#(index)", "hints": ["h1", "h2"]\#(extra)}}"#
    }

    private func run(index: Int, reps: [String], date: String = "2026-10-09") -> PrepRun {
        decode(PrepRun.self, #"{"date": "\#(date)", "index": \#(index), "reps": [\#(reps.joined(separator: ","))]}"#)
    }

    private func result(next: Int, streak: Bool = true) -> PrepAttemptResult {
        decode(PrepAttemptResult.self, #"{"verdict": "correct", "credit": 1.0, "next_index": \#(next)\#(streak ? #", "streak": {"days": 3, "freezes": 1}"# : "")}"#)
    }

    private func map(_ mastery: [(String, Double)]) -> PrepTrackMap {
        let skills = mastery.map { #"{"id": "\#($0.0)", "title": "\#($0.0)", "state": "in_progress", "mastery": \#($0.1)}"# }
        return decode(PrepTrackMap.self, #"{"track": "dsa", "title": "DSA", "levels": [{"title": "L1", "skills": [\#(skills.joined(separator: ","))]}]}"#)
    }

    private func http(_ code: Int) -> APIError { .http(statusCode: code, body: "") }

    private func makeVM(_ client: FakePrepClient, clock: @escaping () -> Date = Date.init) -> PrepRunViewModel {
        PrepRunViewModel(client: client, now: clock)
    }

    private func currentRep(_ vm: PrepRunViewModel) -> PrepRep? {
        if case let .rep(rep, _) = vm.phase { return rep }
        return nil
    }

    // MARK: Home / track

    func testHome404IsUnavailable() async {
        let client = FakePrepClient()
        client.homeResults = [.failure(http(404))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    func testHomeOtherErrorFails() async {
        let client = FakePrepClient()
        client.homeResults = [.failure(http(500))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        if case .failed = vm.state {} else { XCTFail("expected failed, got \(vm.state)") }
    }

    func testTrackLoadsAndMaps404() async {
        let client = FakePrepClient()
        client.mapResults = [.success(map([("a", 0.1)]))]
        let vm = PrepTrackViewModel(track: "dsa", client: client)
        await vm.load()
        XCTAssertEqual(client.log, ["map:dsa"])
        if case .loaded = vm.state {} else { XCTFail("expected loaded") }
        client.mapResults = [.failure(http(404))]
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    // MARK: Run

    func testRunStartsAtServerIndex() async {
        let client = FakePrepClient()
        // Stable indices have gaps: the server's index 4 is the first unanswered rep.
        client.todayResults = [.success(run(index: 4, reps: [rep(0), rep(4), rep(7)]))]
        client.mapResults = [.success(map([("a", 0.1)]))]
        let vm = makeVM(client)
        await vm.load()
        guard case let .rep(rep, index) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(rep.index, 4)
        XCTAssertEqual(index, 4)
        XCTAssertEqual(client.log, ["today", "map:dsa"])
    }

    func testRun404IsUnavailable() async {
        let client = FakePrepClient()
        client.todayResults = [.failure(http(404))]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertEqual(vm.phase, .unavailable)
    }

    func testChoosePostsElapsedAndHints() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 2, reps: [rep(2)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 3))]
        var t = Date(timeIntervalSince1970: 1_000)
        let vm = makeVM(client, clock: { t })
        await vm.load()
        vm.showHint()
        vm.showHint()
        vm.showHint() // capped at hints.count
        XCTAssertEqual(vm.hintsShown, 2)
        t = t.addingTimeInterval(8.25)
        await vm.choose(.choice("dsa.stack"))
        let sent = try! XCTUnwrap(client.attempts.first)
        XCTAssertEqual(sent.index, 2)
        XCTAssertEqual(sent.item, "dsa.2")
        XCTAssertEqual(sent.drill, .approach)
        XCTAssertEqual(sent.date, "2026-10-09")
        XCTAssertEqual(sent.answer, .choice("dsa.stack"))
        XCTAssertEqual(sent.elapsedMS, 8250)
        XCTAssertEqual(sent.hintsUsed, 2)
        if case .result = vm.phase {} else { XCTFail("phase \(vm.phase)") }
    }

    func testContinueFollowsNextIndexAndFinishes() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0), rep(3), rep(5)]))]
        client.mapResults = [.success(map([("a", 0.1)]))]
        client.attemptResults = [.success(result(next: 1)), .success(result(next: 4)), .success(result(next: 6))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("x"))
        await vm.continue()
        XCTAssertEqual(currentRep(vm)?.index, 3, "next_index 1 lands on the first rep with index >= 1")
        await vm.choose(.choice("x"))
        await vm.continue()
        XCTAssertEqual(currentRep(vm)?.index, 5)
        await vm.choose(.choice("x"))
        await vm.continue()
        guard case let .finished(streak, moved) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(streak.days, 3)
        XCTAssertEqual(moved, [])
        XCTAssertEqual(client.attempts.map(\.index), [0, 3, 5])
    }

    func testSubmitFailureKeepsAnswerAndDoesNotAdvance() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "complexity")]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(URLError(.notConnectedToInternet)), .success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        XCTAssertEqual(vm.submitError, "Couldn't save. Try again.")
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertEqual(currentRep(vm)?.index, 0)
        // Retrying works and clears the error.
        await vm.choose(.choice("a"))
        XCTAssertNil(vm.submitError)
        XCTAssertEqual(client.attempts.last?.answer, .choice("a"))
        if case .result = vm.phase {} else { XCTFail("phase \(vm.phase)") }
    }

    func testAdvanceSkipsDroppedRepTheServerPointsAt() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0), rep(2)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("x"))
        await vm.continue()
        XCTAssertEqual(currentRep(vm)?.index, 2)
    }

    func testAdvanceNeverRepeatsTheAnsweredRep() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0), rep(2)]))]
        client.mapResults = [.success(map([]))]
        // A server that points back at the rep just answered.
        client.attemptResults = [.success(result(next: 0))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("x"))
        await vm.continue()
        XCTAssertEqual(currentRep(vm)?.index, 2)
    }

    func testBadRequestReloadsRunLikeConflict() async {
        let client = FakePrepClient()
        client.todayResults = [
            .success(run(index: 0, reps: [rep(0)], date: "2026-10-08")),
            .success(run(index: 2, reps: [rep(0), rep(2)], date: "2026-10-09")),
        ]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(http(400))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        XCTAssertNil(vm.submitError)
        XCTAssertEqual(currentRep(vm)?.index, 2)
    }

    func testStaleSubmitErrorDoesNotLandOnReloadedRun() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(http(500))]
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        let vm = makeVM(client)
        await vm.load()
        let submit = Task { await vm.choose(.choice("a")) }
        for await _ in started { break }
        await vm.load()
        releaseCont.yield()
        await submit.value
        XCTAssertNil(vm.submitError)
        XCTAssertFalse(vm.isSubmitting)
    }

    func testUnauthorizedReportsToAPIErrorHandler() async {
        let client = FakePrepClient()
        client.homeResults = [.failure(http(401))]
        client.todayResults = [.failure(http(401))]
        client.mapResults = [.failure(http(401))]
        var seen = 0
        let handler: (Error) -> Void = { error in
            if case .http(401, _)? = error as? APIError { seen += 1 }
        }
        await PrepHomeViewModel(client: client, onAPIError: handler).load()
        await PrepTrackViewModel(track: "dsa", client: client, onAPIError: handler).load()
        await PrepRunViewModel(client: client, onAPIError: handler).load()
        XCTAssertEqual(seen, 3)
    }

    func testChoiceMatchIgnoresCaseAndWhitespace() {
        XCTAssertTrue(PrepCopy.isSameChoice(" Sliding_Window\n", "sliding_window"))
        XCTAssertFalse(PrepCopy.isSameChoice("stack", "sliding_window"))
        XCTAssertFalse(PrepCopy.isSameChoice("a", nil))
    }

    func testDoubleSubmitPostsOnce() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        let vm = makeVM(client)
        await vm.load()
        let first = Task { await vm.choose(.choice("a")) }
        for await _ in started { break }
        XCTAssertTrue(vm.isSubmitting)
        await vm.choose(.choice("b"))
        releaseCont.yield()
        await first.value
        XCTAssertEqual(client.attempts.count, 1)
        XCTAssertEqual(client.attempts.first?.answer, .choice("a"))
    }

    func testConflictReloadsRun() async {
        let client = FakePrepClient()
        client.todayResults = [
            .success(run(index: 0, reps: [rep(0)], date: "2026-10-08")),
            .success(run(index: 2, reps: [rep(0), rep(2)], date: "2026-10-09")),
        ]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(http(409))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        XCTAssertNil(vm.submitError)
        XCTAssertEqual(vm.run?.date, "2026-10-09")
        XCTAssertEqual(currentRep(vm)?.index, 2)
    }

    func testFinishedComputesMovedSkills() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [
            .success(map([("a", 0.1), ("b", 0.5), ("c", 0.9)])),
            .success(map([("a", 0.1), ("b", 0.7), ("c", 1.0)])),
        ]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        await vm.continue()
        guard case let .finished(_, moved) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(moved.map(\.id), ["b", "c"])
        XCTAssertEqual(client.log, ["today", "map:dsa", "attempt", "map:dsa"])
    }

    func testFinishedMovedEmptyWhenMapFetchFails() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([("a", 0.1)])), .failure(http(500))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        await vm.continue()
        guard case let .finished(_, moved) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(moved, [])
    }

    func testPrimerAcknowledgePostsSeen() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "primer")]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.acknowledgePrimer()
        XCTAssertEqual(client.attempts.first?.answer, .choice("seen"))
        XCTAssertEqual(client.attempts.first?.hintsUsed, 0)
        XCTAssertEqual(client.attempts.first?.drill, .primer)
    }

    func testPrimerAcknowledgeAdvancesWithoutResult() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "primer"), rep(1)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.acknowledgePrimer()
        // Straight to the next rep: no result screen for a primer.
        XCTAssertEqual(currentRep(vm)?.index, 1)
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertNil(vm.submitError)

        // A failed primer post keeps the primer up with the inline error.
        let failing = FakePrepClient()
        failing.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "primer"), rep(1)]))]
        failing.mapResults = [.success(map([]))]
        failing.attemptResults = [.failure(http(500))]
        let failingVM = makeVM(failing)
        await failingVM.load()
        await failingVM.acknowledgePrimer()
        XCTAssertEqual(currentRep(failingVM)?.index, 0)
        XCTAssertEqual(failingVM.submitError, "Couldn't save. Try again.")
        XCTAssertFalse(failingVM.isSubmitting)
    }

    // MARK: Cancellation, conflict, re-entry

    func testCancelledLoadLeavesStateUntouched() async {
        let client = FakePrepClient()
        client.homeResults = [.failure(CancellationError())]
        client.mapResults = [.failure(URLError(.cancelled))]
        client.todayResults = [.failure(CancellationError())]
        let home = PrepHomeViewModel(client: client)
        await home.load()
        XCTAssertEqual(home.state, .loading)
        let track = PrepTrackViewModel(track: "dsa", client: client)
        await track.load()
        XCTAssertEqual(track.state, .loading)
        let vm = makeVM(client)
        await vm.load()
        XCTAssertEqual(vm.phase, .loading)
    }

    func testCancelledSubmitSetsNoError() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(CancellationError())]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        XCTAssertNil(vm.submitError)
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertEqual(currentRep(vm)?.index, 0)
    }

    func testConflictThenTodayFailureFails() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)])), .failure(http(500))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(http(409))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        if case .failed = vm.phase {} else { XCTFail("phase \(vm.phase)") }
        XCTAssertFalse(vm.isSubmitting)
    }

    func testContinueIsNotReentrant() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([("a", 0.1)]))]
        client.attemptResults = [.success(result(next: 1, streak: false))]
        client.homeResults = [.success(decode(PrepHome.self, #"{"streak": {"days": 2, "freezes": 0}, "run": {}, "tracks": []}"#))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("a"))
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.homeGate = (startedCont, release)
        let first = Task { await vm.continue() }
        for await _ in started { break }
        await vm.continue() // second tap while finishing: ignored
        releaseCont.yield()
        releaseCont.yield()
        await first.value
        XCTAssertEqual(client.log.filter { $0 == "home" }.count, 1)
        guard case let .finished(streak, _) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(streak.days, 2)
    }

    // MARK: New drills

    func testApproachSubmitShowsGradingThenResult() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0), rep(1)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        let vm = makeVM(client)
        await vm.load()
        let submit = Task { await vm.submitApproach("Hash map of seen values") }
        for await _ in started { break }
        // Grading: the rep stays up and submitting is on.
        XCTAssertTrue(vm.isSubmitting)
        XCTAssertEqual(currentRep(vm)?.index, 0)
        releaseCont.yield()
        await submit.value
        XCTAssertFalse(vm.isSubmitting)
        guard case let .result(rep, _, _) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(rep.index, 0)
        XCTAssertEqual(client.attempts.first?.answer, .choice("Hash map of seen values"))
        XCTAssertEqual(client.attempts.first?.drill, .approach)
    }

    func testUngradedResultShown() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(decode(PrepAttemptResult.self,
            #"{"verdict": "ungraded", "next_index": 1, "grade": {"verdict": "ungraded"}}"#))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitApproach("Two pointers")
        guard case let .result(_, result, _) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertTrue(result.isUngraded)
        XCTAssertNil(vm.submitError)
    }

    func testGradeFailureKeepsRepWithSubmitError() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.failure(URLError(.timedOut))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitApproach("Binary search on the answer")
        XCTAssertEqual(currentRep(vm)?.index, 0)
        XCTAssertEqual(vm.submitError, "Couldn't save. Try again.")
        XCTAssertFalse(vm.isSubmitting)
    }

    func testLateGradeAfterLeaveIsIgnored() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0), rep(1)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        let vm = makeVM(client)
        await vm.load()
        let before = vm.phase
        let submit = Task { await vm.submitApproach("Stack of indices") }
        for await _ in started { break }
        vm.leave()
        releaseCont.yield()
        await submit.value
        XCTAssertEqual(vm.phase, before, "a grade landing after leaving must not move the run")
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertNil(vm.submitError)
    }

    func testSkipUnknownAdvancesWithoutPost() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "mock"), rep(1)]))]
        client.mapResults = [.success(map([]))]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertEqual(currentRep(vm)?.drill, .unknown)
        await vm.skip()
        XCTAssertEqual(currentRep(vm)?.index, 1)
        XCTAssertTrue(client.attempts.isEmpty)
        XCTAssertFalse(client.log.contains("attempt"))
    }

    func testBugFixAnswerPosted() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "spot_bug")]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitBugFix(line: 2, fix: "while lo <= hi:")
        let sent = try! XCTUnwrap(client.attempts.first)
        XCTAssertEqual(sent.drill, .spotBug)
        XCTAssertEqual(sent.answer, .bugFix(line: 2, fix: "while lo <= hi:"))
        if case .result = vm.phase {} else { XCTFail("phase \(vm.phase)") }
    }

    func testApproachClockCountsDownThenOver() {
        XCTAssertEqual(PrepCopy.approachClock(elapsed: 0).text, "1:30")
        XCTAssertEqual(PrepCopy.approachClock(elapsed: 31.4).text, "0:59")
        XCTAssertFalse(PrepCopy.approachClock(elapsed: 90).isOver)
        XCTAssertEqual(PrepCopy.approachClock(elapsed: 90).text, "0:00")
        XCTAssertTrue(PrepCopy.approachClock(elapsed: 95).isOver)
        XCTAssertEqual(PrepCopy.approachClock(elapsed: 95).text, "+0:05")
        XCTAssertEqual(PrepCopy.approachClock(elapsed: 161).text, "+1:11")
    }

    func testRubricTitle() {
        XCTAssertEqual(PrepCopy.rubricTitle("edge_cases"), "Edge cases")
        XCTAssertEqual(PrepCopy.rubricTitle("pattern"), "Pattern")
    }

    // MARK: - PrepCopy

    func testHomeRowSubtitleSaysWhetherTheRunIsDone() {
        XCTAssertEqual(PrepCopy.homeRowSubtitle(streakDays: 12, remaining: 4), "12-day streak · today's run is ready")
        XCTAssertEqual(PrepCopy.homeRowSubtitle(streakDays: 12, remaining: 0), "12-day streak · run done")
    }

    func testZeroStreakCopy() {
        XCTAssertEqual(PrepCopy.homeRowSubtitle(streakDays: 0, remaining: 4), "Today's run is ready")
        XCTAssertEqual(PrepCopy.homeRowSubtitle(streakDays: 0, remaining: 0), "Run done")
        XCTAssertEqual(PrepCopy.streakTitle(days: 0), "No streak yet")
        XCTAssertEqual(PrepCopy.streakTitle(days: 3), "3-day streak")
        XCTAssertEqual(PrepCopy.streakSubtitle(days: 0, freezes: 2), "Finish a run to start one")
        XCTAssertNil(PrepCopy.streakSubtitle(days: 3, freezes: 0))
        XCTAssertEqual(PrepCopy.streakSubtitle(days: 3, freezes: 1), "1 freeze saved")
    }

    func testRunActionStartsResumesOrIsDone() {
        XCTAssertEqual(PrepCopy.runAction(reps: 14, remaining: 14), .start)
        XCTAssertEqual(PrepCopy.runAction(reps: 14, remaining: 3), .resume)
        XCTAssertEqual(PrepCopy.runAction(reps: 14, remaining: 0), .done)
    }

    func testRunSubtitleRoundsMinutesAndDropsEmptyFocus() {
        XCTAssertEqual(PrepCopy.runSubtitle(minutes: 31.6, reps: 14, focus: ["Sliding window", "Stack"]),
                       "32 min · 14 reps · Sliding window, Stack")
        XCTAssertEqual(PrepCopy.runSubtitle(minutes: 30, reps: 12, focus: []), "30 min · 12 reps")
    }

    func testBlockTitles() {
        XCTAssertEqual(["warmup", "weak", "main", "new", "bonus"].map(PrepCopy.blockTitle),
                       ["Warm-up", "Weak spot", "Main rep", "New", "Bonus"])
    }

    func testFeedbackSplitsAfterTheFirstSentence() {
        let parts = PrepCopy.feedbackParts("It's Sliding window. Grow a range on the right. Shrink it.")
        XCTAssertEqual(parts.lead, "It's Sliding window.")
        XCTAssertEqual(parts.rest, "Grow a range on the right. Shrink it.")
        XCTAssertEqual(PrepCopy.feedbackParts("Right.").lead, "Right.")
        XCTAssertEqual(PrepCopy.feedbackParts("Right.").rest, "")
        XCTAssertEqual(PrepCopy.feedbackParts("It's O(n log n)").lead, "It's O(n log n)")
    }

    func testSkillLabel() {
        XCTAssertEqual(PrepCopy.skillLabel(title: "Sliding Window", state: .weak, detail: "Mixed up with two pointers"),
                       "Sliding Window, weak, Mixed up with two pointers")
    }
}

/// The run player hosted for real: drives SwiftUI controls through their
/// accessibility elements, as VoiceOver would.
@MainActor
final class PrepDrillViewsTests: XCTestCase {
    func testSpotBugTapLineThenFixEnablesSubmit() async throws {
        let client = FakePrepClient()
        let run = #"""
        {"date": "2026-10-10", "index": 0, "reps": [{"index": 0, "block": "main", "drill": "spot_bug",
          "item": {"id": "dsa.bs", "title": "Binary Search",
                   "code": ["def search(nums, t):", "    lo, hi = 0, len(nums)", "    while lo < hi:"],
                   "fixes": ["    lo, hi = 0, len(nums) - 1", "    while lo <= hi:"]}}]}
        """#
        client.todayResults = [.success(try PrepDecoding.decode(PrepRun.self, from: Data(run.utf8)))]
        client.mapResults = [.failure(URLError(.badServerResponse))]
        let vm = PrepRunViewModel(client: client)
        let restoreAutomation = enableAccessibilityAutomation()
        defer { restoreAutomation() }
        let probe = "Prep hosted accessibility probe"
        let window = try show(VStack(spacing: 0) {
            Button(probe) {}
            NavigationStack { PrepRunView(viewModel: vm) }
        })
        defer { close(window) }

        let line = "Line 2:     lo, hi = 0, len(nums)"
        _ = await settle(window) { self.element(line, in: window) != nil }
        try XCTSkipUnless(element(probe, in: window) != nil,
                          "This toolchain does not expose the SwiftUI accessibility tree")
        let submit = try XCTUnwrap(element("Submit", in: window), "spot-the-bug pins a Submit button")
        XCTAssertTrue(submit.accessibilityTraits.contains(.notEnabled), "nothing chosen yet")
        XCTAssertNil(element("    while lo <= hi:", in: window), "fixes wait for a line")

        XCTAssertTrue(try XCTUnwrap(element(line, in: window)).accessibilityActivate())
        let fix = "    lo, hi = 0, len(nums) - 1"
        _ = await settle(window) { self.element(fix, in: window) != nil }
        XCTAssertTrue(try XCTUnwrap(element(line, in: window)).accessibilityTraits.contains(.selected))
        XCTAssertTrue(try XCTUnwrap(element("Submit", in: window)).accessibilityTraits.contains(.notEnabled),
                      "a line alone is not an answer")

        XCTAssertTrue(try XCTUnwrap(element(fix, in: window)).accessibilityActivate())
        _ = await settle(window) {
            self.element("Submit", in: window).map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false
        }
        XCTAssertFalse(try XCTUnwrap(element("Submit", in: window)).accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(client.attempts.isEmpty, "choosing never posts; Submit does")
    }

    // MARK: Hosting

    /// SwiftUI publishes its accessibility tree in-process only while an assistive
    /// technology or UI automation is on. Turns automation on (test process only)
    /// and returns how to put it back.
    private func enableAccessibilityAutomation() -> () -> Void {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getter = dlsym(handle, "_AXSAutomationEnabled"),
              let setter = dlsym(handle, "_AXSSetAutomationEnabled")
        else { return {} }
        typealias Get = @convention(c) () -> Bool
        typealias Set = @convention(c) (Bool) -> Void
        let wasEnabled = unsafeBitCast(getter, to: Get.self)()
        let set = unsafeBitCast(setter, to: Set.self)
        set(true)
        return { set(wasEnabled) }
    }

    private func show<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view.transaction { $0.disablesAnimations = true })
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func settle(_ window: UIWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0..<8 {
            if condition() { return true }
            await settle(window)
        }
        return condition()
    }

    /// The first accessibility element under `root` with exactly this label.
    private func element(_ label: String, in root: UIView) -> NSObject? {
        var pending: [NSObject] = [root]
        var seen: Set<ObjectIdentifier> = []
        while let node = pending.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if node.accessibilityLabel == label { return node }
            pending += (node as? UIView)?.subviews ?? []
            pending += (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                pending += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
        }
        return nil
    }
}
