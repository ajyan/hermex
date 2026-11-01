import XCTest
import Foundation
@testable import HermesMobile

final class PrepModelsTests: XCTestCase {
    private let homeJSON = #"""
    {"streak": {"days": 0, "freezes": 0}, "readiness": null,
     "run": {"minutes": 3.6, "reps": 2, "remaining": 2, "focus": ["Arrays & Hashing"]},
     "tracks": [{"id": "dsa", "title": "DSA patterns", "mastered": 0, "total": 18, "progress": 0.0, "subtitle": "0 of 18 mastered"}],
     "needs_work": [{"skill": "dsa.arrays_hashing", "title": "Arrays & Hashing", "detail": "Mixed up with Two Pointers"}]}
    """#

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PrepDecoding.decode(type, from: Data(json.utf8))
    }

    func testHomeDecodesServerSample() throws {
        let home = try decode(PrepHome.self, homeJSON)
        XCTAssertEqual(home.streak.days, 0)
        XCTAssertEqual(home.run.minutes, 3.6, accuracy: 0.001)
        XCTAssertEqual(home.run.reps, 2)
        XCTAssertEqual(home.run.remaining, 2)
        XCTAssertEqual(home.run.focus, ["Arrays & Hashing"])
        XCTAssertNil(home.course, "the retired readiness, tracks and needs_work fields are read past")
    }

    func testDecodesApproachSpotBugTraceReps() throws {
        let json = #"""
        {"date": "2026-10-09", "index": 1, "reps": [
          {"index": 0, "block": "new", "drill": "primer", "item": {"id": "dsa.0217", "title": "Contains Duplicate",
            "primer": {"signals": ["a"], "template": "t", "invariant": "i", "complexity": "O(n)"}, "reference_md": "## 1"}},
          {"index": 1, "block": "new", "drill": "approach", "item": {"id": "dsa.0217", "skill_title": null, "hints": ["h1", "h2"]}},
          {"block": "new", "drill": "complexity", "item": {"id": "dsa.0217", "options": ["O(n)", "O(n^2)"]}},
          {"index": 3, "block": "warmup", "drill": "spot_bug", "item": {"id": "dsa.0001", "code": ["a", "b", "c"], "fixes": ["f1", "f2", "f3"]}},
          {"index": 4, "block": "warmup", "drill": "trace", "item": {"id": "dsa.0002", "code": ["x = 1"], "input": "[1, 2]", "options": ["1", "2", "3", "4"]}}
        ]}
        """#
        let run = try decode(PrepRun.self, json)
        XCTAssertEqual(run.index, 1)
        XCTAssertEqual(run.reps.map(\.index), [0, 1, 3, 4], "a rep with no index is dropped")
        XCTAssertEqual(run.reps.map(\.drill), [.primer, .approach, .spotBug, .trace])
        XCTAssertEqual(run.reps[0].item.primer?.complexity, "O(n)")
        XCTAssertEqual(run.reps[0].item.referenceMD, "## 1")
        XCTAssertEqual(run.reps[1].item.hints, ["h1", "h2"])
        XCTAssertEqual(run.reps[2].item.code, ["a", "b", "c"])
        XCTAssertEqual(run.reps[2].item.fixes, ["f1", "f2", "f3"])
        XCTAssertEqual(run.reps[3].item.input, "[1, 2]")
        XCTAssertEqual(run.reps[3].item.options.map(\.id), ["1", "2", "3", "4"])
    }

    func testRepDecodesItsWordFloors() throws {
        let json = #"""
        {"date": "2026-11-01", "index": 0, "reps": [
          {"index": 0, "block": "story", "drill": "story", "min_words": 150, "probe_min_words": 50, "item": {"id": "s1"}},
          {"index": 1, "block": "review", "drill": "recall", "item": {"id": "u1.l1"}}
        ]}
        """#
        let run = try decode(PrepRun.self, json)
        XCTAssertEqual(run.reps.map(\.minWords), [150, 0], "an older server sends no floor")
        XCTAssertEqual(run.reps.map(\.probeMinWords), [50, 0])
    }

    func testGapDetailDecodesItsPracticeCount() throws {
        let gap = try decode(PrepGapDetail.self, #"{"id": "g1", "label": "Strength first", "status": "open", "practice": 3}"#)
        XCTAssertEqual(gap.practice, 3)
        let older = try decode(PrepGapDetail.self, #"{"id": "g1", "label": "Strength first", "status": "open"}"#)
        XCTAssertEqual(older.practice, 0, "an older server hides Practice this gap")
    }

    func testWordFloorCountsWordsAndTitlesSubmit() {
        XCTAssertEqual(PrepWordFloor("  one two\nthree  ", floor: 5).submitTitle, "3 of 5 words")
        XCTAssertTrue(PrepWordFloor("one two", floor: 2).isMet)
        XCTAssertEqual(PrepWordFloor("", floor: 0).submitTitle, "Submit")
    }

    func testIHadThatIsOfferedOncePerAnswer() throws {
        let fresh = try decode(PrepAttemptResult.self, #"{"verdict": "partial", "attempt": "a-1", "overridden": []}"#)
        let used = try decode(PrepAttemptResult.self, #"{"verdict": "partial", "attempt": "a-1", "overridden": ["p.x"]}"#)
        XCTAssertTrue(PrepKeyPointRow.offersOverride(hit: false, canOverride: true, result: fresh))
        XCTAssertFalse(PrepKeyPointRow.offersOverride(hit: false, canOverride: true, result: used),
                       "one I had that per answer")
        XCTAssertFalse(PrepKeyPointRow.offersOverride(hit: true, canOverride: true, result: fresh))
    }

    func testAHitShowsTheWordsThatEarnedIt() throws {
        let result = try decode(PrepAttemptResult.self, #"""
        {"verdict": "partial", "attempt": "a-1", "overridden": ["p.c"],
         "grade": {"points_hit": [{"point_id": "p.a", "quote": "the window is a budget"},
                                  {"point_id": "p.c", "quote": ""}],
                   "points_missed": [{"point_id": "p.b", "why": "no cost"}]}}
        """#)
        XCTAssertEqual(PrepKeyPointRow.hitQuote(id: "p.a", hit: true, result: result), "the window is a budget")
        XCTAssertNil(PrepKeyPointRow.hitQuote(id: "p.c", hit: true, result: result), "an I had that has no quote")
        XCTAssertNil(PrepKeyPointRow.hitQuote(id: "p.b", hit: false, result: result))
    }

    func testARecallBlockQuestionReadsInYourOwnWords() {
        XCTAssertEqual(PrepCopy.questionKicker("recall"), "In your own words")
    }

    func testUnknownDrillKeptAsUnknown() throws {
        let json = #"""
        {"date": "d", "index": 0, "reps": [
          {"index": 0, "block": "new", "drill": "flashcard", "item": {"id": "x"}},
          {"index": 1, "block": "new", "drill": "approach", "item": {"id": "y"}}
        ]}
        """#
        let run = try decode(PrepRun.self, json)
        XCTAssertEqual(run.reps.map(\.drill), [.unknown, .approach])
    }

    func testComplexityOptionsAreDisplayStrings() throws {
        let json = #"""
        {"date": "d", "index": 0, "reps": [{"index": 3, "block": "new", "drill": "complexity",
          "item": {"id": "x", "options": ["O(n)", "O(n log n)"]}}]}
        """#
        let rep = try XCTUnwrap(try decode(PrepRun.self, json).reps.first)
        XCTAssertEqual(rep.drill, .complexity)
        XCTAssertEqual(rep.item.options.map(\.title), ["O(n)", "O(n log n)"])
        XCTAssertEqual(rep.item.options.map(\.id), ["O(n)", "O(n log n)"])
    }

    func testAttemptRequestEncodesChoice() throws {
        let data = try JSONEncoder().encode(PrepAttemptRequest(
            date: "2026-10-09", index: 1, item: "dsa.0217", drill: .approach,
            answer: .choice("two pointers"), elapsedMS: 8000, hintsUsed: 0))
        let choice = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(choice["answer"] as? String, "two pointers")
        XCTAssertEqual(choice["drill"] as? String, "approach")
        XCTAssertEqual(choice["elapsed_ms"] as? Int, 8000)
        XCTAssertEqual(choice["hints_used"] as? Int, 0)
        XCTAssertEqual(choice["index"] as? Int, 1)
        XCTAssertEqual(choice["item"] as? String, "dsa.0217")
        XCTAssertEqual(choice["date"] as? String, "2026-10-09")
    }

    func testBugFixAnswerEncodesObject() throws {
        let data = try JSONEncoder().encode(PrepAttemptRequest(
            date: "2026-10-09", index: 3, item: "dsa.0001", drill: .spotBug,
            answer: .bugFix(line: 2, fix: "i += 1"), elapsedMS: 1, hintsUsed: 0))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let answer = try XCTUnwrap(body["answer"] as? [String: Any])
        XCTAssertEqual(answer["line"] as? Int, 2)
        XCTAssertEqual(answer["fix"] as? String, "i += 1")
        XCTAssertEqual(body["drill"] as? String, "spot_bug")
    }

    func testAttemptResultDecodesStringAndNullCorrect() throws {
        let miss = try decode(PrepAttemptResult.self, #"""
        {"verdict": "miss", "correct": "O(n)", "feedback": "It's linear.", "credit": 0,
         "reference_md": "## 1", "links": {"leetcode": "https://l"}, "next_index": 2, "streak": {"days": 1, "freezes": 0}}
        """#)
        XCTAssertEqual(miss.verdict, "miss")
        XCTAssertEqual(miss.correct, .choice("O(n)"))
        XCTAssertEqual(miss.nextIndex, 2)
        XCTAssertEqual(miss.streak?.days, 1)
        XCTAssertEqual(miss.links["leetcode"], "https://l")
        XCTAssertNil(miss.grade)
        XCTAssertFalse(miss.isUngraded)
        let primer = try decode(PrepAttemptResult.self, #"{"verdict": "seen", "correct": null, "feedback": "", "next_index": 1}"#)
        XCTAssertNil(primer.correct)
    }

    func testSpotBugCorrectDecodesAsBugFix() throws {
        let result = try decode(PrepAttemptResult.self, #"""
        {"verdict": "partial", "correct": {"line": 4, "fix": "lo = mid + 1"}, "next_index": 2}
        """#)
        XCTAssertEqual(result.correct, .bugFix(line: 4, fix: "lo = mid + 1"))
    }

    func testOpenGradeDecodesWithMissingFields() throws {
        let result = try decode(PrepAttemptResult.self, #"""
        {"verdict": "pass", "correct": null, "next_index": 1, "grade": {
          "pattern_ok": true,
          "scores": {"insight": 2, "invariant": 1, "complexity": 2, "edge_cases": 0},
          "skills_hit": [{"skill": "dsa.window", "quote": "shrink left"}, {"quote": "orphan"}],
          "skills_missed": [{"skill": "dsa.heap", "why": "never mentioned"}],
          "strong_answer": "Use a window."}}
        """#)
        let grade = try XCTUnwrap(result.grade)
        XCTAssertTrue(grade.patternOK)
        XCTAssertEqual(grade.scores, ["insight": 2, "invariant": 1, "complexity": 2, "edge_cases": 0])
        XCTAssertEqual(grade.skillsHit, [PrepQuote(skill: "dsa.window", quote: "shrink left"),
                                         PrepQuote(skill: "", quote: "orphan")])
        XCTAssertEqual(grade.skillsMissed.first?.why, "never mentioned")
        XCTAssertEqual(grade.strongAnswer, "Use a window.")
        let sparse = try decode(PrepOpenGrade.self, "{}")
        XCTAssertFalse(sparse.patternOK)
        XCTAssertEqual(sparse.scores, [:])
        XCTAssertEqual(sparse.strongAnswer, "")
    }

    func testUngradedResult() throws {
        let result = try decode(PrepAttemptResult.self, #"""
        {"verdict": "ungraded", "correct": null, "feedback": "Couldn't grade.", "credit": 0, "next_index": 3,
         "grade": {"verdict": "ungraded"}}
        """#)
        XCTAssertTrue(result.isUngraded)
        XCTAssertEqual(result.grade?.skillsHit, [])
        XCTAssertEqual(result.nextIndex, 3)
    }

    func testMissingFieldsDefault() throws {
        let home = try decode(PrepHome.self, "{}")
        XCTAssertEqual(home.streak.days, 0)
        XCTAssertEqual(home.run.reps, 0)
        XCTAssertNil(home.course)

        let run = try decode(PrepRun.self, #"{"reps": [{"index": 0, "drill": "primer", "item": {}}]}"#)
        XCTAssertEqual(run.date, "")
        XCTAssertEqual(run.reps.first?.item.id, "")
        XCTAssertEqual(run.reps.first?.item.hints, [])
        XCTAssertTrue(run.reps.first?.item.links.isEmpty ?? false)
    }

    // MARK: - Anthropic track

    func testDecodesFactAndJudgmentDrills() throws {
        let json = #"""
        {"date": "d", "index": 0, "reps": [
          {"index": 0, "block": "warmup", "drill": "fact", "item": {"id": "anth.f.0001", "title": "RSP facts",
            "summary": "Which ASL?", "stage": "1", "format": "choice", "origin": "ingest", "options": ["ASL-2", "ASL-3"]}},
          {"index": 1, "block": "warmup", "drill": "fact", "item": {"id": "anth.f.0002", "summary": "Term?", "format": "cloze"}},
          {"index": 2, "block": "warmup", "drill": "judgment", "item": {"id": "anth.j.0001", "title": "Safety and the RSP",
            "summary": "Ship it?", "stage": "5", "origin": "coach"}}
        ]}
        """#
        let run = try decode(PrepRun.self, json)
        XCTAssertEqual(run.reps.map(\.drill), [.fact, .fact, .judgment])
        XCTAssertEqual(run.reps[0].item.stage, "1")
        XCTAssertEqual(run.reps[0].item.format, "choice")
        XCTAssertEqual(run.reps[0].item.options.map(\.id), ["ASL-2", "ASL-3"])
        XCTAssertEqual(run.reps[1].item.format, "cloze")
        XCTAssertEqual(run.reps[1].item.origin, "", "a missing origin decodes empty")
        XCTAssertEqual(run.reps[2].item.origin, "coach")
        XCTAssertTrue(run.reps[2].item.isCoachWritten)
        XCTAssertFalse(run.reps[0].item.isCoachWritten)
    }

    func testJudgmentResultDecodesPointsAndGapMatch() throws {
        let json = #"""
        {"verdict": "partial", "correct": null, "feedback": "", "credit": 0.5, "next_index": 3,
         "grade": {"verdict": "partial", "points_hit": [{"point_id": "p.tail", "quote": "depends on the tail"}],
                   "points_missed": [{"point_id": "p.harm", "why": "Never named who."}], "strong_answer": "Name who."},
         "gap_match": [{"id": "gap.harm", "label": "Who bears the harm", "misses": 3}], "logged": false,
         "points": [{"id": "p.tail", "text": "Averages hide the tail."}, {"id": "p.harm", "text": "Name who bears it."}, {"x": 1}]}
        """#
        let r = try decode(PrepAttemptResult.self, json)
        XCTAssertEqual(r.pointTexts, ["p.tail": "Averages hide the tail.", "p.harm": "Name who bears it."])
        let j = try XCTUnwrap(r.judgment)
        XCTAssertEqual(j.pointsHit.map(\.pointID), ["p.tail"])
        XCTAssertEqual(j.pointsHit.first?.quote, "depends on the tail")
        XCTAssertEqual(j.pointsMissed.first?.why, "Never named who.")
        XCTAssertEqual(j.strongAnswer, "Name who.")
        XCTAssertEqual(r.gapMatch, [PrepGapMatch(id: "gap.harm", label: "Who bears the harm", misses: 3)])
        XCTAssertFalse(r.logged)
        XCTAssertNil(j.lessonMD, "no lesson_md means no lesson")
    }

    func testJudgmentGradeDecodesLessonTolerantly() throws {
        func lesson(_ field: String) throws -> String? {
            let json = """
            {"verdict": "miss", "next_index": 1,
             "grade": {"points_hit": [], "points_missed": [{"point_id": "p.harm", "why": "w"}]\(field)}}
            """
            return try XCTUnwrap(decode(PrepAttemptResult.self, json).judgment).lessonMD
        }
        XCTAssertEqual(try lesson(###", "lesson_md": "## The idea\n\n```python\nx = 1\n```\n""###),
                       "## The idea\n\n```python\nx = 1\n```")
        XCTAssertNil(try lesson(""))
        XCTAssertNil(try lesson(#", "lesson_md": "  \n ""#))
        XCTAssertNil(try lesson(#", "lesson_md": null"#))
        XCTAssertNil(try lesson(#", "lesson_md": 3"#))
    }

    // MARK: - Judgment lesson parsing

    func testJudgmentLessonParsesRealRepeatLine() throws {
        let md = """
        Third miss on measure-on-fixtures, second miss on add-missing-context.

        ## The idea

        Averages hide the tail. **Name who bears the harm.**

        ## How you'd say it

        Averages hide the tail; name who bears the harm.

        ## Remember

        - Averages hide the tail
        * Name who bears the harm

        ## Check yourself

        When an average looks fine, what do you check next?
        """
        let lesson = try XCTUnwrap(PrepJudgmentLesson(markdown: md))
        XCTAssertEqual(lesson.repeats,
                       [PrepLessonRepeat(concept: "measure-on-fixtures", misses: 3),
                        PrepLessonRepeat(concept: "add-missing-context", misses: 2)])
        XCTAssertNil(lesson.repeatText)
        XCTAssertEqual(lesson.idea, "Averages hide the tail. **Name who bears the harm.**")
        XCTAssertTrue(lesson.code == nil, "\"How you'd say it\" is dropped, not treated as code")
        XCTAssertEqual(lesson.remember, ["Averages hide the tail", "Name who bears the harm"])
        XCTAssertEqual(lesson.check, "When an average looks fine, what do you check next?")
    }

    func testJudgmentLessonParsesNumericOrdinalAndCode() throws {
        let md = """
        11th miss on caching, third miss on idempotency.

        ## The idea

        Cache the result or you recompute the same thing.

        ## Code

        ```python
        # A sketch: ## The idea is not a heading inside the fence
        memo = {}
        ```

        ## Remember

        - Cache the result
        """
        let lesson = try XCTUnwrap(PrepJudgmentLesson(markdown: md))
        XCTAssertEqual(lesson.repeats,
                       [PrepLessonRepeat(concept: "caching", misses: 11),
                        PrepLessonRepeat(concept: "idempotency", misses: 3)])
        XCTAssertTrue(lesson.idea.contains("Cache the result or you recompute"))
        XCTAssertTrue(lesson.code?.contains("memo = {}") == true)
        XCTAssertTrue(lesson.code?.contains("## The idea") == true,
                      "a `## ` line inside the fence is code, not a heading")
        XCTAssertTrue(lesson.check == nil)
    }

    func testJudgmentLessonKeepsUnparseableRepeatLineAsText() throws {
        let lesson = try XCTUnwrap(PrepJudgmentLesson(markdown: """
        Seen before: you keep missing this one.

        ## The idea

        Some idea.
        """))
        XCTAssertNil(lesson.repeats)
        XCTAssertEqual(lesson.repeatText, "Seen before: you keep missing this one.")
        XCTAssertEqual(lesson.idea, "Some idea.")
    }

    func testJudgmentLessonWithoutHeadingsShowsWholeText() throws {
        let text = "Just a paragraph, no headings at all.\n\nStill none."
        let lesson = try XCTUnwrap(PrepJudgmentLesson(markdown: text))
        XCTAssertNil(lesson.repeats)
        XCTAssertNil(lesson.repeatText)
        XCTAssertEqual(lesson.idea, text)
        XCTAssertNil(lesson.code)
        XCTAssertTrue(lesson.remember.isEmpty)
        XCTAssertNil(lesson.check)
    }

    func testJudgmentGradeDecodesLessonSections() throws {
        let json = """
        {"verdict": "miss", "next_index": 1,
         "grade": {"points_hit": [], "points_missed": [{"point_id": "p.harm", "why": "w"}],
                   "lesson_md": "Second miss on p.harm.\\n\\n## The idea\\n\\nIdea.\\n\\n## Remember\\n\\n- One\\n\\n## Check yourself\\n\\nWhy?"}}
        """
        let grade = try XCTUnwrap(decode(PrepAttemptResult.self, json).judgment)
        let lesson = try XCTUnwrap(grade.lesson)
        XCTAssertEqual(lesson.repeats, [PrepLessonRepeat(concept: "p.harm", misses: 2)])
        XCTAssertEqual(lesson.idea, "Idea.")
        XCTAssertEqual(lesson.remember, ["One"])
        XCTAssertEqual(lesson.check, "Why?")
        XCTAssertEqual(grade.lessonMD, "Second miss on p.harm.\n\n## The idea\n\nIdea.\n\n## Remember\n\n- One\n\n## Check yourself\n\nWhy?")
    }

    func testOrdinalNumberAndRepeatLine() throws {
        XCTAssertEqual(PrepJudgmentLesson.ordinalNumber("third"), 3)
        XCTAssertEqual(PrepJudgmentLesson.ordinalNumber("11th"), 11)
        XCTAssertEqual(PrepJudgmentLesson.ordinalNumber("1st"), 1)
        XCTAssertNil(PrepJudgmentLesson.ordinalNumber("sometimes"))
        XCTAssertNil(PrepJudgmentLesson.parseRepeatLine("just a sentence."))
        XCTAssertEqual(PrepJudgmentLesson.parseRepeatLine("Tenth miss on a."),
                       [PrepLessonRepeat(concept: "a", misses: 10)])
    }

    func testApproachResultStillDecodesOpenGrade() throws {
        let json = #"""
        {"verdict": "pass", "credit": 1, "next_index": 1,
         "grade": {"pattern_ok": true, "scores": {"insight": 2}, "skills_hit": [], "skills_missed": [], "strong_answer": "s"}}
        """#
        let r = try decode(PrepAttemptResult.self, json)
        XCTAssertEqual(r.grade?.patternOK, true)
        XCTAssertNil(r.judgment, "an approach grade has no points")
        XCTAssertEqual(r.gapMatch, [])
        XCTAssertFalse(r.logged)
    }

    func testGapSummaryUnknownStatusIsTolerated() throws {
        let json = #"""
        {"gaps": [{"id": "gap.a", "label": "A", "stage": "5", "status": "open", "misses": 3, "hits_toward_close": 0,
                   "last_seen": "2026-10-12", "card_count": 2},
                  {"id": "gap.b", "label": "B", "status": "snoozed"},
                  {"label": "no id"}]}
        """#
        let gaps = try decode(PrepGaps.self, json).gaps
        XCTAssertEqual(gaps.map(\.id), ["gap.a", "gap.b"], "a gap without an id is dropped")
        XCTAssertEqual(gaps[0].status, .open)
        XCTAssertEqual(gaps[0].misses, 3)
        XCTAssertEqual(gaps[0].lastSeen, "2026-10-12")
        XCTAssertEqual(gaps[1].status, .unknown)
        XCTAssertEqual(gaps[1].hitsTowardClose, 0)
    }

    func testGapDetailMissingFieldsDefault() throws {
        let json = #"""
        {"id": "gap.a", "label": "A", "status": "improving", "hits_toward_close": 1, "summary": "Skips who.",
         "evidence": [{"date": "2026-10-12", "item": "anth.j.0001", "item_title": "Ship it?", "quote": "ship the 98%"}, {"date": 3}],
         "cards": [{"id": "anth.j.c001", "title": "Who is the 2%?", "origin": "coach", "due": "2026-10-14"},
                   {"id": "anth.j.0001", "title": "Ship it?", "origin": "ingest", "due": null}]}
        """#
        let d = try decode(PrepGapDetail.self, json)
        XCTAssertEqual(d.status, .improving)
        XCTAssertEqual(d.summary, "Skips who.")
        XCTAssertEqual(d.evidence.count, 2)
        XCTAssertEqual(d.evidence[0].quote, "ship the 98%")
        XCTAssertEqual(d.evidence[0].itemTitle, "Ship it?")
        XCTAssertEqual(d.evidence[1].date, "", "a mistyped date decodes empty")
        XCTAssertEqual(d.cards.map(\.isCoachWritten), [true, false])
        XCTAssertNil(d.cards[1].due)
        XCTAssertEqual(d.stage, "")
    }

    func testFlagRequestEncodesItem() throws {
        let data = try JSONEncoder().encode(PrepFlagRequest(item: "anth.j.c001"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["item": "anth.j.c001"])
    }

    func testTutorGapEndpoints() {
        XCTAssertEqual(Endpoint.tutorGaps.path, "/api/tutor/gaps")
        XCTAssertEqual(Endpoint.tutorGap(id: "gap.a").path, "/api/tutor/gap")
        XCTAssertEqual(Endpoint.tutorGap(id: "gap.a").queryItems, [URLQueryItem(name: "id", value: "gap.a")])
        XCTAssertEqual(Endpoint.tutorFlag.path, "/api/tutor/flag")
    }

    // MARK: - Course

    private let courseHomeJSON = #"""
    {"streak": {"days": 6, "freezes": 1}, "readiness": null,
     "run": {"minutes": 7, "reps": 10, "remaining": 3, "focus": []}, "tracks": [], "needs_work": [],
     "course": {"xp": 340, "today": {"done": 7, "total": 10}, "units": [
       {"id": "u1", "title": "LLM fundamentals", "module": null, "stage": "cross", "state": "passed", "stars": 3,
        "lessons_done": 8, "lessons_total": 8, "boss": "passed", "mock": true},
       {"id": "u2", "title": "Prompt engineering", "module": "M5.5", "stage": "2a", "state": "current", "stars": 0,
        "lessons_done": 2, "lessons_total": 7, "boss": "locked", "mock": false,
        "lessons": [{"id": "u2.l1", "title": "Clear instructions", "state": "learned", "due": "2026-10-20", "reteach": false},
                    {"id": "u2.l3", "title": "XML tags", "state": "next", "due": null, "reteach": true}]},
       {"id": "u3", "title": "Agents", "state": "glowing"}]}}
    """#

    func testHomeDecodesCourseAndKeepsOldFields() throws {
        let home = try decode(PrepHome.self, courseHomeJSON)
        XCTAssertEqual(home.streak.days, 6)
        XCTAssertEqual(home.run.reps, 10)
        let course = try XCTUnwrap(home.course)
        XCTAssertEqual(course.xp, 340)
        XCTAssertEqual(course.today, PrepDayCount(done: 7, total: 10))
        XCTAssertEqual(course.units.map(\.state), [.passed, .current, .unknown])
        XCTAssertEqual(course.units[0].stars, 3)
        XCTAssertTrue(course.units[0].mock)
        XCTAssertEqual(course.units[1].boss, .locked)
        XCTAssertEqual(course.units[1].lessons.map(\.state), [.learned, .next])
        XCTAssertEqual(course.units[1].lessons[0].due, "2026-10-20")
        XCTAssertTrue(course.units[1].lessons[1].reteach)
        XCTAssertEqual(course.currentUnit?.id, "u2")
    }

    func testHomeWithoutCourse() throws {
        XCTAssertNil(try decode(PrepHome.self, homeJSON).course)
    }

    func testUnknownDrillAndRunDecodeAsUnknown() throws {
        let json = #"""
        {"date": "d", "run": "sprint", "index": 0, "reps": [{"index": 0, "block": "new", "drill": "quiz", "item": {"id": "x"}}]}
        """#
        let run = try decode(PrepRun.self, json)
        XCTAssertEqual(run.run, .unknown)
        XCTAssertEqual(run.reps.first?.drill, .unknown)
        XCTAssertEqual(try decode(PrepRun.self, #"{"date": "d", "index": 0, "reps": []}"#).run, .daily)
    }

    func testLessonRepDecodesTeachingAndCheck() throws {
        let json = #"""
        {"date": "2026-10-20", "run": "daily", "index": 0, "reps": [
          {"index": 0, "block": "new", "drill": "lesson", "item": {"id": "u2.l3", "title": "XML tags", "summary": "Why tag?",
            "unit": "u2", "idea_md": "Wrap each part.", "say_it_md": "I tag every input.",
            "check": {"format": "choice", "prompt": "Why tag?", "options": ["A", "B", "C", "D"]},
            "sources": [{"ref": "prompt-docs"}, {"ref": "guide", "path": "05/06.md"}], "origin": "coach", "reteach_of": "u2.l2"}},
          {"index": 1, "block": "boss", "drill": "boss", "item": {"id": "anth.j.0201", "summary": "Design a prompt"}}]}
        """#
        let run = try decode(PrepRun.self, json)
        XCTAssertEqual(run.reps.map(\.drill), [.lesson, .boss])
        let lesson = try XCTUnwrap(run.reps[0].item.lesson)
        XCTAssertEqual(lesson.ideaMD, "Wrap each part.")
        XCTAssertEqual(lesson.sayItMD, "I tag every input.")
        XCTAssertEqual(lesson.check.format, "choice")
        XCTAssertEqual(lesson.check.options, ["A", "B", "C", "D"])
        XCTAssertNil(lesson.check.answer)
        XCTAssertEqual(lesson.sources.map(\.ref), ["prompt-docs", "guide"])
        XCTAssertEqual(lesson.reteachOf, "u2.l2")
        XCTAssertTrue(lesson.isReteach)
        XCTAssertNil(run.reps[1].item.lesson)
    }

    func testLessonDecodesWithMissingOptionalFields() throws {
        let lesson = try decode(PrepLesson.self, #"{"id": "u1.l1", "title": "Tokens", "idea_md": "I", "check": {"answer": "A"}}"#)
        XCTAssertEqual(lesson.sources, [])
        XCTAssertNil(lesson.reteachOf)
        XCTAssertEqual(lesson.sayItMD, "")
        XCTAssertEqual(lesson.check.answer, "A")
        XCTAssertEqual(lesson.check.format, "choice")
    }

    func testBossResultDecodesSittingAndRevisit() throws {
        let json = #"""
        {"verdict": "pass", "correct": null, "feedback": "", "credit": 1, "next_index": 2,
         "grade": {"verdict": "pass", "points_hit": [{"point_id": "p.tail", "quote": "q"}], "strong_answer": "S"},
         "points": [{"id": "p.tail", "text": "Averages hide the tail"}],
         "revisit": [{"lesson_id": "u2.l4", "title": "Prefill"}, {"title": "no id"}],
         "sitting": {"score": 0.82, "passed": true, "stars": 2, "unlocked": "Agents and evals"}}
        """#
        let result = try decode(PrepAttemptResult.self, json)
        XCTAssertEqual(result.revisit, [PrepRevisit(lessonID: "u2.l4", title: "Prefill")])
        XCTAssertEqual(result.sitting, PrepBossSitting(score: 0.82, passed: true, stars: 2, unlocked: "Agents and evals"))
        XCTAssertEqual(result.strongAnswer, "S")
        XCTAssertEqual(result.judgment?.pointsHit.map(\.pointID), ["p.tail"])
    }

    func testUngradedBossSittingHasNoScore() throws {
        let json = #"{"verdict": "ungraded", "sitting": {"score": null, "passed": false, "stars": 0, "unlocked": null}}"#
        let sitting = try XCTUnwrap(try decode(PrepAttemptResult.self, json).sitting)
        XCTAssertNil(sitting.score)
        XCTAssertNil(sitting.unlocked)
    }

    func testAttemptRequestEncodesRun() throws {
        let request = PrepAttemptRequest(date: "d", index: 0, item: "anth.j.0301", drill: .boss, answer: .choice("a"),
                                         elapsedMS: 1, hintsUsed: 0, run: .testout, unit: "u3")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
        XCTAssertTrue(json.contains(#""run":"testout""#))
        XCTAssertTrue(json.contains(#""unit":"u3""#))
        let daily = PrepAttemptRequest(date: "d", index: 0, item: "u1.l1", drill: .lesson, answer: .choice("a"),
                                       elapsedMS: 1, hintsUsed: 0)
        let dailyJSON = try XCTUnwrap(String(data: JSONEncoder().encode(daily), encoding: .utf8))
        XCTAssertTrue(dailyJSON.contains(#""run":"daily""#))
        XCTAssertFalse(dailyJSON.contains("unit"))
    }

    func testCheckResultDecodesWhy() throws {
        let json = #"{"verdict": "miss", "correct": "Separates data", "feedback": "Tags mark data.", "why": "Tags add tokens"}"#
        let result = try decode(PrepAttemptResult.self, json)
        XCTAssertEqual(result.why, "Tags add tokens")
        XCTAssertNil(try decode(PrepAttemptResult.self, #"{"verdict": "pass"}"#).why)
    }

    // MARK: - Recall

    func testRecallRepDecodesPromptAndDrills() throws {
        let json = #"""
        {"date": "d", "run": "bonus", "index": 0, "reps": [
          {"index": 0, "block": "warmup", "drill": "warmup", "item": {"id": "u1.l1", "idea_md": "I", "check": {"prompt": "Q?", "options": ["A", "B"]}}},
          {"index": 1, "block": "new", "drill": "lesson", "item": {"id": "u1.l2", "idea_md": "I", "recall": {"prompt": "Explain tiers."}}},
          {"index": 2, "block": "review", "drill": "recall", "item": {"id": "u1.l3", "idea_md": "I", "recall": {"prompt": "Explain caching."}}}]}
        """#
        let run = try decode(PrepRun.self, json)
        XCTAssertEqual(run.run, .bonus)
        XCTAssertEqual(run.reps.map(\.drill), [.warmup, .lesson, .recall])
        XCTAssertNil(run.reps[0].item.lesson?.recall)
        XCTAssertEqual(run.reps[1].item.lesson?.recall?.prompt, "Explain tiers.")
        XCTAssertTrue(run.reps[2].item.lesson?.hasRecall == true)
    }

    func testRecallResultDecodesXPAndAttempt() throws {
        let json = #"""
        {"verdict": "partial", "next_index": 1, "attempt": "a-1", "xp": 10, "overridden": ["p.x"],
         "grade": {"points_hit": [{"point_id": "p.a", "quote": ""}], "points_missed": [{"point_id": "p.b", "why": ""}], "strong_answer": "S"},
         "points": [{"id": "p.a", "text": "A"}, {"id": "p.b", "text": "B"}]}
        """#
        let result = try decode(PrepAttemptResult.self, json)
        XCTAssertEqual(result.attemptID, "a-1")
        XCTAssertEqual(result.xp, 10)
        XCTAssertEqual(result.overridden, ["p.x"])
        XCTAssertEqual(result.judgment?.pointsMissed.map(\.pointID), ["p.b"])
    }

    func testBossOverrideRescoresTheSittingAndRevisit() throws {
        let base = try decode(PrepAttemptResult.self, #"""
        {"verdict": "partial", "attempt": "a-1", "revisit": [{"lesson_id": "u1.l7", "title": "Seven"}],
         "sitting": {"score": 0.67, "passed": false, "stars": 0, "unlocked": null},
         "grade": {"points_hit": [{"point_id": "p.a", "quote": ""}], "points_missed": [{"point_id": "p.b", "why": ""}], "strong_answer": "S"}}
        """#)
        let claimed = try decode(PrepAttemptResult.self, #"""
        {"verdict": "pass", "attempt": "a-2", "overridden": ["p.b"], "revisit": [],
         "sitting": {"score": 0.78, "passed": true, "stars": 1, "unlocked": "Prompt engineering"},
         "grade": {"points_hit": [{"point_id": "p.a", "quote": ""}, {"point_id": "p.b", "quote": ""}], "points_missed": [], "strong_answer": "S"}}
        """#)
        let merged = PrepAttemptResult(merging: base, override: claimed)
        XCTAssertEqual(merged.sitting, PrepBossSitting(score: 0.78, passed: true, stars: 1, unlocked: "Prompt engineering"))
        XCTAssertTrue(merged.revisit.isEmpty)
        XCTAssertEqual(merged.attemptID, "a-2")
        let recall = try decode(PrepAttemptResult.self, #"{"verdict": "pass", "attempt": "a-3"}"#)
        XCTAssertEqual(PrepAttemptResult(merging: base, override: recall).sitting, base.sitting,
                       "a response without a sitting keeps the one shown")
    }

    func testRecallRequestEncodesDontKnowWithoutConfidence() throws {
        let request = PrepAttemptRequest(date: "d", index: 0, item: "u1.l1", drill: .recall, answer: .choice(""),
                                         elapsedMS: 1, hintsUsed: 0, dontKnow: true)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
        XCTAssertFalse(json.contains("confidence"))
        XCTAssertTrue(json.contains(#""dont_know":true"#))
        let plain = PrepAttemptRequest(date: "d", index: 0, item: "u1.l1", drill: .warmup, answer: .choice("A"),
                                       elapsedMS: 1, hintsUsed: 0)
        let plainJSON = try XCTUnwrap(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        XCTAssertFalse(plainJSON.contains("dont_know"))
    }

    func testCourseDecodesReadiness() throws {
        let json = #"""
        {"xp": 40, "ready_count": 3, "lesson_total": 48,
         "units": [{"id": "u1", "title": "F", "state": "current", "ready_count": 3,
                    "lessons": [{"id": "u1.l1", "state": "ready"}, {"id": "u1.l2", "state": "shaky"}]}]}
        """#
        let course = try decode(PrepCourse.self, json)
        XCTAssertEqual(course.readyCount, 3)
        XCTAssertEqual(course.lessonTotal, 48)
        XCTAssertEqual(course.units[0].readyCount, 3)
        XCTAssertEqual(course.units[0].lessons.map(\.state), [.ready, .shaky])
    }

    func testStreakDecodesLastDay() throws {
        XCTAssertEqual(try decode(PrepStreak.self, #"{"days": 2, "freezes": 0, "last_day": "2026-10-20"}"#).lastDay, "2026-10-20")
        XCTAssertNil(try decode(PrepStreak.self, #"{"days": 0}"#).lastDay)
    }

    // MARK: - Story reps

    func testDecodesStoryList() throws {
        let json = #"""
        {"stories": [
          {"id": "s1", "title": "Story s1", "status": "active", "primary_signal": "ownership", "ready": false,
           "marks": {"time": true, "score": true, "probes": true}, "last": "2026-10-18"},
          {"id": "s2", "title": "Story s2", "status": "active", "primary_signal": "ownership", "ready": false,
           "marks": {"time": null, "score": null, "probes": null}, "last": null},
          {"id": "s4", "title": "Story s4", "status": "bench", "primary_signal": null, "ready": false,
           "marks": {}, "last": null}],
         "ready_count": 0, "active_total": 3,
         "candidates": [{"id": "c1", "title": "The outage", "for_prompt": "a failure", "why": "strong number",
                         "verdict": "keep", "status": "new"}]}
        """#
        let list = try decode(PrepStoryList.self, json)
        XCTAssertEqual(list.stories.map(\.id), ["s1", "s2", "s4"])
        XCTAssertEqual(list.stories[0].primarySignal, "ownership")
        XCTAssertEqual(list.stories[0].marks.time, true)
        XCTAssertEqual(list.stories[0].marks.probes, true)
        XCTAssertNil(list.stories[1].marks.score)
        XCTAssertNil(list.stories[2].primarySignal)
        XCTAssertNil(list.stories[2].marks.time)
        XCTAssertEqual(list.stories[2].status, "bench")
        XCTAssertFalse(list.stories[0].ready)
        XCTAssertEqual(list.readyCount, 0)
        XCTAssertEqual(list.activeTotal, 3)
        XCTAssertEqual(list.candidates.first?.forPrompt, "a failure")
        XCTAssertEqual(list.candidates.first?.verdict, "keep")
        XCTAssertEqual(list.candidates.first?.status, "new")
        // A server with nothing to say still decodes.
        let empty = try decode(PrepStoryList.self, "{}")
        XCTAssertTrue(empty.stories.isEmpty)
        XCTAssertTrue(empty.candidates.isEmpty)
        XCTAssertEqual(empty.activeTotal, 0)
    }

    func testDecodesStoryRepExcerpt() throws {
        let json = #"""
        {"date": "2026-10-18", "index": 3, "reps": [
          {"index": 3, "block": "story", "drill": "story",
           "item": {"id": "s1", "title": null, "prompt": "Describe a time you disagreed with a plan (s1).",
                    "limit_ms": 240000, "warn_ms": 210000}}]}
        """#
        let rep = try XCTUnwrap(decode(PrepRun.self, json).reps.first)
        XCTAssertEqual(rep.drill, .story)
        XCTAssertEqual(rep.item.id, "s1")
        XCTAssertEqual(rep.item.prompt, "Describe a time you disagreed with a plan (s1).")
        XCTAssertEqual(rep.item.limitMS, 240_000)
        XCTAssertEqual(rep.item.warnMS, 210_000)
        // Other drills carry no limits.
        let plain = try decode(PrepItemExcerpt.self, #"{"id": "x"}"#)
        XCTAssertNil(plain.limitMS)
        XCTAssertNil(plain.warnMS)
    }

    func testDecodesStoryRepWithPendingProbe() throws {
        let json = #"""
        {"date": "2026-10-18", "index": 3, "reps": [
          {"index": 3, "block": "story", "drill": "story",
           "item": {"id": "s1", "title": null, "prompt": "p", "limit_ms": 240000, "warn_ms": 210000},
           "pending": {"attempt": "942bad09", "number": 2, "probe": {"id": "p2", "attack": "What did it not fix?"}}},
          {"index": 4, "block": "new", "drill": "approach", "item": {"id": "y"}}]}
        """#
        let reps = try decode(PrepRun.self, json).reps
        XCTAssertEqual(reps[0].pending, PrepStoryPending(
            attempt: "942bad09", number: 2, probe: PrepProbe(id: "p2", attack: "What did it not fix?")))
        XCTAssertNil(reps[1].pending)
    }

    func testRepLabelDecodes() throws {
        let json = #"""
        {"date": "2026-10-18", "index": 0, "reps": [
          {"index": 0, "block": "gap", "drill": "recall", "label": "From your mock", "item": {"id": "a"}},
          {"index": 1, "block": "review", "drill": "recall", "item": {"id": "b"}},
          {"index": 2, "block": "gap", "drill": "recall", "label": 7, "item": {"id": "c"}}]}
        """#
        let reps = try decode(PrepRun.self, json).reps
        XCTAssertEqual(reps[0].block, "gap")
        XCTAssertEqual(reps[0].label, "From your mock")
        XCTAssertNil(reps[1].label)
        XCTAssertNil(reps[2].label)
    }

    func testDecodesStoryAttemptResultWithProbe() throws {
        let json = #"""
        {"verdict": "pass", "correct": null, "feedback": "", "credit": 1.0, "reference_md": null, "links": {},
         "next_index": 0, "streak": {"days": 1, "freezes": 0, "last_day": "2026-10-18"},
         "grade": {"verdict": "pass",
                   "points_hit": [{"point_id": "b.situation", "quote": ""}, {"point_id": "b.task", "quote": ""}],
                   "points_missed": [{"point_id": "b.number", "why": "w"}],
                   "strong_answer": "I'd tell s1 like this.", "weakest": "b.number"},
         "score": 4, "elapsed_ms": 200000, "weakest": "b.number", "story_told": "s1", "role": "backup",
         "points": [{"id": "b.situation", "text": "Beat b.situation of s1"},
                    {"id": "b.number", "text": "Beat b.number of s1"}],
         "attempt": "942bad09-74ec-4893-a90b-65cbae0c9971",
         "probe": {"id": "s1.p1", "attack": "What was the number for s1?"},
         "say_it_md": "I'd tell s1 like this."}
        """#
        let result = try decode(PrepAttemptResult.self, json)
        XCTAssertEqual(result.verdict, "pass")
        XCTAssertEqual(result.score, 4)
        XCTAssertEqual(result.elapsedMS, 200_000)
        XCTAssertEqual(result.weakest, "b.number")
        XCTAssertEqual(result.storyTold, "s1")
        XCTAssertEqual(result.role, "backup")
        XCTAssertEqual(result.probe, PrepProbe(id: "s1.p1", attack: "What was the number for s1?"))
        XCTAssertEqual(result.sayItMD, "I'd tell s1 like this.")
        XCTAssertNil(result.repVerdict)
        XCTAssertNil(result.lead)
        XCTAssertNil(result.backup)
        XCTAssertEqual(result.attemptID, "942bad09-74ec-4893-a90b-65cbae0c9971")
        XCTAssertEqual(result.judgment?.pointsHit.count, 2)
        XCTAssertEqual(result.pointTexts["b.number"], "Beat b.number of s1")
    }

    func testDecodesWrongStoryNamesLeadAndBackup() throws {
        let json = #"""
        {"verdict": "partial", "score": 3, "role": "wrong", "story_told": "s2", "probe": null,
         "lead": {"id": "s1", "title": "The migration"}, "backup": {"id": "s3", "title": "The outage"}}
        """#
        let result = try decode(PrepAttemptResult.self, json)
        XCTAssertEqual(result.role, "wrong")
        XCTAssertEqual(result.lead, PrepStoryRef(id: "s1", title: "The migration"))
        XCTAssertEqual(result.backup, PrepStoryRef(id: "s3", title: "The outage"))
        XCTAssertNil(result.probe)
    }

    func testDecodesProbeAttemptResults() throws {
        let first = try decode(PrepAttemptResult.self, #"""
        {"verdict": "pass", "credit": 1.0, "next_index": 0,
         "grade": {"verdict": "pass", "points_hit": [{"point_id": "s1.p1.1", "quote": ""}], "points_missed": [], "strong_answer": ""},
         "points": [{"id": "s1.p1.1", "text": "States the number"}],
         "attempt": "4125ebc9", "probe": {"id": "s1.p2", "attack": "What did it not fix in s1?"}}
        """#)
        XCTAssertEqual(first.probe?.id, "s1.p2")
        XCTAssertNil(first.repVerdict)
        let last = try decode(PrepAttemptResult.self, #"""
        {"verdict": "pass", "credit": 1.0, "next_index": 0, "attempt": "78262740", "probe": null, "rep_verdict": "pass"}
        """#)
        XCTAssertNil(last.probe)
        XCTAssertEqual(last.repVerdict, "pass")
        let failed = try decode(PrepAttemptResult.self, #"{"verdict": "fail", "probe": null, "rep_verdict": "fail"}"#)
        XCTAssertEqual(failed.repVerdict, "fail")
    }

    func testMergingOverrideKeepsStoryFields() throws {
        let base = try decode(PrepAttemptResult.self, #"""
        {"verdict": "partial", "score": 3, "weakest": "b.number", "story_told": "s1", "role": "backup",
         "probe": {"id": "p1", "attack": "a"}, "say_it_md": "say", "elapsed_ms": 1000}
        """#)
        let override = try decode(PrepAttemptResult.self, #"{"verdict": "pass", "score": 4}"#)
        let merged = PrepAttemptResult(merging: base, override: override)
        XCTAssertEqual(merged.verdict, "pass")
        XCTAssertEqual(merged.score, 4)
        XCTAssertEqual(merged.weakest, "b.number")
        XCTAssertEqual(merged.storyTold, "s1")
        XCTAssertEqual(merged.probe?.id, "p1")
        XCTAssertEqual(merged.sayItMD, "say")
    }

    func testUnknownDrillStillDecodes() throws {
        XCTAssertEqual(try decode(PrepDrill.self, #""story""#), .story)
        XCTAssertEqual(try decode(PrepDrill.self, #""probe""#), .probe)
        XCTAssertEqual(try decode(PrepDrill.self, #""hologram""#), .unknown)
        XCTAssertEqual(try decode(PrepRunKind.self, #""story""#), .story)
        XCTAssertEqual(try decode(PrepRunKind.self, #""hologram""#), .unknown)
    }

    func testProbeRequestEncodesParentAndProbe() throws {
        let data = try JSONEncoder().encode(PrepAttemptRequest(
            date: "2026-10-18", index: 3, item: "s1", drill: .probe,
            answer: .choice("It was 40%."), elapsedMS: 30_000, hintsUsed: 0,
            parent: "942bad09", probe: "s1.p1"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["drill"] as? String, "probe")
        XCTAssertEqual(body["parent"] as? String, "942bad09")
        XCTAssertEqual(body["probe"] as? String, "s1.p1")
        XCTAssertEqual(body["answer"] as? String, "It was 40%.")
        XCTAssertEqual(body["elapsed_ms"] as? Int, 30_000)
    }

    func testStoryRequestOmitsOptionalFields() throws {
        let data = try JSONEncoder().encode(PrepAttemptRequest(
            date: "2026-10-18", index: 3, item: "s1", drill: .story,
            answer: .choice("So the plan was..."), elapsedMS: 200_000, hintsUsed: 0))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["drill"] as? String, "story")
        XCTAssertEqual(body["run"] as? String, "daily")
        XCTAssertEqual(body["item"] as? String, "s1")
        XCTAssertNil(body["parent"])
        XCTAssertNil(body["probe"])
        XCTAssertNil(body["unit"])
        XCTAssertNil(body["dont_know"])
    }
}

// MARK: - Tutor dialogue and lesson cards (spec 2026-10-19 Track A)

final class PrepDialogueModelTests: XCTestCase {
    func testSSEParserSplitsEventsWithoutBlankLines() {
        // URLSession's line reader drops blank lines, so the server's framing arrives like this.
        var parser = PrepSSEParser()
        let lines = ["event: delta", #"data: {"text": "Hi"}"#, "event: turn", #"data: {"text": "Hi"}"#,
                     "event: done", #"data: {"verdict": "miss", "dialogue": {"open": true, "followups": 0, "turns": [{"role": "tutor", "text": "Hi"}]}}"#]
        let events = lines.compactMap { parser.feed($0) } + [parser.finish()].compactMap { $0 }
        XCTAssertEqual(events.map(\.event), ["delta", "turn", "done"])
        XCTAssertEqual(PrepDialogueEvent.decode(event: events[0].event, data: events[0].data), .delta("Hi"))
        guard case .done(let done)? = PrepDialogueEvent.decode(event: events[2].event, data: events[2].data) else {
            return XCTFail("done decodes")
        }
        XCTAssertEqual(done.dialogue?.awaitingReply, true)
    }

    func testSSEParserFoldsEventsAndSkipsComments() {
        var parser = PrepSSEParser()
        let lines = [": keepalive", "", "event: delta", "data: {\"text\": \"Hi\"}", "", "event: turn",
                     "data: {\"text\": \"Hi there\"}"]
        let events = lines.compactMap { parser.feed($0) } + [parser.finish()].compactMap { $0 }
        XCTAssertEqual(events.map(\.event), ["delta", "turn"])
        XCTAssertEqual(PrepDialogueEvent.decode(event: events[0].event, data: events[0].data), .delta("Hi"))
        XCTAssertEqual(PrepDialogueEvent.decode(event: events[1].event, data: events[1].data), .turn("Hi there"))
    }

    func testUnknownAndErrorEvents() {
        XCTAssertNil(PrepDialogueEvent.decode(event: "ping", data: "{}"))
        XCTAssertEqual(PrepDialogueEvent.decode(event: "reset", data: "{}"), .reset)
        XCTAssertEqual(PrepDialogueEvent.decode(event: "error", data: #"{"status": 409, "error": "moved on"}"#),
                       .failed(status: 409, message: "moved on"))
    }

    func testDialogueStateDecodesTolerantly() throws {
        let state = try PrepDecoding.decode(PrepDialogueState.self, from: Data(#"""
        {"open": true, "followups": 1, "turns": [{"role": "tutor", "text": "Why?"}, {"bad": 1}]}
        """#.utf8))
        XCTAssertTrue(state.open)
        XCTAssertEqual(state.max, 3)
        XCTAssertEqual(state.turns.count, 2, "a turn missing fields decodes empty, never crashes")
        XCTAssertFalse(state.awaitingReply)
        XCTAssertEqual(PrepCopy.followupLine(state), "Follow-up 1 of 3")
        XCTAssertNil(PrepCopy.followupLine(nil), "no count before the tutor's first follow-up")
    }

    func testLessonCardsDecodeAndSkipMissingPictureAndWork() throws {
        let lesson = try PrepDecoding.decode(PrepLesson.self, from: Data(#"""
        {"id": "u1.l1", "title": "Tokens", "idea_md": "Idea", "check": {"prompt": "Q?"},
         "recall": {"prompt": "Why?", "question": "u1.l1.q2", "type": "apply"},
         "cards": {"case": {"headline": "H", "body": "B", "ask": "A?"}, "idea": [{"lead": "Budget", "text": "the window."}],
                   "picture": {"steps": ["a"]}, "in_your_work": {"text": ""}}}
        """#.utf8))
        let cards = try XCTUnwrap(lesson.cards)
        XCTAssertNil(cards.picture, "one step is not a flow")
        XCTAssertNil(cards.inYourWork)
        XCTAssertEqual(PrepLessonCardKind.cards(for: cards), [.theCase, .point(0), .lockIn])
        XCTAssertEqual(lesson.recall?.questionID, "u1.l1.q2")
        XCTAssertEqual(lesson.recall?.isQuestion, true)
    }

    func testAFlowPictureNoLongerGetsACard() throws {
        let lesson = try PrepDecoding.decode(PrepLesson.self, from: Data(#"""
        {"id": "u2.l12", "title": "Multi-step", "idea_md": "Idea",
         "cards": {"case": {"headline": "H", "body": "B", "ask": "A?"}, "idea": [{"lead": "Keep", "text": "both."}],
                   "picture": {"steps": ["read", "think", "answer"]}, "in_your_work": {"text": "At work."}}}
        """#.utf8))
        let cards = try XCTUnwrap(lesson.cards)
        XCTAssertEqual(PrepLessonCardKind.cards(for: cards), [.theCase, .point(0), .work, .lockIn],
                       "Lock it in closes every lesson, after In your work")
    }

    func testEachIdeaPointGetsItsOwnCardWithItsExample() throws {
        let lesson = try PrepDecoding.decode(PrepLesson.self, from: Data(#"""
        {"id": "u4.l2", "title": "Why the RSP changed", "idea_md": "Idea",
         "cards": {"case": {"headline": "H", "body": "B", "ask": "A?"},
                   "idea": [{"lead": "Collective action:", "text": "Risk depends on everyone.", "example": "A lab pausing alone."},
                            {"lead": "Arguments, not lists:", "text": "Argue the risk is contained."},
                            {"lead": "ASL labels now:", "text": "Labels describe protections.", "example": "  "}]}}
        """#.utf8))
        let cards = try XCTUnwrap(lesson.cards)
        XCTAssertEqual(PrepLessonCardKind.cards(for: cards), [.theCase, .point(0), .point(1), .point(2), .lockIn])
        XCTAssertEqual(cards.idea[0].example, "A lab pausing alone.")
        XCTAssertNil(cards.idea[1].example, "a lesson without examples still decodes")
        XCTAssertEqual(PrepLessonCardKind.point(1).title, "Point 2")
        XCTAssertEqual(PrepCopy.cardPageLabel(page: .point(2), in: PrepLessonCardKind.cards(for: cards)), "Card 4 of 5, Point 3")
    }

    func testIdeaLeadDropsTheAuthoredColon() {
        XCTAssertEqual(PrepCopy.ideaLead("Quote first:"), "Quote first")
        XCTAssertEqual(PrepCopy.ideaLead(" Split when work fans out: "), "Split when work fans out")
        XCTAssertEqual(PrepCopy.ideaLead("Budget"), "Budget", "an older lead without a colon is unchanged")
    }

    func testTakeawayLineIsTheIdeasFirstSentence() {
        XCTAssertEqual(PrepCopy.takeawayLine("For refusals, state the line and show one example. Add one request that sounds risky."),
                       "For refusals, state the line and show one example.")
        XCTAssertEqual(PrepCopy.takeawayLine(" Cluster the failures by cause "), "Cluster the failures by cause",
                       "a sentence with no end comes back whole")
        XCTAssertEqual(PrepCopy.takeawayLine(#"Give one exact reply for when no quote supports an answer, such as "The policy does not cover this." An empty quote set tells the model to stop."#),
                       #"Give one exact reply for when no quote supports an answer, such as "The policy does not cover this.""#,
                       "the closing quote stays with its sentence")
        XCTAssertEqual(PrepCopy.takeawayLine("Use a cheap model, e.g. a small one, first. Then escalate."),
                       "Use a cheap model, e.g. a small one, first.", "a period before lowercase text doesn't end it")
    }

    func testLockInPromptCountsThePoints() {
        XCTAssertEqual(PrepCopy.lockInPrompt(3), "Say what each of these 3 means in your own words, then check it.")
        XCTAssertEqual(PrepCopy.lockInPrompt(1), "Say what this means in your own words, then check it.")
    }

    func testCodeCardAndDiagramDecode() throws {
        let lesson = try PrepDecoding.decode(PrepLesson.self, from: Data(#"""
        {"id": "u10.l2", "title": "Recall vs rank", "idea_md": "Idea",
         "cards": {"case": {"headline": "H", "body": "B", "ask": "A?"}, "idea": [{"lead": "Split", "text": "the metric."}],
                   "code": {"lang": "python", "body": "def hit(r, k):\n    return r < k", "caption": "Two questions."}},
         "diagram": {"topic": "recall-vs-rank-miss", "title": "Recall vs rank miss"}}
        """#.utf8))
        let cards = try XCTUnwrap(lesson.cards)
        XCTAssertEqual(PrepLessonCardKind.cards(for: cards), [.theCase, .point(0), .code, .lockIn])
        XCTAssertEqual(cards.code?.body, "def hit(r, k):\n    return r < k")
        XCTAssertEqual(cards.code?.caption, "Two questions.")
        XCTAssertEqual(lesson.diagram?.topic, "recall-vs-rank-miss")
    }

    func testAnEmptyCodeCardOrDiagramIsDropped() throws {
        let lesson = try PrepDecoding.decode(PrepLesson.self, from: Data(#"""
        {"id": "u1.l1", "title": "T", "idea_md": "Idea",
         "cards": {"case": {"headline": "H", "body": "B", "ask": "A?"}, "idea": [{"lead": "L", "text": "t."}],
                   "code": {"lang": "python", "body": "  "}},
         "diagram": {"title": "No topic"}}
        """#.utf8))
        XCTAssertNil(lesson.cards?.code)
        XCTAssertNil(lesson.diagram)
    }

    func testCaseBodyJoinsAuthoredLineBreaks() {
        XCTAssertEqual(PrepCopy.caseBody("Asked about a leave type,\nthe model says yes."),
                       "Asked about a leave type, the model says yes.")
        XCTAssertEqual(PrepCopy.caseBody("One.\n\nTwo,\nthree."), "One.\n\nTwo, three.")
    }

    func testStoryCuesDecodeFromTheExcerpt() throws {
        let item = try PrepDecoding.decode(PrepItemExcerpt.self, from: Data(#"""
        {"id": "s9", "title": "Retrieval quality", "prompt": "Hardest problem?", "signal": "Most technically challenging thing",
         "cues": [{"id": "b.situation", "label": "Scope", "cue": "No retrieval metric"}, {"id": "b.task", "label": "Owned"}],
         "script_md": "The script."}
        """#.utf8))
        XCTAssertEqual(item.cues.map(\.label), ["Scope"], "a cue with no words is dropped")
        XCTAssertEqual(item.signal, "Most technically challenging thing")
        XCTAssertEqual(item.scriptMD, "The script.")
    }
}
