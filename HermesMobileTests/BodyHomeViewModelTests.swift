import XCTest
@testable import HermesMobile

private final class FakeBodyClient: BodyDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []

    var homeResults: [Result<BodyHome, Error>] = []
    /// Per-call gates for `home()`: call n waits on `homeGates[n]` when set, after signaling `homeStarted`.
    var homeGates: [Int: AsyncStream<Void>] = [:]
    var homeStarted: AsyncStream<Int>.Continuation?
    var decideResults: [Result<BodyProposal, Error>] = []

    var log: [String] { lock.withLock { _log } }

    func home() async throws -> BodyHome {
        let (call, result): (Int, Result<BodyHome, Error>) = lock.withLock {
            _log.append("home")
            let call = _log.filter { $0 == "home" }.count - 1
            guard !homeResults.isEmpty else { return (call, .failure(URLError(.badServerResponse))) }
            return (call, homeResults.count > 1 ? homeResults.removeFirst() : homeResults[0])
        }
        homeStarted?.yield(call)
        if let gate = homeGates[call] { for await _ in gate { break } }
        return try result.get()
    }

    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal {
        try lock.withLock {
            _log.append("decide:\(proposalID):\(accept ? "accept" : "skip")")
            guard !decideResults.isEmpty else { throw URLError(.badServerResponse) }
            return try decideResults.removeFirst().get()
        }
    }

    func prescription(day: String?) async throws -> BodyPrescription { throw URLError(.unsupportedURL) }
    func save(_ session: BodySession) async throws -> BodySession { throw URLError(.unsupportedURL) }
    func finish(id: String, check: BodyCheck) async throws -> BodyFinishResult { throw URLError(.unsupportedURL) }
    func session(id: String) async throws -> BodySession { throw URLError(.unsupportedURL) }
    func sessions(before: String?) async throws -> [BodySessionSummary] { throw URLError(.unsupportedURL) }
    func lift(id: String) async throws -> BodyLift { throw URLError(.unsupportedURL) }
    func plan() async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func sleepHistory() async throws -> SleepHistory? { throw URLError(.unsupportedURL) }
}

@MainActor
final class BodyHomeViewModelTests: XCTestCase {
    private func home(proposals: Int = 2) throws -> BodyHome {
        let base = try PrepDecoding.decode(BodyHome.self, from: BodyModelsTests.fixture("home.json"))
        return base.with(proposals: (1...max(proposals, 1)).prefix(proposals).map { proposal("p\($0)") })
    }

    private func proposal(_ id: String) -> BodyProposal {
        let json = #"{"id":"\#(id)","kind":"reset","lift":"strict-press","title":"Reset \#(id)","why":["a"],"rule":"r","status":"pending"}"#
        return try! PrepDecoding.decode(BodyProposal.self, from: Data(json.utf8))
    }

    private func loaded(_ vm: BodyHomeViewModel) -> BodyHome? {
        if case .loaded(let home) = vm.state { return home }
        return nil
    }

    func testLoadsHome() async throws {
        let client = FakeBodyClient()
        client.homeResults = [.success(try home())]
        let vm = BodyHomeViewModel(client: client)
        XCTAssertEqual(vm.state, .loading)
        await vm.load()
        let loaded = try XCTUnwrap(loaded(vm))
        XCTAssertEqual(loaded.phaseLabel, "Build · 6 weeks to January")
        XCTAssertEqual(loaded.next?.day, "push")
        XCTAssertEqual(loaded.proposals.map(\.id), ["p1", "p2"])
    }

    func testNotFoundIsUnavailable() async {
        let client = FakeBodyClient()
        client.homeResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let vm = BodyHomeViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    func testFirstLoadFailureShowsTheError() async {
        let client = FakeBodyClient()
        client.homeResults = [.failure(URLError(.notConnectedToInternet))]
        let vm = BodyHomeViewModel(client: client)
        await vm.load()
        guard case .failed = vm.state else { return XCTFail("expected failed, got \(vm.state)") }
    }

    func testRefreshFailureKeepsContent() async throws {
        let client = FakeBodyClient()
        let first = try home()
        client.homeResults = [.success(first), .failure(URLError(.timedOut))]
        let vm = BodyHomeViewModel(client: client)
        await vm.load()
        await vm.load()
        XCTAssertEqual(vm.state, .loaded(first))
    }

    func testRefreshNotFoundDropsContent() async throws {
        let client = FakeBodyClient()
        client.homeResults = [.success(try home()), .failure(APIError.http(statusCode: 404, body: nil))]
        let vm = BodyHomeViewModel(client: client)
        await vm.load()
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }

    func testDecideSkipRemovesProposalAndKeepsTheRest() async throws {
        let client = FakeBodyClient()
        client.homeResults = [.success(try home())]
        client.decideResults = [.success(proposal("p1"))]
        let vm = BodyHomeViewModel(client: client)
        await vm.load()
        await vm.decide(try XCTUnwrap(loaded(vm)?.proposals.first), accept: false)
        XCTAssertEqual(loaded(vm)?.proposals.map(\.id), ["p2"])
        XCTAssertEqual(client.log, ["home", "decide:p1:skip"])
        XCTAssertNil(vm.decideError)
    }

    func testAcceptReloadsHome() async throws {
        let client = FakeBodyClient()
        client.homeResults = [.success(try home()), .success(try home(proposals: 1))]
        client.decideResults = [.success(proposal("p1"))]
        let vm = BodyHomeViewModel(client: client)
        await vm.load()
        await vm.decide(try XCTUnwrap(loaded(vm)?.proposals.first), accept: true)
        XCTAssertEqual(client.log, ["home", "decide:p1:accept", "home"])
        XCTAssertEqual(loaded(vm)?.proposals.map(\.id), ["p1"])
    }

    func testStaleLoadDoesNotOverwriteNewerOne() async throws {
        let client = FakeBodyClient()
        let stale = try home()
        let fresh = BodyHome(
            phase: "build", phaseLabel: "Fresh", starts: nil, next: nil, week: stale.week, sleep: nil,
            lifts: [], sessions: [], proposals: [], gaps: [])
        client.homeResults = [.success(stale), .success(fresh)]
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (started, startedContinuation) = AsyncStream<Int>.makeStream()
        client.homeGates = [0: gate]
        client.homeStarted = startedContinuation
        let vm = BodyHomeViewModel(client: client)
        let slow = Task { await vm.load() }
        for await call in started where call == 0 { break }
        await vm.load()
        release.yield()
        await slow.value
        XCTAssertEqual(loaded(vm)?.phaseLabel, "Fresh")
    }

    func testCancelledDecideStillRollsBack() async throws {
        let client = FakeBodyClient()
        client.homeResults = [.success(try home())]
        client.decideResults = [.failure(CancellationError())]
        let vm = BodyHomeViewModel(client: client)
        await vm.load()
        await vm.decide(try XCTUnwrap(loaded(vm)?.proposals.first), accept: false)
        XCTAssertEqual(loaded(vm)?.proposals.map(\.id), ["p1", "p2"])
        XCTAssertNil(vm.decideError)
    }

    func testDecideRollsBackOnFailure() async throws {
        let client = FakeBodyClient()
        client.homeResults = [.success(try home(proposals: 3))]
        client.decideResults = [.failure(URLError(.notConnectedToInternet))]
        let vm = BodyHomeViewModel(client: client)
        await vm.load()
        await vm.decide(try XCTUnwrap(loaded(vm)?.proposals[1]), accept: true)
        XCTAssertEqual(loaded(vm)?.proposals.map(\.id), ["p1", "p2", "p3"])
        XCTAssertNotNil(vm.decideError)
        XCTAssertTrue(vm.deciding.isEmpty)
    }
}

final class BodyHomeCopyTests: XCTestCase {
    func testSleepTitleReadsHoursAndMinutes() {
        XCTAssertEqual(BodyHomeCopy.sleepTitle(hours: 7.2), "Last night · 7h 12m")
        XCTAssertEqual(BodyHomeCopy.sleepTitle(hours: 5.05), "Last night · 5h 03m")
        XCTAssertEqual(BodyHomeCopy.sleepTitle(hours: nil), "Last night")
    }

    func testSleepDetailLeavesOutMissingPieces() throws {
        let full = try PrepDecoding.decode(BodyHomeSleep.self, from: Data(
            #"{"hours":7.2,"quality":4,"bed":"2026-11-29T22:48","wake":"2026-11-30T06:05"}"#.utf8))
        XCTAssertEqual(BodyHomeCopy.sleepDetail(full), "Rated 4 · 10:48 → 6:05")
        let bare = try PrepDecoding.decode(BodyHomeSleep.self, from: Data(#"{"hours":6}"#.utf8))
        XCTAssertNil(BodyHomeCopy.sleepDetail(bare))
    }

    func testSessionDateAndSubtitle() throws {
        XCTAssertEqual(BodyHomeCopy.sessionDate("not a date"), "not a date")
        let session = try PrepDecoding.decode(BodySessionSummary.self, from: Data(
            #"{"id":"a","day":"pull","label":"Pull","date":"2026-11-28","minutes":46,"trimmed":true}"#.utf8))
        XCTAssertTrue(BodyHomeCopy.sessionSubtitle(session).hasSuffix("46 min · one set dropped"))
    }

    func testDoneDaysReadAsWeekdayNames() {
        XCTAssertEqual(BodyHomeCopy.doneDays([.done, .off, .done, .today, .ahead, .ahead, .ahead]), "Monday and Wednesday")
        XCTAssertEqual(BodyHomeCopy.doneDays([.ahead, .ahead, .ahead, .ahead, .ahead, .done, .ahead]), "Saturday")
        XCTAssertEqual(BodyHomeCopy.doneDays([.today, .ahead]), "none yet this week")
    }

    func testLiftedLabelsFollowTheWeek() throws {
        let home = try PrepDecoding.decode(BodyHome.self, from: BodyModelsTests.fixture("home.json"))
        let week = home.week
        let sessions = try ["pull", "push"].enumerated().map { offset, label in
            try PrepDecoding.decode(BodySessionSummary.self, from: Data(
                #"{"id":"\#(label)","day":"\#(label)","label":"\#(label.capitalized)","date":"\#(week.days[offset == 0 ? 2 : 0])"}"#.utf8))
        }
        XCTAssertEqual(BodyHomeCopy.liftedLabels(week: week, sessions: sessions), "Push, Pull")
        XCTAssertNil(BodyHomeCopy.liftedLabels(week: week, sessions: []))
    }

    private func lift(_ json: String) throws -> BodyHomeLift {
        try PrepDecoding.decode(BodyHomeLift.self, from: Data(json.utf8))
    }

    func testUpFromLabelAndLiftSummary() throws {
        let incline = try lift(#"{"id":"i","name":"Incline bench","weight_label":"150 lb","up":true,"up_from":145,"dots":[true,true,true,false]}"#)
        XCTAssertEqual(incline.upFromLabel, "145 lb")
        XCTAssertEqual(BodyHomeCopy.liftSummary(incline),
                       "Incline bench, 150 lb, up from 145 lb. Last time 3 of 4 sets hit the top of the range")
        let db = try lift(#"{"id":"d","name":"DB bench","weight_label":"42.5s","up":true,"up_from":40,"dots":[]}"#)
        XCTAssertEqual(db.upFromLabel, "40s")
        XCTAssertEqual(BodyHomeCopy.liftSummary(db), "DB bench, 42.5s, up from 40s")
        let noFrom = try lift(#"{"id":"x","name":"X","weight_label":"50 lb","up":true}"#)
        XCTAssertNil(noFrom.upFromLabel)
        XCTAssertEqual(BodyHomeCopy.liftSummary(noFrom), "X, 50 lb, going up")
        let pull = try lift(#"{"id":"p","name":"Pull-ups","weight_label":"BW","up":false,"dots":[true,false,false,false],"goal_reps":[8,7,6,6]}"#)
        XCTAssertEqual(BodyHomeCopy.liftSummary(pull), "Pull-ups, BW. Last time 1 of 4 sets at goal")
    }

    func testGoalLabelAndOtherDays() {
        XCTAssertEqual(BodyHomeCopy.goalLabel([8, 7, 6, 6]), "Goal 8·7·6·6")
        XCTAssertEqual(BodyHomeCopy.otherDays(than: "legs"), ["push", "pull"])
    }

    func testDayStatesMapToDeckDots() {
        XCTAssertEqual(
            [BodyDayState.done, .off, .today, .ahead, .unknown].map(\.deckDotState),
            ["done", "missed", "today", "ahead", "off"])
    }
}
