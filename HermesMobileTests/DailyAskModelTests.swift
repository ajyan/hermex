import XCTest
import Foundation
import SwiftUI
@testable import HermesMobile

/// A scripted Daily Ask API: queued GET and POST results, the requests it saw, and an optional
/// gate that holds a POST until released.
private final class FakeDailyAskClient: DailyAskDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _requests: [DailyAskRequest] = []

    var askResults: [Result<DailyAsk, Error>] = []
    var actResults: [Result<DailyAsk, Error>] = []
    var gate: (started: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?

    var log: [String] { lock.withLock { _log } }
    var requests: [DailyAskRequest] { lock.withLock { _requests } }

    private func next(_ name: String, _ queue: inout [Result<DailyAsk, Error>]) throws -> DailyAsk {
        lock.lock(); defer { lock.unlock() }
        _log.append(name)
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        return try (queue.count > 1 ? queue.removeFirst() : queue[0]).get()
    }

    func ask() async throws -> DailyAsk { try next("ask", &askResults) }

    func act(_ r: DailyAskRequest) async throws -> DailyAsk {
        lock.withLock { _requests.append(r) }
        if let gate {
            gate.started.yield()
            for await _ in gate.release { break }
        }
        return try next("act", &actResults)
    }
}

@MainActor
final class DailyAskModelTests: XCTestCase {
    static let fullJSON = """
    {"today": "2026-10-19", "weekday": true, "lead": "apply", "previous": "missed", "locked": true,
     "outcome": null,
     "week": {"applications": {"done": 1, "target": 2}, "outreach": {"done": 0, "target": 5}},
     "roles": [
      {"id": "ashby:harvey:1", "company": "Harvey", "title": "Senior Software Engineer, Agents",
       "location": "New York, NY", "url": "https://jobs.ashbyhq.com/harvey/1", "band_label": "$200K–$270K base",
       "note": "I build agent evals.", "search_url": "https://www.linkedin.com/search/results/people/?keywords=Harvey%20Applied%20AI",
       "opener": "Hi <name> — I saw Harvey is hiring."},
      {"id": "ashby:ramp:2", "company": "Ramp", "title": "Applied AI Engineer", "band_label": "band unknown", "future_field": 1},
      {"id": "greenhouse:anthropic:3", "company": "Anthropic", "title": "Applied AI Engineer, Enterprise Tech"}
     ]}
    """

    static func ask(_ json: String = fullJSON, _ edit: (inout [String: Any]) -> Void = { _ in }) throws -> DailyAsk {
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        edit(&object)
        return try PrepDecoding.decode(DailyAsk.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func loaded(_ client: FakeDailyAskClient) async -> DailyAskModel {
        let model = DailyAskModel(client: client)
        await model.load()
        return model
    }

    func testDecodesFullAndSparsePayloads() throws {
        let full = try Self.ask()
        XCTAssertEqual(full.roles?.count, 3)
        XCTAssertEqual(full.roles?.first?.bandLabel, "$200K–$270K base")
        XCTAssertEqual(full.roles?.first?.searchUrl, "https://www.linkedin.com/search/results/people/?keywords=Harvey%20Applied%20AI")
        XCTAssertEqual(full.week?.applications?.done, 1)
        XCTAssertTrue(full.needsNeverMissTwice)
        XCTAssertFalse(full.isReachFirst)
        let sparse = try PrepDecoding.decode(DailyAsk.self, from: Data(#"{"today":"2026-10-19"}"#.utf8))
        XCTAssertNil(sparse.roles)
        XCTAssertFalse(sparse.needsNeverMissTwice)
    }

    func testOneBadRoleIsDroppedNotTheWholeAsk() throws {
        let ask = try Self.ask {
            var roles = $0["roles"] as! [[String: Any]]
            roles[1].removeValue(forKey: "company")
            $0["roles"] = roles
        }
        XCTAssertEqual(ask.roles?.map(\.id), ["ashby:harvey:1", "greenhouse:anthropic:3"])
        XCTAssertEqual(ask.locked, true, "a bad role must not fail the decode and open Prep")
    }

    func testCountsTolerateMissingFields() throws {
        let ask = try Self.ask { $0["week"] = ["applications": ["done": 1], "outreach": ["target": 5]] }
        XCTAssertEqual(ask.week?.applications?.done, 1)
        XCTAssertNil(ask.week?.applications?.target)
        XCTAssertNil(DailyAskBody.weekLine(ask), "half a count is no line")
    }

    func testLockedOnlyWhenLoadedAndLocked() async throws {
        let client = FakeDailyAskClient()
        client.askResults = [.success(try Self.ask())]
        let model = await loaded(client)
        XCTAssertTrue(model.isLocked)
        client.askResults = [.success(try Self.ask { $0["locked"] = false })]
        await model.load()
        XCTAssertFalse(model.isLocked)
        client.askResults = [.success(try Self.ask { $0.removeValue(forKey: "locked") })]
        await model.load()
        XCTAssertFalse(model.isLocked)
    }

    func testUnavailableAndFailedAreUnlocked() async throws {
        XCTAssertFalse(DailyAskModel(client: FakeDailyAskClient()).isLocked, "loading is unlocked")
        let missing = FakeDailyAskClient()
        missing.askResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let unavailable = await loaded(missing)
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertFalse(unavailable.isLocked)
        let down = FakeDailyAskClient()
        down.askResults = [.failure(URLError(.notConnectedToInternet))]
        let failed = await loaded(down)
        if case .failed = failed.state {} else { XCTFail("expected .failed, got \(failed.state)") }
        XCTAssertFalse(failed.isLocked)
    }

    func testActSendsBodyAndSwapsState() async throws {
        let client = FakeDailyAskClient()
        client.askResults = [.success(try Self.ask())]
        client.actResults = [.success(try Self.ask {
            $0["locked"] = false
            $0["outcome"] = ["event": "applied", "role": "ashby:harvey:1", "company": "Harvey"]
        })]
        let model = await loaded(client)
        await model.act(.applied(role: "ashby:harvey:1"))
        XCTAssertEqual(client.requests, [DailyAskRequest(asOf: "2026-10-19", action: "applied", role: "ashby:harvey:1",
                                                          reason: nil, name: nil, rule: nil)])
        XCTAssertFalse(model.isLocked)
        if case .loaded(let ask) = model.state { XCTAssertEqual(ask.outcome?.company, "Harvey") } else { XCTFail() }
    }

    func testActBodies() async throws {
        let client = FakeDailyAskClient()
        client.askResults = [.success(try Self.ask())]
        client.actResults = [.success(try Self.ask())]
        let model = await loaded(client)
        await model.act(.sent(role: "r", name: "Jane"))
        await model.act(.pass(role: "r", reason: "Not agents", rule: "title"))
        await model.act(.skip(reason: "sick"))
        XCTAssertEqual(client.requests.map(\.action), ["sent", "pass", "skip"])
        XCTAssertEqual(client.requests[0].name, "Jane")
        XCTAssertEqual(client.requests[1].rule, "title")
        XCTAssertEqual(client.requests[1].reason, "Not agents")
        XCTAssertEqual(client.requests[2].reason, "sick")
        XCTAssertNil(client.requests[2].role)
    }

    func testRequestEncodesSnakeCaseAndDropsNils() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase  // as APIClient encodes bodies
        let data = try encoder.encode(DailyAskRequest(asOf: "2026-10-19", action: "skip", role: nil, reason: "sick", name: nil, rule: nil))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: String]
        XCTAssertEqual(object, ["as_of": "2026-10-19", "action": "skip", "reason": "sick"])
    }

    func testActConflictReloads() async throws {
        let client = FakeDailyAskClient()
        client.askResults = [.success(try Self.ask()), .success(try Self.ask { $0["today"] = "2026-10-20" })]
        client.actResults = [.failure(APIError.http(statusCode: 409, body: nil))]
        let model = await loaded(client)
        await model.act(.skip(reason: "sick"))
        XCTAssertEqual(client.log, ["ask", "act", "ask"])
        if case .loaded(let ask) = model.state { XCTAssertEqual(ask.today, "2026-10-20") } else { XCTFail() }
        XCTAssertEqual(model.error, "The day changed. Nothing was saved; this is today's Ask.")
    }

    func testActFailureKeepsStateAndShowsError() async throws {
        let client = FakeDailyAskClient()
        client.askResults = [.success(try Self.ask())]
        client.actResults = [.failure(URLError(.timedOut))]
        let model = await loaded(client)
        await model.act(.applied(role: "ashby:harvey:1"))
        XCTAssertTrue(model.isLocked)
        XCTAssertEqual(model.error, "Couldn't save. Try again.")
        XCTAssertFalse(model.pending)
    }

    /// The Pass sheet closes only on `true`, so a failed save keeps the typed reason.
    func testActReportsWhetherItSaved() async throws {
        let client = FakeDailyAskClient()
        client.askResults = [.success(try Self.ask())]
        client.actResults = [.failure(URLError(.timedOut))]
        let model = await loaded(client)
        let failed = await model.act(.pass(role: "ashby:harvey:1", reason: "Not agents", rule: "title"))
        XCTAssertFalse(failed)
        client.actResults = [.failure(APIError.http(statusCode: 409, body: nil))]
        let conflicted = await model.act(.pass(role: "ashby:harvey:1", reason: "Not agents", rule: "title"))
        XCTAssertFalse(conflicted)
        client.actResults = [.success(try Self.ask())]
        let saved = await model.act(.pass(role: "ashby:harvey:1", reason: "Not agents", rule: "title"))
        XCTAssertTrue(saved)
    }

    func testPendingBlocksDoubleTap() async throws {
        let client = FakeDailyAskClient()
        let (started, startedCont) = AsyncStream<Void>.makeStream()
        let (release, releaseCont) = AsyncStream<Void>.makeStream()
        client.gate = (startedCont, release)
        client.askResults = [.success(try Self.ask())]
        client.actResults = [.success(try Self.ask { $0["locked"] = false })]
        let model = await loaded(client)
        let first = Task { await model.act(.applied(role: "ashby:harvey:1")) }
        for await _ in started { break }
        await model.act(.applied(role: "ashby:harvey:1"))
        releaseCont.yield()
        await first.value
        XCTAssertEqual(client.requests.count, 1)
    }

    func testIsLiveOnlyForServerToday() async throws {
        let client = FakeDailyAskClient()
        client.askResults = [.success(try Self.ask())]
        let model = await loaded(client)
        XCTAssertTrue(model.isLive(for: "2026-10-19"))
        XCTAssertFalse(model.isLive(for: "2026-10-18"))
    }

    func testDoneLineCopy() {
        XCTAssertEqual(DailyAskBody.doneLine(DailyAskOutcome(event: "applied", role: "r", company: "Harvey", title: "T",
                                                             reason: nil, name: nil)),
                       "Applied to Harvey — Prep is open")
        XCTAssertEqual(DailyAskBody.doneLine(DailyAskOutcome(event: "sent", role: "r", company: "Ramp", title: "T",
                                                             reason: nil, name: "Jane")),
                       "Reached out to Jane at Ramp — Prep is open")
        XCTAssertEqual(DailyAskBody.doneLine(DailyAskOutcome(event: "skip", role: nil, company: nil, title: nil,
                                                             reason: "sick", name: nil)),
                       "Skipped: sick")
    }

    func testNeverMissTwiceLine() throws {
        XCTAssertEqual(DailyAskBody.neverMissTwiceLine(try Self.ask()), "Yesterday's Ask was missed — never miss twice.")
        XCTAssertEqual(DailyAskBody.neverMissTwiceLine(try Self.ask { $0["previous"] = "skipped" }),
                       "Yesterday's Ask was skipped — never miss twice.")
        XCTAssertNil(DailyAskBody.neverMissTwiceLine(try Self.ask { $0["previous"] = "done" }))
    }

    func testWeekLine() throws {
        XCTAssertEqual(DailyAskBody.weekLine(try Self.ask()), "Applications 1/2 · Outreach 0/5")
        XCTAssertNil(DailyAskBody.weekLine(try Self.ask { $0.removeValue(forKey: "week") }))
    }

    func testGateFollowsModel() async throws {
        let client = FakeDailyAskClient()
        client.askResults = [.success(try Self.ask())]
        client.actResults = [.success(try Self.ask { $0["locked"] = false })]
        let model = await loaded(client)
        XCTAssertTrue(PrepGate<EmptyView>.shouldGate(model))
        await model.act(.skip(reason: "sick"))
        XCTAssertFalse(PrepGate<EmptyView>.shouldGate(model))
        let missing = FakeDailyAskClient()
        missing.askResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let unavailable = await loaded(missing)
        XCTAssertFalse(PrepGate<EmptyView>.shouldGate(unavailable))
    }

    func testGateSpinsOnlyOnFirstLoad() async throws {
        let client = FakeDailyAskClient()
        let model = DailyAskModel(client: client)
        XCTAssertTrue(PrepGate<EmptyView>.showsSpinner(model))
        client.askResults = [.success(try Self.ask { $0["locked"] = false })]
        await model.load()
        XCTAssertFalse(PrepGate<EmptyView>.showsSpinner(model))
        client.askResults = [.failure(URLError(.timedOut))]
        await model.load()  // a later push's refresh fails: Prep stays open, no spinner
        XCTAssertFalse(PrepGate<EmptyView>.showsSpinner(model))
        XCTAssertFalse(PrepGate<EmptyView>.shouldGate(model))
    }
}
