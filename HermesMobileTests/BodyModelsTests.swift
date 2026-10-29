import XCTest
@testable import HermesMobile

/// The Body models decode the synthetic output of the vault's `tools/gym.py` kept in
/// `Fixtures/Body/` (invented sessions on a temp vault, never real data), and the adapter
/// sends the shapes `api/vault_body.py` reads.
final class BodyModelsTests: APIClientTestCase {
    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Body/\(name)")
        return try Data(contentsOf: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try PrepDecoding.decode(type, from: Self.fixture(name))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Decoding

    func testDecodesHomeFixture() throws {
        let home = try decode(BodyHome.self, "home.json")
        XCTAssertEqual(home.phase, "build")
        XCTAssertEqual(home.phaseLabel, "Build · 6 weeks to January")
        XCTAssertNil(home.starts)
        XCTAssertEqual(home.next?.day, "push")
        XCTAssertEqual(home.next?.preview.map(\.weightLabel), ["150 lb", "75 lb", "42.5s"])
        XCTAssertEqual(home.next?.preview.map(\.up), [true, false, true])
        XCTAssertEqual(home.week.days.count, 7)
        XCTAssertEqual(home.week.days.first, "2026-11-30")
        XCTAssertEqual(home.week.lifted, [.off, .off, .today, .ahead, .ahead, .ahead, .ahead],
                       "Monday and Tuesday passed without lifting")
        XCTAssertEqual(home.week.ran, [.off, .done, .today, .ahead, .ahead, .ahead, .ahead])
        XCTAssertEqual(home.sleep?.hours, 5.2)
        XCTAssertEqual(home.sleep?.quality, 2)
        let incline = try XCTUnwrap(home.lifts.first { $0.id == "incline-bench" })
        XCTAssertEqual(incline.dots, [true, true, true, true])
        XCTAssertTrue(incline.up)
        XCTAssertEqual(incline.upFrom, 145)
        XCTAssertEqual(home.lifts.first { $0.id == "bench-dips" }?.weightLabel, "BW")
        XCTAssertFalse(home.lifts.contains { $0.id == "curl-up" }, "the warm-up is not a lift on home")
        XCTAssertEqual(home.sessions.count, 3)
        XCTAssertEqual(home.sessions.first?.id, "2026-11-27-pull")
        XCTAssertEqual(home.sessions.first?.minutes, 52)
        XCTAssertEqual(home.sessions.first?.trimmed, true)
        let proposal = try XCTUnwrap(home.proposals.first)
        XCTAssertEqual(proposal.kind, "reset")
        XCTAssertEqual(proposal.lift, "strict-press")
        XCTAssertEqual(proposal.change?.weight, 70)
        XCTAssertEqual(proposal.why.count, 2)
        XCTAssertTrue(proposal.isPending)
        XCTAssertEqual(home.gaps, [])
    }

    func testDecodesPrescriptionFixtureWithBumpAndOffers() throws {
        let rx = try decode(BodyPrescription.self, "prescription.json")
        XCTAssertEqual(rx.id, "2026-12-02-push")
        XCTAssertEqual(rx.day, "push")
        XCTAssertFalse(rx.resumed)
        XCTAssertEqual(rx.offers.sleep?.hours, 5.2)
        XCTAssertEqual(rx.offers.sleep?.quality, 2)
        XCTAssertFalse(rx.offers.hinge)
        XCTAssertNil(rx.offers.hingeMinutes)
        // The warm-up leads, logged like a lift: holds in seconds, then the band.
        XCTAssertEqual(rx.exercises.prefix(4).map(\.id), ["curl-up", "side-plank", "bird-dog", "band-pull-apart"])
        XCTAssertTrue(rx.exercises.prefix(4).allSatisfy { $0.section == .warmup })
        XCTAssertEqual(rx.exercises[0].target.holdS, 10)
        XCTAssertEqual(rx.exercises[0].sets.map(\.kind), [.work, .work, .work])
        XCTAssertFalse(rx.exercises.contains(where: \.hinge), "push has no hinge lift")
        let incline = try XCTUnwrap(rx.exercises.first { $0.id == "incline-bench" })
        XCTAssertEqual(incline.weightLabel, "150 lb")
        XCTAssertTrue(incline.up)
        XCTAssertEqual(incline.upFrom, 145)
        XCTAssertEqual(incline.target.reps, [6, 8])
        XCTAssertEqual(incline.sets.map(\.kind), [.warm, .warm, .work, .work, .work, .work])
        XCTAssertEqual(incline.workSets.map(\.weight), [150, 150, 150, 150])
        XCTAssertEqual(incline.last.count, 4)
        XCTAssertEqual(rx.exercises.first { $0.id == "db-bench" }?.weightLabel, "42.5s")
        XCTAssertEqual(rx.exercises.first { $0.id == "suitcase-carry" }?.target.distanceYd, 40)
    }

    func testDecodesPrescriptionWithNullWeights() throws {
        let rx = try decode(BodyPrescription.self, "prescription-pull.json")
        let pullUps = try XCTUnwrap(rx.exercises.first { $0.id == "pull-ups" })
        XCTAssertEqual(pullUps.weightLabel, "BW")
        XCTAssertEqual(pullUps.goalReps, [8, 7, 6, 6])
        XCTAssertEqual(pullUps.sets.map(\.reps), [8, 7, 6, 6])
        XCTAssertTrue(pullUps.sets.allSatisfy { $0.weight == nil })
        // A weighted lift with no weight yet ("—"): he types one in.
        let pulldown = try XCTUnwrap(rx.exercises.first { $0.id == "lat-pulldown" })
        XCTAssertEqual(pulldown.unit, "lb")
        XCTAssertEqual(pulldown.weightLabel, "—")
        XCTAssertTrue(pulldown.sets.allSatisfy { $0.weight == nil })
        XCTAssertNil(pulldown.upFrom)
    }

    func testDecodesLegsPrescriptionWithTheHingeOffer() throws {
        let rx = try decode(BodyPrescription.self, "prescription-legs.json")
        XCTAssertEqual(rx.id, "2026-12-02-legs")
        XCTAssertTrue(rx.offers.hinge)
        XCTAssertEqual(rx.offers.hingeMinutes, 35, "he woke 35 minutes before opening it")
        XCTAssertEqual(rx.exercises.filter(\.hinge).map(\.id), ["db-rdl"])
        let rdl = try XCTUnwrap(rx.exercises.first { $0.id == "db-rdl" })
        XCTAssertTrue(rdl.up)
        XCTAssertEqual(rdl.upFrom, 35)
        XCTAssertEqual(rdl.weightLabel, "37.5s")
    }

    func testDecodesSessionWithCheckAndCoachNote() throws {
        let session = try decode(BodySession.self, "session.json")
        XCTAssertEqual(session.id, "2026-11-23-push")
        XCTAssertEqual(session.day, "push")
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.check?.effort, .solid)
        XCTAssertEqual(session.check?.note, "Felt strong")
        XCTAssertEqual(session.coachNote?.headline, "Incline is ready to move")
        XCTAssertEqual(session.coachNote?.body.count, 2)
        XCTAssertEqual(session.started, "2026-11-23T07:00:00")
        XCTAssertEqual(session.finished, "2026-11-23T07:52:00")
        XCTAssertEqual(session.exercises.first?.section, .warmup)
        let incline = try XCTUnwrap(session.exercises.first { $0.id == "incline-bench" })
        XCTAssertEqual(incline.repsLeft, 1)
        XCTAssertEqual(incline.workSets.first?.weight, 145)
    }

    func testDecodesFinishResultSessionsLiftAndPlan() throws {
        let finish = try decode(BodyFinishResult.self, "finish.json")
        XCTAssertEqual(finish.session.check?.effort, .easy)
        XCTAssertEqual(finish.session.id, try decode(BodyPrescription.self, "prescription.json").id,
                       "the finished session is today's prescription")
        XCTAssertEqual(finish.session.started, "2026-12-02T07:05:00")
        XCTAssertEqual(finish.session.finished, "2026-12-02T07:58:00")
        XCTAssertTrue(finish.proposals.isEmpty)

        let summaries = try decode([BodySessionSummary].self, "sessions.json")
        XCTAssertEqual(summaries.map(\.label), ["Pull", "Legs", "Push"])
        XCTAssertEqual(summaries.last?.note, "Felt strong")

        let lift = try decode(BodyLift.self, "lift.json")
        XCTAssertEqual(lift.weightLabel, "150 lb")
        XCTAssertTrue(lift.up)
        XCTAssertEqual(lift.series.map(\.weight), [145])
        XCTAssertEqual(lift.sessions.first?.reps, [8, 8, 8, 8])

        let plan = try decode(BodyPlan.self, "plan.json")
        XCTAssertEqual(plan.rotation, ["push", "legs", "pull"])
        XCTAssertEqual(plan.phases["recover"]?.end, "2026-11-08")
        XCTAssertNil(plan.phases["reentry"]?.end)
        XCTAssertEqual(plan.days["push"]?.count, 7)
        let rdl = try XCTUnwrap(plan.days["legs"]?.first { $0.id == "db-rdl" })
        XCTAssertTrue(rdl.hinge)
        XCTAssertEqual(rdl.alternates, ["Hip thrust", "Back extension"])
        XCTAssertEqual(rdl.load.increment, 2.5)
        XCTAssertEqual(plan.days["pull"]?.first { $0.id == "lat-pulldown" }?.load.build, nil)
    }

    func testUnknownDayStateIsTolerated() throws {
        let json = #"{"days":["2026-11-30"],"lifted":["done","missed","ask","off","today","ahead"],"ran":[]}"#
        let week = try PrepDecoding.decode(BodyWeek.self, from: Data(json.utf8))
        XCTAssertEqual(week.lifted, [.done, .unknown, .unknown, .off, .today, .ahead])
    }

    func testUnknownFieldsAndMissingFieldsNeverFail() throws {
        let json = """
        {"phase":"before","phase_label":"Starts Nov 9","starts":"Nov 9","next":null,"extra":{"a":1},
         "week":{"days":[],"lifted":[],"ran":[]},"lifts":[{"id":"x"},"junk",{"id":"y","dots":[true]}],
         "sessions":[7],"proposals":[{"id":"p","kind":"future-kind","title":"t","status":"later"}]}
        """
        let home = try PrepDecoding.decode(BodyHome.self, from: Data(json.utf8))
        XCTAssertEqual(home.starts, "Nov 9")
        XCTAssertNil(home.next)
        XCTAssertNil(home.sleep)
        XCTAssertEqual(home.lifts.map(\.id), ["x", "y"])
        XCTAssertEqual(home.proposals.first?.kind, "future-kind")
        XCTAssertFalse(home.proposals.first?.isPending ?? true)
        XCTAssertTrue(home.gaps.isEmpty)

        let empty = try PrepDecoding.decode(BodyHome.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.phase, "")
        XCTAssertTrue(empty.week.days.isEmpty)
    }

    // MARK: Formatting

    func testWeightLabelTrimsWholeNumbers() {
        XCTAssertEqual(BodyFormat.weightLabel(unit: "lb_each", weight: 42.5), "42.5s")
        XCTAssertEqual(BodyFormat.weightLabel(unit: "lb_each", weight: 40), "40s")
        XCTAssertEqual(BodyFormat.weightLabel(unit: "lb", weight: 150), "150 lb")
        XCTAssertEqual(BodyFormat.weightLabel(unit: "lb", weight: 142.5), "142.5 lb")
        XCTAssertEqual(BodyFormat.weightLabel(unit: "bw", weight: nil), "BW")
        XCTAssertEqual(BodyFormat.weightLabel(unit: "band", weight: nil), "Band")
        XCTAssertEqual(BodyFormat.weightLabel(unit: "cable", weight: nil), "Light cable")
        XCTAssertEqual(BodyFormat.weightLabel(unit: "lb", weight: nil), "—")
        XCTAssertEqual(BodyFormat.number(2.5), "2.5")
    }

    // MARK: Encoding

    func testSessionRoundTripsKeepingSnakeCaseKeys() throws {
        let decoded = try decode(BodyPrescription.self, "prescription.json")
        let session = BodySession(id: decoded.id, day: decoded.day, exercises: decoded.exercises, movedHinge: true,
                                  check: BodyCheck(effort: .grinder, back: .tight, pain: BodyPain(score: 4, lift: "strict-press"),
                                                   note: "tweaky"))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase  // what APIClient.sendData(body:) uses
        let object = try jsonObject(encoder.encode(session))
        XCTAssertEqual(object["moved_hinge"] as? Bool, true)
        let check = try XCTUnwrap(object["check"] as? [String: Any])
        XCTAssertEqual(check["effort"] as? String, "grinder")
        XCTAssertEqual((check["pain"] as? [String: Any])?["score"] as? Int, 4)
        let exercises = try XCTUnwrap(object["exercises"] as? [[String: Any]])
        let incline = try XCTUnwrap(exercises.first { ($0["id"] as? String) == "incline-bench" })
        XCTAssertEqual(incline["weight_label"] as? String, "150 lb")
        XCTAssertEqual(incline["up_from"] as? Double, 145)
        XCTAssertEqual(incline["hinge"] as? Bool, false)
        let pull = try XCTUnwrap(exercises.first { ($0["id"] as? String) == "suitcase-carry" })
        let firstSet = try XCTUnwrap((pull["sets"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstSet["distance_yd"] as? Int, 40)
        XCTAssertNil(object["finished"], "an unfinished session sends no finished stamp")

        // And reads back as the same session.
        let back = try PrepDecoding.decode(BodySession.self, from: encoder.encode(session))
        XCTAssertEqual(back, session)
    }

    func testPlanRoundTripsAndKeepsPlanFileShape() throws {
        let plan = try decode(BodyPlan.self, "plan.json")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(plan)
        XCTAssertEqual(try PrepDecoding.decode(BodyPlan.self, from: data), plan)
        let days = try XCTUnwrap(try jsonObject(data)["days"] as? [String: [[String: Any]]])
        let curlUp = try XCTUnwrap(days["warmup"]?.first)
        XCTAssertEqual(curlUp["hold_s"] as? Int, 10)
        XCTAssertNil(curlUp["reps"])
        XCTAssertNil(curlUp["big"], "false flags are left out, like plan.yaml")
        let load = try XCTUnwrap(curlUp["load"] as? [String: Any])
        XCTAssertTrue(load["build"] is NSNull, "null weights stay null")
        let incline = try XCTUnwrap(days["push"]?.first)
        XCTAssertEqual(incline["big"] as? Bool, true)
        XCTAssertEqual(incline["ramp_sets"] as? Int, 2)
    }

    // MARK: Client

    func testAdapterSendsAndDecodesEveryCall() async throws {
        var seen: [String] = []
        var bodies: [String: [String: Any]] = [:]
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            let key = "\(request.httpMethod ?? "") \(path)"
            seen.append(key + (request.url?.query.map { "?\($0)" } ?? ""))
            if let data = apiTestBodyData(from: request), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodies[key] = object
            }
            let fixture: String
            switch path {
            case "/api/body/home": fixture = "home.json"
            case "/api/body/prescription": fixture = "prescription.json"
            case "/api/body/session": fixture = "session.json"
            case "/api/body/session/finish": fixture = "finish.json"
            case "/api/body/sessions": fixture = "sessions.json"
            case "/api/body/lift": fixture = "lift.json"
            case "/api/body/plan": fixture = "plan.json"
            case "/api/body/proposal":
                return apiTestJSONResponse(#"{"id":"2026-11-29-reset-strict-press","kind":"reset","title":"t","status":"accepted","why":[]}"#, for: request)
            default: throw URLError(.badURL)
            }
            return apiTestJSONResponse(String(decoding: try Self.fixture(fixture), as: UTF8.self), for: request)
        }
        let body = APIClientBodyAdapter(apiClient: client)

        _ = try await body.home()
        let rx = try await body.prescription(day: "push")
        let saved = try await body.save(BodySession(id: rx.id, day: rx.day, exercises: rx.exercises))
        _ = try await body.finish(id: rx.id, check: BodyCheck(effort: .easy, pain: BodyPain(score: 5, lift: "incline-bench")))
        _ = try await body.session(id: "2026-11-23-push")
        let list = try await body.sessions(before: "2026-11-27-pull")
        _ = try await body.lift(id: "incline-bench")
        let plan = try await body.plan()
        _ = try await body.savePlan(plan)
        let decided = try await body.decide(proposalID: "2026-11-29-reset-strict-press", accept: true)
        _ = try await body.decide(proposalID: "x", accept: false)

        XCTAssertEqual(seen, [
            "GET /api/body/home",
            "GET /api/body/prescription?day=push",
            "POST /api/body/session",
            "POST /api/body/session/finish",
            "GET /api/body/session?id=2026-11-23-push",
            "GET /api/body/sessions?before=2026-11-27-pull",
            "GET /api/body/lift?id=incline-bench",
            "GET /api/body/plan",
            "POST /api/body/plan",
            "POST /api/body/proposal",
            "POST /api/body/proposal"
        ])
        XCTAssertEqual(saved.id, "2026-11-23-push")
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(decided.status, "accepted")
        XCTAssertEqual(bodies["POST /api/body/session"]?["id"] as? String, "2026-12-02-push")
        let finishBody = try XCTUnwrap(bodies["POST /api/body/session/finish"])
        XCTAssertEqual(finishBody["id"] as? String, "2026-12-02-push")
        let check = try XCTUnwrap(finishBody["check"] as? [String: Any])
        XCTAssertEqual(check["effort"] as? String, "easy")
        XCTAssertEqual((check["pain"] as? [String: Any])?["lift"] as? String, "incline-bench")
        XCTAssertNotNil(bodies["POST /api/body/plan"]?["rotation"])
    }

    func testDecideSendsAcceptAndSkip() async throws {
        var decisions: [String] = []
        let client = makeClient { request in
            if let data = apiTestBodyData(from: request),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                decisions.append("\(object["id"] ?? "")=\(object["decision"] ?? "")")
            }
            return apiTestJSONResponse(#"{"id":"p","status":"skipped"}"#, for: request)
        }
        let body = APIClientBodyAdapter(apiClient: client)
        _ = try await body.decide(proposalID: "p", accept: true)
        _ = try await body.decide(proposalID: "p", accept: false)
        XCTAssertEqual(decisions, ["p=accept", "p=skip"])
    }

    func testSleepHistoryIsNilOn404AndDecodesOtherwise() async throws {
        let missing = APIClientBodyAdapter(apiClient: makeClient { request in
            apiTestJSONResponse(#"{"error":"no sleep history"}"#, for: request, status: 404)
        })
        let none = try await missing.sleepHistory()
        XCTAssertNil(none)

        let present = APIClientBodyAdapter(apiClient: makeClient { request in
            apiTestJSONResponse(#"{"columns":["date","sleep_hours"],"nights":[["2026-11-29",7.5]],"stages":{}}"#, for: request)
        })
        let history = try await present.sleepHistory()
        XCTAssertEqual(history?.nights.count, 1)

        let broken = APIClientBodyAdapter(apiClient: makeClient { request in
            apiTestJSONResponse(#"{"error":"boom"}"#, for: request, status: 500)
        })
        do {
            _ = try await broken.sleepHistory()
            XCTFail("a 500 is not 'no history'")
        } catch {}
    }
}
