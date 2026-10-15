import XCTest
import Foundation
@testable import HermesMobile

/// Answers `confirmWeek` from a queue and records each request; the rest of the API is unused.
private final class FakeWeekGoalsClient: GoalsDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _weeks: [GoalWeekRequest] = []
    var weekResults: [Result<GoalCheckInResult, Error>] = []
    /// What a reload after a 409 reads; empty throws.
    var homeResults: [Result<GoalsHome, Error>] = []

    var weeks: [GoalWeekRequest] { lock.withLock { _weeks } }

    func home() async throws -> GoalsHome {
        let next: Result<GoalsHome, Error>? = lock.withLock { homeResults.isEmpty ? nil : homeResults.removeFirst() }
        guard let next else { throw URLError(.badServerResponse) }
        return try next.get()
    }
    func detail(slug: String) async throws -> GoalDetail { throw URLError(.unsupportedURL) }
    func checkIn(_ r: GoalCheckInRequest) async throws -> GoalCheckInResult { throw URLError(.unsupportedURL) }

    func confirmWeek(_ r: GoalWeekRequest) async throws -> GoalCheckInResult {
        let next: Result<GoalCheckInResult, Error>? = lock.withLock {
            _weeks.append(r)
            return weekResults.isEmpty ? nil : weekResults.removeFirst()
        }
        guard let next else { throw URLError(.badServerResponse) }
        return try next.get()
    }
}

/// A Sunday deck's Week ahead card for `career`: Outreach raised 5 → 6, Prep counted by its
/// source, Applications new, and Mock interview proposed for dropping.
private func weekCard() throws -> DeckCard {
    let deck = try DailyDeck.decode(#"""
    {"date": "2026-10-18", "kind": "weekly", "cards": [
      {"id": "week-career", "type": "week_ahead", "goal": "career", "title": "Next week · Land an AI role",
       "color": "wiki", "start": "2026-10-19", "fallback": "Next week: Outreach 6",
       "commitments": [
         {"id": "outreach", "action": "Outreach", "target": 6, "skips": 0, "unit": "item", "was": 5,
          "reason": "You hit 5 two weeks running.", "future": {"x": 1}},
         {"id": "prep", "action": "Prep session", "target": 5, "skips": 1, "unit": "day", "source": "prep.days",
          "cue": "After coffee", "minimum": "One card", "days": ["mon", "tue"]},
         {"id": "apps", "action": "Applications", "target": 3, "skips": 0, "unit": "item"},
         {"id": "mock", "action": "Mock interview", "target": 1, "skips": 0, "unit": "day", "drop": true,
          "reason": "Prep covers it now."}],
       "last_week": [
         {"id": "outreach", "action": "Outreach", "target": 5, "skips": 0, "unit": "item"},
         {"id": "prep", "action": "Prep session", "target": 1, "skips": 1, "unit": "day", "source": "prep.days"}]}
    ]}
    """#)
    return try XCTUnwrap(deck.cards.first)
}

private func confirmed(starts: [String]) throws -> GoalCheckInResult {
    let body: [String: Any] = ["goal": ["slug": "career", "title": "Land an AI role", "confirmed_starts": starts],
                               "streak": ["days": 1], "today": "2026-10-18", "yesterday": "2026-10-17"]
    return try PrepDecoding.decode(GoalCheckInResult.self, from: JSONSerialization.data(withJSONObject: body))
}

/// The goals home on `today`, with `career`'s pending deck and confirmed weeks.
private func goalsHome(today: String, weekPending: String? = nil, confirmed: [String] = []) throws -> GoalsHome {
    var goal: [String: Any] = ["slug": "career", "title": "Land an AI role", "confirmed_starts": confirmed]
    if let weekPending { goal["week_pending"] = weekPending }
    let body: [String: Any] = ["today": today, "yesterday": "2026-10-17", "goals": [goal]]
    return try PrepDecoding.decode(GoalsHome.self, from: JSONSerialization.data(withJSONObject: body))
}

/// The request as the server receives it: `APIClient` encodes with snake_case keys.
private func sentJSON(_ request: GoalWeekRequest) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
}

@MainActor
final class WeekAheadViewModelTests: XCTestCase {
    private func model(_ client: FakeWeekGoalsClient) throws -> WeekAheadViewModel {
        WeekAheadViewModel(card: try weekCard(), client: client, today: "2026-10-18")
    }

    func testKeepSendsEditedNonRemovedRowsWithoutReason() async throws {
        let client = FakeWeekGoalsClient()
        client.weekResults = [.success(try confirmed(starts: ["2026-10-19"]))]
        let vm = try model(client)
        vm.rows[1].target = 4
        vm.rows[2].removed = true

        await vm.keep()

        XCTAssertEqual(vm.phase, .confirmed)
        let json = try sentJSON(try XCTUnwrap(client.weeks.first))
        XCTAssertEqual(json["slug"] as? String, "career")
        XCTAssertEqual(json["start"] as? String, "2026-10-19")
        XCTAssertEqual(json["as_of"] as? String, "2026-10-18")
        let rows = try XCTUnwrap(json["commitments"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["outreach", "prep"])
        XCTAssertEqual(rows.map { $0["target"] as? Int }, [6, 4])
        for row in rows {
            XCTAssertNil(row["was"])
            XCTAssertNil(row["reason"])
            XCTAssertNil(row["drop"])
        }
        XCTAssertEqual(rows[1]["source"] as? String, "prep.days")
        XCTAssertEqual(rows[1]["cue"] as? String, "After coffee")
        XCTAssertEqual(rows[1]["minimum"] as? String, "One card")
        XCTAssertEqual(rows[1]["days"] as? [String], ["mon", "tue"])
        XCTAssertNil(rows[0]["source"], "an absent optional stays out of the body")
    }

    func testDroppedRowStartsRemovedAndIsLeftOutOfKeep() async throws {
        let client = FakeWeekGoalsClient()
        client.weekResults = [.success(try confirmed(starts: ["2026-10-19"]))]
        let vm = try model(client)
        XCTAssertEqual(vm.rows.map(\.removed), [false, false, false, true])
        XCTAssertEqual(vm.rows[3].commitment.reason, "Prep covers it now.")

        await vm.keep()

        let rows = try XCTUnwrap(try sentJSON(try XCTUnwrap(client.weeks.first))["commitments"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["outreach", "prep", "apps"])
    }

    func testEaseOffDropsEachTargetByOneFloorOne() async throws {
        let client = FakeWeekGoalsClient()
        client.weekResults = [.success(try confirmed(starts: ["2026-10-19"]))]
        let vm = try model(client)
        vm.rows[0].target = 9  // edits to the proposal don't matter: ease off starts from last week

        await vm.easeOff()

        let request = try XCTUnwrap(client.weeks.first)
        XCTAssertEqual(request.commitments.map(\.id), ["outreach", "prep"])
        XCTAssertEqual(request.commitments.map(\.target), [4, 1])
        XCTAssertEqual(request.commitments[1].source, "prep.days")
        XCTAssertEqual(vm.phase, .confirmed)
    }

    func testConflictShowsCarriedForwardCopy() async throws {
        let client = FakeWeekGoalsClient()
        client.weekResults = [.failure(APIError.http(statusCode: 409, body: #"{"error": "The day changed"}"#))]
        client.homeResults = [.success(try goalsHome(today: "2026-10-18"))]  // the day didn't move
        let vm = try model(client)

        await vm.keep()

        XCTAssertEqual(vm.phase, .failed("This week has started; the plan carried forward."))
        XCTAssertFalse(vm.canEdit)
    }

    func testConflictFromAStaleDayReloadsAndKeepsEditing() async throws {
        // Opened Sunday night, kept on Monday: the 409 is only the day moving on, and this
        // week's plan is still waiting, so the card takes the new today and stays editable.
        let client = FakeWeekGoalsClient()
        client.weekResults = [.failure(APIError.http(statusCode: 409, body: #"{"error": "The day changed"}"#)),
                              .success(try confirmed(starts: ["2026-10-19"]))]
        client.homeResults = [.success(try goalsHome(today: "2026-10-19", weekPending: "2026-10-18"))]
        let vm = try model(client)
        vm.rows[0].target = 7

        await vm.keep()

        XCTAssertEqual(vm.phase, .editing)
        XCTAssertTrue(vm.canEdit)
        XCTAssertEqual(vm.today, "2026-10-19")
        XCTAssertEqual(vm.rows[0].target, 7)

        await vm.keep()

        XCTAssertEqual(vm.phase, .confirmed)
        XCTAssertEqual(client.weeks.map(\.asOf), ["2026-10-18", "2026-10-19"])
    }

    func testConflictWhoseReloadFailsStaysRetryable() async throws {
        let client = FakeWeekGoalsClient()
        client.weekResults = [.failure(APIError.http(statusCode: 409, body: ""))]
        let vm = try model(client)

        await vm.keep()

        XCTAssertEqual(vm.phase, .failed("Couldn't save. Try again."))
        XCTAssertTrue(vm.canEdit)
    }

    func testSyncTakesTheHomesToday() throws {
        let vm = try model(FakeWeekGoalsClient())
        vm.sync(try goalsHome(today: "2026-10-19", weekPending: "2026-10-18"))
        XCTAssertEqual(vm.today, "2026-10-19")
        XCTAssertEqual(vm.phase, .editing)
        vm.sync(try goalsHome(today: "2026-10-19", confirmed: ["2026-10-19"]))
        XCTAssertEqual(vm.phase, .confirmed)
    }

    func testFailureKeepsEdits() async throws {
        let client = FakeWeekGoalsClient()
        client.weekResults = [.failure(URLError(.notConnectedToInternet)), .success(try confirmed(starts: ["2026-10-19"]))]
        let vm = try model(client)
        vm.rows[0].target = 7
        vm.rows[2].removed = true

        await vm.keep()

        XCTAssertEqual(vm.phase, .failed("Couldn't save. Try again."))
        XCTAssertTrue(vm.canEdit)
        XCTAssertEqual(vm.rows[0].target, 7)
        XCTAssertTrue(vm.rows[2].removed)

        await vm.keep()
        XCTAssertEqual(vm.phase, .confirmed)
        XCTAssertEqual(client.weeks.count, 2)
        XCTAssertEqual(client.weeks[1].commitments.map(\.target), [7, 5])
    }

    func testConfirmedWhenStartAlreadyConfirmed() throws {
        let vm = try model(FakeWeekGoalsClient())
        func home(_ starts: [String]) throws -> GoalsHome {
            let body: [String: Any] = ["today": "2026-10-20", "yesterday": "2026-10-19",
                                       "goals": [["slug": "career", "confirmed_starts": starts], ["slug": "other", "confirmed_starts": ["2026-10-19"]]]]
            return try PrepDecoding.decode(GoalsHome.self, from: JSONSerialization.data(withJSONObject: body))
        }

        vm.markConfirmedIfKnown(try home(["2026-10-12"]))
        XCTAssertEqual(vm.phase, .editing)

        vm.markConfirmedIfKnown(try home(["2026-10-19", "2026-10-12"]))
        XCTAssertEqual(vm.phase, .confirmed)
        XCTAssertFalse(vm.canEdit)
    }

    func testChatDraftListsTheProposalAndTheCommand() throws {
        let draft = WeekAheadViewModel.chatDraft(card: try weekCard(), goalTitle: "Land an AI role")
        XCTAssertTrue(draft.hasPrefix("Help me adjust next week's plan for Land an AI role (week of 2026-10-19). Atlas proposed:\n- Outreach 6"))
        XCTAssertTrue(draft.contains("- Mock interview: drop"))
        XCTAssertTrue(draft.hasSuffix("Use `tools/.venv/bin/python tools/goals.py confirm-week`."))
    }
}
