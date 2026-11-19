import XCTest
@testable import HermesMobile

/// A Body client for the Form page: a scripted lift, and cue picks that record what was sent and
/// can wait on a gate so a test sees the page while the pick is out.
private final class FakeFormClient: BodyDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _picks: [String] = []

    var liftResult: Result<BodyLift, Error> = .failure(URLError(.badServerResponse))
    var pickResult: Result<BodyForm, Error> = .failure(URLError(.badServerResponse))
    var pickGate: AsyncStream<Void>?
    var pickStarted: AsyncStream<Void>.Continuation?

    var picks: [String] { lock.withLock { _picks } }

    func lift(id: String) async throws -> BodyLift { try liftResult.get() }

    func pickCue(lift: String, index: Int) async throws -> BodyForm {
        lock.withLock { _picks.append("\(lift)=\(index)") }
        pickStarted?.yield()
        if let pickGate { for await _ in pickGate { break } }
        return try pickResult.get()
    }

    func home() async throws -> BodyHome { throw URLError(.unsupportedURL) }
    func prescription(day: String?) async throws -> BodyPrescription { throw URLError(.unsupportedURL) }
    func save(_ session: BodySession) async throws -> BodySession { throw URLError(.unsupportedURL) }
    func finish(id: String, check: BodyCheck) async throws -> BodyFinishResult { throw URLError(.unsupportedURL) }
    func session(id: String) async throws -> BodySession { throw URLError(.unsupportedURL) }
    func sessions(before: String?) async throws -> [BodySessionSummary] { throw URLError(.unsupportedURL) }
    func plan() async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan { throw URLError(.unsupportedURL) }
    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal { throw URLError(.unsupportedURL) }
    func sleepHistory() async throws -> SleepHistory? { throw URLError(.unsupportedURL) }
}

/// A lift's form card as the server sends it, with one malformed fault.
private enum FormFixture {
    static let json = #"""
    {"lift": "pull-ups",
     "setup": "Overhand grip a little wider than your shoulders.",
     "cues": ["Pull the bar to your chest", "Drive your elbows down to the floor", "Snap the bar in half"],
     "picked": 0,
     "faults": [{"fault": "Swinging", "fix": "Legs together, glutes tight."}, "not a fault"],
     "feel": ["Lats", "Grip"],
     "safety": "Keep your shoulder blades lightly set between reps.",
     "sources": [{"title": "ExRx", "url": "https://exrx.net/WeightExercises/LatissimusDorsi/BWPullup"}],
     "focus": {"title": "Pace the first set", "body": "Leave two in the tank.", "checks": ["mostly"], "retired": false}}
    """#

    static var form: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }
}

/// The Form page: a lift's cue card, and picking a cue with the page showing it at once.
@MainActor
final class LiftFormViewModelTests: XCTestCase {
    private func lift(form: [String: Any]? = FormFixture.form, edit: (inout [String: Any]) -> Void = { _ in }) throws -> BodyLift {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BodyModelsTests.fixture("lift.json")) as? [String: Any])
        if let form { object["form"] = form }
        edit(&object)
        return try PrepDecoding.decode(BodyLift.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func decodedForm(_ edit: (inout [String: Any]) -> Void) throws -> BodyForm {
        var object = FormFixture.form
        edit(&object)
        return try PrepDecoding.decode(BodyForm.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func loaded(_ client: FakeFormClient) async -> LiftFormViewModel {
        let vm = LiftFormViewModel(client: client, id: "pull-ups")
        await vm.load()
        return vm
    }

    func testLoadsTheLiftsForm() async throws {
        let client = FakeFormClient()
        client.liftResult = .success(try lift())
        let vm = await loaded(client)
        let form = try XCTUnwrap(vm.lift?.form)
        XCTAssertEqual(form.cues.count, 3)
        XCTAssertEqual(form.picked, 0)
        XCTAssertEqual(form.faults.map(\.fault), ["Swinging"], "a malformed fault is skipped, the rest stay")
        XCTAssertEqual(form.focus?.title, "Pace the first set")
        XCTAssertEqual(form.focus?.checks, ["mostly"])
        XCTAssertEqual(form.sources.first?.title, "ExRx")
    }

    func testALiftWithoutACueCardLoadsWithNoForm() async throws {
        let client = FakeFormClient()
        client.liftResult = .success(try lift(form: nil))
        let vm = await loaded(client)
        XCTAssertNotNil(vm.lift)
        XCTAssertNil(vm.lift?.form, "the fixture has no form: the page says so instead of failing")
    }

    func testAMissingLiftIsUnavailableAndAFailureCanRetry() async throws {
        let client = FakeFormClient()
        client.liftResult = .failure(APIError.http(statusCode: 404, body: nil))
        var vm = await loaded(client)
        XCTAssertEqual(vm.state, .unavailable)

        client.liftResult = .failure(URLError(.timedOut))
        vm = await loaded(client)
        guard case .failed = vm.state else { return XCTFail("expected a failure, got \(vm.state)") }
        client.liftResult = .success(try lift())
        await vm.load()
        XCTAssertNotNil(vm.lift?.form)
    }

    func testPickingACueShowsAtOnceThenTakesTheServersForm() async throws {
        let client = FakeFormClient()
        client.liftResult = .success(try lift())
        client.pickResult = .success(try decodedForm { form in
            form["picked"] = 2
            form["focus"] = ["title": "Snap the bar in half", "body": "One cue at a time."]
        })
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        client.pickGate = gate
        client.pickStarted = startedContinuation
        let vm = await loaded(client)

        let pick = Task { await vm.pick(2) }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        XCTAssertEqual(vm.lift?.form?.picked, 2, "the page shows the pick while it is on its way")
        XCTAssertEqual(vm.picking, 2)
        XCTAssertEqual(vm.lift?.form?.focus?.title, "Pace the first set", "the rest waits for the server")

        release.yield()
        await pick.value
        XCTAssertNil(vm.picking)
        XCTAssertNil(vm.pickError)
        XCTAssertEqual(vm.lift?.form?.picked, 2)
        XCTAssertEqual(vm.lift?.form?.focus?.title, "Snap the bar in half", "the server's form replaces the page's")
        XCTAssertEqual(client.picks, ["pull-ups=2"])
    }

    func testAFailedPickGoesBackToTheOldCue() async throws {
        let client = FakeFormClient()
        client.liftResult = .success(try lift())
        client.pickResult = .failure(URLError(.timedOut))
        let vm = await loaded(client)
        await vm.pick(1)
        XCTAssertEqual(vm.lift?.form?.picked, 0, "the old cue is back")
        XCTAssertNotNil(vm.pickError)
        XCTAssertNil(vm.picking)

        client.pickResult = .success(try decodedForm { $0["picked"] = 1 })
        await vm.pick(1)
        XCTAssertEqual(vm.lift?.form?.picked, 1)
        XCTAssertNil(vm.pickError, "the next pick clears the error")
    }

    func testPickPostsTheCueCardsKeyNotTheLiftsId() async throws {
        let client = FakeFormClient()
        // On an alternate week the split squat's page shows the reverse lunge's card.
        var alternate = FormFixture.form
        alternate["lift"] = "reverse-lunge"
        client.liftResult = .success(try lift(form: alternate) { $0["id"] = "split-squat" })
        client.pickResult = .success(try decodedForm { $0["picked"] = 1 })
        let vm = await loaded(client)
        await vm.pick(1)
        XCTAssertEqual(client.picks, ["reverse-lunge=1"])

        // A server that doesn't name the card: the lift's own id.
        var unnamed = FormFixture.form
        unnamed["lift"] = nil
        client.liftResult = .success(try lift(form: unnamed) { $0["id"] = "db-row" })
        let other = await loaded(client)
        await other.pick(1)
        XCTAssertEqual(client.picks.last, "db-row=1")
    }

    func testPickingTheSameCueOrOneItDoesNotHaveSendsNothing() async throws {
        let client = FakeFormClient()
        client.liftResult = .success(try lift())
        let vm = await loaded(client)
        await vm.pick(0)
        await vm.pick(7)
        await vm.pick(-1)
        XCTAssertEqual(client.picks, [])
        XCTAssertEqual(vm.lift?.form?.picked, 0)
    }

    func testSafetyHeaderFollowsWhatTheLiftLoads() throws {
        XCTAssertEqual(WorkoutCoach.safetyHeader(loads: ["lower_back"]), "Guard your back")
        XCTAssertEqual(WorkoutCoach.safetyHeader(loads: ["shoulders"]), "Guard your shoulders")
        XCTAssertEqual(WorkoutCoach.safetyHeader(loads: ["shoulder_blades"]), "Guard your shoulders")
        XCTAssertEqual(WorkoutCoach.safetyHeader(loads: ["shoulders", "shoulder_blades"]), "Guard your shoulders")
        XCTAssertEqual(WorkoutCoach.safetyHeader(loads: ["lower_back", "shoulders"]), "Stay safe")
        XCTAssertEqual(WorkoutCoach.safetyHeader(loads: []), "Stay safe", "a server that doesn't say")
        XCTAssertEqual(LiftFormCopy.loads(try lift { $0["loads"] = ["lower_back"] }), ["lower_back"])
        var withLoads = FormFixture.form
        withLoads["loads"] = ["shoulders"]
        XCTAssertEqual(LiftFormCopy.loads(try lift(form: withLoads) { $0["loads"] = ["lower_back"] }), ["shoulders"],
                       "the form's own areas win")
        XCTAssertEqual(LiftFormCopy.cueLabel("Snap the bar in half", index: 2), "Cue 3: Snap the bar in half")
    }
}
