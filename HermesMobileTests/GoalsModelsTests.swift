import XCTest
@testable import HermesMobile

final class GoalsModelsTests: XCTestCase {
    /// `GET /api/goals` from the real vault on 2026-10-10 (Task 3's read check).
    static let homeSample = #"""
    {"today": "2026-10-10", "yesterday": "2026-10-09", "streak": {"days": 0, "at_risk": false}, "goals": [{"slug": "nyc-marathon-2026", "title": "Finish the NYC Marathon, uninjured", "status": "active", "deadline": "2026-11-01", "days_left": 22, "identity": "a New York City Marathon finisher", "next_milestone": {"id": "m1", "title": "Taper long run: ~12 mi easy, foot and hips no worse next day", "due": "2026-10-17"}, "week": {"start": "2026-10-12", "end": "2026-10-18", "commitments": [{"id": "stretch-pm", "action": "Nightly stretch (knee hugs, figure-4 twists, open books)", "target": 6, "skips": 1, "cue": "In bed → water + vitamin → stretch → then read", "minimum": "30 s knee hugs + one figure-4 each side", "days": null, "done": 0, "min": 0, "skipped": 0, "missed": 0, "hit": false, "remaining": 6, "due_today": true, "due_yesterday": true, "today": null, "yesterday": null}, {"id": "long-run", "action": "Saturday taper run (~12 mi easy)", "target": 1, "skips": 0, "cue": "Saturday morning", "minimum": "30-min walk and book a PT if the foot still hurts", "days": ["sat"], "done": 0, "min": 0, "skipped": 0, "missed": 0, "hit": false, "remaining": 1, "due_today": true, "due_yesterday": false, "today": null, "yesterday": null}]}, "daily_checks": [{"id": "foot", "question": "Foot today: better, same, or worse?", "options": ["better", "same", "worse"], "today": null, "yesterday": null}], "flags": {"miss_twice": [], "escalations": [], "unlock_ready": []}}], "agent_goals": [{"slug": "interview-ready", "title": "Interview ready (Applied AI Engineer)", "status": "active", "next_check": "2026-10-16T17:00"}], "errors": []}
    """#

    static func detailJSON(consistency: String = #"{"weeks": 0, "weeks_hit": 0, "last4": null, "lifetime": null}"#) -> String {
        let home = try! JSONSerialization.jsonObject(with: Data(homeSample.utf8)) as! [String: Any]
        var goal = (home["goals"] as! [[String: Any]])[0]
        goal["why"] = "Prove I can do hard things"
        goal["objective"] = "Run it."
        goal["done_when"] = [["text": "Finished", "checked": false]]
        goal["milestones"] = [["id": "m1", "title": "Taper", "due": "2026-10-17", "done": NSNull()]]
        goal["consistency"] = try! JSONSerialization.jsonObject(with: Data(consistency.utf8))
        goal["heatmap"] = [["date": "2026-10-10", "status": "done"], ["date": "2026-10-11", "status": "none"]]
        goal["check_history"] = ["foot": [["date": "2026-10-10", "value": "same"]]]
        goal["today"] = "2026-10-13"
        goal["yesterday"] = "2026-10-12"
        goal["streak"] = ["days": 1, "at_risk": false]
        let data = try! JSONSerialization.data(withJSONObject: goal)
        return String(decoding: data, as: UTF8.self)
    }

    func testHomeDecodesServerSample() throws {
        let home = try PrepDecoding.decode(GoalsHome.self, from: Data(Self.homeSample.utf8))
        XCTAssertEqual(home.today, "2026-10-10")
        XCTAssertEqual(home.yesterday, "2026-10-09")
        XCTAssertEqual(home.streak, GoalStreak(days: 0, atRisk: false))
        let goal = try XCTUnwrap(home.goals.first)
        XCTAssertEqual(goal.slug, "nyc-marathon-2026")
        XCTAssertEqual(goal.daysLeft, 22)
        XCTAssertEqual(goal.nextMilestone?.due, "2026-10-17")
        XCTAssertEqual(goal.week.commitments.map(\.id), ["stretch-pm", "long-run"])
        XCTAssertNil(goal.week.commitments[0].days)
        XCTAssertEqual(goal.week.commitments[1].days, ["sat"])
        XCTAssertEqual(goal.week.commitments[0].target, 6)
        XCTAssertNil(goal.week.commitments[0].today)
        XCTAssertEqual(goal.dailyChecks.first?.options, ["better", "same", "worse"])
        XCTAssertEqual(home.agentGoals.map(\.slug), ["interview-ready"])
        XCTAssertTrue(home.errors.isEmpty)
    }

    func testDetailDecodesHeatmapAndConsistencyNulls() throws {
        let detail = try PrepDecoding.decode(GoalDetail.self, from: Data(Self.detailJSON().utf8))
        XCTAssertEqual(detail.summary.slug, "nyc-marathon-2026")
        XCTAssertEqual(detail.heatmap.map(\.status), [.done, GoalStatus.none])
        XCTAssertNil(detail.consistency.lifetime)
        XCTAssertEqual(detail.consistency.weeks, 0)
        XCTAssertEqual(detail.milestones.first?.done, nil)
        XCTAssertEqual(detail.checkHistory["foot"]?.first?.value, "same")
        XCTAssertEqual(detail.doneWhen.first?.text, "Finished")
        XCTAssertEqual(detail.today, "2026-10-13")
        XCTAssertEqual(detail.streak.days, 1)
    }

    func testUnknownStatusDecodesAsUnknown() throws {
        let json = #"{"id":"x","today":"later","yesterday":"done"}"#
        let row = try PrepDecoding.decode(GoalCommitmentProgress.self, from: Data(json.utf8))
        XCTAssertEqual(row.today, .unknown)
        XCTAssertEqual(row.yesterday, .done)
    }

    func testCheckInRequestEncodesBothShapes() throws {
        let commitment = GoalCheckInRequest.commitment(slug: "m", date: "2026-10-10", asOf: "2026-10-11", id: "stretch-pm", status: .min)
        let check = GoalCheckInRequest.check(slug: "m", date: "2026-10-10", asOf: "2026-10-11", id: "foot", value: "worse")
        let a = try JSONSerialization.jsonObject(with: JSONEncoder().encode(commitment)) as! [String: String]
        let b = try JSONSerialization.jsonObject(with: JSONEncoder().encode(check)) as! [String: String]
        XCTAssertEqual(a, ["slug": "m", "date": "2026-10-10", "as_of": "2026-10-11", "commitment": "stretch-pm", "status": "min"])
        XCTAssertEqual(b, ["slug": "m", "date": "2026-10-10", "as_of": "2026-10-11", "check": "foot", "value": "worse"])
    }

    func testMissingFieldsDefault() throws {
        let home = try PrepDecoding.decode(GoalsHome.self, from: Data(#"{"goals":[{"slug":"a"}, 5]}"#.utf8))
        XCTAssertEqual(home.goals.map(\.slug), ["a"])
        XCTAssertEqual(home.streak, GoalStreak(days: 0, atRisk: false))
        XCTAssertEqual(home.goals[0].week.commitments, [])
        XCTAssertNil(home.goals[0].nextMilestone)
        XCTAssertEqual(home.goals[0].flags, GoalFlags())
    }
}
