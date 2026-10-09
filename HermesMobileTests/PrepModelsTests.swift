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

    func testRunDropsUnknownDrillReps() throws {
        let json = #"""
        {"date": "2026-10-09", "index": 1, "reps": [
          {"index": 0, "block": "new", "drill": "primer", "item": {"id": "dsa.0217", "title": "Contains Duplicate",
            "primer": {"signals": ["a"], "template": "t", "invariant": "i", "complexity": "O(n)"}, "reference_md": "## 1"}},
          {"index": 1, "block": "new", "drill": "pattern_id", "item": {"id": "dsa.0217", "skill_title": null,
            "options": [{"id": "dsa.stack", "title": "Stack"}]}},
          {"index": 2, "block": "new", "drill": "flashcard", "item": {"id": "dsa.0217"}},
          {"block": "new", "drill": "complexity", "item": {"id": "dsa.0217", "options": ["O(n)", "O(n^2)"]}},
          {"index": 4, "block": "warmup", "drill": "parsons", "item": {"id": "dsa.0001", "lines": ["a", "b"]}}
        ]}
        """#
        let run = try decode(PrepRun.self, json)
        XCTAssertEqual(run.index, 1)
        XCTAssertEqual(run.reps.map(\.index), [0, 1, 4])
        XCTAssertEqual(run.reps.map(\.drill), [.primer, .patternID, .parsons])
        XCTAssertEqual(run.reps[0].item.primer?.complexity, "O(n)")
        XCTAssertEqual(run.reps[0].item.referenceMD, "## 1")
        XCTAssertEqual(run.reps[1].item.options, [PrepOption(id: "dsa.stack", title: "Stack")])
        XCTAssertEqual(run.reps[2].item.lines, ["a", "b"])
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

    func testAttemptRequestEncodesChoiceAndLines() throws {
        func object(_ r: PrepAttemptRequest) throws -> [String: Any] {
            let data = try JSONEncoder().encode(r)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let choice = try object(PrepAttemptRequest(
            date: "2026-10-09", index: 1, item: "dsa.0217", drill: .patternID,
            answer: .choice("dsa.two_pointers"), elapsedMS: 8000, hintsUsed: 0))
        XCTAssertEqual(choice["answer"] as? String, "dsa.two_pointers")
        XCTAssertEqual(choice["drill"] as? String, "pattern_id")
        XCTAssertEqual(choice["elapsed_ms"] as? Int, 8000)
        XCTAssertEqual(choice["hints_used"] as? Int, 0)
        XCTAssertEqual(choice["index"] as? Int, 1)
        XCTAssertEqual(choice["item"] as? String, "dsa.0217")
        XCTAssertEqual(choice["date"] as? String, "2026-10-09")

        let lines = try object(PrepAttemptRequest(
            date: "2026-10-09", index: 4, item: "dsa.0001", drill: .parsons,
            answer: .lines(["a", "b"]), elapsedMS: 1, hintsUsed: 2))
        XCTAssertEqual(lines["answer"] as? [String], ["a", "b"])
        XCTAssertEqual(lines["drill"] as? String, "parsons")
    }

    func testAttemptResultDecodesStringAndArrayCorrect() throws {
        let miss = try decode(PrepAttemptResult.self, #"""
        {"verdict": "miss", "correct": "dsa.arrays_hashing", "feedback": "It's A&H.", "credit": 0,
         "reference_md": "## 1", "links": {"leetcode": "https://l"}, "next_index": 2, "streak": {"days": 1, "freezes": 0}}
        """#)
        XCTAssertEqual(miss.verdict, "miss")
        XCTAssertEqual(miss.correct, .choice("dsa.arrays_hashing"))
        XCTAssertEqual(miss.nextIndex, 2)
        XCTAssertEqual(miss.streak?.days, 1)
        XCTAssertEqual(miss.links["leetcode"], "https://l")
        let parsons = try decode(PrepAttemptResult.self, #"{"verdict": "hit", "correct": ["a", "b"], "next_index": 5}"#)
        XCTAssertEqual(parsons.correct, .lines(["a", "b"]))
        let primer = try decode(PrepAttemptResult.self, #"{"verdict": "seen", "correct": null, "feedback": "", "next_index": 1}"#)
        XCTAssertNil(primer.correct)
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
}
