import XCTest
import Foundation
@testable import HermesMobile

/// A scripted Goals API for the Check In a Goal intent: queued homes and check-in answers.
private final class IntentGoalsClient: GoalsDataClient, @unchecked Sendable {
    var homeResults: [Result<GoalsHome, Error>] = []
    var checkInResults: [Result<GoalCheckInResult, Error>] = []
    private(set) var checkIns: [GoalCheckInRequest] = []
    private(set) var homeReads = 0

    func home() async throws -> GoalsHome {
        homeReads += 1
        return try homeResults.removeFirst().get()
    }
    func checkIn(_ r: GoalCheckInRequest, clientID: String) async throws -> GoalCheckInResult {
        checkIns.append(r)
        return try checkInResults.removeFirst().get()
    }
    func detail(slug: String) async throws -> GoalDetail { throw URLError(.unsupportedURL) }
    func confirmWeek(_ r: GoalWeekRequest) async throws -> GoalCheckInResult { throw URLError(.unsupportedURL) }
    func finish(_ r: GoalFinishRequest) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func record(slug: String) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
    func reopen(slug: String) async throws -> GoalDetail { throw URLError(.unsupportedURL) }
    func saveReflection(_ r: GoalReflectionRequest) async throws -> GoalRecord { throw URLError(.unsupportedURL) }
}

@MainActor
final class GoalCheckInIntentTests: XCTestCase {
    private let server = URL(string: "https://a.example")!

    /// The sample home (today Oct 10) with an Outreach item row added.
    private func home(today: String = "2026-10-10") throws -> GoalsHome {
        var json = try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.homeSample.utf8)) as! [String: Any]
        json["today"] = today
        var goal = (json["goals"] as! [[String: Any]])[0]
        var week = goal["week"] as! [String: Any]
        var rows = week["commitments"] as! [[String: Any]]
        rows.append(["id": "outreach", "action": "Outreach", "target": 5, "unit": "item", "done": 1])
        week["commitments"] = rows
        goal["week"] = week
        json["goals"] = [goal]
        return try PrepDecoding.decode(GoalsHome.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func result(stretchDone: Int) throws -> GoalCheckInResult {
        var goal = (try JSONSerialization.jsonObject(with: Data(GoalsModelsTests.homeSample.utf8)) as! [String: Any])["goals"]
            as! [[String: Any]]
        var week = goal[0]["week"] as! [String: Any]
        var rows = week["commitments"] as! [[String: Any]]
        rows[0]["done"] = stretchDone
        rows[0]["today"] = "done"
        week["commitments"] = rows
        goal[0]["week"] = week
        let body: [String: Any] = ["goal": goal[0], "streak": ["days": 7, "at_risk": false],
                                   "today": "2026-10-10", "yesterday": "2026-10-09"]
        return try PrepDecoding.decode(GoalCheckInResult.self, from: JSONSerialization.data(withJSONObject: body))
    }

    private func checkIn(_ id: String, _ status: GoalStatus = .done, client: IntentGoalsClient, server: URL?,
                         saved: @escaping (URL, GoalsHome) -> Void = { _, _ in }) async throws -> String {
        try await GoalIntentCheckIns.checkIn(id: id, status: status, server: server, client: { _ in client }, onSaved: saved)
    }

    func testEntitiesNameEachCommitmentUnderItsGoal() throws {
        let entities = GoalIntentCheckIns.entities(try home())
        XCTAssertEqual(entities.map(\.id), ["nyc-marathon-2026/stretch-pm", "nyc-marathon-2026/long-run",
                                            "nyc-marathon-2026/outreach"])
        XCTAssertEqual(entities.map(\.name), ["Stretch", "Run", "Outreach"])
        XCTAssertEqual(entities.first?.goal, "Finish the NYC Marathon, uninjured")
    }

    func testQueryIsEmptyWithoutAServerOrGoals() async throws {
        let none = await GoalIntentCheckIns.entities(server: nil, client: { _ in IntentGoalsClient() })
        XCTAssertEqual(none.map(\.id), [])
        let client = IntentGoalsClient()
        client.homeResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let noGoals = await GoalIntentCheckIns.entities(server: server, client: { _ in client })
        XCTAssertEqual(noGoals.map(\.id), [])
    }

    func testChecksInForTheServersTodayAndHandsTheHomeToTheWidget() async throws {
        let client = IntentGoalsClient()
        client.homeResults = [.success(try home())]
        client.checkInResults = [.success(try result(stretchDone: 2))]
        var saved: [(URL, GoalsHome)] = []
        let line = try await checkIn("nyc-marathon-2026/stretch-pm", .min, client: client, server: server) { saved.append(($0, $1)) }
        XCTAssertEqual(line, "Stretch: 2-minute version logged for today.")
        XCTAssertEqual(client.checkIns, [
            .commitment(slug: "nyc-marathon-2026", date: "2026-10-10", asOf: "2026-10-10", id: "stretch-pm", status: .min),
        ])
        XCTAssertEqual(saved.first?.0, server)
        XCTAssertEqual(saved.first?.1.goals.first?.week.commitments.first?.done, 2)
        XCTAssertEqual(saved.first?.1.streak.days, 7)
    }

    func testAnItemCountsOneMore() async throws {
        let client = IntentGoalsClient()
        client.homeResults = [.success(try home())]
        client.checkInResults = [.success(try result(stretchDone: 0))]
        let line = try await checkIn("nyc-marathon-2026/outreach", .skip, client: client, server: server)
        XCTAssertEqual(line, "One more outreach counted for today.")
        XCTAssertEqual(client.checkIns, [
            .item(slug: "nyc-marathon-2026", date: "2026-10-10", asOf: "2026-10-10", id: "outreach", n: 1, note: nil),
        ])
    }

    func testADayThatTurnedIsReadAgainAndTriedOnce() async throws {
        let client = IntentGoalsClient()
        client.homeResults = [.success(try home()), .success(try home(today: "2026-10-11"))]
        client.checkInResults = [.failure(APIError.http(statusCode: 409, body: nil)), .success(try result(stretchDone: 1))]
        let line = try await checkIn("nyc-marathon-2026/stretch-pm", client: client, server: server)
        XCTAssertEqual(line, "Stretch checked in for today.")
        XCTAssertEqual(client.checkIns.last,
                       .commitment(slug: "nyc-marathon-2026", date: "2026-10-11", asOf: "2026-10-11", id: "stretch-pm", status: .done))
    }

    func testFailuresSayWhy() async throws {
        let client = IntentGoalsClient()
        do {
            _ = try await checkIn("nyc-marathon-2026/stretch-pm", client: client, server: nil)
            XCTFail("checked in without a server")
        } catch { XCTAssertEqual(error as? GoalIntentError, .noServer) }

        client.homeResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        do {
            _ = try await checkIn("nyc-marathon-2026/stretch-pm", client: client, server: server)
            XCTFail("checked in on a server without Goals")
        } catch { XCTAssertEqual(error as? GoalIntentError, .noGoals) }

        client.homeResults = [.success(try home())]
        do {
            _ = try await checkIn("nyc-marathon-2026/gone", client: client, server: server)
            XCTFail("checked in a commitment that's gone")
        } catch { XCTAssertEqual(error as? GoalIntentError, .notFound) }

        var saved = 0
        client.homeResults = [.success(try home())]
        client.checkInResults = [.failure(URLError(.timedOut))]
        do {
            _ = try await checkIn("nyc-marathon-2026/stretch-pm", client: client, server: server) { _, _ in saved += 1 }
            XCTFail("a failed post said it saved")
        } catch { XCTAssertEqual(error as? GoalIntentError, .notSaved) }
        XCTAssertEqual(saved, 0, "nothing reaches the widget")
    }
}
