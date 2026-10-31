import XCTest
@testable import HermesMobile

/// Finishing a goal: the record's decode, the words and numbers drawn from it, and the
/// finish and reflection flows.
@MainActor
final class GoalFinishTests: XCTestCase {
    /// `POST /api/goals/finish` from the vault's goals.py (tests' marathon fixture, 2026-11-01),
    /// with the splits and heatmap cut short.
    static let recordSample = #"""
    {"started": "2026-10-10", "finished": "2026-11-01", "days": 23, "shown": 20, "min_days": 2, "skip_days": 2, "miss_days": 1, "missed_twice": 0, "streak": {"days": 20, "start": "2026-10-10", "end": "2026-11-01"}, "weeks": {"weeks": 3, "weeks_hit": 3, "last4": 1.0, "lifetime": 1.0}, "skips": {"used": 2, "budget": 4}, "milestones": [{"id": "m1", "title": "Taper long run", "due": "2026-10-17", "done": "2026-10-17", "on_time": true}, {"id": "m3", "title": "Cross the finish line, uninjured", "due": "2026-11-01", "done": "2026-11-01", "on_time": true}], "commitments": [{"id": "stretch-pm", "unit": "day", "done": 18, "min": 2, "total": 20, "action": "Nightly stretch (knee hugs, figure-4 twists, open books)"}, {"id": "outreach", "unit": "item", "done": 64, "min": 0, "total": 64, "action": "Outreach"}, {"id": "long-run", "unit": "day", "done": 0, "min": 0, "total": 0, "action": "Saturday taper run"}], "checks": [{"id": "foot", "question": "Foot today: better, same, or worse?", "counts": [{"value": "better", "count": 16}, {"value": "same", "count": 6}, {"value": "worse", "count": 1}]}], "runs": {"year": 2026, "count": 27, "miles": 259.5, "seconds": 150120, "first": "2026-04-24", "longest": {"date": "2026-11-01", "miles": 26.2, "seconds": 17800, "avg_hr": 151, "pr": false}, "prs": ["2026-08-22", "2026-10-10"], "months": [{"month": "2026-10", "miles": 48.8}, {"month": "2026-11", "miles": 26.2}], "race": {"date": "2026-11-01", "miles": 26.2, "seconds": 17800, "avg_hr": 151, "pr": false, "pace_s": 679, "max_hr": 175, "splits": [705, 690, 631], "fastest_mile_s": 631, "halves_s": -72}}, "heatmap": [{"date": "2026-10-10", "status": "done"}, {"date": "2026-10-11", "status": "min"}], "headline": {"value": "259.5", "label": "miles run in 2026"}, "story": [{"date": "2026-10-10", "title": "Set the goal, then ran 20.1 mi", "detail": "20.1 mi · 3 h 55 m · 11:39/mi", "major": true}, {"date": "2026-11-01", "title": "Cross the finish line, uninjured", "detail": "26.2 mi · 4:56:40", "major": true}], "closed_at": "2026-11-01T16:30", "slug": "nyc-marathon-2026", "title": "Finish the NYC Marathon, uninjured", "identity": "a New York City Marathon finisher", "why": "Prove to myself I can do something very difficult.", "color": "wiki", "icon": "figure.run", "outcome": "achieved", "reflection": ""}
    """#

    static func record(_ fields: [String: Any] = [:]) throws -> GoalRecord {
        var body = try JSONSerialization.jsonObject(with: Data(recordSample.utf8)) as! [String: Any]
        body.merge(fields) { $1 }
        return try PrepDecoding.decode(GoalRecord.self, from: JSONSerialization.data(withJSONObject: body))
    }

    private func detail(finishDue: Bool) throws -> GoalDetail {
        var goal = try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.detailJSON().utf8)) as! [String: Any]
        goal["finish_due"] = finishDue
        goal["milestones"] = [["id": "m3", "title": "Cross the finish line", "due": "2026-10-13", "done": NSNull()]]
        return try PrepDecoding.decode(GoalDetail.self, from: JSONSerialization.data(withJSONObject: goal))
    }

    // MARK: Decoding

    func testRecordDecodesTheVaultsShape() throws {
        let r = try Self.record()
        XCTAssertEqual([r.days, r.shown, r.minDays, r.skipsUsed, r.skipsBudget], [23, 20, 2, 2, 4])
        XCTAssertEqual(r.streak?.days, 20)
        XCTAssertEqual(r.weeks.weeksHit, 3)
        XCTAssertEqual(r.checks.first?.counts.map(\.value), ["better", "same", "worse"], "the question's order")
        XCTAssertEqual(r.runs?.race?.splits, [705, 690, 631])
        XCTAssertEqual(r.runs?.race?.halvesSeconds, -72)
        XCTAssertEqual(r.runs?.months.map(\.month), ["2026-10", "2026-11"])
        XCTAssertEqual(r.heatmap.map(\.status), [.done, .min])
        XCTAssertEqual(r.story.last?.title, "Cross the finish line, uninjured")
        XCTAssertEqual(r.headline?.value, "259.5")
    }

    func testRecordWithoutRunsOrOptionalPartsStillDecodes() throws {
        let r = try PrepDecoding.decode(GoalRecord.self, from: Data(#"{"slug": "x", "runs": null, "skips": "bad"}"#.utf8))
        XCTAssertNil(r.runs)
        XCTAssertNil(r.streak)
        XCTAssertEqual(r.skipsBudget, 0)
        XCTAssertTrue(r.story.isEmpty)
    }

    func testHomeCarriesFinishedGoalsAndFinishDue() throws {
        var home = try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.homeSample.utf8)) as! [String: Any]
        var goals = home["goals"] as! [[String: Any]]
        goals[0]["finish_due"] = true
        home["goals"] = goals
        home["finished"] = [["slug": "nyc-marathon-2026", "title": "Finish the NYC Marathon", "identity": "a New York City Marathon finisher",
                             "color": "wiki", "icon": "figure.run", "started": "2026-10-10", "finished": "2026-11-01",
                             "days": 23, "shown": 20, "headline": ["value": "259.5", "label": "miles run in 2026"],
                             "milestones": 3, "milestones_on_time": 3], "junk"]
        let decoded = try PrepDecoding.decode(GoalsHome.self, from: JSONSerialization.data(withJSONObject: home))
        XCTAssertTrue(decoded.goals[0].finishDue)
        XCTAssertEqual(decoded.finished.map(\.slug), ["nyc-marathon-2026"], "a bad row is dropped, not fatal")
        XCTAssertEqual(decoded.finished[0].milestonesOnTime, 3)
        let older = try PrepDecoding.decode(GoalsHome.self, from: Data(GoalsModelsTests.homeSample.utf8))
        XCTAssertFalse(older.goals[0].finishDue, "an older server never asks")
        XCTAssertTrue(older.finished.isEmpty)
    }

    func testRequestsEncodeTheServersKeys() throws {
        let finish = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            GoalFinishRequest(slug: "m", asOf: "2026-11-01"))) as! [String: String]
        XCTAssertEqual(finish, ["slug": "m", "as_of": "2026-11-01"])
        let reflection = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            GoalReflectionRequest(slug: "m", text: "Hi"))) as! [String: String]
        XCTAssertEqual(reflection, ["slug": "m", "text": "Hi"])
    }

    // MARK: Copy

    func testTimesAndPaces() {
        XCTAssertEqual(GoalFinishCopy.clock(17800), "4:56:40")
        XCTAssertEqual(GoalFinishCopy.clock(2892), "48:12")
        XCTAssertEqual(GoalFinishCopy.pace(679), "11:19")
        XCTAssertEqual(GoalFinishCopy.hours(150120), "41 h 42 m")
        XCTAssertEqual(GoalFinishCopy.halves(-72).value, "−1:12")
        XCTAssertEqual(GoalFinishCopy.halves(-72).note, "negative split")
        XCTAssertEqual(GoalFinishCopy.halves(30).value, "+0:30")
        XCTAssertEqual(GoalFinishCopy.miles(26.2), "26.2")
        XCTAssertEqual(GoalFinishCopy.miles(3), "3")
        XCTAssertEqual(GoalFinishCopy.month("2026-04"), "Apr")
        XCTAssertEqual(GoalFinishCopy.longDate("2026-11-01"), "Sunday, Nov 1")
    }

    func testHeadlinesComeFromWhoHeBecame() throws {
        let r = try Self.record()
        XCTAssertEqual(GoalFinishCopy.headline(r), "You're a New York City Marathon finisher")
        XCTAssertEqual(GoalFinishCopy.identityTitle(r), "A New York City Marathon finisher")
        let plain = try Self.record(["identity": ""])
        XCTAssertEqual(GoalFinishCopy.headline(plain), "You finished Finish the NYC Marathon, uninjured")
        XCTAssertEqual(GoalFinishCopy.raceLine(try XCTUnwrap(r.runs?.race)), "26.2 mi in 4:56:40 · 11:19/mi")
    }

    func testTilesTellTheStory() throws {
        let r = try Self.record()
        XCTAssertEqual(GoalFinishCopy.recordTiles(r).map(\.value), ["20 / 23", "259.5", "20 days", "Never"])
        XCTAssertEqual(GoalFinishCopy.recordTiles(r)[1].note, "27 runs since Apr 24")
        XCTAssertEqual(GoalFinishCopy.celebrationTiles(r).map(\.label),
                       ["Showed up", "Longest streak", "Weeks hit", "Missed twice"])
        XCTAssertEqual(GoalFinishCopy.missedTwice(r).note, "1 miss, back next day")
        XCTAssertEqual(GoalFinishCopy.recordTiles(try Self.record(["runs": NSNull()]))[1].label, "Weeks hit")
        XCTAssertEqual(GoalFinishCopy.missedTwice(try Self.record(["missed_twice": 2, "miss_days": 5])).value, "2 times")
    }

    func testRecordLines() throws {
        let r = try Self.record()
        XCTAssertEqual(GoalRecordCopy.daysLine(r), "2 minimum days · 2 of 4 skips used · 1 missed day")
        let totals = GoalRecordCopy.totals(r)
        XCTAssertEqual(totals.map(\.label), ["Nightly stretch", "Outreach", "Foot today", "Milestones"])
        XCTAssertEqual(totals.map(\.value), ["20 days", "64", "16 better · 6 same · 1 worse", "2 of 2 on time"])
        XCTAssertEqual(GoalRecordCopy.yearLine(try XCTUnwrap(r.runs)), "27 runs · 41 h 42 m since Apr 24 · PRs Aug 22, Oct 10")
    }

    func testFinishedLogNamesAndGroups() throws {
        func goal(_ slug: String, _ finished: String, identity: String = "", shown: Int = 10) throws -> GoalFinishedSummary {
            let row: [String: Any] = ["slug": slug, "title": "T \(slug)", "identity": identity, "finished": finished,
                                      "shown": shown, "milestones": 2, "milestones_on_time": 1]
            return try PrepDecoding.decode(GoalFinishedSummary.self, from: JSONSerialization.data(withJSONObject: row))
        }
        let goals = [try goal("b", "2027-02-28", identity: "an Applied AI Engineer"),
                     try goal("a", "2026-11-01", identity: "a New York City Marathon finisher"),
                     try goal("c", "2026-06-01")]
        XCTAssertEqual(GoalsFinishedCopy.name(goals[0]), "Applied AI Engineer")
        XCTAssertEqual(GoalsFinishedCopy.name(goals[1]), "New York City Marathon finisher")
        XCTAssertEqual(GoalsFinishedCopy.name(goals[2]), "T c")
        XCTAssertEqual(GoalsFinishedCopy.byYear(goals).map(\.year), ["2027", "2026"])
        XCTAssertEqual(GoalsFinishedCopy.byYear(goals)[1].goals.map(\.slug), ["a", "c"])
        XCTAssertEqual(GoalsFinishedCopy.lifetime(goals).map(\.value), ["3", "30", "3 / 6"])
    }

    // MARK: Flows

    func testFinishPromptShowsWhenDueAndHidesOnNotYet() async throws {
        let client = FinishClient()
        client.details = [.success(try detail(finishDue: true))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        XCTAssertTrue(vm.asksToFinish)
        vm.finishDeferred = true
        XCTAssertFalse(vm.asksToFinish)

        let quiet = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        client.details = [.success(try detail(finishDue: false))]
        await quiet.load()
        XCTAssertFalse(quiet.asksToFinish)
    }

    func testFinishSendsTheServersDayAndKeepsTheRecord() async throws {
        let client = FinishClient()
        client.details = [.success(try detail(finishDue: true))]
        client.finishes = [.success(try Self.record())]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        await vm.finish()
        XCTAssertEqual(client.finishRequests, [GoalFinishRequest(slug: "nyc-marathon-2026", asOf: "2026-10-13")])
        XCTAssertEqual(vm.finished?.shown, 20)
        XCTAssertFalse(vm.asksToFinish)
        XCTAssertFalse(vm.isFinishing)
        await vm.finish()
        XCTAssertEqual(client.finishRequests.count, 1, "a finished goal never finishes twice")
    }

    func testFinishFailureSaysSoAndKeepsTheGoalOpen() async throws {
        let client = FinishClient()
        client.details = [.success(try detail(finishDue: true))]
        client.finishes = [.failure(URLError(.timedOut))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        await vm.finish()
        XCTAssertNil(vm.finished)
        XCTAssertTrue(vm.asksToFinish)
        XCTAssertEqual(vm.error, "Couldn't finish this goal. Try again.")
    }

    func testFinishOnAChangedDayReloads() async throws {
        let client = FinishClient()
        client.details = [.success(try detail(finishDue: true))]
        client.finishes = [.failure(APIError.http(statusCode: 409, body: "The day changed"))]
        let vm = GoalDetailViewModel(slug: "nyc-marathon-2026", client: client)
        await vm.load()
        await vm.finish()
        XCTAssertEqual(client.detailCalls, 2)
        XCTAssertEqual(vm.error, "The day changed. Try again.")
    }

    func testReflectionSavesAndFailureKeepsTheOld() async throws {
        let client = FinishClient()
        let vm = GoalRecordViewModel(slug: "nyc-marathon-2026", record: try Self.record(), client: client)
        client.reflections = [.success(try Self.record(["reflection": "Stretching mattered."]))]
        let saved = await vm.saveReflection("Stretching mattered.")
        XCTAssertTrue(saved)
        XCTAssertEqual(vm.reflection, "Stretching mattered.")
        XCTAssertEqual(client.reflectionRequests, [GoalReflectionRequest(slug: "nyc-marathon-2026", text: "Stretching mattered.")])
        client.reflections = [.failure(URLError(.notConnectedToInternet))]
        let failed = await vm.saveReflection("Changed my mind")
        XCTAssertFalse(failed)
        XCTAssertEqual(vm.reflection, "Stretching mattered.")
        XCTAssertEqual(vm.error, "Couldn't save your reflection. Try again.")
    }

    func testRecordLoadsBySlugAnd404IsUnavailable() async throws {
        let client = FinishClient()
        client.records = [.failure(APIError.http(statusCode: 404, body: "not found"))]
        let vm = GoalRecordViewModel(slug: "gone", client: client)
        await vm.load()
        guard case .unavailable = vm.state else { return XCTFail("expected unavailable, got \(vm.state)") }
        client.records = [.success(try Self.record())]
        await vm.load()
        XCTAssertEqual(vm.subtitle, "Achieved Nov 1")
    }
}

private final class FinishClient: GoalsDataClient, @unchecked Sendable {
    var details: [Result<GoalDetail, Error>] = []
    var finishes: [Result<GoalRecord, Error>] = []
    var records: [Result<GoalRecord, Error>] = []
    var reflections: [Result<GoalRecord, Error>] = []
    private(set) var detailCalls = 0
    private(set) var finishRequests: [GoalFinishRequest] = []
    private(set) var reflectionRequests: [GoalReflectionRequest] = []

    private func next<T>(_ queue: inout [Result<T, Error>]) throws -> T {
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        return try (queue.count > 1 ? queue.removeFirst() : queue[0]).get()
    }

    func home() async throws -> GoalsHome { throw URLError(.unsupportedURL) }
    func detail(slug: String) async throws -> GoalDetail {
        detailCalls += 1
        return try next(&details)
    }
    func checkIn(_ r: GoalCheckInRequest, clientID: String) async throws -> GoalCheckInResult { throw URLError(.unsupportedURL) }
    func confirmWeek(_ r: GoalWeekRequest) async throws -> GoalCheckInResult { throw URLError(.unsupportedURL) }
    func finish(_ r: GoalFinishRequest) async throws -> GoalRecord {
        finishRequests.append(r)
        return try next(&finishes)
    }
    func record(slug: String) async throws -> GoalRecord { try next(&records) }
    func saveReflection(_ r: GoalReflectionRequest) async throws -> GoalRecord {
        reflectionRequests.append(r)
        return try next(&reflections)
    }
}
