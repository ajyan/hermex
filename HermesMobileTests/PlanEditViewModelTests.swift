import XCTest
@testable import HermesMobile

/// A Body client for the plan editor and a lift's page: a scripted plan and lift, and a save that
/// records what was sent.
private final class FakePlanClient: BodyDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: [BodyPlan] = []

    var planResult: Result<BodyPlan, Error> = .failure(URLError(.badServerResponse))
    /// What a save answers; nil echoes the sent plan.
    var saveResult: Result<BodyPlan?, Error> = .success(nil)
    var liftResult: Result<BodyLift, Error> = .failure(URLError(.badServerResponse))

    var saved: [BodyPlan] { lock.withLock { _saved } }

    func plan() async throws -> BodyPlan { try planResult.get() }

    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan {
        lock.withLock { _saved.append(plan) }
        return try saveResult.get() ?? plan
    }

    func lift(id: String) async throws -> BodyLift { try liftResult.get() }

    func home() async throws -> BodyHome { throw URLError(.unsupportedURL) }
    func prescription(day: String?) async throws -> BodyPrescription { throw URLError(.unsupportedURL) }
    func save(_ session: BodySession) async throws -> BodySession { throw URLError(.unsupportedURL) }
    func finish(id: String, check: BodyCheck) async throws -> BodyFinishResult { throw URLError(.unsupportedURL) }
    func session(id: String) async throws -> BodySession { throw URLError(.unsupportedURL) }
    func sessions(before: String?) async throws -> [BodySessionSummary] { throw URLError(.unsupportedURL) }
    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal { throw URLError(.unsupportedURL) }
    func sleepHistory() async throws -> SleepHistory? { throw URLError(.unsupportedURL) }
}

@MainActor
final class PlanEditViewModelTests: XCTestCase {
    private func plan() throws -> BodyPlan {
        try PrepDecoding.decode(BodyPlan.self, from: BodyModelsTests.fixture("plan.json"))
    }

    private func loaded(_ client: FakePlanClient = FakePlanClient()) async throws -> PlanEditViewModel {
        client.planResult = .success(try plan())
        let vm = PlanEditViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.phase, .loaded)
        return vm
    }

    private func ids(_ vm: PlanEditViewModel, _ day: String) -> [String] { vm.exercises(day: day).map(\.id) }

    // MARK: Load

    func testLoadsThePlanAndDaysInOrder() async throws {
        let vm = try await loaded()
        XCTAssertEqual(vm.dayKeys, ["warmup", "push", "legs", "pull"])
        XCTAssertFalse(vm.dirty)
    }

    func testNotFoundIsUnavailable() async {
        let client = FakePlanClient()
        client.planResult = .failure(APIError.http(statusCode: 404, body: nil))
        let vm = PlanEditViewModel(client: client)
        await vm.load()
        XCTAssertEqual(vm.phase, .unavailable)
    }

    func testLoadNeverReplacesEdits() async throws {
        let client = FakePlanClient()
        let vm = try await loaded(client)
        vm.remove(day: "push", id: "chest-fly")
        await vm.load()
        XCTAssertFalse(ids(vm, "push").contains("chest-fly"))
    }

    // MARK: Edits

    func testMoveReorders() async throws {
        let vm = try await loaded()
        vm.move(day: "push", from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(ids(vm, "push"), [
            "strict-press", "db-bench", "incline-bench", "bench-dips", "lateral-raise", "chest-fly", "suitcase-carry",
        ])
        XCTAssertTrue(vm.dirty)
    }

    func testMoveWithinASectionKeepsTheOtherSectionsInPlace() async throws {
        let vm = try await loaded()
        // Superset is [bench-dips, lateral-raise] at positions 3 and 4: swap them.
        vm.move(day: "push", section: .superset, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(ids(vm, "push"), [
            "incline-bench", "strict-press", "db-bench", "lateral-raise", "bench-dips", "chest-fly", "suitcase-carry",
        ])
    }

    func testAddGivesUniqueSlugID() async throws {
        let vm = try await loaded()
        let first = vm.add(day: "push", exercise: .draft(name: "Cable Fly!"))
        XCTAssertEqual(first, "cable-fly")
        let second = vm.add(day: "legs", exercise: .draft(name: "cable fly"))
        XCTAssertEqual(second, "cable-fly-2", "ids are unique across every day, not just this one")
        let clash = vm.add(day: "push", exercise: .draft(name: "Incline bench"))
        XCTAssertEqual(clash, "incline-bench-2")
        XCTAssertTrue(ids(vm, "push").contains("incline-bench-2"))
        XCTAssertEqual(vm.add(day: "pull", exercise: .draft(name: "!!!")), "exercise")
    }

    func testAddJoinsItsSectionsGroup() async throws {
        let vm = try await loaded()
        vm.add(day: "push", exercise: .draft(name: "Skull crusher", section: .superset))
        XCTAssertEqual(ids(vm, "push"), [
            "incline-bench", "strict-press", "db-bench", "bench-dips", "lateral-raise", "skull-crusher",
            "chest-fly", "suitcase-carry",
        ])
    }

    func testRemoveAndUpdate() async throws {
        let vm = try await loaded()
        vm.update(day: "push", id: "incline-bench") { $0.sets = 5; $0.load.build = 150 }
        let edited = try XCTUnwrap(vm.exercises(day: "push").first)
        XCTAssertEqual(edited.sets, 5)
        XCTAssertEqual(edited.load.build, 150)
        vm.remove(day: "push", id: "incline-bench")
        XCTAssertFalse(ids(vm, "push").contains("incline-bench"))
        vm.update(day: "push", id: "nope") { $0.sets = 9 }   // an unknown id changes nothing
        XCTAssertEqual(vm.exercises(day: "push").count, 6)
    }

    func testChangingBackToTheOriginalIsNotDirty() async throws {
        let vm = try await loaded()
        let sets = try XCTUnwrap(vm.exercises(day: "push").first?.sets)
        vm.update(day: "push", id: "incline-bench") { $0.sets = sets + 1 }
        XCTAssertTrue(vm.dirty)
        vm.update(day: "push", id: "incline-bench") { $0.sets = sets }
        XCTAssertFalse(vm.dirty)
    }

    func testPhaseDatesAreISOCalendarDays() async throws {
        let vm = try await loaded()
        vm.setPhase("build", end: false, to: PlanEditCopy.parse("2026-11-30")!)
        vm.setPhase("recover", end: true, to: PlanEditCopy.parse("2026-11-09")!)
        XCTAssertEqual(vm.plan.phases["build"]?.start, "2026-11-30")
        XCTAssertEqual(vm.plan.phases["recover"]?.end, "2026-11-09")
        vm.setPhase("nonexistent", end: false, to: Date())
        XCTAssertNil(vm.plan.phases["nonexistent"])
    }

    // MARK: Save

    func testSaveSendsWholePlan() async throws {
        let client = FakePlanClient()
        let vm = try await loaded(client)
        vm.remove(day: "push", id: "chest-fly")
        vm.add(day: "legs", exercise: .draft(name: "Calf raise"))
        let edited = vm.plan
        try await vm.save()
        XCTAssertEqual(client.saved, [edited], "the whole plan goes, not a patch")
        XCTAssertEqual(Set(edited.days.keys), ["warmup", "push", "legs", "pull"])
        XCTAssertFalse(vm.dirty)
        XCTAssertNil(vm.saveError)
        XCTAssertFalse(vm.isSaving)
    }

    func testSaveWithNothingChangedSendsNothing() async throws {
        let client = FakePlanClient()
        let vm = try await loaded(client)
        try await vm.save()
        XCTAssertTrue(client.saved.isEmpty)
    }

    func testServerValidationErrorIsShown() async throws {
        let client = FakePlanClient()
        client.saveResult = .failure(APIError.http(
            statusCode: 400, body: #"{"error":"incline-bench: sets must be at least 1"}"#))
        let vm = try await loaded(client)
        vm.update(day: "push", id: "incline-bench") { $0.sets = 0 }
        do {
            try await vm.save()
            XCTFail("the server's 400 should throw")
        } catch {}
        XCTAssertEqual(vm.saveError, "incline-bench: sets must be at least 1")
        XCTAssertTrue(vm.dirty, "his edits stay so he can fix them")
        XCTAssertFalse(vm.isSaving)
        vm.update(day: "push", id: "incline-bench") { $0.sets = 4 }
        XCTAssertNil(vm.saveError, "the message goes away once he edits again")
    }

    // MARK: Copy

    func testSlugAndSummary() throws {
        XCTAssertEqual(PlanEditCopy.slug("  DB Bench Press (45°)  "), "db-bench-press-45")
        let vm = try PrepDecoding.decode(BodyPlan.self, from: BodyModelsTests.fixture("plan.json"))
        let incline = try XCTUnwrap(vm.days["push"]?.first)
        XCTAssertEqual(PlanEditCopy.prescription(incline), "4 × 6–8")
        XCTAssertTrue(PlanEditCopy.summary(incline).hasPrefix("4 × 6–8"))
        let carry = try XCTUnwrap(vm.days["push"]?.last)
        XCTAssertEqual(PlanEditCopy.prescription(carry), "3 × 40 yd")
        XCTAssertEqual(PlanEditCopy.dayTitle("warmup"), "Warm-up")
        XCTAssertEqual(PlanEditCopy.shortDate("2026-11-09"), "Nov 9")
    }
}

/// A lift's page: the step line's numbers and the one-line change.
@MainActor
final class LiftProgressTests: XCTestCase {
    private func points(_ pairs: [(String, Double?)]) -> [BodyLiftPoint] {
        let rows = pairs.map { #"{"date":"\#($0.0)","weight":\#($0.1.map { "\($0)" } ?? "null")}"# }
        return try! PrepDecoding.decode([BodyLiftPoint].self, from: Data("[\(rows.joined(separator: ","))]".utf8))
    }

    func testChangeSinceFirst() {
        let series = points([("2026-11-09", 115), ("2026-11-16", 120), ("2026-11-23", 145), ("2026-12-04", 150)])
        XCTAssertEqual(LiftProgressCopy.change(series, unit: "lb"), "Up 35 lb since Nov 9.")
        XCTAssertEqual(LiftProgressCopy.change(points([("2026-11-09", 42.5), ("2026-11-16", 47.5)]), unit: "lb_each"),
                       "Up 5 lb each since Nov 9.")
        XCTAssertEqual(LiftProgressCopy.change(points([("2026-11-09", 150), ("2026-11-16", 145)]), unit: "lb"),
                       "Down 5 lb since Nov 9.")
        XCTAssertEqual(LiftProgressCopy.change(points([("2026-11-09", 145), ("2026-11-16", 145)]), unit: "lb"),
                       "Holding at 145 lb since Nov 9.")
        XCTAssertEqual(LiftProgressCopy.change(points([("2026-11-09", 145)]), unit: "lb"), "First session Nov 9.")
    }

    func testNoWeightsMeansNoChangeLineAndNoChart() {
        let series = points([("2026-11-09", nil), ("2026-11-16", nil)])
        XCTAssertNil(LiftProgressCopy.change(series, unit: "bw"))
        XCTAssertTrue(LiftProgressCopy.weighted(series).isEmpty)
        XCTAssertNil(LiftProgressCopy.change([], unit: "lb"))
    }

    func testWeightedKeepsOrderAndSkipsGaps() {
        let series = points([("2026-11-09", 115), ("2026-11-16", nil), ("2026-11-23", 145)])
        XCTAssertEqual(LiftProgressCopy.weighted(series).map(\.weight), [115, 145])
    }

    func testChartSummaryForVoiceOver() {
        let series = points([("2026-11-23", 145), ("2026-12-04", 150)])
        XCTAssertEqual(LiftProgressCopy.chartSummary(series, unit: "lb"),
                       "Working weight by session: 145 lb on Nov 23, 150 lb on Dec 4")
    }

    func testSubtitleFromThePlan() throws {
        let plan = try PrepDecoding.decode(BodyPlan.self, from: BodyModelsTests.fixture("plan.json"))
        XCTAssertEqual(LiftProgressCopy.subtitle(id: "incline-bench", plan: plan), "Push · 4 × 6–8")
        XCTAssertNil(LiftProgressCopy.subtitle(id: "gone", plan: plan))
    }

    func testViewModelLoadsLiftAndSubtitle() async throws {
        let client = FakePlanClient()
        client.liftResult = .success(try PrepDecoding.decode(BodyLift.self, from: BodyModelsTests.fixture("lift.json")))
        client.planResult = .success(try PrepDecoding.decode(BodyPlan.self, from: BodyModelsTests.fixture("plan.json")))
        let vm = LiftProgressViewModel(client: client, id: "incline-bench")
        await vm.load()
        guard case .loaded(let lift) = vm.state else { return XCTFail("expected a loaded lift, got \(vm.state)") }
        XCTAssertEqual(lift.weightLabel, "150 lb")
        XCTAssertEqual(vm.subtitle, "Push · 4 × 6–8")
    }

    func testViewModelStillLoadsWhenThePlanCannotBeRead() async throws {
        let client = FakePlanClient()
        client.liftResult = .success(try PrepDecoding.decode(BodyLift.self, from: BodyModelsTests.fixture("lift.json")))
        let vm = LiftProgressViewModel(client: client, id: "incline-bench")
        await vm.load()
        guard case .loaded = vm.state else { return XCTFail("expected a loaded lift, got \(vm.state)") }
        XCTAssertNil(vm.subtitle)
    }

    func testViewModelNotFoundIsUnavailable() async {
        let client = FakePlanClient()
        client.liftResult = .failure(APIError.http(statusCode: 404, body: nil))
        let vm = LiftProgressViewModel(client: client, id: "gone")
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }
}
