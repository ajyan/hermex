import XCTest
@testable import HermesMobile

/// A Body client for the coached workout: a scripted prescription, and saves and finishes that
/// record what was sent.
private final class FakeCoachClient: BodyDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: [BodySession] = []
    private var _log: [String] = []

    var prescriptionResult: Result<BodyPrescription, Error> = .failure(URLError(.badServerResponse))
    var finishResult: Result<BodyFinishResult, Error> = .failure(URLError(.badServerResponse))

    var saved: [BodySession] { lock.withLock { _saved } }
    var log: [String] { lock.withLock { _log } }

    func prescription(day: String?) async throws -> BodyPrescription {
        lock.withLock { _log.append("prescription") }
        return try prescriptionResult.get()
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

    func home() async throws -> BodyHome { throw URLError(.unsupportedURL) }
    func session(id: String) async throws -> BodySession { throw URLError(.unsupportedURL) }
    func sessions(before: String?) async throws -> [BodySessionSummary] { throw URLError(.unsupportedURL) }
    func lift(id: String) async throws -> BodyLift { throw URLError(.unsupportedURL) }
    func plan() async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal { throw URLError(.unsupportedURL) }
    func sleepHistory() async throws -> SleepHistory? { throw URLError(.unsupportedURL) }
    func pickCue(lift: String, index: Int) async throws -> BodyForm { throw URLError(.unsupportedURL) }
}

/// The synthetic prescriptions in `Fixtures/Body/`, as a server with Baki's coaching sends them:
/// every lift says what it `loads`, and tests add a `coach`, `adjustments` or a saved answer.
private enum CoachFixture {
    static let lowerBack = ["goblet-squat", "db-rdl", "split-squat"]

    static let adjustments = #"""
    [{"id": "move-up:db-row", "kind": "move_up", "lift": "db-row", "after": "pull-ups",
      "title": "DB row got skipped the last 3 pull days", "question": "Do it second today, before the pulldown?",
      "use": "Move it up", "keep": "Keep the order", "done": "DB row moved to second."},
     {"id": "cap-first:pull-ups", "kind": "cap_first", "lift": "pull-ups", "reps": 7,
      "title": "Pull-ups went 9, 5, 3, 2 last time", "question": "Stop the first set at 7 so the rest hold up?",
      "use": "Cap set 1 at 7", "keep": "Go by feel", "done": "Set 1 capped at 7."}]
    """#

    static let pace = #"""
    {"cue": "Pull the bar to your chest", "focus": "pace", "title": "Pace the first set",
     "plan": "Stop set 1 at 7 with two left. Going to 9 last time cost you sets 2 to 4.",
     "ask": "Did you pace set 1?", "checks": ["mostly"], "retired": false, "film": false, "leave": 2}
    """#

    static let cue = #"""
    {"cue": "Elbows to your back pockets", "focus": "cue", "title": "Your cue", "plan": null,
     "ask": "Did the cue land?", "checks": [], "retired": false, "film": false, "leave": 1}
    """#

    static func json(_ text: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? NSNull()
    }

    /// A fixture as a JSON object with `loads` on every lift (the lower-back lifts on a legs day),
    /// after `edit`.
    static func object(_ name: String, edit: (inout [String: Any]) -> Void = { _ in }) throws -> [String: Any] {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BodyModelsTests.fixture(name)) as? [String: Any])
        var exercises = try XCTUnwrap(object["exercises"] as? [[String: Any]])
        for index in exercises.indices {
            let id = exercises[index]["id"] as? String ?? ""
            exercises[index]["loads"] = lowerBack.contains(id) ? ["lower_back"] : [String]()
        }
        object["exercises"] = exercises
        edit(&object)
        return object
    }

    static func prescription(_ name: String, edit: (inout [String: Any]) -> Void = { _ in }) throws -> BodyPrescription {
        try PrepDecoding.decode(BodyPrescription.self, from: JSONSerialization.data(withJSONObject: object(name, edit: edit)))
    }

    /// Changes one lift of a prescription object.
    static func lift(_ id: String, in object: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        guard var exercises = object["exercises"] as? [[String: Any]],
              let index = exercises.firstIndex(where: { $0["id"] as? String == id }) else { return }
        change(&exercises[index])
        object["exercises"] = exercises
    }

    /// Marks sets of one lift done, by their place in its sets.
    static func tick(_ id: String, sets ticked: [Int], in object: inout [String: Any]) {
        lift(id, in: &object) { exercise in
            guard var sets = exercise["sets"] as? [[String: Any]] else { return }
            for index in ticked where sets.indices.contains(index) { sets[index]["done"] = true }
            exercise["sets"] = sets
        }
    }
}

// MARK: - Decoding

/// Everything Baki's coaching adds to the wire is optional: present it decodes, absent nothing
/// changes, and a value this build doesn't know never fails a document.
final class BodyCoachModelsTests: XCTestCase {
    func testAbsentFieldsLeaveTodaysDocuments() throws {
        let prescription = try PrepDecoding.decode(BodyPrescription.self, from: BodyModelsTests.fixture("prescription.json"))
        XCTAssertNil(prescription.adjustments)
        XCTAssertNil(prescription.adjustmentAnswers)
        XCTAssertNil(prescription.bodyCheck)
        XCTAssertNil(prescription.saved, "a fresh prescription is not a saved workout")
        XCTAssertTrue(prescription.exercises.allSatisfy { $0.coach == nil && $0.loads == nil && $0.focusCheck == nil })
        XCTAssertTrue(prescription.exercises.allSatisfy { lift in lift.sets.allSatisfy { $0.left == nil } })
        XCTAssertFalse(WorkoutCoach.offersBodyCheck(prescription.exercises), "no body check on a server without loads")

        let home = try PrepDecoding.decode(BodyHome.self, from: BodyModelsTests.fixture("home.json"))
        XCTAssertEqual(home.watching, [])
        let lift = try PrepDecoding.decode(BodyLift.self, from: BodyModelsTests.fixture("lift.json"))
        XCTAssertNil(lift.form)
        XCTAssertEqual(lift.loads, [])

        // Saving an old document adds none of the new keys.
        let session = try PrepDecoding.decode(BodySession.self, from: BodyModelsTests.fixture("session.json"))
        let sent = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        for key in ["adjustments", "adjustment_answers", "body_check", "coach", "focus_check", "loads", "left"] {
            XCTAssertFalse(sent.contains("\"\(key)\""), "\(key) appears in a document that never had it")
        }
    }

    func testPrescriptionDecodesCoachAdjustmentsLoadsAndTheBodyCheck() throws {
        let prescription = try CoachFixture.prescription("prescription-pull.json") { object in
            object["adjustments"] = CoachFixture.json(CoachFixture.adjustments)
            object["adjustment_answers"] = ["move-up:db-row": "keep"]
            object["body_check"] = ["area": "shoulder_blades", "score": 3, "removed": [String]()] as [String: Any]
            CoachFixture.lift("pull-ups", in: &object) { lift in
                lift["coach"] = CoachFixture.json(CoachFixture.pace)
                lift["focus_check"] = "mostly"
                lift["loads"] = ["shoulders", "shoulder_blades"]
                var sets = lift["sets"] as? [[String: Any]] ?? []
                sets[0]["left"] = 2
                lift["sets"] = sets
            }
        }
        XCTAssertEqual(prescription.adjustments?.map(\.id), ["move-up:db-row", "cap-first:pull-ups"])
        let move = try XCTUnwrap(prescription.adjustments?.first)
        XCTAssertEqual(move.kind, BodyAdjustment.moveUp)
        XCTAssertEqual(move.after, "pull-ups")
        XCTAssertEqual(move.use, "Move it up")
        XCTAssertEqual(prescription.adjustments?.last?.reps, 7)
        XCTAssertEqual(prescription.adjustmentAnswers, ["move-up:db-row": "keep"])
        XCTAssertEqual(prescription.bodyCheck, BodyDayCheck(area: .shoulderBlades, score: 3))

        let pullUps = try XCTUnwrap(prescription.exercises.first { $0.id == "pull-ups" })
        let coach = try XCTUnwrap(pullUps.coach)
        XCTAssertEqual(coach.cue, "Pull the bar to your chest")
        XCTAssertTrue(coach.isPace)
        XCTAssertEqual(coach.ask, "Did you pace set 1?")
        XCTAssertEqual(coach.checks, ["mostly"])
        XCTAssertEqual(coach.leave, 2)
        XCTAssertFalse(coach.retired)
        XCTAssertEqual(pullUps.focusCheck, "mostly")
        XCTAssertEqual(pullUps.loads, ["shoulders", "shoulder_blades"])
        XCTAssertEqual(pullUps.sets[0].left, 2)
        XCTAssertEqual(prescription.exercises.first { $0.id == "db-row" }?.loads, [], "loads nothing is still an answer")
    }

    func testUnknownValuesNeverFailADocument() throws {
        let prescription = try CoachFixture.prescription("prescription-pull.json") { object in
            object["adjustments"] = [
                ["id": "swap:x", "kind": "swap", "lift": "db-row", "title": "A kind from the future"] as [String: Any],
                "not an adjustment",
            ] as [Any]
            object["adjustment_answers"] = "nope"
            object["body_check"] = ["area": "knee", "score": "bad"] as [String: Any]
            CoachFixture.lift("pull-ups", in: &object) { lift in
                lift["coach"] = ["cue": "Chest up", "focus": "tempo", "checks": ["yes", "maybe"], "leave": "two"] as [String: Any]
                lift["focus_check"] = 4
                lift["loads"] = "everything"
                var sets = lift["sets"] as? [[String: Any]] ?? []
                sets[0]["left"] = "many"
                lift["sets"] = sets
            }
        }
        XCTAssertEqual(prescription.adjustments?.map(\.kind), ["swap"], "a malformed adjustment is skipped")
        XCTAssertNil(prescription.adjustmentAnswers)
        XCTAssertEqual(prescription.bodyCheck?.area, "knee")
        XCTAssertNil(prescription.bodyCheck?.bodyArea, "an area this build doesn't know shows no line")
        XCTAssertEqual(prescription.bodyCheck?.score, 0)
        let pullUps = try XCTUnwrap(prescription.exercises.first { $0.id == "pull-ups" })
        let coach = try XCTUnwrap(pullUps.coach)
        XCTAssertFalse(coach.isPace, "an unknown focus reads as a cue")
        XCTAssertNil(coach.leave)
        XCTAssertEqual(coach.ask, "")
        XCTAssertFalse(WorkoutCoach.asksFocus(pullUps), "no question without the coach's words for it")
        XCTAssertEqual(WorkoutCoach.focusPips(coach.checks), [.hit, .notDone, .notDone])
        XCTAssertNil(pullUps.focusCheck)
        XCTAssertNil(pullUps.loads)
        XCTAssertNil(pullUps.sets[0].left)

        // An adjustment of a kind this build can't apply asks nothing.
        var session = BodySession(id: prescription.id, day: prescription.day, exercises: prescription.exercises)
        session.adjustments = prescription.adjustments
        XCTAssertEqual(WorkoutCoach.adjustmentRows(session) { _ in true }, [])
    }

    func testTheSessionSavesWhatTheAppWrote() throws {
        let prescription = try CoachFixture.prescription("prescription-pull.json") { object in
            object["adjustments"] = CoachFixture.json(CoachFixture.adjustments)
            CoachFixture.lift("pull-ups", in: &object) { $0["coach"] = CoachFixture.json(CoachFixture.pace) }
        }
        var session = BodySession(id: prescription.id, day: prescription.day, exercises: prescription.exercises)
        session.adjustments = prescription.adjustments
        session.adjustmentAnswers = ["cap-first:pull-ups": BodyAdjustment.used]
        session.bodyCheck = BodyDayCheck()
        session.exercises[4].sets[0].left = 3
        session.exercises[4].focusCheck = BodyFocusAnswer.no.rawValue

        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        let check = try XCTUnwrap(sent["body_check"] as? [String: Any])
        XCTAssertTrue(check["area"] is NSNull, "all good is written as area null")
        XCTAssertEqual(check["score"] as? Int, 0)
        XCTAssertEqual(check["removed"] as? [String], [])
        XCTAssertEqual(sent["adjustment_answers"] as? [String: String], ["cap-first:pull-ups": "use"])
        XCTAssertEqual((sent["adjustments"] as? [[String: Any]])?.count, 2)
        let pullUps = try XCTUnwrap((sent["exercises"] as? [[String: Any]])?[4])
        XCTAssertEqual(pullUps["focus_check"] as? String, "no")
        XCTAssertEqual((pullUps["coach"] as? [String: Any])?["focus"] as? String, "pace",
                       "the coach rides with the answer, so history knows which focus it was for")
        XCTAssertEqual((pullUps["sets"] as? [[String: Any]])?[0]["left"] as? Int, 3)

        // And it reads back the same.
        XCTAssertEqual(try PrepDecoding.decode(BodySession.self, from: JSONEncoder().encode(session)), session)
    }

    func testHomeDecodesWatchingAndReadsItAloud() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BodyModelsTests.fixture("home.json")) as? [String: Any])
        object["watching"] = [
            ["id": "skipped:db-row", "name": "DB row skipped on pull days", "pips": ["no", "yes", "yes", "yes"],
             "next": "Next Pull asks to move it second."] as [String: Any],
            ["id": "back:pull", "name": "Back tight after pull days", "pips": ["none", "yes", "later", "yes"],
             "next": "Only in notes for now."] as [String: Any],
            ["id": "warmup", "name": "Warm-up skipped"] as [String: Any],
            7,
        ] as [Any]
        let home = try PrepDecoding.decode(BodyHome.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(home.watching.map(\.id), ["skipped:db-row", "back:pull", "warmup"])
        XCTAssertEqual(WorkoutCoach.watchingPips(home.watching[0]), [.short, .hit, .hit, .hit],
                       "yes is filled, no a glow ring")
        XCTAssertEqual(WorkoutCoach.watchingPips(home.watching[1]), [.notDone, .hit, .notDone, .hit],
                       "none and anything unknown are an empty ring")
        XCTAssertEqual(WorkoutCoach.watchingSpoken(home.watching[0]),
                       "DB row skipped on pull days: 3 of the last 4 times. Next Pull asks to move it second.")
        XCTAssertEqual(WorkoutCoach.watchingSpoken(home.watching[1]),
                       "Back tight after pull days: 2 of the last 4 times, 2 unknown. Only in notes for now.",
                       "next is read as sent, whatever it says")
        XCTAssertEqual(WorkoutCoach.watchingCaption(home.watching), "Last 4 times")
        XCTAssertEqual(WorkoutCoach.watchingCaption([home.watching[2]]), "Last time")
        XCTAssertEqual(WorkoutCoach.watchingSpoken(home.watching[2]), "Warm-up skipped.")
    }
}

// MARK: - The workout

/// Baki's coaching on the live workout: the body check, his adjustments, reps left after every
/// set, the focus question, and the words the card shows.
@MainActor
final class WorkoutCoachTests: XCTestCase {
    // Legs: 0–3 the warm-up, 4 goblet squat, 5 DB Romanian deadlift (the hinge), 6 reverse lunge,
    // 7 glute bridge, 8 pallof press, 9 wall sit. The first three main lifts load the lower back.
    private let squat = 4, rdl = 5, lunge = 6
    // Pull: 0–3 the warm-up, 4 pull-ups (goal 8 7 6 6), 5 lat pulldown, 6 DB row, 7 face pull and
    // 8 hammer curl (a superset), 9 farmer carry.
    private let pullUps = 4, pulldown = 5, row = 6, facePull = 7, curl = 8, carry = 9

    private func workout(_ name: String, edit: @escaping (inout [String: Any]) -> Void = { _ in }) async throws
        -> (WorkoutViewModel, FakeCoachClient) {
        let client = FakeCoachClient()
        client.prescriptionResult = .success(try CoachFixture.prescription(name, edit: edit))
        let vm = WorkoutViewModel(client: client, day: nil, debounce: .zero)
        await vm.load()
        XCTAssertNotNil(vm.session, "expected a loaded workout, got \(vm.state)")
        return (vm, client)
    }

    private func ids(_ vm: WorkoutViewModel) -> [String] { vm.session?.exercises.map(\.id) ?? [] }

    private func lift(_ vm: WorkoutViewModel, _ index: Int) -> BodyExercise { vm.session!.exercises[index] }

    private func tickAllWork(_ vm: WorkoutViewModel, _ index: Int) {
        for (j, set) in lift(vm, index).sets.enumerated() where set.kind == .work && !set.done {
            vm.toggle(exercise: index, set: j)
        }
    }

    private func after(_ vm: WorkoutViewModel, _ index: Int, named: Bool = false) -> WorkoutAfterSet {
        let lift = lift(vm, index)
        return WorkoutCoach.afterSet(lift, asked: vm.askedSet(in: lift), named: named)
    }

    // MARK: Body check

    func testTheBodyCheckAsksOnlyOnAFreshWorkoutWhoseServerSendsLoads() async throws {
        let (fresh, _) = try await workout("prescription-legs.json")
        XCTAssertEqual(fresh.coach.bodyCheckBanner, .asking)
        XCTAssertNil(fresh.bodyCheckLine)

        // A server without `loads` knows nothing of the check.
        let client = FakeCoachClient()
        client.prescriptionResult = .success(
            try PrepDecoding.decode(BodyPrescription.self, from: BodyModelsTests.fixture("prescription-legs.json")))
        let old = WorkoutViewModel(client: client, day: nil, debounce: .zero)
        await old.load()
        XCTAssertEqual(old.coach.bodyCheckBanner, .hidden)

        // Resumed with ticks: too late to ask.
        let (resumed, _) = try await workout("prescription-legs.json") { object in
            object["resumed"] = true
            CoachFixture.tick("curl-up", sets: [0], in: &object)
        }
        XCTAssertEqual(resumed.coach.bodyCheckBanner, .hidden)

        // Resumed after answering: the line, not the question.
        let (answered, _) = try await workout("prescription-legs.json") { object in
            object["resumed"] = true
            object["body_check"] = ["area": "shoulders", "score": 2, "removed": [String]()] as [String: Any]
        }
        XCTAssertEqual(answered.coach.bodyCheckBanner, .done)
        XCTAssertEqual(answered.bodyCheckLine, "Shoulders at 2. Baki will keep an eye on it.")
        XCTAssertEqual(answered.bodyCheckAction, .change)

        let (allGood, _) = try await workout("prescription-legs.json") { object in
            object["resumed"] = true
            object["body_check"] = ["area": NSNull(), "score": 0, "removed": [String]()] as [String: Any]
        }
        XCTAssertEqual(allGood.coach.bodyCheckBanner, .hidden, "all good was said: nothing to show")
    }

    func testAllGoodSavesAndGoesAway() async throws {
        let (vm, client) = try await workout("prescription-legs.json")
        vm.answerBodyCheck(area: nil, score: 9)
        XCTAssertEqual(vm.coach.bodyCheckBanner, .hidden)
        XCTAssertEqual(vm.session?.bodyCheck, BodyDayCheck(area: nil, score: 0, removed: []))
        XCTAssertEqual(vm.session?.exercises.count, 10)
        await vm.idle()
        XCTAssertEqual(client.saved.last?.bodyCheck, BodyDayCheck())
        XCTAssertEqual(client.log, ["prescription", "save"], "it goes with the whole-session save")
    }

    func testALowScoreKeepsEveryLiftAndCanChange() async throws {
        let (vm, _) = try await workout("prescription-legs.json")
        vm.answerBodyCheck(area: .lowerBack, score: 2)
        XCTAssertEqual(vm.coach.bodyCheckBanner, .done)
        XCTAssertEqual(vm.session?.bodyCheck, BodyDayCheck(area: .lowerBack, score: 2))
        XCTAssertEqual(vm.session?.exercises.count, 10)
        XCTAssertEqual(vm.bodyCheckLine, "Lower back at 2. Baki will keep an eye on it.")
        XCTAssertEqual(vm.bodyCheckAction, .change)

        vm.changeBodyCheck()
        XCTAssertEqual(vm.coach.bodyCheckBanner, .asking)
        XCTAssertEqual(vm.session?.bodyCheck?.score, 2, "the saved answer stays until he gives a new one")
        vm.answerBodyCheck(area: .shoulders, score: 3)
        XCTAssertEqual(vm.bodyCheckLine, "Shoulders at 3. Baki will keep an eye on it.")
    }

    func testFourOrMoreTakesOutTheLiftsThatLoadTheArea() async throws {
        let (vm, client) = try await workout("prescription-legs.json")
        XCTAssertEqual(vm.hingeBanner, .asking)
        vm.open(exercise: squat)
        vm.answerBodyCheck(area: .lowerBack, score: 4)

        XCTAssertEqual(ids(vm), ["curl-up", "side-plank", "bird-dog", "band-pull-apart",
                                 "sl-glute-bridge", "pallof-press", "wall-sit"])
        XCTAssertEqual(vm.session?.bodyCheck, BodyDayCheck(area: .lowerBack, score: 4, removed: CoachFixture.lowerBack))
        XCTAssertEqual(vm.bodyCheckLine, "Lower back at 4: Goblet squat, DB Romanian deadlift and Reverse lunge "
            + "are out today. They load your lower back.")
        XCTAssertEqual(vm.bodyCheckAction, .putBack)
        XCTAssertEqual(vm.current, 0, "the open lift left, so the first unfinished one opens")
        XCTAssertEqual(vm.hingeBanner, .hidden, "the hinge lift is out: nothing to move")
        await vm.idle()
        XCTAssertEqual(client.saved.last?.exercises.count, 7)
        XCTAssertEqual(client.saved.last?.bodyCheck?.removed, CoachFixture.lowerBack)

        vm.putBackBodyCheckLifts()
        XCTAssertEqual(ids(vm), ["curl-up", "side-plank", "bird-dog", "band-pull-apart", "goblet-squat", "db-rdl",
                                 "split-squat", "sl-glute-bridge", "pallof-press", "wall-sit"],
                       "they return in their places")
        XCTAssertEqual(vm.session?.bodyCheck, BodyDayCheck(area: .lowerBack, score: 4), "the area and score stay")
        XCTAssertEqual(vm.bodyCheckLine, "Lower back at 4. Baki will keep an eye on it.")
        XCTAssertEqual(vm.bodyCheckAction, .change)
        XCTAssertEqual(vm.hingeBanner, .asking, "the hinge offer comes back with its lift")
        XCTAssertEqual(vm.hingeNames, ["DB Romanian deadlift"])
    }

    func testALiftWithATickedSetIsNeverTakenOut() async throws {
        let (vm, _) = try await workout("prescription-legs.json")
        vm.toggle(exercise: squat, set: 0) // a warm-up set of the goblet squat
        vm.answerBodyCheck(area: .lowerBack, score: 6)
        XCTAssertTrue(ids(vm).contains("goblet-squat"))
        XCTAssertEqual(vm.session?.bodyCheck?.removed, ["db-rdl", "split-squat"])
        XCTAssertEqual(vm.bodyCheckLine,
                       "Lower back at 6: DB Romanian deadlift and Reverse lunge are out today. They load your lower back.")
        XCTAssertEqual(vm.session?.exercises[squat].sets[0].done, true, "his tick is kept")
    }

    func testALiftHeldAsideIsTrimmedWithTheRestAndReturnsToItsPlace() async throws {
        let (vm, _) = try await workout("prescription-legs.json") { object in
            // Only the lunge loads the lower back here, so the hinge lift stays and can move.
            CoachFixture.lift("goblet-squat", in: &object) { $0["loads"] = [String]() }
            CoachFixture.lift("db-rdl", in: &object) { $0["loads"] = [String]() }
        }
        vm.answerBodyCheck(area: .lowerBack, score: 5)
        XCTAssertFalse(ids(vm).contains("split-squat"))
        vm.acceptSleepOffer()
        vm.putBackBodyCheckLifts()
        XCTAssertEqual(Array(ids(vm)[squat...lunge + 1]), ["goblet-squat", "db-rdl", "split-squat", "sl-glute-bridge"])
        XCTAssertEqual(lift(vm, lunge).workSets.count, 2, "a lift held aside is trimmed with the rest")
        vm.undoSleepOffer()
        XCTAssertEqual(lift(vm, lunge).workSets.count, 3)
    }

    func testBodyCheckCopy() {
        let names = ["DB Romanian deadlift", "Goblet squat", "Suitcase carry"]
        XCTAssertEqual(WorkoutCoach.bodyCheckLine(area: .lowerBack, score: 2, removed: [], loaded: true),
                       "Lower back at 2. Baki will keep an eye on it.")
        XCTAssertEqual(WorkoutCoach.bodyCheckLine(area: .lowerBack, score: 4, removed: names, loaded: false),
                       "Lower back at 4: DB Romanian deadlift, Goblet squat and Suitcase carry are out today. "
                        + "They load your lower back.")
        XCTAssertEqual(WorkoutCoach.bodyCheckLine(area: .shoulders, score: 5, removed: ["Strict press"], loaded: false),
                       "Shoulders at 5: Strict press is out today. It loads your shoulders.")
        XCTAssertEqual(WorkoutCoach.bodyCheckLine(area: .lowerBack, score: 7, removed: ["Goblet squat", "Suitcase carry"], loaded: false),
                       "Lower back at 7: Goblet squat and Suitcase carry are out today. They load your lower back. "
                        + "At 7, today is better as a rest day. If it isn't easing in a few days, see a physio.")
        XCTAssertEqual(WorkoutCoach.bodyCheckLine(area: .shoulderBlades, score: 4, removed: [], loaded: false),
                       "Shoulder blades at 4. Nothing today loads your shoulder blades.")
        XCTAssertEqual(WorkoutCoach.bodyCheckLine(area: .shoulderBlades, score: 8, removed: [], loaded: false),
                       "Shoulder blades at 8. Nothing today loads your shoulder blades. "
                        + "At 8, today is better as a rest day. If it isn't easing in a few days, see a physio.")
        XCTAssertEqual(WorkoutCoach.bodyCheckLine(area: .lowerBack, score: 5, removed: [], removedCount: 2, loaded: false),
                       "Lower back at 5: the lifts that load your lower back are out today.",
                       "a resumed workout knows they are out, not their names")
        XCTAssertEqual(WorkoutBodyCheckAction.putBack.label, "Put them back")
        XCTAssertEqual(WorkoutBodyCheckAction.change.label, "Change")
    }

    func testAResumedWorkoutWithLiftsOutShowsItsLineWithoutAButton() async throws {
        let (vm, _) = try await workout("prescription-legs.json") { object in
            object["resumed"] = true
            object["body_check"] = ["area": "lower_back", "score": 5, "removed": ["db-rdl"]] as [String: Any]
            object["exercises"] = (object["exercises"] as? [[String: Any]])?.filter { $0["id"] as? String != "db-rdl" }
        }
        XCTAssertEqual(vm.coach.bodyCheckBanner, .done)
        XCTAssertEqual(vm.bodyCheckLine, "Lower back at 5: the lifts that load your lower back are out today.")
        XCTAssertNil(vm.bodyCheckAction, "the phone no longer holds the lift to put back")
        vm.putBackBodyCheckLifts()
        vm.changeBodyCheck()
        XCTAssertEqual(vm.session?.bodyCheck?.removed, ["db-rdl"])
        XCTAssertEqual(vm.coach.bodyCheckBanner, .done)
    }

    // MARK: Adjustments

    private func adjusted(_ edit: @escaping (inout [String: Any]) -> Void = { _ in }) async throws
        -> (WorkoutViewModel, FakeCoachClient) {
        try await workout("prescription-pull.json") { object in
            object["adjustments"] = CoachFixture.json(CoachFixture.adjustments)
            edit(&object)
        }
    }

    func testMoveUpAppliesRecordsAndUndoes() async throws {
        let (vm, client) = try await adjusted()
        XCTAssertEqual(vm.adjustmentRows.map(\.state), [.asking, .asking])
        let before = ids(vm)
        vm.open(exercise: pulldown)

        vm.useAdjustment("move-up:db-row")
        XCTAssertEqual(Array(ids(vm)[pullUps...row]), ["pull-ups", "db-row", "lat-pulldown"])
        XCTAssertEqual(vm.session?.adjustmentAnswers, ["move-up:db-row": "use"])
        XCTAssertEqual(vm.adjustmentRows.first?.state, .done(canUndo: true))
        XCTAssertEqual(lift(vm, vm.current).id, "lat-pulldown", "the open lift stays open")
        await vm.idle()
        XCTAssertEqual(client.saved.last?.adjustmentAnswers, ["move-up:db-row": "use"])
        XCTAssertEqual(client.saved.last?.adjustments?.count, 2, "the adjustments save as they came")

        vm.undoAdjustment("move-up:db-row")
        XCTAssertEqual(ids(vm), before)
        XCTAssertEqual(vm.session?.adjustmentAnswers, [:])
        XCTAssertEqual(vm.adjustmentRows.map(\.state), [.asking, .asking], "the question is back")
    }

    func testCapFirstSetsTheFirstWorkSetAndUndoes() async throws {
        let (vm, _) = try await adjusted()
        vm.useAdjustment("cap-first:pull-ups")
        XCTAssertEqual(lift(vm, pullUps).sets.map(\.reps), [7, 7, 6, 6], "only set 1 changes")
        XCTAssertEqual(vm.session?.adjustmentAnswers, ["cap-first:pull-ups": "use"])
        XCTAssertEqual(vm.adjustmentRows.last?.state, .done(canUndo: true))

        vm.undoAdjustment("cap-first:pull-ups")
        XCTAssertEqual(lift(vm, pullUps).sets.map(\.reps), [8, 7, 6, 6])
        XCTAssertEqual(vm.adjustmentRows.last?.state, .asking)

        // Once set 1 is ticked the cap can't be taken back, and an unanswered cap stops asking.
        vm.useAdjustment("cap-first:pull-ups")
        vm.toggle(exercise: pullUps, set: 0)
        XCTAssertEqual(vm.adjustmentRows.last?.state, .done(canUndo: false))
        vm.undoAdjustment("cap-first:pull-ups")
        XCTAssertEqual(lift(vm, pullUps).sets[0].reps, 7, "a logged set keeps its reps")

        let (late, _) = try await adjusted()
        late.toggle(exercise: pullUps, set: 0)
        XCTAssertEqual(late.adjustmentRows.map(\.id), ["move-up:db-row"])
        late.useAdjustment("cap-first:pull-ups")
        XCTAssertEqual(lift(late, pullUps).sets[0].reps, 8)
    }

    func testKeepRecordsTheAnswerAndTheBannerGoes() async throws {
        let (vm, client) = try await adjusted()
        let before = ids(vm)
        vm.keepAdjustment("move-up:db-row")
        XCTAssertEqual(ids(vm), before)
        XCTAssertEqual(vm.session?.adjustmentAnswers, ["move-up:db-row": "keep"])
        XCTAssertEqual(vm.adjustmentRows.map(\.id), ["cap-first:pull-ups"])
        vm.useAdjustment("move-up:db-row") // answered: nothing more happens
        XCTAssertEqual(ids(vm), before)
        await vm.idle()
        XCTAssertEqual(client.saved.last?.adjustmentAnswers, ["move-up:db-row": "keep"])
    }

    func testAnAdjustmentWhoseLiftIsOutIsSkipped() async throws {
        let (vm, _) = try await adjusted { object in
            CoachFixture.lift("db-row", in: &object) { $0["loads"] = ["shoulder_blades"] }
        }
        vm.answerBodyCheck(area: .shoulderBlades, score: 5)
        XCTAssertFalse(ids(vm).contains("db-row"))
        XCTAssertEqual(vm.adjustmentRows.map(\.id), ["cap-first:pull-ups"])
        vm.useAdjustment("move-up:db-row")
        XCTAssertNil(vm.session?.adjustmentAnswers?["move-up:db-row"])
        vm.putBackBodyCheckLifts()
        XCTAssertEqual(vm.adjustmentRows.map(\.id), ["move-up:db-row", "cap-first:pull-ups"], "it asks again once the lift is back")
    }

    func testAResumedDraftShowsItsAnswersNotTheQuestions() async throws {
        let (vm, _) = try await adjusted { object in
            object["resumed"] = true
            object["adjustment_answers"] = ["move-up:db-row": "use", "cap-first:pull-ups": "use"]
            CoachFixture.lift("pull-ups", in: &object) { lift in
                var sets = lift["sets"] as? [[String: Any]] ?? []
                sets[0]["reps"] = 7
                lift["sets"] = sets
            }
        }
        XCTAssertEqual(vm.adjustmentRows.map(\.state), [.done(canUndo: false), .done(canUndo: true)],
                       "a move can't be put back once the phone forgot where the lift was; a cap goes back to the set's goal")
        vm.undoAdjustment("move-up:db-row")
        XCTAssertEqual(vm.session?.adjustmentAnswers?["move-up:db-row"], "use")
        vm.undoAdjustment("cap-first:pull-ups")
        XCTAssertEqual(lift(vm, pullUps).sets[0].reps, 8)
        XCTAssertNil(vm.session?.adjustmentAnswers?["cap-first:pull-ups"])

        let (kept, _) = try await adjusted { object in
            object["resumed"] = true
            object["adjustment_answers"] = ["move-up:db-row": "keep", "cap-first:pull-ups": "keep"]
        }
        XCTAssertEqual(kept.adjustmentRows, [])
    }

    func testUndoingTheHingeMoveKeepsALiftBakiMovedUp() async throws {
        let (vm, _) = try await workout("prescription-legs.json") { object in
            object["adjustments"] = [[
                "id": "move-up:sl-glute-bridge", "kind": "move_up", "lift": "sl-glute-bridge", "after": "goblet-squat",
                "title": "t", "question": "q", "use": "u", "keep": "k", "done": "d",
            ]]
        }
        vm.moveHinge()
        vm.useAdjustment("move-up:sl-glute-bridge")
        vm.undoMoveHinge()
        XCTAssertEqual(Array(ids(vm)[squat...squat + 3]), ["goblet-squat", "sl-glute-bridge", "db-rdl", "split-squat"])
        vm.undoAdjustment("move-up:sl-glute-bridge")
        XCTAssertEqual(Array(ids(vm)[squat...squat + 3]), ["goblet-squat", "db-rdl", "split-squat", "sl-glute-bridge"])
    }

    // MARK: Reps left

    private func coached() async throws -> (WorkoutViewModel, FakeCoachClient) {
        try await workout("prescription-pull.json") { object in
            CoachFixture.lift("pull-ups", in: &object) { $0["coach"] = CoachFixture.json(CoachFixture.pace) }
            CoachFixture.lift("face-pull", in: &object) { $0["coach"] = CoachFixture.json(CoachFixture.cue) }
        }
    }

    func testEveryTickedRepsSetAsksAndWritesLeft() async throws {
        let (vm, client) = try await coached()
        vm.open(exercise: pullUps)
        XCTAssertTrue(after(vm, pullUps).isEmpty, "nothing to ask before a set is ticked")

        vm.toggle(exercise: pullUps, set: 0)
        XCTAssertEqual(after(vm, pullUps).question, "Set 1: how many more could you have done?")
        XCTAssertEqual(after(vm, pullUps).next, "Next, set 2: 7 reps, leave 2.")
        vm.setRepsLeft(2)
        XCTAssertEqual(lift(vm, pullUps).sets[0].left, 2)
        XCTAssertEqual(after(vm, pullUps).answer, 2)
        XCTAssertNil(lift(vm, pullUps).repsLeft, "a big lift's reps left come from its last set alone")
        XCTAssertEqual(vm.current, pullUps)

        // Answering is never needed: the next set ticks, and the question moves to it.
        vm.toggle(exercise: pullUps, set: 1)
        vm.toggle(exercise: pullUps, set: 2)
        XCTAssertNil(lift(vm, pullUps).sets[1].left)
        XCTAssertEqual(after(vm, pullUps).question, "Set 3: how many more could you have done?")
        vm.setRepsLeft(9)
        XCTAssertEqual(lift(vm, pullUps).sets[2].left, 3, "3 means 3 or more")

        // Unticking a set forgets its answer and takes its question away.
        vm.toggle(exercise: pullUps, set: 2)
        XCTAssertNil(lift(vm, pullUps).sets[2].left)
        XCTAssertNil(after(vm, pullUps).question)
        vm.toggle(exercise: pullUps, set: 0)
        XCTAssertNil(lift(vm, pullUps).sets[0].left)

        await vm.idle()
        XCTAssertEqual(client.saved.last, vm.session, "reps left save with the whole session")
    }

    func testTheLastSetOfABigLiftStillSetsRepsLeft() async throws {
        let (vm, _) = try await workout("prescription-pull.json")
        vm.open(exercise: row)
        tickAllWork(vm, row)
        XCTAssertEqual(vm.effortPrompt, row)
        vm.setRepsLeft(1)
        XCTAssertEqual(lift(vm, row).sets.last?.left, 1)
        XCTAssertEqual(lift(vm, row).repsLeft, 1)
        XCTAssertNil(vm.effortPrompt)
        XCTAssertEqual(lift(vm, vm.current).id, "face-pull")

        // A carry asks nothing and moves on.
        vm.open(exercise: carry)
        tickAllWork(vm, carry)
        XCTAssertNil(vm.effortPrompt)
        XCTAssertTrue(lift(vm, carry).sets.allSatisfy { $0.left == nil })
    }

    // MARK: Focus

    func testTheFocusQuestionFollowsTheLastSetAndSavesWithTheCoach() async throws {
        let (vm, client) = try await coached()
        vm.open(exercise: pullUps)
        tickAllWork(vm, pullUps)
        XCTAssertEqual(vm.effortPrompt, pullUps, "the lift stays open for its questions")
        var row = after(vm, pullUps)
        XCTAssertEqual(row.question, "Set 4: how many more could you have done?")
        XCTAssertNil(row.next, "no set remains")
        XCTAssertEqual(row.focusAsk, "Did you pace set 1?")
        XCTAssertNil(row.focusAnswer)
        XCTAssertEqual(row.praise, "Every set hit its target.")

        vm.setRepsLeft(1)
        XCTAssertEqual(lift(vm, pullUps).repsLeft, 1)
        XCTAssertEqual(vm.current, pullUps, "the focus question is still waiting")
        vm.setFocusCheck(.mostly, exercise: pullUps)
        XCTAssertEqual(lift(vm, pullUps).focusCheck, "mostly")
        XCTAssertNil(vm.effortPrompt)
        XCTAssertEqual(vm.current, pulldown, "both answered: the next lift opens")

        await vm.idle()
        let saved = try XCTUnwrap(client.saved.last?.exercises[pullUps])
        XCTAssertEqual(saved.focusCheck, "mostly")
        XCTAssertEqual(saved.coach?.focus, "pace", "the coach is saved beside the answer")

        // Opened again, the card shows the answer he gave.
        vm.open(exercise: pullUps)
        row = after(vm, pullUps)
        XCTAssertEqual(row.focusAnswer, .mostly)
        XCTAssertNil(row.question)
        vm.setFocusCheck(.yes, exercise: pullUps)
        XCTAssertEqual(lift(vm, pullUps).focusCheck, "yes")
        XCTAssertEqual(vm.current, pullUps, "changing an answer later doesn't jump away")
    }

    func testTheFocusQuestionWaitsForTheLastSetAndARetiredCueAsksNothing() async throws {
        let (vm, _) = try await workout("prescription-pull.json") { object in
            CoachFixture.lift("pull-ups", in: &object) { $0["coach"] = CoachFixture.json(CoachFixture.pace) }
            CoachFixture.lift("lat-pulldown", in: &object) { lift in
                var coach = CoachFixture.json(CoachFixture.cue) as? [String: Any] ?? [:]
                coach["retired"] = true
                lift["coach"] = coach
            }
        }
        vm.open(exercise: pullUps)
        vm.toggle(exercise: pullUps, set: 0)
        XCTAssertNil(after(vm, pullUps).focusAsk)
        vm.setFocusCheck(.yes, exercise: pullUps)
        XCTAssertNil(lift(vm, pullUps).focusCheck, "not before the last set")

        vm.open(exercise: pulldown)
        tickAllWork(vm, pulldown)
        XCTAssertNil(after(vm, pulldown).focusAsk)
        vm.setRepsLeft(2)
        XCTAssertEqual(lift(vm, vm.current).id, "db-row", "only reps left stood between it and the next lift")
    }

    func testASupersetAsksEachLiftByName() async throws {
        let (vm, _) = try await coached()
        vm.open(exercise: facePull)
        vm.toggle(exercise: facePull, set: 0)
        XCTAssertEqual(after(vm, facePull, named: true).name, "Face pull")
        XCTAssertEqual(after(vm, facePull, named: true).next, "Next, set 2: 15 reps, leave 1.")
        vm.toggle(exercise: curl, set: 0)
        XCTAssertTrue(after(vm, facePull, named: true).isEmpty, "the question moved to the set he just ticked")
        XCTAssertEqual(after(vm, curl, named: true).name, "Hammer curl")
        XCTAssertEqual(after(vm, curl, named: true).next, "Next, set 2: 12 reps.", "no coach, so no leave")
        vm.setRepsLeft(0)
        XCTAssertEqual(lift(vm, curl).sets[0].left, 0)
        XCTAssertNil(lift(vm, facePull).sets[0].left)
    }

    // MARK: Copy

    func testNextSetLine() throws {
        let prescription = try CoachFixture.prescription("prescription-pull.json") { object in
            CoachFixture.lift("pull-ups", in: &object) { $0["coach"] = CoachFixture.json(CoachFixture.pace) }
        }
        var pullUps = try XCTUnwrap(prescription.exercises.first { $0.id == "pull-ups" })
        XCTAssertEqual(WorkoutCoach.nextLine(pullUps),
                       "Stop set 1 at 7 with two left. Going to 9 last time cost you sets 2 to 4.",
                       "under a pace focus, set 1 gets the plan")
        pullUps.sets[0].done = true
        XCTAssertEqual(WorkoutCoach.nextLine(pullUps), "Next, set 2: 7 reps, leave 2.")
        pullUps.coach?.leave = nil
        XCTAssertEqual(WorkoutCoach.nextLine(pullUps), "Next, set 2: 7 reps.")
        pullUps.sets[1].reps = 1
        XCTAssertEqual(WorkoutCoach.nextLine(pullUps), "Next, set 2: 1 rep.")
        for index in pullUps.sets.indices { pullUps.sets[index].done = true }
        XCTAssertNil(WorkoutCoach.nextLine(pullUps))
    }

    func testPraiseNamesTheSetsThatHitTheirGoal() throws {
        let prescription = try CoachFixture.prescription("prescription-pull.json")
        var pullUps = try XCTUnwrap(prescription.exercises.first { $0.id == "pull-ups" }) // goal 8 7 6 6
        XCTAssertNil(WorkoutCoach.praise(pullUps), "not before the last set")
        for index in pullUps.sets.indices { pullUps.sets[index].done = true }
        XCTAssertEqual(WorkoutCoach.praise(pullUps), "Every set hit its target.")
        pullUps.sets[2].reps = 5
        pullUps.sets[3].reps = 4
        XCTAssertEqual(WorkoutCoach.praise(pullUps), "Sets 1 and 2 hit their targets.")
        pullUps.sets[1].reps = 3
        XCTAssertEqual(WorkoutCoach.praise(pullUps), "Set 1 hit its target.")
        pullUps.sets[3].reps = 6
        pullUps.sets[2].reps = 6
        XCTAssertEqual(WorkoutCoach.praise(pullUps), "Sets 1, 3 and 4 hit their targets.")
        pullUps.sets[0].reps = 2
        pullUps.sets[2].reps = 2
        pullUps.sets[3].reps = 2
        XCTAssertNil(WorkoutCoach.praise(pullUps), "no set hit: no line")
    }

    func testCueWords() throws {
        let prescription = try CoachFixture.prescription("prescription-pull.json") { object in
            CoachFixture.lift("pull-ups", in: &object) { $0["coach"] = CoachFixture.json(CoachFixture.pace) }
            CoachFixture.lift("face-pull", in: &object) { $0["coach"] = CoachFixture.json(CoachFixture.cue) }
        }
        let pace = try XCTUnwrap(prescription.exercises[pullUps].coach)
        var cue = try XCTUnwrap(prescription.exercises[facePull].coach)
        XCTAssertEqual(WorkoutCoach.cueKicker(pace), "Baki · focus")
        XCTAssertEqual(WorkoutCoach.cueKicker(cue), "Baki · your cue")
        XCTAssertEqual(WorkoutCoach.cueLine(pace), "Stop set 1 at 7 with two left. Going to 9 last time cost you sets 2 to 4.")
        XCTAssertEqual(WorkoutCoach.cueLine(cue), "Leave 1 in the tank.")
        cue.leave = nil
        XCTAssertNil(WorkoutCoach.cueLine(cue))

        XCTAssertEqual(WorkoutCoach.focusPips(["mostly"]), [.short, .notDone, .notDone])
        XCTAssertEqual(WorkoutCoach.focusPips(["yes", "no", "yes"]), [.hit, .notDone, .hit])
        XCTAssertEqual(WorkoutCoach.focusPips(["no", "yes", "yes", "mostly"]), [.hit, .hit, .short], "the newest three")
        XCTAssertEqual(WorkoutCoach.focusPipsSpoken([]), "No checks yet.")
        XCTAssertEqual(WorkoutCoach.focusPipsSpoken(["yes", "no"]), "Earlier checks: yes, not yet.")

        XCTAssertEqual(WorkoutCoach.pairedCue(prescription.exercises[facePull]), "Face pull: Elbows to your back pockets")
        XCTAssertEqual(WorkoutCoach.pairedCue(prescription.exercises[curl]), "Hammer curl")
        XCTAssertEqual(BodyFocusAnswer.allCases.map(\.label), ["Yes", "Mostly", "Not yet"])
    }

    // MARK: A prescription that comes back closed

    func testAWorkoutThatClosedItselfTodayOpensAsItWasAndReopensOnTheFirstSave() async throws {
        let (vm, client) = try await workout("prescription-pull.json") { object in
            object["resumed"] = true
            object["finished"] = "2026-12-02T09:40:00"
            object["auto_finished"] = true
            object["adjustments"] = CoachFixture.json(CoachFixture.adjustments)
            object["hurts"] = [["lift": "pull-ups", "part": "back", "at": "2026-12-02T09:10:00"]]
            object.removeValue(forKey: "offers")
            CoachFixture.tick("pull-ups", sets: [0, 1, 2, 3], in: &object)
        }
        client.finishResult = .success(
            try PrepDecoding.decode(BodyFinishResult.self, from: BodyModelsTests.fixture("finish.json")))
        let session = try XCTUnwrap(vm.session)
        XCTAssertTrue(session.exercises[pullUps].sets.allSatisfy(\.done), "his sets are there, not a fresh sheet")
        XCTAssertEqual(session.hurts.count, 1)
        XCTAssertFalse(session.autoFinished, "what it sends is an open workout")
        XCTAssertEqual(vm.saveStatus, .saved)
        XCTAssertEqual(vm.coach.bodyCheckBanner, .hidden, "a reopened workout shows no offers")
        XCTAssertEqual(vm.adjustmentRows, [])
        XCTAssertEqual(vm.sleepBanner, .hidden)

        vm.toggle(exercise: pulldown, set: 0)
        await vm.idle()
        XCTAssertEqual(client.log, ["prescription", "save"], "the first save reopens it on the server")
        XCTAssertEqual(client.saved.last?.exercises[pullUps].sets.map(\.done), [true, true, true, true])
    }

    func testFinishingAnUntouchedClosedWorkoutSendsOnlyTheCheck() async throws {
        let (vm, client) = try await workout("prescription-pull.json") { object in
            object["resumed"] = true
            object["finished"] = "2026-12-02T09:40:00"
            object["auto_finished"] = true
            CoachFixture.tick("pull-ups", sets: [0], in: &object)
        }
        client.finishResult = .success(
            try PrepDecoding.decode(BodyFinishResult.self, from: BodyModelsTests.fixture("finish.json")))
        let result = await vm.finish(check: BodyCheck())
        XCTAssertNotNil(result)
        XCTAssertEqual(client.log, ["prescription", "finish:2026-12-02-pull"],
                       "no save first, so it keeps the time it closed itself")
    }

    func testAResumedDraftIsTheSavedDocument() async throws {
        let (vm, client) = try await workout("prescription-pull.json") { object in
            object["resumed"] = true
            object["started"] = "2026-12-02T09:00:00"
            object["hurts"] = [["lift": "pull-ups", "part": "back", "at": "2026-12-02T09:10:00"]]
            CoachFixture.tick("pull-ups", sets: [0], in: &object)
        }
        XCTAssertEqual(vm.session?.hurts.count, 1, "what he logged before leaving is still there")
        vm.toggle(exercise: pullUps, set: 1)
        await vm.idle()
        XCTAssertEqual(client.saved.last?.hurts.count, 1)
        XCTAssertEqual(client.saved.last?.started, "2026-12-02T09:00:00")
    }
}
