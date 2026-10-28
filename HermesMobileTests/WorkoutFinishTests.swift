import XCTest
@testable import HermesMobile

/// A Body client for finishing a workout: saves and finish calls are logged in order, finish and
/// the session read answer from a script, and the proposal decision can fail.
private final class FakeFinishClient: BodyDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _checks: [BodyCheck] = []

    var prescriptionResult: Result<BodyPrescription, Error> = .failure(URLError(.badServerResponse))
    var finishResult: Result<BodyFinishResult, Error> = .failure(URLError(.badServerResponse))
    /// One result per `session(id:)` call; the last repeats.
    var sessionResults: [Result<BodySession, Error>] = []
    var decideResult: Result<BodyProposal, Error> = .failure(URLError(.badServerResponse))

    var log: [String] { lock.withLock { _log } }
    var checks: [BodyCheck] { lock.withLock { _checks } }

    func prescription(day: String?) async throws -> BodyPrescription {
        lock.withLock { _log.append("prescription") }
        return try prescriptionResult.get()
    }

    func save(_ session: BodySession) async throws -> BodySession {
        lock.withLock { _log.append("save") }
        return session
    }

    func finish(id: String, check: BodyCheck) async throws -> BodyFinishResult {
        lock.withLock {
            _log.append("finish:\(id)")
            _checks.append(check)
        }
        return try finishResult.get()
    }

    func session(id: String) async throws -> BodySession {
        try lock.withLock {
            _log.append("session:\(id)")
            guard !sessionResults.isEmpty else { throw URLError(.badServerResponse) }
            return try (sessionResults.count > 1 ? sessionResults.removeFirst() : sessionResults[0]).get()
        }
    }

    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal {
        lock.withLock { _log.append("decide:\(proposalID):\(accept ? "accept" : "skip")") }
        return try decideResult.get()
    }

    func home() async throws -> BodyHome { throw URLError(.unsupportedURL) }
    func sessions(before: String?) async throws -> [BodySessionSummary] { throw URLError(.unsupportedURL) }
    func lift(id: String) async throws -> BodyLift { throw URLError(.unsupportedURL) }
    func plan() async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func sleepHistory() async throws -> SleepHistory? { throw URLError(.unsupportedURL) }
}

@MainActor
final class WorkoutFinishTests: XCTestCase {
    private func proposal(_ id: String) -> BodyProposal {
        let json = #"{"id":"\#(id)","kind":"reset","lift":"strict-press","title":"Reset \#(id)","why":["a"],"rule":"r","status":"pending"}"#
        return try! PrepDecoding.decode(BodyProposal.self, from: Data(json.utf8))
    }

    /// The finished session from the fixture, with `note` as Baki's coach note when given.
    private func finishedSession(note: String? = nil) throws -> BodySession {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BodyModelsTests.fixture("session.json")) as? [String: Any])
        object["coach_note"] = nil   // Baki writes it after the finish; the fixture already has one
        if let note {
            object["coach_note"] = ["headline": note, "body": ["One.", "Two."], "written_at": "2026-11-30T08:00:00"]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try PrepDecoding.decode(BodySession.self, from: data)
    }

    private func result(proposals: [BodyProposal] = []) throws -> BodyFinishResult {
        var session = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BodyModelsTests.fixture("session.json")) as? [String: Any])
        session["coach_note"] = nil
        let rows = try proposals.map { p in
            ["id": p.id, "kind": p.kind, "title": p.title, "why": p.why, "rule": p.rule, "status": p.status] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["session": session, "proposals": rows])
        return try PrepDecoding.decode(BodyFinishResult.self, from: data)
    }

    private func workout(_ client: FakeFinishClient) async throws -> WorkoutViewModel {
        client.prescriptionResult = .success(
            try PrepDecoding.decode(BodyPrescription.self, from: BodyModelsTests.fixture("prescription.json")))
        let vm = WorkoutViewModel(client: client, day: nil, debounce: .zero)
        await vm.load()
        return vm
    }

    private func finishVM(_ client: FakeFinishClient) async throws -> (WorkoutFinishViewModel, WorkoutViewModel) {
        let workout = try await workout(client)
        return (WorkoutFinishViewModel(workout: workout, client: client), workout)
    }

    // MARK: WorkoutViewModel.finish

    func testFinishSendsCheckAndReturnsProposals() async throws {
        let client = FakeFinishClient()
        client.finishResult = .success(try result(proposals: [proposal("p1")]))
        let vm = try await workout(client)
        vm.toggle(exercise: 0, set: 2)

        let check = BodyCheck(effort: .grinder, back: .tight, shoulders: .pain,
                              pain: BodyPain(score: 6, lift: "strict-press"), note: "Left side")
        let finished = await vm.finish(check: check)

        XCTAssertEqual(finished?.proposals.map(\.id), ["p1"])
        XCTAssertEqual(finished?.session.id, "2026-11-23-push")
        XCTAssertEqual(client.checks, [check])
        XCTAssertEqual(client.log, ["prescription", "save", "finish:2026-11-30-push"],
                       "the latest sets are saved before the workout is finished")
        XCTAssertEqual(vm.saveStatus, .finished)
        vm.toggle(exercise: 0, set: 3)
        await vm.idle()
        XCTAssertEqual(client.log.filter { $0 == "save" }.count, 1, "a finished workout never saves again")
    }

    func testFinishFailureKeepsTheWorkoutOpen() async throws {
        let client = FakeFinishClient()
        client.finishResult = .failure(URLError(.notConnectedToInternet))
        let vm = try await workout(client)
        let finished = await vm.finish(check: BodyCheck())
        XCTAssertNil(finished)
        XCTAssertNotNil(vm.finishError)
        XCTAssertNotEqual(vm.saveStatus, .finished)
        XCTAssertFalse(vm.isFinishing)
    }

    func testFinishConflictSaysItWasAlreadyFinished() async throws {
        let client = FakeFinishClient()
        client.finishResult = .failure(APIError.http(statusCode: 409, body: #"{"error":"session is finished"}"#))
        let vm = try await workout(client)
        let finished = await vm.finish(check: BodyCheck())
        XCTAssertNil(finished)
        XCTAssertEqual(vm.finishError, "This workout was already finished.")
        XCTAssertEqual(vm.saveStatus, .finished)
    }

    // MARK: The check

    func testPainRequiresScoreAndLift() async throws {
        let (vm, _) = try await finishVM(FakeFinishClient())
        XCTAssertTrue(vm.canSave, "Fine and Tight need nothing more")
        vm.back = .tight
        XCTAssertTrue(vm.canSave)
        vm.shoulders = .pain
        XCTAssertFalse(vm.canSave, "Pain needs a score and a lift")
        vm.stepPain(1)
        XCTAssertFalse(vm.canSave, "a score alone is not enough")
        vm.painLift = "strict-press"
        XCTAssertTrue(vm.canSave)
        vm.painScore = nil
        XCTAssertFalse(vm.canSave, "a lift alone is not enough")
    }

    func testPainLiftsAreTheWorkLiftsOfThisSession() async throws {
        let client = FakeFinishClient()
        let workout = try await workout(client)
        let vm = WorkoutFinishViewModel(workout: workout, client: client)
        XCTAssertEqual(vm.painLifts.map(\.id), [
            "incline-bench", "strict-press", "db-bench", "bench-dips", "lateral-raise", "chest-fly", "suitcase-carry",
        ])
    }

    func testPainStepperStaysInRange() async throws {
        let (vm, _) = try await finishVM(FakeFinishClient())
        XCTAssertNil(vm.painScore)
        vm.stepPain(-1)
        XCTAssertEqual(vm.painScore, 5, "the first tap on either side starts at 5")
        for _ in 0..<20 { vm.stepPain(1) }
        XCTAssertEqual(vm.painScore, 10)
        for _ in 0..<20 { vm.stepPain(-1) }
        XCTAssertEqual(vm.painScore, 0)
    }

    func testSaveSendsThePainReportOnlyWhileAPartIsPain() async throws {
        let client = FakeFinishClient()
        client.finishResult = .success(try result())
        let (vm, _) = try await finishVM(client)
        vm.shoulders = .pain
        vm.stepPain(1)
        vm.painLift = "strict-press"
        vm.note = "  Left side  "
        vm.shoulders = .tight   // changed his mind: no part is Pain, so no report goes
        await vm.save()
        let check = try XCTUnwrap(client.checks.first)
        XCTAssertNil(check.pain)
        XCTAssertEqual(check.note, "Left side")
        XCTAssertEqual(check.effort, .solid)
        XCTAssertEqual(vm.phase, .saved)
    }

    func testSaveWithPainSendsScoreAndLift() async throws {
        let client = FakeFinishClient()
        client.finishResult = .success(try result())
        let (vm, _) = try await finishVM(client)
        vm.back = .pain
        vm.stepPain(1)
        vm.stepPain(1)
        vm.painLift = "incline-bench"
        await vm.save()
        XCTAssertEqual(client.checks.first?.pain, BodyPain(score: 6, lift: "incline-bench"))
    }

    func testSaveIsIgnoredWhilePainIsIncomplete() async throws {
        let client = FakeFinishClient()
        let (vm, _) = try await finishVM(client)
        vm.back = .pain
        await vm.save()
        XCTAssertEqual(vm.phase, .asking)
        XCTAssertFalse(client.log.contains { $0.hasPrefix("finish") })
    }

    func testSaveFailureReturnsToTheForm() async throws {
        let client = FakeFinishClient()
        client.finishResult = .failure(URLError(.notConnectedToInternet))
        let (vm, _) = try await finishVM(client)
        await vm.save()
        XCTAssertEqual(vm.phase, .asking)
        XCTAssertNotNil(vm.saveError)
        XCTAssertTrue(vm.canSave, "he can try again")
    }

    // MARK: After saving

    func testCoachNoteArrivesOnRefresh() async throws {
        let client = FakeFinishClient()
        client.finishResult = .success(try result())
        client.sessionResults = [.success(try finishedSession()), .success(try finishedSession(note: "The jump held."))]
        let (vm, _) = try await finishVM(client)

        await vm.refreshNote()
        XCTAssertFalse(client.log.contains { $0.hasPrefix("session:") }, "nothing to refresh before saving")

        await vm.save()
        XCTAssertNil(vm.coachNote)
        await vm.refreshNote()
        XCTAssertNil(vm.coachNote, "the note isn't written yet")
        await vm.refreshNote()
        XCTAssertEqual(vm.coachNote?.headline, "The jump held.")
        XCTAssertEqual(vm.coachNote?.body, ["One.", "Two."])
    }

    func testRefreshFailureKeepsWaiting() async throws {
        let client = FakeFinishClient()
        client.finishResult = .success(try result())
        client.sessionResults = [.failure(URLError(.notConnectedToInternet))]
        let (vm, _) = try await finishVM(client)
        await vm.save()
        await vm.refreshNote()
        XCTAssertNil(vm.coachNote)
        XCTAssertEqual(vm.phase, .saved)
    }

    func testDecideRemovesTheProposalAndRollsBackOnFailure() async throws {
        let client = FakeFinishClient()
        client.finishResult = .success(try result(proposals: [proposal("p1"), proposal("p2")]))
        let (vm, _) = try await finishVM(client)
        await vm.save()
        XCTAssertEqual(vm.proposals.map(\.id), ["p1", "p2"])

        client.decideResult = .success(proposal("p1"))
        await vm.decide(vm.proposals[0], accept: true)
        XCTAssertEqual(vm.proposals.map(\.id), ["p2"])

        client.decideResult = .failure(URLError(.notConnectedToInternet))
        await vm.decide(vm.proposals[0], accept: false)
        XCTAssertEqual(vm.proposals.map(\.id), ["p2"], "a failed decision puts the proposal back")
        XCTAssertNotNil(vm.decideError)
    }

    // MARK: Copy

    func testSummaryReadsLikeTheBoard() throws {
        var session = try finishedSession()
        session.started = "2026-11-23T07:00:00"
        session.finished = "2026-11-23T07:52:00"
        // The fixture has 11 lifts' worth in the real push day; here count what is in it.
        let lifts = session.exercises.filter { $0.sets.contains(where: \.done) }.count
        let up = session.exercises.filter { $0.up && $0.sets.contains(where: \.done) }.count
        let text = WorkoutFinishCopy.summary(session, now: Date())
        XCTAssertTrue(text.hasPrefix("52 min · "), text)
        XCTAssertTrue(text.contains(lifts == 1 ? "1 lift" : "\(lifts) lifts"), text)
        XCTAssertTrue(text.hasSuffix("\(up) went up"), text)
    }

    func testSummaryWithoutAStartLeavesOutTheMinutes() throws {
        var session = try finishedSession()
        session.started = nil
        XCTAssertFalse(WorkoutFinishCopy.summary(session, now: Date()).contains("min"))
    }

    func testTitleAndKicker() {
        XCTAssertEqual(WorkoutFinishCopy.title(day: "push"), "Push done")
        XCTAssertEqual(WorkoutFinishCopy.kicker(day: "legs"), "Baki · after Legs")
    }
}
