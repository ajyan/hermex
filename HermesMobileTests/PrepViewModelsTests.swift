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
    var gapsResults: [Result<[PrepGapSummary], Error>] = []
    var gapResults: [Result<PrepGapDetail, Error>] = []
    var flagResults: [Result<Void, Error>] = [.success(())]
    var courseResults: [Result<PrepCourse, Error>] = []
    var lessonResults: [Result<PrepLesson, Error>] = []
    var overrideResults: [Result<PrepAttemptResult, Error>] = []

    /// When set, `attempt` signals `started` and then waits on `release`.
    var gate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

    /// Same, for `override`.
    var overrideGate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

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
    func today(run: PrepRunKind, unit: String?) async throws -> PrepRun {
        let name = run == .daily ? "today" : "today:\(run.rawValue)" + (unit.map { ":\($0)" } ?? "")
        return try next(name, &todayResults)
    }
    func map(track: String) async throws -> PrepTrackMap { try next("map:\(track)", &mapResults) }

    func attempt(_ r: PrepAttemptRequest) async throws -> PrepAttemptResult {
        lock.withLock { _attempts.append(r) }
        if let gate {
            gate.started.yield()
            for await _ in gate.release { break }
        }
        return try next("attempt", &attemptResults)
    }

    func gaps() async throws -> [PrepGapSummary] { try next("gaps", &gapsResults) }
    func gap(id: String) async throws -> PrepGapDetail { try next("gap:\(id)", &gapResults) }
    func flag(item: String) async throws { try next("flag:\(item)", &flagResults) }
    func course() async throws -> PrepCourse { try next("course", &courseResults) }
    func lesson(id: String) async throws -> PrepLesson { try next("lesson:\(id)", &lessonResults) }
    func override(attempt: String, point: String) async throws -> PrepAttemptResult {
        if let overrideGate {
            overrideGate.started.yield()
            for await _ in overrideGate.release { break }
        }
        return try next("override:\(attempt):\(point)", &overrideResults)
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

    // MARK: Course runs

    private func lessonRep(_ index: Int, block: String = "new", cloze: Bool = false) -> String {
        let check = cloze ? #"{"format": "cloze", "prompt": "Fill"}"# : #"{"format": "choice", "prompt": "Why?", "options": ["A", "B", "C", "D"]}"#
        return #"{"index": \#(index), "block": "\#(block)", "drill": "lesson", "item": {"id": "u2.l\#(index)", "title": "Lesson \#(index)", "idea_md": "Idea \#(index)", "say_it_md": "Say", "check": \#(check)}}"#
    }

    private func bossRep(_ index: Int) -> String {
        #"{"index": \#(index), "block": "boss", "drill": "boss", "item": {"id": "anth.j.020\#(index)", "summary": "Design it"}}"#
    }

    private func courseRun(_ reps: [String], run kind: String = "daily") -> PrepRun {
        decode(PrepRun.self, #"{"date": "2026-10-20", "run": "\#(kind)", "index": 0, "reps": [\#(reps.joined(separator: ","))]}"#)
    }

    private func checked(_ verdict: String, next: Int) -> PrepAttemptResult {
        decode(PrepAttemptResult.self, #"{"verdict": "\#(verdict)", "correct": "A", "feedback": "Because.", "next_index": \#(next), "streak": {"days": 7, "freezes": 1}}"#)
    }

    private func courseHome(xp: Int, boss: String = "locked") -> PrepHome {
        decode(PrepHome.self, #"{"streak": {"days": 7, "freezes": 1}, "course": {"xp": \#(xp), "today": {"done": 3, "total": 3}, "units": [{"id": "u2", "title": "Prompt engineering", "state": "current", "boss": "\#(boss)", "lessons_done": 7, "lessons_total": 7}]}}"#)
    }

    func testLessonRepSubmitsChoiceWithDailyRun() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([lessonRep(0)]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(checked("pass", next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.choose(.choice("A"))
        XCTAssertEqual(client.attempts.first?.drill, .lesson)
        XCTAssertEqual(client.attempts.first?.run, .daily)
        XCTAssertNil(client.attempts.first?.unit)
        XCTAssertFalse(client.log.contains { $0.hasPrefix("map") }, "course runs skip the skill map")
    }

    func testLessonXPTicks() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([lessonRep(0), lessonRep(1), lessonRep(2, block: "review"), lessonRep(3, block: "review")]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(checked("pass", next: 1)), .success(checked("miss", next: 2)),
                                 .success(checked("pass", next: 3)), .success(checked("miss", next: 4))]
        let vm = makeVM(client)
        await vm.load()
        var ticks: [Int?] = []
        for _ in 0..<4 {
            await vm.choose(.choice("A"))
            ticks.append(vm.lastXP)
            await vm.continue()
        }
        XCTAssertEqual(ticks, [15, 10, 5, nil])
    }

    func testReviewStartsHiddenAndShowIdeaReveals() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([lessonRep(0, block: "review"), lessonRep(1)]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(checked("pass", next: 1))]
        let vm = makeVM(client)
        await vm.load()
        let review = try! XCTUnwrap(currentRep(vm))
        XCTAssertTrue(vm.isReview(review))
        XCTAssertFalse(vm.revealedLesson)
        vm.showIdea()
        XCTAssertTrue(vm.revealedLesson)
        await vm.choose(.choice("A"))
        await vm.continue()
        let next = try! XCTUnwrap(currentRep(vm))
        XCTAssertFalse(vm.isReview(next))
        XCTAssertFalse(vm.revealedLesson)
    }

    func testBossResultExposesSittingAndRevisit() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([bossRep(0)]))]
        client.homeResults = [.success(courseHome(xp: 0, boss: "ready"))]
        client.attemptResults = [.success(decode(PrepAttemptResult.self, #"""
        {"verdict": "pass", "next_index": 1, "grade": {"points_hit": [{"point_id": "p.a", "quote": ""}], "strong_answer": "S"},
         "revisit": [{"lesson_id": "u2.l4", "title": "Prefill"}],
         "sitting": {"score": 0.9, "passed": true, "stars": 2, "unlocked": "Agents and evals"}}
        """#))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitJudgment("My design")
        guard case let .result(rep, result, _) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(rep.drill, .boss)
        XCTAssertEqual(result.sitting?.stars, 2)
        XCTAssertEqual(result.revisit.map(\.lessonID), ["u2.l4"])
        XCTAssertEqual(vm.lastXP, 50)
        XCTAssertEqual(client.attempts.first?.drill, .boss)
    }

    func testTestoutRunSendsRunAndUnit() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([bossRep(0)], run: "testout"))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(checked("pass", next: 1))]
        let vm = PrepRunViewModel(client: client, run: .testout, unit: "u3")
        await vm.load()
        await vm.submitJudgment("My design")
        XCTAssertEqual(client.log.first, "today:testout:u3")
        XCTAssertEqual(client.attempts.first?.run, .testout)
        XCTAssertEqual(client.attempts.first?.unit, "u3")
    }

    func testFinishedSummaryCountsLearnedAndXP() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([lessonRep(0), lessonRep(1), lessonRep(2, block: "review")]))]
        client.homeResults = [.success(courseHome(xp: 100)), .success(courseHome(xp: 130, boss: "ready"))]
        client.attemptResults = [.success(checked("pass", next: 1)), .success(checked("miss", next: 2)),
                                 .success(checked("pass", next: 3))]
        let vm = makeVM(client)
        await vm.load()
        for _ in 0..<3 {
            await vm.choose(.choice("A"))
            await vm.continue()
        }
        guard case let .finished(summary) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertTrue(summary.isCourse)
        XCTAssertEqual(summary.xpGained, 30)
        XCTAssertEqual(summary.learned, ["Lesson 0", "Lesson 1"])
        XCTAssertEqual(summary.reviews, 1)
        XCTAssertEqual(summary.missedChecks, 1)
        XCTAssertEqual(summary.streak.days, 7)
        XCTAssertEqual(summary.nextUp, "Boss quiz · Prompt engineering")
        XCTAssertEqual(summary.repCount, 3)
    }

    func testLessonReaderLoadStates() async {
        let client = FakePrepClient()
        client.lessonResults = [.failure(http(404))]
        let vm = PrepLessonViewModel(id: "u2.l3", client: client)
        await vm.load()
        guard case .failed = vm.state else { return XCTFail("state \(vm.state)") }
        client.lessonResults = [.success(decode(PrepLesson.self, #"{"id": "u2.l3", "title": "XML tags", "idea_md": "I", "check": {"answer": "A"}}"#))]
        await vm.load()
        guard case let .loaded(lesson) = vm.state else { return XCTFail("state \(vm.state)") }
        XCTAssertEqual(lesson.check.answer, "A")
        XCTAssertEqual(client.log, ["lesson:u2.l3", "lesson:u2.l3"])
    }

    func testLessonSourceLineNamesRefsOnce() throws {
        let lesson = decode(PrepLesson.self, #"""
        {"id": "u2.l3", "sources": [{"ref": "prompt-docs"}, {"ref": "guide", "path": "05/06.md"},
                                    {"ref": "playbook"}, {"ref": "question-bank"}, {"ref": "mystery"}]}
        """#)
        XCTAssertEqual(PrepCopy.sourceLine(lesson.sources),
                       "Anthropic prompting docs · AI system design guide · Your notes · mystery")
        XCTAssertNil(PrepCopy.sourceLine([]))
    }

    func testRewardCopy() {
        XCTAssertEqual(PrepCopy.starsLabel(2), "2 of 3 stars")
        XCTAssertEqual(PrepCopy.xpLabel(15), "+15 XP")
        XCTAssertEqual(PrepCopy.xpSpoken(15), "Plus 15 XP")
        XCTAssertEqual(PrepCopy.percent(0.824), "82%")
    }

    func testSittingHeadline() {
        XCTAssertEqual(PrepCopy.sittingHeadline(PrepBossSitting(score: 0.9, passed: true, stars: 2, unlocked: nil)), "Boss passed")
        XCTAssertEqual(PrepCopy.sittingHeadline(PrepBossSitting(score: 0.5, passed: false, stars: 0, unlocked: nil)), "Not yet")
        XCTAssertEqual(PrepCopy.sittingHeadline(PrepBossSitting(score: nil, passed: false, stars: 0, unlocked: nil)), "Grading tonight")
        XCTAssertEqual(PrepCopy.unlockLine(PrepBossSitting(score: 0.9, passed: true, stars: 2, unlocked: "Agents and evals"), xp: 50),
                       "Agents and evals unlocked · +50 XP")
        XCTAssertEqual(PrepCopy.unlockLine(PrepBossSitting(score: 0.5, passed: false, stars: 0, unlocked: nil), xp: nil),
                       "The next unit keeps going. This boss comes back in a few days.")
        XCTAssertEqual(PrepCopy.unlockLine(PrepBossSitting(score: 0.5, passed: false, stars: 0, unlocked: nil), xp: nil,
                                           testOut: true), "Not yet. Start with the lessons below.")
        XCTAssertEqual(PrepCopy.unlockLine(PrepBossSitting(score: 0.9, passed: true, stars: 2, unlocked: nil), xp: 50,
                                           testOut: true), "+50 XP")
    }

    func testHomeExposesCourseWhenPresent() async {
        let client = FakePrepClient()
        client.homeResults = [.success(courseHome(xp: 40))]
        client.courseResults = [.success(decode(PrepCourse.self, #"""
        {"xp": 40, "today": {"done": 0, "total": 10}, "units": [
          {"id": "u1", "title": "LLM fundamentals", "state": "current", "lessons": [{"id": "u1.l1", "title": "Tokens", "state": "next"}]},
          {"id": "u2", "title": "Prompt engineering", "state": "locked"}]}
        """#))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.course?.units.count, 2)
        XCTAssertEqual(vm.course?.units.first?.lessons.first?.state, .next)
        XCTAssertTrue(client.log.contains("course"))
    }

    func testHomeWithoutCourseSkipsCourseCall() async {
        let client = FakePrepClient()
        client.homeResults = [.success(decode(PrepHome.self, #"{"streak": {"days": 1, "freezes": 0}}"#))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        XCTAssertNil(vm.course)
        XCTAssertFalse(client.log.contains("course"))
    }

    func testHomeFallsBackToHomeCourseWhenCourseFails() async {
        let client = FakePrepClient()
        client.homeResults = [.success(courseHome(xp: 40))]
        client.courseResults = [.failure(http(500))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.course?.xp, 40)
        XCTAssertEqual(vm.course?.units.first?.lessons, [])
    }

    func testPathCopy() {
        XCTAssertEqual(PrepCopy.unitHeader(index: 1, title: "Prompt engineering"), "Unit 2 · Prompt engineering")
        XCTAssertEqual(PrepCopy.todayLine(days: 6, xp: 340), "6-day streak · 340 XP")
        XCTAssertEqual(PrepCopy.todayLine(days: 0, xp: 0), "0 XP")
        XCTAssertEqual(PrepCopy.bossNode(.ready), "Boss quiz · ready")
        XCTAssertEqual(PrepCopy.bossNode(.resting), "Boss quiz · back in a few days")
        XCTAssertEqual(PrepCopy.bossNode(.locked), "Boss quiz")
    }

    // MARK: Recall

    private func recallLessonRep(_ index: Int, drill: String = "lesson", block: String = "new") -> String {
        #"{"index": \#(index), "block": "\#(block)", "drill": "\#(drill)", "item": {"id": "u1.l\#(index)", "title": "Lesson \#(index)", "idea_md": "Idea", "say_it_md": "Say", "check": {"prompt": "Q?", "options": ["A", "B", "C", "D"]}, "recall": {"prompt": "Explain \#(index)."}}}"#
    }

    private func recallResult(_ verdict: String, next: Int, missed: [String] = ["p.b"], xp: Int = 10, surprise: Bool = false) -> PrepAttemptResult {
        let missedJSON = missed.map { #"{"point_id": "\#($0)", "why": ""}"# }.joined(separator: ",")
        return decode(PrepAttemptResult.self, #"""
        {"verdict": "\#(verdict)", "next_index": \#(next), "attempt": "att-\#(next)", "xp": \#(xp), "surprise": \#(surprise),
         "streak": {"days": 3, "freezes": 0, "last_day": "2026-10-20"},
         "grade": {"points_hit": [{"point_id": "p.a", "quote": ""}], "points_missed": [\#(missedJSON)], "strong_answer": "S"},
         "points": [{"id": "p.a", "text": "A"}, {"id": "p.b", "text": "B"}]}
        """#)
    }

    func testLessonGoesReadingThenRecalling() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([recallLessonRep(0), recallLessonRep(1, drill: "recall", block: "review")]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(recallResult("partial", next: 1))]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertEqual(vm.lessonStage, .reading)
        vm.beginRecall()
        XCTAssertEqual(vm.lessonStage, .recalling)
        vm.recallDraft = "Routing goes to the fast tier"
        vm.confidence = .fairly
        await vm.submitRecall()
        XCTAssertEqual(client.attempts.first?.confidence, .fairly)
        XCTAssertEqual(client.attempts.first?.drill, .lesson)
        XCTAssertEqual(vm.lastXP, 10)
        await vm.continue()
        XCTAssertEqual(vm.lessonStage, .recalling, "a recall review starts on the recall card")
        XCTAssertEqual(vm.recallDraft, "", "each recall starts empty")
        XCTAssertNil(vm.confidence)
    }

    func testRecallSubmitNeedsTextAndConfidence() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([recallLessonRep(0, drill: "recall", block: "review")]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertFalse(vm.canSubmitRecall)
        vm.recallDraft = "   "
        vm.confidence = .certain
        XCTAssertFalse(vm.canSubmitRecall)
        vm.recallDraft = "An answer"
        XCTAssertTrue(vm.canSubmitRecall)
        vm.confidence = nil
        XCTAssertFalse(vm.canSubmitRecall)
        await vm.submitRecall()
        XCTAssertTrue(client.attempts.isEmpty)
    }

    func testDontKnowPostsWithoutText() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([recallLessonRep(0, drill: "recall", block: "review")]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(recallResult("miss", next: 1, missed: ["p.a", "p.b"], xp: 5))]
        let vm = makeVM(client)
        await vm.load()
        await vm.dontKnow()
        XCTAssertEqual(client.attempts.first?.dontKnow, true)
        XCTAssertEqual(client.attempts.first?.confidence, .guess)
        XCTAssertEqual(client.attempts.first?.answer, .choice(""))
    }

    func testOverrideReplacesResult() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([recallLessonRep(0, drill: "recall", block: "review")]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(recallResult("partial", next: 1))]
        client.overrideResults = [.success(decode(PrepAttemptResult.self, #"""
        {"verdict": "pass", "attempt": "att-2", "xp": 15, "overridden": ["p.b"],
         "grade": {"points_hit": [{"point_id": "p.a", "quote": ""}, {"point_id": "p.b", "quote": ""}], "points_missed": [], "strong_answer": "S"}}
        """#))]
        let vm = makeVM(client)
        await vm.load()
        vm.recallDraft = "x"
        vm.confidence = .fairly
        await vm.submitRecall()
        await vm.overridePoint("p.b")
        guard case let .result(_, result, _) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(result.verdict, "pass")
        XCTAssertEqual(result.overridden, ["p.b"])
        XCTAssertEqual(result.nextIndex, 1, "keeps the original next index")
        XCTAssertEqual(result.pointTexts["p.b"], "B", "keeps the point texts")
        XCTAssertEqual(vm.lastXP, 15)
        XCTAssertEqual(client.log.last, "override:att-1:p.b")
    }

    func testDontKnowResultCannotBeOverridden() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([recallLessonRep(0, drill: "recall", block: "review")]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(recallResult("miss", next: 1, missed: ["p.a", "p.b"], xp: 5))]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertTrue(vm.canOverride)
        await vm.dontKnow()
        XCTAssertFalse(vm.canOverride)
        await vm.overridePoint("p.a")
        XCTAssertFalse(client.log.contains { $0.hasPrefix("override") })
    }

    func testOverrideIgnoresASecondTapWhileSaving() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([recallLessonRep(0, drill: "recall", block: "review")]))]
        client.homeResults = [.success(courseHome(xp: 0))]
        client.attemptResults = [.success(recallResult("miss", next: 1, missed: ["p.a", "p.b"], xp: 5))]
        client.overrideResults = [.success(recallResult("partial", next: 1, missed: ["p.b"], xp: 10))]
        let vm = makeVM(client)
        await vm.load()
        vm.recallDraft = "x"
        vm.confidence = .fairly
        await vm.submitRecall()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.overrideGate = (startedCont, release)
        let first = Task { await vm.overridePoint("p.a") }
        for await _ in started { break }
        XCTAssertEqual(vm.overridingPoint, "p.a")
        await vm.overridePoint("p.b")
        releaseCont.yield()
        await first.value
        XCTAssertEqual(client.log.filter { $0.hasPrefix("override") }, ["override:att-1:p.a"])
        XCTAssertNil(vm.overridingPoint)
    }

    func testRecallOnlyDailyRunIsACourseRun() {
        let run = courseRun([recallLessonRep(0, drill: "recall", block: "review")])
        XCTAssertTrue(PrepRunViewModel.isCourse(run, kind: .daily))
    }

    func testBonusRunLoads() async {
        let client = FakePrepClient()
        client.todayResults = [.success(courseRun([recallLessonRep(0, drill: "recall", block: "review")], run: "bonus"))]
        client.homeResults = [.success(courseHome(xp: 0))]
        let vm = PrepRunViewModel(client: client, run: .bonus)
        await vm.load()
        XCTAssertEqual(client.log.first, "today:bonus")
        XCTAssertEqual(vm.lessonStage, .recalling)
    }

    func testMilestonesDetected() {
        let before = decode(PrepHome.self, #"{"streak": {"days": 6}, "course": {"ready_count": 9, "lesson_total": 48, "units": [{"id": "u1", "title": "Fundamentals", "state": "current"}]}}"#)
        let after = decode(PrepHome.self, #"{"streak": {"days": 7}, "course": {"ready_count": 10, "lesson_total": 48, "units": [{"id": "u1", "title": "Fundamentals", "state": "passed"}]}}"#)
        XCTAssertEqual(PrepMilestone.detect(before: before, after: after),
                       [.bossPassed("Fundamentals"), .ready(10), .streak(7)])
        XCTAssertEqual(PrepMilestone.detect(before: after, after: after), [])
    }

    func testWelcomeBackWhenLastDayBeforeYesterday() {
        let today = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")!
        XCTAssertTrue(PrepCopy.isWelcomeBack(lastDay: "2026-10-20", today: today))
        XCTAssertFalse(PrepCopy.isWelcomeBack(lastDay: "2026-10-21", today: today))
        XCTAssertFalse(PrepCopy.isWelcomeBack(lastDay: nil, today: today))
    }

    func testReadyAndCalibrationCopy() {
        XCTAssertEqual(PrepCopy.readyLine(ready: 14, total: 48), "14 of 48 ready")
        XCTAssertEqual(PrepCopy.calibrationLine(PrepCalibration(certainRight: 4, certainTotal: 5)),
                       "When you say certain, you're right 80% of the time")
        XCTAssertEqual(PrepCopy.milestoneTitle(.ready(10)), "10 topics interview-ready")
        XCTAssertEqual(PrepCopy.milestoneTitle(.streak(7)), "7-day streak")
        XCTAssertEqual(PrepCopy.milestoneTitle(.bossPassed("Fundamentals")), "Fundamentals passed")
        XCTAssertEqual(PrepCopy.keyPointsLine(hit: 3, total: 4), "3 of 4 key points")
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
        guard case let .finished(summary) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(summary.streak.days, 3)
        XCTAssertEqual(summary.moved, [])
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
        guard case let .finished(summary) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(summary.moved.map(\.id), ["b", "c"])
        XCTAssertFalse(summary.isCourse)
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
        guard case let .finished(summary) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(summary.moved, [])
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
        guard case let .finished(summary) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(summary.streak.days, 2)
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

    func testBugFixAnswerPosted() async throws {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "spot_bug")]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitBugFix(line: 2, fix: "while lo <= hi:")
        let sent = try XCTUnwrap(client.attempts.first)
        XCTAssertEqual(sent.drill, .spotBug)
        XCTAssertEqual(sent.answer, .bugFix(line: 2, fix: "while lo <= hi:"))
        if case .result = vm.phase {} else { XCTFail("phase \(vm.phase)") }
    }

    func testShownAtResetsForEachRepAndTimesTheAnswer() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0), rep(1)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        var t = Date(timeIntervalSince1970: 1_000)
        let vm = makeVM(client, clock: { t })
        t = t.addingTimeInterval(5)
        await vm.load()
        XCTAssertEqual(vm.shownAt, Date(timeIntervalSince1970: 1_005), "the clock starts when the rep is shown")
        t = t.addingTimeInterval(42)
        await vm.submitApproach("Monotonic stack")
        XCTAssertEqual(client.attempts.first?.elapsedMS, 42_000)
        t = t.addingTimeInterval(3)
        await vm.continue()
        XCTAssertEqual(vm.shownAt, Date(timeIntervalSince1970: 1_050))
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

    func testApproachDraftIsCappedAtTheServerLimit() {
        XCTAssertEqual(PrepCopy.approachMaxLength, 4000)
        let long = String(repeating: "x", count: 4001)
        XCTAssertEqual(PrepCopy.cappedApproach(long).count, 4000)
        XCTAssertEqual(PrepCopy.cappedApproach("short"), "short")
        // The server counts Unicode scalars (Python len), so a multi-scalar emoji counts as several.
        let flags = String(repeating: "🇺🇸", count: 2001)
        XCTAssertEqual(PrepCopy.cappedApproach(flags).unicodeScalars.count, 4000)
        XCTAssertFalse(PrepCopy.isAtApproachLimit("short"))
        XCTAssertTrue(PrepCopy.isAtApproachLimit(PrepCopy.cappedApproach(long)))
    }

    func testRubricTitle() {
        XCTAssertEqual(PrepCopy.rubricTitle("edge_cases"), "Edge cases")
        XCTAssertEqual(PrepCopy.rubricTitle("pattern"), "Pattern")
    }

    // MARK: - PrepCopy

    func testZeroStreakCopy() {
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
        XCTAssertEqual(["reteach", "review", "boss"].map(PrepCopy.blockTitle),
                       ["Another way to see it", "Review", "Boss quiz"])
        XCTAssertEqual(PrepCopy.reviewLine(reviews: 2, missed: 1), "2 reviews · 1 check to look at again")
        XCTAssertEqual(PrepCopy.reviewLine(reviews: 1, missed: 0), "1 review")
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

    // MARK: Anthropic drills

    private func judgmentResult(next: Int, gap: Bool = true, logged: Bool = false) -> PrepAttemptResult {
        let match = gap ? #"[{"id": "gap.harm", "label": "Who bears the harm", "misses": 3}]"# : "[]"
        return decode(PrepAttemptResult.self, #"""
        {"verdict": "partial", "credit": 0.5, "next_index": \#(next),
         "grade": {"points_hit": [{"point_id": "p.a", "quote": "q"}], "points_missed": [{"point_id": "p.b", "why": "w"}]},
         "gap_match": \#(match), "logged": \#(logged)}
        """#)
    }

    func testJudgmentBlankCannotSubmit() {
        XCTAssertFalse(PrepCopy.canSubmitJudgment(""))
        XCTAssertFalse(PrepCopy.canSubmitJudgment("  \n\t "))
        XCTAssertTrue(PrepCopy.canSubmitJudgment("a"))
    }

    func testGapCalloutCopy() {
        let match = [PrepGapMatch(id: "gap.harm", label: "Who bears the harm", misses: 3)]
        XCTAssertEqual(PrepCopy.gapCallout(match: match, logged: false), "Seen before: Who bears the harm · 3 misses")
        XCTAssertEqual(PrepCopy.gapCallout(match: [PrepGapMatch(id: "g", label: "L", misses: 1)], logged: true),
                       "Seen before: L · 1 miss")
        XCTAssertEqual(PrepCopy.gapCallout(match: [], logged: true), "Logged · Atlas will review tonight")
        XCTAssertNil(PrepCopy.gapCallout(match: [], logged: false))
    }

    func testAnthRunLoadsAnthMap() async {
        let client = FakePrepClient()
        let anthRep = #"{"index": 0, "block": "warmup", "drill": "judgment", "item": {"id": "anth.j.0001"}}"#
        client.todayResults = [.success(run(index: 0, reps: [anthRep]))]
        client.mapResults = [.success(map([]))]
        let vm = makeVM(client)
        await vm.load()
        XCTAssertEqual(client.log, ["today", "map:anth"])
    }

    // MARK: Gaps

    private func gapSummary(_ id: String, status: String, misses: Int = 3, hits: Int = 0) -> PrepGapSummary {
        decode(PrepGapSummary.self, #"{"id": "\#(id)", "label": "Label \#(id)", "stage": "5", "status": "\#(status)", "misses": \#(misses), "hits_toward_close": \#(hits)}"#)
    }

    private var homeValue: PrepHome {
        decode(PrepHome.self, #"{"streak": {"days": 1, "freezes": 0}, "run": {"minutes": 30, "reps": 9, "remaining": 9}, "tracks": [], "needs_work": [{"skill": "s", "title": "T", "detail": "d"}]}"#)
    }

    func testHomeFallsBackToNeedsWorkOn404() async {
        let client = FakePrepClient()
        client.homeResults = [.success(homeValue)]
        client.gapsResults = [.failure(http(404))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        XCTAssertNil(vm.gaps)
        if case let .loaded(home) = vm.state { XCTAssertEqual(home.needsWork.count, 1) } else { XCTFail("\(vm.state)") }
    }

    func testGapsLoadedAlongsideHome() async {
        let client = FakePrepClient()
        client.homeResults = [.success(homeValue)]
        client.gapsResults = [.success([gapSummary("gap.a", status: "open"), gapSummary("gap.b", status: "improving", hits: 1)])]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.gaps?.map(\.id), ["gap.a", "gap.b"])
        XCTAssertEqual(Set(client.log), ["home", "gaps"])
    }

    func testGapsFailureDoesNotFailHome() async {
        let client = FakePrepClient()
        client.homeResults = [.success(homeValue)]
        client.gapsResults = [.failure(http(500))]
        let vm = PrepHomeViewModel(client: client)
        await vm.load()
        XCTAssertNil(vm.gaps)
        if case .loaded = vm.state {} else { XCTFail("\(vm.state)") }
    }

    func testGapRowDetailCopy() {
        XCTAssertEqual(PrepCopy.gapRowDetail(gapSummary("g", status: "open", misses: 3)), "Seen 3×")
        XCTAssertEqual(PrepCopy.gapRowDetail(gapSummary("g", status: "improving", hits: 1)), "1 of 3 hits")
        XCTAssertEqual(PrepCopy.gapRowDetail(gapSummary("g", status: "closed")), "Closed")
    }

    func testGapsHeaderCopy() {
        XCTAssertEqual(PrepCopy.gapsHeader(open: 4, improving: 2), "4 open · 2 improving")
        XCTAssertEqual(PrepCopy.gapsHeader(open: 1, improving: 0), "1 open")
        XCTAssertEqual(PrepCopy.gapsHeader(open: 0, improving: 0), "None open")
    }

    func testGapDetailLoadStates() async {
        let client = FakePrepClient()
        let detail = decode(PrepGapDetail.self, #"{"id": "gap.a", "label": "A", "status": "open", "evidence": [], "cards": []}"#)
        client.gapResults = [.success(detail)]
        let vm = PrepGapViewModel(id: "gap.a", client: client)
        await vm.load()
        XCTAssertEqual(vm.state, .loaded(detail))
        XCTAssertEqual(client.log, ["gap:gap.a"])
        client.gapResults = [.failure(http(404))]
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    func testPointTitleFallback() {
        XCTAssertEqual(PrepCopy.pointTitle("p.harm-bearer"), "Harm bearer")
        XCTAssertEqual(PrepCopy.pointTitle("odd"), "Odd")
    }

    func testStageChip() {
        XCTAssertEqual(PrepCopy.stageChip("5"), "Stage 5")
        XCTAssertEqual(PrepCopy.stageChip("2a"), "Stage 2a")
        XCTAssertNil(PrepCopy.stageChip(""))
    }

    func testJudgmentSubmitsJudgmentDrill() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "judgment")]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(judgmentResult(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitJudgment("  Find the tail first.  ")
        let sent = try! XCTUnwrap(client.attempts.first)
        XCTAssertEqual(sent.drill, .judgment)
        XCTAssertEqual(sent.answer, .choice("Find the tail first."))
        guard case let .result(_, result, _) = vm.phase else { return XCTFail("phase \(vm.phase)") }
        XCTAssertEqual(result.judgment?.pointsMissed.first?.pointID, "p.b")
    }

    func testClozeSubmitsTrimmedText() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "fact", extra: #", "format": "cloze""#)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(result(next: 1))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitCloze(" ASL-3 ")
        XCTAssertEqual(client.attempts.first?.answer, .choice("ASL-3"))
        XCTAssertEqual(client.attempts.first?.drill, .fact)
    }

    func testFlagOnlyForCoachItems() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [
            rep(0, drill: "judgment"), rep(1, drill: "judgment", extra: #", "origin": "coach""#)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(judgmentResult(next: 1)), .success(judgmentResult(next: 2))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitJudgment("answer")
        XCTAssertFalse(vm.canFlag, "an ingest card can't be flagged")
        await vm.flagCurrent()
        XCTAssertFalse(client.log.contains { $0.hasPrefix("flag:") })
        await vm.continue()
        await vm.submitJudgment("answer")
        XCTAssertTrue(vm.canFlag)
        await vm.flagCurrent()
        XCTAssertEqual(client.log.filter { $0.hasPrefix("flag:") }, ["flag:dsa.1"])
        XCTAssertFalse(vm.canFlag, "flagged once")
        XCTAssertTrue(vm.isFlagged("dsa.1"))
    }

    func testFlagFailureLeavesItFlaggable() async {
        let client = FakePrepClient()
        client.todayResults = [.success(run(index: 0, reps: [rep(0, drill: "judgment", extra: #", "origin": "coach""#)]))]
        client.mapResults = [.success(map([]))]
        client.attemptResults = [.success(judgmentResult(next: 1))]
        client.flagResults = [.failure(http(500))]
        let vm = makeVM(client)
        await vm.load()
        await vm.submitJudgment("answer")
        await vm.flagCurrent()
        XCTAssertTrue(vm.canFlag)
        XCTAssertEqual(vm.flagError, "Couldn't flag this card. Try again.")
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
