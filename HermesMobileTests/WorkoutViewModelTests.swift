import XCTest
@testable import HermesMobile

/// A Body client for the workout: a scripted prescription and plan, and saves that record what
/// was sent, report when they start, and can each wait on a gate so a test controls their order.
private final class FakeWorkoutClient: BodyDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: [BodySession] = []
    private var _log: [String] = []

    var prescriptionResult: Result<BodyPrescription, Error> = .failure(URLError(.badServerResponse))
    var planResult: Result<BodyPlan, Error> = .failure(URLError(.badServerResponse))
    /// Per-call results for `save`; nil echoes the sent session. Past the end, saves echo.
    var saveResults: [Result<BodySession?, Error>] = []
    /// Per-call gates for `save`: call n waits on `saveGates[n]` when set, after signaling `saveStarted`.
    var saveGates: [Int: AsyncStream<Void>] = [:]
    var saveStarted: AsyncStream<Int>.Continuation?

    var saved: [BodySession] { lock.withLock { _saved } }
    var log: [String] { lock.withLock { _log } }

    func prescription(day: String?) async throws -> BodyPrescription {
        lock.withLock { _log.append("prescription:\(day ?? "next")") }
        return try prescriptionResult.get()
    }

    func plan() async throws -> BodyPlan {
        lock.withLock { _log.append("plan") }
        return try planResult.get()
    }

    func save(_ session: BodySession) async throws -> BodySession {
        let (call, result): (Int, Result<BodySession?, Error>) = lock.withLock {
            let call = _saved.count
            _saved.append(session)
            _log.append("save\(call):start")
            return (call, call < saveResults.count ? saveResults[call] : .success(nil))
        }
        saveStarted?.yield(call)
        if let gate = saveGates[call] { for await _ in gate { break } }
        lock.withLock { _log.append("save\(call):end") }
        return try result.get() ?? session
    }

    func home() async throws -> BodyHome { throw URLError(.unsupportedURL) }
    func finish(id: String, check: BodyCheck) async throws -> BodyFinishResult { throw URLError(.unsupportedURL) }
    func session(id: String) async throws -> BodySession { throw URLError(.unsupportedURL) }
    func sessions(before: String?) async throws -> [BodySessionSummary] { throw URLError(.unsupportedURL) }
    func lift(id: String) async throws -> BodyLift { throw URLError(.unsupportedURL) }
    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal { throw URLError(.unsupportedURL) }
    func sleepHistory() async throws -> SleepHistory? { throw URLError(.unsupportedURL) }
}

@MainActor
final class WorkoutViewModelTests: XCTestCase {
    // The push fixture: the warm-up leads (0 curl-up, 1 side plank, 2 bird dog: 3 holds each; 3 band
    // pull-apart: 2), then 4 incline bench (big, 2 warm + 4 work), 5 strict press (big, 3), 6 DB bench (3),
    // 7 bench dips (superset, BW, 3), 8 lateral raise (superset, 3), 9 chest fly (optional, 2),
    // 10 suitcase carry (finisher, 3). Last night was rough, so it offers to drop a set.
    private let curlUp = 0, incline = 4, press = 5, dbBench = 6, dips = 7, carry = 10

    private func pushPrescription() throws -> BodyPrescription {
        try PrepDecoding.decode(BodyPrescription.self, from: BodyModelsTests.fixture("prescription.json"))
    }

    private func loadedVM(_ client: FakeWorkoutClient, day: String? = nil) async throws -> WorkoutViewModel {
        let vm = WorkoutViewModel(client: client, day: day, debounce: .zero)
        await vm.load()
        XCTAssertNotNil(session(vm), "expected a loaded workout, got \(vm.state)")
        return vm
    }

    private func pushVM() async throws -> (WorkoutViewModel, FakeWorkoutClient) {
        let client = FakeWorkoutClient()
        client.prescriptionResult = .success(try pushPrescription())
        return (try await loadedVM(client), client)
    }

    private func session(_ vm: WorkoutViewModel) -> BodySession? {
        if case .loaded(let session) = vm.state { return session }
        return nil
    }

    private func exercise(_ vm: WorkoutViewModel, _ index: Int) -> BodyExercise {
        session(vm)!.exercises[index]
    }

    /// Ticks every work set of one lift, in order.
    private func tickAllWork(_ vm: WorkoutViewModel, _ index: Int) {
        for (j, set) in exercise(vm, index).sets.enumerated() where set.kind == .work {
            vm.toggle(exercise: index, set: j)
        }
    }

    private func gate() -> (AsyncStream<Void>, AsyncStream<Void>.Continuation) {
        AsyncStream<Void>.makeStream()
    }

    // MARK: Load

    func testLoadBuildsSessionFromPrescription() async throws {
        let (vm, client) = try await pushVM()
        let s = try XCTUnwrap(session(vm))
        XCTAssertEqual(s.id, "2026-12-02-push")
        XCTAssertEqual(s.day, "push")
        XCTAssertEqual(s.phase, "build")
        XCTAssertFalse(s.trimmed)
        XCTAssertFalse(s.movedHinge)
        XCTAssertNil(s.finished)
        XCTAssertEqual(s.exercises.map(\.id), [
            "curl-up", "side-plank", "bird-dog", "band-pull-apart",
            "incline-bench", "strict-press", "db-bench", "bench-dips", "lateral-raise", "chest-fly", "suitcase-carry",
        ])
        XCTAssertEqual(s.exercises[incline].sets.map(\.kind), [.warm, .warm, .work, .work, .work, .work])
        XCTAssertEqual(s.exercises[dbBench].sets.first?.weight, 42.5)
        XCTAssertEqual(vm.current, curlUp, "the warm-up opens first")
        XCTAssertNil(vm.effortPrompt)
        XCTAssertEqual(vm.saveStatus, .saved)
        XCTAssertEqual(vm.sleepBanner, .asking)
        XCTAssertEqual(vm.sleepOffer?.quality, 2)
        XCTAssertEqual(vm.hingeBanner, .hidden)
        XCTAssertEqual(client.log, ["prescription:next"], "loading never saves and needs no plan without a hinge offer")
    }

    func testResumedSessionKeepsDoneSets() async throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: BodyModelsTests.fixture("prescription.json")) as? [String: Any])
        json["resumed"] = true
        json["trimmed"] = true
        json.removeValue(forKey: "offers") // a resumed session is the saved document: it has no offers
        var exercises = try XCTUnwrap(json["exercises"] as? [[String: Any]])
        for i in 0...press { // the warm-up, incline and strict press
            var sets = try XCTUnwrap(exercises[i]["sets"] as? [[String: Any]])
            for j in sets.indices { sets[j]["done"] = true }
            exercises[i]["sets"] = sets
        }
        exercises[incline]["reps_left"] = 2
        json["exercises"] = exercises
        let client = FakeWorkoutClient()
        client.prescriptionResult = .success(try PrepDecoding.decode(
            BodyPrescription.self, from: JSONSerialization.data(withJSONObject: json)))

        let vm = try await loadedVM(client)
        let s = try XCTUnwrap(session(vm))
        XCTAssertTrue(s.exercises[incline].sets.allSatisfy(\.done))
        XCTAssertTrue(s.exercises[press].sets.allSatisfy(\.done))
        XCTAssertEqual(s.exercises[incline].repsLeft, 2)
        XCTAssertTrue(s.trimmed)
        XCTAssertEqual(vm.current, dbBench, "the first unfinished lift opens")
        XCTAssertEqual(vm.sleepBanner, .hidden, "a resumed workout never asks about last night again")
    }

    func testNotFoundIsUnavailable() async {
        let client = FakeWorkoutClient()
        client.prescriptionResult = .failure(APIError.http(statusCode: 404, body: nil))
        let vm = WorkoutViewModel(client: client, day: "push", debounce: .zero)
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
        XCTAssertEqual(client.log, ["prescription:push"])
    }

    // MARK: Ticking and advancing

    func testToggleLastSetAdvances() async throws {
        let (vm, _) = try await pushVM()
        vm.open(exercise: dbBench) // not a big lift
        vm.toggle(exercise: dbBench, set: 0)
        vm.toggle(exercise: dbBench, set: 1)
        XCTAssertEqual(vm.current, dbBench, "a set short of the last keeps the lift open")
        vm.toggle(exercise: dbBench, set: 2)
        XCTAssertEqual(vm.current, dips, "the last set opens the next lift")
        XCTAssertTrue(exercise(vm, dbBench).sets.allSatisfy(\.done))

        // Unticking and reticking a set of a finished lift opens the next unfinished one, wrapping to the start.
        vm.toggle(exercise: dbBench, set: 2)
        XCTAssertFalse(exercise(vm, dbBench).sets[2].done)
        vm.toggle(exercise: dbBench, set: 2)
        XCTAssertEqual(vm.current, dips)
        for i in dips...carry { tickAllWork(vm, i) }
        XCTAssertEqual(vm.current, curlUp, "past the last lift, the first unfinished one opens")

        // Finishing the warm-up opens the first lift not yet done.
        for i in curlUp..<incline { tickAllWork(vm, i) }
        XCTAssertEqual(vm.current, incline)
    }

    func testBigLiftAsksRepsLeftBeforeAdvancing() async throws {
        let (vm, _) = try await pushVM()
        vm.open(exercise: incline)
        vm.toggle(exercise: incline, set: 0) // a warm-up set never asks
        XCTAssertNil(vm.effortPrompt)
        tickAllWork(vm, incline)
        XCTAssertEqual(vm.effortPrompt, incline)
        XCTAssertEqual(vm.current, incline, "the lift stays open for the effort tap")

        vm.setRepsLeft(1)
        XCTAssertNil(vm.effortPrompt)
        XCTAssertEqual(exercise(vm, incline).repsLeft, 1)
        XCTAssertEqual(vm.current, press)

        // Unticking the last set while the question waits takes the question away.
        tickAllWork(vm, press)
        XCTAssertEqual(vm.effortPrompt, press)
        vm.toggle(exercise: press, set: 2)
        XCTAssertNil(vm.effortPrompt)
        XCTAssertEqual(vm.current, press)
    }

    func testAccessoryNeverAsksRepsLeft() async throws {
        let (vm, _) = try await pushVM()
        for i in [curlUp, dbBench, dips, carry] {
            vm.open(exercise: i)
            tickAllWork(vm, i)
            XCTAssertNil(vm.effortPrompt, "\(exercise(vm, i).id) is not a big lift")
            XCTAssertNil(exercise(vm, i).repsLeft)
        }
    }

    // MARK: Editing sets

    func testAddAndRemoveSet() async throws {
        let (vm, _) = try await pushVM()
        vm.setReps(9, exercise: dbBench, set: 2)
        vm.addSet(exercise: dbBench)
        var sets = exercise(vm, dbBench).sets
        XCTAssertEqual(sets.count, 4)
        XCTAssertEqual(sets[3], BodySet(kind: .work, weight: 42.5, reps: 9, done: false), "a new set copies the last one")

        vm.removeSet(exercise: dbBench)
        XCTAssertEqual(exercise(vm, dbBench).sets.count, 3)

        vm.deleteSet(exercise: incline, set: 0) // a warm-up set
        sets = exercise(vm, incline).sets
        XCTAssertEqual(sets.map(\.kind), [.warm, .work, .work, .work, .work])

        vm.addSet(exercise: carry) // a carry copies its distance
        XCTAssertEqual(exercise(vm, carry).sets.last, BodySet(kind: .work, weight: 50, distanceYd: 40, done: false))

        vm.addSet(exercise: curlUp) // a hold copies its seconds
        XCTAssertEqual(exercise(vm, curlUp).sets.last, BodySet(kind: .work, holdS: 10, done: false))
    }

    func testWeightAndRepsEditsLandOnTheirSet() async throws {
        let (vm, _) = try await pushVM()
        vm.toggle(exercise: incline, set: 2)
        vm.setWeight(155, exercise: incline, set: 3)
        let sets = exercise(vm, incline).sets
        XCTAssertEqual(sets[2].weight, 150, "a done set keeps its weight")
        XCTAssertEqual(sets[3].weight, 155)
        XCTAssertEqual(sets[4].weight, 155, "later open sets follow a weight change")
        XCTAssertEqual(sets[5].weight, 155)
        XCTAssertEqual(sets[0].weight, 90, "warm-up sets keep theirs")

        vm.setWeight(nil, exercise: incline, set: 4)
        XCTAssertNil(exercise(vm, incline).sets[4].weight)
        XCTAssertEqual(exercise(vm, incline).sets[5].weight, 155, "a cleared weight never carries forward")

        vm.setReps(7, exercise: incline, set: 3)
        XCTAssertEqual(exercise(vm, incline).sets[3].reps, 7)
        XCTAssertEqual(exercise(vm, incline).sets[4].reps, 8, "reps change one set only")

        vm.setReps(35, exercise: carry, set: 0) // a carry logs yards
        XCTAssertEqual(exercise(vm, carry).sets[0].distanceYd, 35)
        XCTAssertNil(exercise(vm, carry).sets[0].reps)

        vm.setReps(20, exercise: curlUp, set: 0) // a warm-up hold logs seconds
        XCTAssertEqual(exercise(vm, curlUp).sets[0].holdS, 20)
        XCTAssertNil(exercise(vm, curlUp).sets[0].reps)
    }

    func testRemoveNeverDropsBelowOneWorkSet() async throws {
        let (vm, _) = try await pushVM()
        for _ in 0..<5 { vm.removeSet(exercise: press) }
        XCTAssertEqual(exercise(vm, press).sets.count, 1)
        vm.deleteSet(exercise: press, set: 0)
        XCTAssertEqual(exercise(vm, press).sets.count, 1, "the last work set can't be deleted")

        for _ in 0..<5 { vm.removeSet(exercise: incline) }
        XCTAssertEqual(exercise(vm, incline).sets.map(\.kind), [.warm, .warm, .work], "warm-up sets never count toward the floor")
    }

    // MARK: Offers

    func testDropASetKeepsWarmupAndFinisherAndUndoRestores() async throws {
        let (vm, _) = try await pushVM()
        let before = try XCTUnwrap(session(vm))
        vm.acceptSleepOffer()
        let after = try XCTUnwrap(session(vm))
        XCTAssertTrue(after.trimmed)
        XCTAssertEqual(vm.sleepBanner, .done)
        XCTAssertEqual(after.exercises.map { $0.sets.count }, [3, 3, 3, 2, 5, 2, 2, 2, 2, 1, 3],
                       "the warm-up lifts and the finisher keep every set")
        XCTAssertEqual(after.exercises[incline].sets.filter { $0.kind == .warm }.count, 2, "warm-up sets stay")

        vm.toggle(exercise: incline, set: 0)
        vm.undoSleepOffer()
        let undone = try XCTUnwrap(session(vm))
        XCTAssertFalse(undone.trimmed)
        XCTAssertEqual(vm.sleepBanner, .hidden)
        XCTAssertEqual(undone.exercises.map { $0.sets.count }, before.exercises.map { $0.sets.count })
        XCTAssertTrue(undone.exercises[incline].sets[0].done, "Undo keeps the taps made since")
        var expected = before.exercises
        expected[incline].sets[0].done = true
        XCTAssertEqual(undone.exercises, expected)
    }

    func testKeepThemAllHidesTheOfferWithoutChanges() async throws {
        let (vm, client) = try await pushVM()
        let before = session(vm)
        vm.keepAllSets()
        XCTAssertEqual(vm.sleepBanner, .hidden)
        XCTAssertEqual(session(vm), before)
        await vm.idle()
        XCTAssertTrue(client.saved.isEmpty)
    }

    func testMoveHingeToEnd() async throws {
        let json = #"""
        {"id":"2026-11-30-legs","day":"legs","phase":"build","resumed":false,"offers":{"sleep":null,"hinge":true,"hinge_minutes":40},
         "exercises":[
          {"id":"curl-up","name":"Curl-up","section":"warmup","unit":"bw","target":{"hold_s":10},"sets":[{"kind":"work","hold_s":10}]},
          {"id":"goblet-squat","name":"Goblet squat","section":"main","big":true,"sets":[{"kind":"work","weight":53,"reps":12}]},
          {"id":"db-rdl","name":"DB Romanian deadlift","section":"main","big":true,"hinge":true,"unit":"lb_each","sets":[{"kind":"work","weight":35,"reps":10}]},
          {"id":"split-squat","name":"Bulgarian split squat","section":"main","big":true,"sets":[{"kind":"work","weight":35,"reps":8}]},
          {"id":"pallof-press","name":"Pallof press","section":"superset","unit":"cable","sets":[{"kind":"work","reps":10}]},
          {"id":"wall-sit","name":"Wall sit","section":"finisher","unit":"bw","target":{"hold_s":45},"sets":[{"kind":"work","hold_s":45}]}
         ]}
        """#
        let client = FakeWorkoutClient()
        client.prescriptionResult = .success(try PrepDecoding.decode(BodyPrescription.self, from: Data(json.utf8)))
        let vm = try await loadedVM(client, day: "legs")
        XCTAssertEqual(vm.hingeBanner, .asking)
        XCTAssertEqual(vm.hingeNames, ["DB Romanian deadlift"])
        XCTAssertEqual(vm.hingeMinutes, 40)
        XCTAssertEqual(vm.sleepBanner, .hidden)
        XCTAssertEqual(client.log, ["prescription:legs"], "the hinge flag comes with each lift: no plan call")
        XCTAssertEqual(WorkoutCopy.hingeTitle(minutes: 40), "You woke 40 min ago.")
        XCTAssertEqual(WorkoutCopy.hingeTitle(minutes: nil), "You woke under an hour ago.")
        XCTAssertEqual(WorkoutCopy.hingeQuestion(vm.hingeNames), "Move RDLs to the end?")

        vm.toggle(exercise: 1, set: 0) // the squat: a big lift, so it waits on reps left
        vm.open(exercise: 3)
        vm.moveHinge()
        let moved = try XCTUnwrap(session(vm))
        XCTAssertEqual(moved.exercises.map(\.id),
                       ["curl-up", "goblet-squat", "split-squat", "db-rdl", "pallof-press", "wall-sit"])
        XCTAssertTrue(moved.movedHinge)
        XCTAssertEqual(vm.current, 2, "the open lift stays open where it moved to")
        XCTAssertEqual(vm.hingeBanner, .done)

        vm.undoMoveHinge()
        let undone = try XCTUnwrap(session(vm))
        XCTAssertEqual(undone.exercises.map(\.id),
                       ["curl-up", "goblet-squat", "db-rdl", "split-squat", "pallof-press", "wall-sit"])
        XCTAssertFalse(undone.movedHinge)
        XCTAssertEqual(vm.current, 3)
        XCTAssertEqual(vm.hingeBanner, .hidden)
    }

    // MARK: Saving

    func testSavesAreDebouncedToNewestState() async throws {
        let (vm, client) = try await pushVM()
        let (started, startedContinuation) = AsyncStream<Int>.makeStream()
        client.saveStarted = startedContinuation
        let (firstGate, release) = gate()
        client.saveGates[0] = firstGate
        var starts = started.makeAsyncIterator()

        vm.toggle(exercise: incline, set: 0)
        vm.toggle(exercise: incline, set: 1)
        XCTAssertEqual(vm.saveStatus, .saving)
        _ = await starts.next()
        XCTAssertEqual(client.saved.count, 1, "taps in one burst send one save")
        XCTAssertEqual(client.saved[0].exercises[incline].sets.prefix(2).map(\.done), [true, true])

        // Taps while a save is out wait for it, then go as one save of the newest state.
        vm.toggle(exercise: incline, set: 2)
        vm.setReps(6, exercise: incline, set: 2)
        vm.setRepsLeft(2) // no question waiting: ignored
        release.yield()
        await vm.idle()

        XCTAssertEqual(client.saved.count, 2)
        XCTAssertEqual(client.log, ["prescription:next", "save0:start", "save0:end", "save1:start", "save1:end"])
        let newest = client.saved[1].exercises[incline].sets[2]
        XCTAssertTrue(newest.done)
        XCTAssertEqual(newest.reps, 6)
        XCTAssertEqual(client.saved[1], session(vm))
        XCTAssertEqual(vm.saveStatus, .saved)
    }

    func testStaleSaveDoesNotOverwriteNewerTaps() async throws {
        let (vm, client) = try await pushVM()
        let (started, startedContinuation) = AsyncStream<Int>.makeStream()
        client.saveStarted = startedContinuation
        let (firstGate, release) = gate()
        client.saveGates[0] = firstGate
        // The slow first response comes back as the server stored it: one tap behind, and failing.
        client.saveResults = [.failure(URLError(.timedOut))]
        var starts = started.makeAsyncIterator()

        vm.toggle(exercise: incline, set: 0)
        _ = await starts.next()
        vm.toggle(exercise: incline, set: 1)
        release.yield()
        await vm.idle()

        let local = try XCTUnwrap(session(vm))
        XCTAssertEqual(local.exercises[incline].sets.prefix(2).map(\.done), [true, true])
        XCTAssertEqual(vm.saveStatus, .saved, "an older save's failure never marks the newer state unsaved")
        XCTAssertEqual(client.saved.last, local)

        // A slow success carrying an older document doesn't replace newer local sets either.
        let (secondGate, releaseSecond) = gate()
        client.saveGates[2] = secondGate
        var stale = local
        stale.exercises[incline].sets[2].done = false
        stale.started = "2026-12-02T07:05:00"
        client.saveResults += [.success(stale)]
        vm.toggle(exercise: incline, set: 2)
        _ = await starts.next()
        vm.toggle(exercise: incline, set: 3)
        releaseSecond.yield()
        await vm.idle()
        let newest = try XCTUnwrap(session(vm))
        XCTAssertEqual(newest.exercises[incline].sets[2...3].map(\.done), [true, true])
        XCTAssertEqual(client.saved.last?.exercises[incline].sets[3].done, true)
    }

    func testFailedSaveKeepsLocalStateAndRetries() async throws {
        let (vm, client) = try await pushVM()
        client.saveResults = [.failure(URLError(.notConnectedToInternet))]
        vm.toggle(exercise: incline, set: 0)
        await vm.idle()
        XCTAssertEqual(vm.saveStatus, .failed)
        XCTAssertTrue(exercise(vm, incline).sets[0].done, "a failed save keeps the tap")

        vm.toggle(exercise: incline, set: 1)
        await vm.idle()
        XCTAssertEqual(vm.saveStatus, .saved)
        XCTAssertEqual(client.saved.count, 2)
        XCTAssertEqual(client.saved[1].exercises[incline].sets.prefix(2).map(\.done), [true, true])
    }

    func testTickingAWorkSetWithdrawsTheSleepOffer() async throws {
        let (vm, _) = try await pushVM()
        tickAllWork(vm, curlUp) // the warm-up lifts come first: the offer stays
        XCTAssertEqual(vm.sleepBanner, .asking)
        vm.toggle(exercise: incline, set: 0) // a lift's warm-up set: the offer stays
        XCTAssertEqual(vm.sleepBanner, .asking)
        vm.toggle(exercise: press, set: 2) // a work set: too late to drop one
        XCTAssertEqual(vm.sleepBanner, .hidden)
        let before = try XCTUnwrap(session(vm))
        vm.acceptSleepOffer()
        XCTAssertEqual(session(vm), before, "a ticked set is never dropped")
        XCTAssertFalse(try XCTUnwrap(session(vm)).trimmed)
    }

    func testWarmupAndFinisherKeepEverySetWhenDropping() async throws {
        let (vm, _) = try await pushVM()
        XCTAssertEqual(exercise(vm, curlUp).section, .warmup)
        XCTAssertEqual(WorkoutCopy.sectionTitle(.warmup), "Warm-up")
        let before = try XCTUnwrap(session(vm))

        vm.acceptSleepOffer()
        let after = try XCTUnwrap(session(vm))
        for i in [0, 1, 2, 3, carry] {
            XCTAssertEqual(after.exercises[i].sets, before.exercises[i].sets, "\(after.exercises[i].id) keeps every set")
        }
    }

    func testFinishedSessionStopsSaving() async throws {
        let (vm, client) = try await pushVM()
        client.saveResults = [.failure(APIError.http(statusCode: 409, body: #"{"error":"session is finished"}"#))]
        vm.toggle(exercise: 0, set: 0)
        await vm.idle()
        XCTAssertEqual(vm.saveStatus, .finished)

        vm.toggle(exercise: 0, set: 1)
        await vm.idle()
        vm.saveNow()
        await vm.idle()
        XCTAssertEqual(client.saved.count, 1, "a finished workout is never saved again")
        XCTAssertEqual(vm.saveStatus, .finished)
    }

    func testDeletingAMiddleSetKeepsTheOthersIdentity() async throws {
        let (vm, _) = try await pushVM()
        let before = exercise(vm, incline).sets.map(\.uid)
        XCTAssertEqual(Set(before).count, before.count, "every set has its own identity")
        vm.toggle(exercise: incline, set: 2) // a tick keeps identity too
        vm.deleteSet(exercise: incline, set: 3)
        var expected = before
        expected.remove(at: 3)
        XCTAssertEqual(exercise(vm, incline).sets.map(\.uid), expected)

        vm.addSet(exercise: incline)
        let added = try XCTUnwrap(exercise(vm, incline).sets.last?.uid)
        XCTAssertFalse(before.contains(added), "an added set is a new row")
    }

    func testWeightEditorStartsFromLastTime() throws {
        let json = #"""
        {"id":"lat-pulldown","name":"Lat pulldown","section":"main","unit":"lb","target":{"reps":[10,12]},
         "last":[{"weight":90,"reps":12},{"weight":95,"reps":10}],
         "sets":[{"kind":"work","weight":null,"reps":12},{"kind":"work","weight":null,"reps":12},{"kind":"work","weight":null,"reps":12}]}
        """#
        let lift = try PrepDecoding.decode(BodyExercise.self, from: Data(json.utf8))
        XCTAssertEqual(WorkoutCopy.startingWeight(lift, set: 0), 90)
        XCTAssertEqual(WorkoutCopy.startingWeight(lift, set: 1), 95)
        XCTAssertEqual(WorkoutCopy.startingWeight(lift, set: 2), 95, "past last time's sets, its heaviest")
        let fresh = try PrepDecoding.decode(BodyExercise.self, from: Data(
            #"{"id":"x","unit":"lb","sets":[{"kind":"work","weight":null}]}"#.utf8))
        XCTAssertNil(WorkoutCopy.startingWeight(fresh, set: 0))
        let prescribed = try pushPrescription().exercises[incline]
        XCTAssertEqual(WorkoutCopy.startingWeight(prescribed, set: 3), 150, "a set with a weight starts from it")
    }

    // MARK: Copy

    func testCopyReadsLikeTheBoard() throws {
        let lifts = try pushPrescription().exercises
        let incline = lifts[self.incline], dbBench = lifts[self.dbBench], dips = lifts[self.dips], carry = lifts[self.carry]
        let curlUp = lifts[self.curlUp], bandPullApart = lifts[3]
        XCTAssertEqual(WorkoutCopy.planLine(curlUp), "3 × 10 s · BW")
        XCTAssertEqual(WorkoutCopy.planLine(bandPullApart), "2 × 15 · Band")
        XCTAssertEqual(WorkoutCopy.planLine(incline), "4 × 6–8 · 150")
        XCTAssertEqual(WorkoutCopy.planLine(dbBench), "3 × 10 · 42.5s")
        XCTAssertEqual(WorkoutCopy.planLine(dips), "3 × 10–12 · BW")
        XCTAssertEqual(WorkoutCopy.planLine(carry), "3 × 40 yd a side · 50")
        XCTAssertEqual(WorkoutCopy.targetLine(incline), "4 × 6–8 · last time 145 × 8 8 8 8")
        XCTAssertEqual(WorkoutCopy.upNote(incline), "↑ 5 lb today: every set hit 8 last time.")
        XCTAssertEqual(WorkoutCopy.upNote(dbBench), "↑ 2.5 lb a dumbbell today: every set hit 10 last time.")
        XCTAssertNil(WorkoutCopy.upNote(dips))
        XCTAssertEqual(incline.sets.indices.map { WorkoutCopy.tag(incline, set: $0) }, ["W", "W", "1", "2", "3", "4"])
        XCTAssertEqual(WorkoutCopy.lastTime(incline, workIndex: WorkoutCopy.workIndex(incline, set: 0)), "—")
        XCTAssertEqual(WorkoutCopy.lastTime(incline, workIndex: WorkoutCopy.workIndex(incline, set: 2)), "145 × 8")
        XCTAssertEqual(WorkoutCopy.lastTime(dips, workIndex: 0), "BW × 12")
        XCTAssertEqual(WorkoutCopy.lastTime(curlUp, workIndex: 0), "10 s")
        XCTAssertEqual(WorkoutCopy.sleepTitle(try XCTUnwrap(try pushPrescription().offers.sleep)), "Rough night: 5h 12m, rated 2")
        XCTAssertEqual(WorkoutCopy.phaseLabel("reentry", deload: false), "Re-entry")
        XCTAssertEqual(WorkoutCopy.phaseLabel("newborn", deload: true), "Newborn mode · Deload")
    }

    func testRetryResendsAfterAFailureWithoutNewTaps() async throws {
        let (vm, client) = try await pushVM()
        client.saveResults = [.failure(URLError(.notConnectedToInternet))]
        vm.toggle(exercise: 0, set: 0)
        await vm.idle()
        XCTAssertEqual(vm.saveStatus, .failed)
        vm.saveNow()
        await vm.idle()
        XCTAssertEqual(vm.saveStatus, .saved)
        XCTAssertEqual(client.saved.count, 2)

        vm.saveNow() // nothing new: nothing sent
        await vm.idle()
        XCTAssertEqual(client.saved.count, 2)
    }
}
