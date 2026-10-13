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
        XCTAssertEqual(home.tracks.first?.id, "dsa")
        XCTAssertEqual(home.tracks.first?.total, 18)
        XCTAssertEqual(home.tracks.first?.subtitle, "0 of 18 mastered")
        XCTAssertEqual(home.needsWork.first?.skill, "dsa.arrays_hashing")
        XCTAssertEqual(home.needsWork.first?.detail, "Mixed up with Two Pointers")
        XCTAssertNil(home.readiness)
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

    func testMapDecodesLevelsAndSkillStates() throws {
        let map = try decode(PrepTrackMap.self, #"""
        {"track": "dsa", "title": "DSA patterns", "summary": {"mastered": 0, "total": 18, "problems": 150, "due": 0},
         "levels": [
          {"title": "Start here", "locked": false, "skills": [{"id": "dsa.arrays_hashing", "title": "Arrays & Hashing", "state": "in_progress", "mastery": 0.4, "detail": "9 problems"}]},
          {"title": "Level 2", "locked": true, "skills": [{"id": "dsa.stack", "title": "Stack", "state": "locked", "mastery": 0.0, "detail": "x"},
                                                           {"id": "dsa.q", "title": "Q", "state": "brand_new", "mastery": 0.0}]}]}
        """#)
        XCTAssertEqual(map.summary.problems, 150)
        XCTAssertEqual(map.levels.count, 2)
        XCTAssertTrue(map.levels[1].locked)
        XCTAssertEqual(map.levels[0].skills[0].state, .inProgress)
        XCTAssertEqual(map.levels[0].skills[0].mastery, 0.4, accuracy: 0.001)
        XCTAssertEqual(map.levels[1].skills.map(\.state), [.locked, .unknown])
    }

    func testMissingFieldsDefault() throws {
        let home = try decode(PrepHome.self, "{}")
        XCTAssertEqual(home.streak.days, 0)
        XCTAssertEqual(home.run.reps, 0)
        XCTAssertTrue(home.tracks.isEmpty)
        XCTAssertTrue(home.needsWork.isEmpty)

        let run = try decode(PrepRun.self, #"{"reps": [{"index": 0, "drill": "primer", "item": {}}]}"#)
        XCTAssertEqual(run.date, "")
        XCTAssertEqual(run.reps.first?.item.id, "")
        XCTAssertEqual(run.reps.first?.item.hints, [])
        XCTAssertTrue(run.reps.first?.item.links.isEmpty ?? false)

        let map = try decode(PrepTrackMap.self, #"{"levels": [{"skills": [{"id": "s"}]}]}"#)
        XCTAssertEqual(map.levels.first?.skills.first?.state, .unknown)
        XCTAssertEqual(map.levels.first?.locked, false)
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
}
