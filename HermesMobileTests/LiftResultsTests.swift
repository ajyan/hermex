import XCTest
@testable import HermesMobile

/// One lift decoded from the workout document's JSON, with invented numbers.
private func lift(unit: String = "lb", target: String = #"{"reps":[6,8]}"#, goal: String? = nil,
                  sets: [String], last: [String] = []) throws -> BodyExercise {
    let goalReps = goal.map { #","goal_reps":\#($0)"# } ?? ""
    let json = #"{"id":"x","name":"Pull-ups","section":"main","unit":"\#(unit)","target":\#(target)\#(goalReps),"#
        + #""sets":[\#(sets.joined(separator: ","))],"last":[\#(last.joined(separator: ","))]}"#
    return try PrepDecoding.decode(BodyExercise.self, from: Data(json.utf8))
}

/// A work set as the document writes it: `{"kind":"work","weight":145,"reps":8,"done":true}`.
private func work(_ weight: Double? = nil, _ count: Int, key: String = "reps", done: Bool = true) -> String {
    let load = weight.map { #""weight":\#($0),"# } ?? ""
    return #"{"kind":"work",\#(load)"\#(key)":\#(count),"done":\#(done)}"#
}

/// A `last` entry; `done` is left out when nil, as older workouts have it.
private func before(_ weight: Double? = nil, _ count: Int, key: String = "reps", done: Bool? = nil) -> String {
    let load = weight.map { #""weight":\#($0),"# } ?? ""
    let ticked = done.map { #","done":\#($0)"# } ?? ""
    return #"{\#(load)"\#(key)":\#(count)\#(ticked)}"#
}

/// The lift-by-lift results: which pip each set draws and how a lift compares with the time before.
final class LiftResultsTests: XCTestCase {
    // MARK: Pips

    func testASetIsHitAtTheTopOfItsRangeShortBelowItAndNotDoneWhenUnticked() throws {
        let result = LiftResults.result(try lift(sets: [work(145, 8), work(145, 7), work(145, 8, done: false)]))
        XCTAssertEqual(result.now, [.hit, .short, .notDone])
    }

    func testWarmUpSetsDrawNoPip() throws {
        let warm = #"{"kind":"warm","weight":85,"reps":8,"done":true}"#
        XCTAssertEqual(LiftResults.result(try lift(sets: [warm, work(145, 8)])).now, [.hit])
    }

    func testGoalRepsSetEachSetsGoalAndTheRangeCoversTheRest() throws {
        let pullUps = try lift(unit: "bw", target: #"{"reps":[5,8]}"#, goal: "[8,7,6]",
                               sets: [work(nil, 9), work(nil, 5), work(nil, 6), work(nil, 7), work(nil, 8)])
        XCTAssertEqual(LiftResults.result(pullUps).now, [.hit, .short, .hit, .short, .hit],
                       "sets past the goal list fall back to the top of the range, as the server's dots do")
        XCTAssertEqual(LiftResults.goal(pullUps, set: 1), 7)
        XCTAssertEqual(LiftResults.goal(pullUps, set: 4), 8)
    }

    func testHoldsAndCarriesAreMeasuredAgainstTheirTarget() throws {
        let plank = try lift(unit: "bw", target: #"{"hold_s":30}"#,
                             sets: [work(nil, 30, key: "hold_s"), work(nil, 20, key: "hold_s")])
        XCTAssertEqual(LiftResults.result(plank).now, [.hit, .short])
        let carry = try lift(target: #"{"distance_yd":40}"#,
                             sets: [work(50, 40, key: "distance_yd"), work(50, 25, key: "distance_yd")])
        XCTAssertEqual(LiftResults.result(carry).now, [.hit, .short])
    }

    func testADoneSetWithNothingToReachIsAHit() throws {
        XCTAssertEqual(LiftResults.result(try lift(target: "{}", sets: [work(20, 3)])).now, [.hit])
        XCTAssertEqual(LiftResults.pip(done: true, count: nil, goal: 8), .short, "a done set with no number logged")
    }

    func testLastSetsWithoutDoneReadAsDone() throws {
        let result = LiftResults.result(try lift(
            sets: [work(145, 8)],
            last: [before(140, 8), before(140, 6), before(140, 8, done: true), before(140, 8, done: false)]))
        XCTAssertEqual(result.last, [.hit, .short, .hit, .notDone])
    }

    func testALiftWithNoLastTimeShowsOnlyThisWorkout() throws {
        let result = LiftResults.result(try lift(sets: [work(145, 8)]))
        XCTAssertEqual(result.last, [])
        XCTAssertNil(result.change)
    }

    // MARK: Against the time before

    func testAHeavierTopWeightIsUpAndALighterOneDown() throws {
        let up = LiftResults.change(try lift(sets: [work(150, 6), work(150, 6)], last: [before(140, 8), before(140, 8)]))
        XCTAssertEqual(up, .heavier(10), "weight wins even with fewer reps")
        XCTAssertEqual(up?.words, "10 lb")
        XCTAssertEqual(up?.isUp, true)

        let down = LiftResults.change(try lift(unit: "lb_each", sets: [work(30, 10)], last: [before(42.5, 10)]))
        XCTAssertEqual(down, .lighter(12.5))
        XCTAssertEqual(down?.words, "12.5 lb")
        XCTAssertEqual(down?.isUp, false)
    }

    func testOnlyDoneSetsCount() throws {
        let change = LiftResults.change(try lift(
            sets: [work(140, 8), work(160, 8, done: false)],
            last: [before(140, 8), before(170, 8, done: false)]))
        XCTAssertEqual(change, .same, "the unticked heavier sets on both sides are left out")
    }

    func testAtTheSameWeightRepsDecide() throws {
        XCTAssertEqual(LiftResults.change(try lift(sets: [work(140, 8), work(140, 8)], last: [before(140, 8), before(140, 7)])),
                       .more(.reps))
        XCTAssertEqual(LiftResults.change(try lift(sets: [work(140, 8)], last: [before(140, 8), before(140, 7)])),
                       .less(.reps), "a skipped set is fewer reps")
        let same = LiftResults.change(try lift(sets: [work(140, 8), work(140, 7)], last: [before(140, 7), before(140, 8)]))
        XCTAssertEqual(same, .same)
        XCTAssertEqual(same?.words, "Same")
        XCTAssertNil(same?.isUp)
        XCTAssertEqual(LiftChange.more(.reps).words, "reps")
        XCTAssertEqual(LiftChange.less(.reps).isUp, false)
    }

    func testBodyweightLiftsCompareRepsWhateverWeightIsWritten() throws {
        let dips = try lift(unit: "bw", target: #"{"reps":[10,12]}"#,
                            sets: [work(nil, 12), work(nil, 12)], last: [before(25, 10), before(25, 10)])
        XCTAssertEqual(LiftResults.change(dips), .more(.reps))
    }

    func testHoldsCompareSecondsAndCarriesYards() throws {
        let plank = try lift(unit: "bw", target: #"{"hold_s":30}"#,
                             sets: [work(nil, 30, key: "hold_s"), work(nil, 30, key: "hold_s")],
                             last: [before(nil, 30, key: "hold_s"), before(nil, 20, key: "hold_s")])
        XCTAssertEqual(LiftResults.change(plank), .more(.hold))
        XCTAssertEqual(LiftChange.more(.hold).words, "time")
        let carry = try lift(target: #"{"distance_yd":40}"#,
                             sets: [work(50, 40, key: "distance_yd")],
                             last: [before(50, 40, key: "distance_yd"), before(50, 40, key: "distance_yd")])
        XCTAssertEqual(LiftResults.change(carry), .less(.distance))
        XCTAssertEqual(LiftChange.less(.distance).words, "yards")
        let heavier = try lift(target: #"{"distance_yd":40}"#,
                               sets: [work(40, 40, key: "distance_yd")], last: [before(26, 40, key: "distance_yd")])
        XCTAssertEqual(LiftResults.change(heavier), .heavier(14))
    }

    func testNothingToCompareWhenEitherSideHasNoDoneSet() throws {
        XCTAssertNil(LiftResults.change(try lift(sets: [work(140, 8, done: false)], last: [before(140, 8)])))
        XCTAssertNil(LiftResults.change(try lift(sets: [work(140, 8)], last: [before(140, 8, done: false)])))
        XCTAssertNil(LiftResults.change(try lift(sets: [work(140, 8)])))
    }

    // MARK: The row

    func testTheWeightIsTheTopOneHeDid() throws {
        XCTAssertEqual(LiftResults.result(try lift(sets: [work(85, 8), work(90, 8), work(95, 8, done: false)])).weightLabel, "90 lb")
        XCTAssertEqual(LiftResults.result(try lift(sets: [work(90, 8, done: false)])).weightLabel, "90 lb",
                       "nothing done: the planned weight")
        XCTAssertEqual(LiftResults.result(try lift(unit: "lb_each", sets: [work(42.5, 8)])).weightLabel, "42.5s")
        XCTAssertEqual(LiftResults.result(try lift(unit: "bw", sets: [work(nil, 8)])).weightLabel, "BW")
    }

    func testVoiceOverReadsTheWholeRow() throws {
        let pullUps = LiftResults.result(try lift(
            unit: "bw", target: #"{"reps":[5,8]}"#, goal: "[8,7,6,6]",
            sets: [work(nil, 9), work(nil, 5), work(nil, 3), work(nil, 2)],
            last: [before(nil, 7), before(nil, 6), before(nil, 5), before(nil, 5)]))
        XCTAssertEqual(LiftResults.spoken(pullUps, frame: .today),
                       "Pull-ups, body weight. Today: 1 of 4 sets hit the goal, 3 short. Last time: 0 of 4. Fewer reps than last time.")
        XCTAssertEqual(LiftResults.spoken(pullUps, frame: .past),
                       "Pull-ups, body weight. Then: 1 of 4 sets hit the goal, 3 short. The time before: 0 of 4. Fewer reps than the time before.")

        let skipped = LiftResults.result(try lift(
            sets: [work(90, 8), work(90, 8, done: false)], last: [before(80, 8), before(80, 8, done: false)]))
        XCTAssertEqual(LiftResults.spoken(skipped, frame: .today),
                       "Pull-ups, 90 pounds. Today: 1 of 2 sets hit the goal, 1 not done. Last time: 1 of 2, 1 not done. 10 pounds heavier than last time.")

        let first = LiftResults.result(try lift(unit: "lb_each", sets: [work(30, 8)]))
        XCTAssertEqual(LiftResults.spoken(first, frame: .today), "Pull-ups, 30 pounds each. Today: 1 of 1 sets hit the goal.")
    }

    func testTheHeaderAndRowLabelsFollowWhoseWorkoutItIs() {
        XCTAssertEqual(LiftResultsFrame.today.caption, "Today over last time")
        XCTAssertEqual(LiftResultsFrame.today.rowLabel, "Today")
        XCTAssertEqual(LiftResultsFrame.past.caption, "This day over the time before")
        XCTAssertEqual(LiftResultsFrame.past.rowLabel, "Then")
        XCTAssertEqual(LiftResultsFrame.lastLabel, "Last")
    }

    func testEveryLiftWithWorkSetsGetsARowInTheWorkoutsOrder() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BodyModelsTests.fixture("session.json")) as? [String: Any])
        var exercises = try XCTUnwrap(object["exercises"] as? [[String: Any]])
        // Strict press with only a warm-up set: no work sets, so no row.
        exercises[5]["sets"] = [["kind": "warm", "weight": 45, "reps": 8, "done": true] as [String: Any]]
        object["exercises"] = exercises
        let session = try PrepDecoding.decode(BodySession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(LiftResults.results(session).map(\.id), [
            "curl-up", "side-plank", "bird-dog", "band-pull-apart",
            "incline-bench", "db-bench", "bench-dips", "lateral-raise", "chest-fly", "suitcase-carry",
        ], "the warm-up's lifts are rows too")
    }
}

/// A Body client for a reopened workout: `session(id:)` answers from a script, and every call is logged.
private final class FakeReopenClient: BodyDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    private var _saved: [BodySession] = []

    /// One result per `session(id:)` call; the last repeats.
    var sessionResults: [Result<BodySession, Error>] = []
    var finishResult: Result<BodyFinishResult, Error> = .failure(URLError(.badServerResponse))

    var log: [String] { lock.withLock { _log } }
    var saved: [BodySession] { lock.withLock { _saved } }

    func session(id: String) async throws -> BodySession {
        try lock.withLock {
            _log.append("session:\(id)")
            guard !sessionResults.isEmpty else { throw URLError(.badServerResponse) }
            return try (sessionResults.count > 1 ? sessionResults.removeFirst() : sessionResults[0]).get()
        }
    }

    func save(_ session: BodySession) async throws -> BodySession {
        lock.withLock {
            _log.append("save")
            _saved.append(session)
        }
        return session
    }

    func finish(id: String, check: BodyCheck) async throws -> BodyFinishResult {
        lock.withLock { _log.append("finish:\(id)") }
        return try finishResult.get()
    }

    func prescription(day: String?) async throws -> BodyPrescription {
        lock.withLock { _log.append("prescription") }
        throw URLError(.unsupportedURL)
    }

    func home() async throws -> BodyHome { throw URLError(.unsupportedURL) }
    func sessions(before: String?) async throws -> [BodySessionSummary] { throw URLError(.unsupportedURL) }
    func lift(id: String) async throws -> BodyLift { throw URLError(.unsupportedURL) }
    func plan() async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal { throw URLError(.unsupportedURL) }
    func sleepHistory() async throws -> SleepHistory? { throw URLError(.unsupportedURL) }
}

/// A workout that saved itself: the new fields decode, its page says so, and it reopens by id.
@MainActor
final class BodyAutoSaveTests: XCTestCase {
    private let id = "2026-11-23-push"
    private let dips = 7

    /// The session fixture as the server leaves a workout it closed itself: no check, and the last
    /// lift's sets never ticked. `edit` changes the document before it decodes.
    private func savedItself(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> BodySession {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BodyModelsTests.fixture("session.json")) as? [String: Any])
        object["auto_finished"] = true
        object["check"] = NSNull()
        var exercises = try XCTUnwrap(object["exercises"] as? [[String: Any]])
        var sets = try XCTUnwrap(exercises[dips]["sets"] as? [[String: Any]])
        for index in sets.indices { sets[index]["done"] = false }
        exercises[dips]["sets"] = sets
        object["exercises"] = exercises
        edit(&object)
        return try PrepDecoding.decode(BodySession.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func reopened(_ client: FakeReopenClient) async -> WorkoutViewModel {
        let vm = WorkoutViewModel(client: client, sessionID: id, debounce: .zero)
        await vm.load()
        return vm
    }

    // MARK: Decoding

    func testAutoFinishedDecodesOnTheSessionAndItsSummary() throws {
        XCTAssertTrue(try savedItself().autoFinished)
        XCTAssertFalse(try PrepDecoding.decode(BodySession.self, from: BodyModelsTests.fixture("session.json")).autoFinished,
                       "absent on older documents")
        XCTAssertFalse(try savedItself { $0["auto_finished"] = "yes" }.autoFinished, "a wrong type reads as false")

        let json = #"[{"id":"a","day":"push","label":"Push","date":"2026-11-16","minutes":26,"auto_finished":true},"#
            + #"{"id":"b","day":"pull","label":"Pull","date":"2026-11-14","minutes":40}]"#
        let rows = try PrepDecoding.decode([BodySessionSummary].self, from: Data(json.utf8))
        XCTAssertEqual(rows.map(\.autoFinished), [true, false])
        XCTAssertTrue(BodyHomeCopy.sessionSubtitle(rows[0]).hasSuffix("26 min · saved itself"))
        XCTAssertTrue(BodyHomeCopy.sessionSubtitle(rows[1]).hasSuffix("40 min"))
    }

    func testLastSetsDecodeAnOptionalDone() throws {
        let sets = try PrepDecoding.decode([BodyLastSet].self, from: Data(
            #"[{"weight":140,"reps":8,"done":true},{"weight":140,"reps":8,"done":false},{"weight":140,"reps":8}]"#.utf8))
        XCTAssertEqual(sets.map(\.done), [true, false, nil])
    }

    func testAutoFinishedGoesBackOnTheWireInSnakeCase() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase  // what APIClient.sendData(body:) uses
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(try savedItself())) as? [String: Any])
        XCTAssertEqual(object["auto_finished"] as? Bool, true)
    }

    // MARK: The past workout's page

    func testOutcomeSaysWhatHowItWentShows() throws {
        XCTAssertEqual(BodySessionCopy.outcome(try savedItself()), .savedItself)
        let checked = try PrepDecoding.decode(BodySession.self, from: BodyModelsTests.fixture("session.json"))
        XCTAssertEqual(BodySessionCopy.outcome(checked), .checked(try XCTUnwrap(checked.check)),
                       "a workout he finished never offers Reopen")
        XCTAssertEqual(BodySessionCopy.outcome(try savedItself { $0["auto_finished"] = false }), .unchecked)
        let open = try savedItself {
            $0["auto_finished"] = false
            $0["finished"] = NSNull()
        }
        XCTAssertEqual(BodySessionCopy.outcome(open), .open, "reopened and left: it can be continued")
    }

    func testSavedItselfNoteNamesTheTimeOfTheLastSet() {
        let note = BodySessionCopy.savedItselfNote(finished: "2026-11-16T08:24:00", locale: Locale(identifier: "en_US"))
        XCTAssertTrue(note.hasPrefix("It saved itself at your last set, 8:24"), note)
        XCTAssertTrue(note.hasSuffix("AM. Reopen it to add sets or say how it went."), note)
        XCTAssertEqual(BodySessionCopy.savedItselfNote(finished: nil),
                       "It saved itself at your last set. Reopen it to add sets or say how it went.")
        XCTAssertEqual(BodySessionCopy.savedItselfNote(finished: "soon"),
                       "It saved itself at your last set. Reopen it to add sets or say how it went.")
    }

    func testThePageReadsTheWorkoutAgainOnTheWayBack() async throws {
        let client = FakeReopenClient()
        let finished = try PrepDecoding.decode(BodySession.self, from: BodyModelsTests.fixture("session.json"))
        client.sessionResults = [.success(try savedItself()), .success(finished)]
        let page = BodySessionViewModel(client: client, id: id)
        await page.load()
        guard case .loaded(let first) = page.state else { return XCTFail("expected the workout, got \(page.state)") }
        XCTAssertEqual(BodySessionCopy.outcome(first), .savedItself)

        await page.load()   // the screen appears again after the reopened workout was finished
        guard case .loaded(let second) = page.state else { return XCTFail("expected the workout, got \(page.state)") }
        XCTAssertEqual(BodySessionCopy.outcome(second), .checked(try XCTUnwrap(finished.check)))
    }

    // MARK: Reopening

    func testReopenLoadsTheSavedWorkoutByItsID() async throws {
        let client = FakeReopenClient()
        client.sessionResults = [.success(try savedItself())]
        let vm = await reopened(client)
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(client.log, ["session:\(id)"], "the saved workout, never a fresh prescription")
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.exercises.count, 11)
        XCTAssertEqual(session.exercises[4].sets.map(\.done), [true, true, true, true, true, true], "his ticks are kept")
        XCTAssertEqual(vm.current, dips, "it opens on the first lift he didn't finish")
        XCTAssertEqual(vm.saveStatus, .saved)
        XCTAssertEqual(vm.sleepBanner, .hidden)
        XCTAssertEqual(vm.hingeBanner, .hidden)
        XCTAssertFalse(session.autoFinished, "what it sends is an open workout")
    }

    func testTickingASetSavesTheReopenedWorkout() async throws {
        let client = FakeReopenClient()
        client.sessionResults = [.success(try savedItself())]
        let vm = await reopened(client)
        vm.toggle(exercise: dips, set: 0)
        await vm.idle()
        XCTAssertEqual(client.log, ["session:\(id)", "save"])
        XCTAssertEqual(client.saved.last?.id, id)
        XCTAssertEqual(client.saved.last?.exercises[dips].sets.first?.done, true)
        XCTAssertEqual(client.saved.last?.autoFinished, false)
        XCTAssertEqual(vm.saveStatus, .saved)
    }

    func testAFailedReopenLoadCanBeTriedAgain() async throws {
        let client = FakeReopenClient()
        client.sessionResults = [.failure(URLError(.timedOut)), .success(try savedItself())]
        let vm = await reopened(client)
        guard case .failed = vm.state else { return XCTFail("expected a failure, got \(vm.state)") }
        await vm.load()
        XCTAssertEqual(vm.session?.id, id)
    }

    func testAWorkoutTheServerNoLongerHasIsUnavailable() async {
        let client = FakeReopenClient()
        client.sessionResults = [.failure(APIError.http(statusCode: 404, body: nil))]
        let vm = await reopened(client)
        guard case .unavailable = vm.state else { return XCTFail("expected unavailable, got \(vm.state)") }
    }

    func testFinishingAnUntouchedReopenedWorkoutSendsOnlyTheCheck() async throws {
        let client = FakeReopenClient()
        client.sessionResults = [.success(try savedItself())]
        client.finishResult = .success(
            try PrepDecoding.decode(BodyFinishResult.self, from: BodyModelsTests.fixture("finish.json")))
        let vm = await reopened(client)
        let result = await vm.finish(check: BodyCheck())
        XCTAssertNotNil(result)
        XCTAssertEqual(client.log, ["session:\(id)", "finish:\(id)"],
                       "the server has it already: no save, so it keeps the time it saved itself")
        XCTAssertEqual(vm.saveStatus, .finished)
    }

    func testFinishingAfterAddingSetsSavesThemFirst() async throws {
        let client = FakeReopenClient()
        client.sessionResults = [.success(try savedItself())]
        client.finishResult = .success(
            try PrepDecoding.decode(BodyFinishResult.self, from: BodyModelsTests.fixture("finish.json")))
        let vm = await reopened(client)
        vm.toggle(exercise: dips, set: 0)
        _ = await vm.finish(check: BodyCheck())
        XCTAssertEqual(client.log, ["session:\(id)", "save", "finish:\(id)"])
    }

    func testAWorkoutHeFinishedByHandStaysClosed() async throws {
        let client = FakeReopenClient()
        client.sessionResults = [.success(
            try PrepDecoding.decode(BodySession.self, from: BodyModelsTests.fixture("session.json")))]
        let vm = await reopened(client)
        XCTAssertEqual(vm.saveStatus, .finished)
        vm.toggle(exercise: 0, set: 0)
        await vm.idle()
        XCTAssertEqual(client.log, ["session:\(id)"], "nothing is sent: the server would answer 409")
    }
}
