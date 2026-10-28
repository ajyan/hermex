import XCTest
@testable import HermesMobile

private final class FakeTrainingClient: BodyDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _log: [String] = []
    var fails = false
    var failure: Error = URLError(.badServerResponse)
    var homeProposals: [BodyProposal]?
    var log: [String] { lock.withLock { _log } }

    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal {
        lock.withLock { _log.append("decide:\(proposalID):\(accept ? "accept" : "skip")") }
        if fails { throw failure }
        return try WeekTrainingCardTests.proposal(id: proposalID, status: accept ? "accepted" : "skipped")
    }

    func home() async throws -> BodyHome {
        guard let homeProposals else { throw URLError(.notConnectedToInternet) }
        let base = try PrepDecoding.decode(BodyHome.self, from: BodyModelsTests.fixture("home.json"))
        return base.with(proposals: homeProposals)
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
final class WeekTrainingCardTests: XCTestCase {
    nonisolated static func proposal(id: String, status: String = "pending") throws -> BodyProposal {
        let json = """
        {"id": "\(id)", "kind": "reset", "lift": "strict-press", "title": "Strict press: 70 lb for 3 x 8",
         "why": ["Missed reps twice", "Slept 5.4 h Thu"], "rule": "Two misses in a row", "status": "\(status)"}
        """
        return try PrepDecoding.decode(BodyProposal.self, from: Data(json.utf8))
    }

    private static let deckJSON = """
    {"version": 3, "date": "2026-11-01", "kind": "weekly", "generated_at": "2026-11-01T05:30:00-04:00",
     "cards": [
      {"id": "training", "type": "training", "headline": "Three sessions, press stalled",
       "bullets": ["Push, legs, pull all done", "Press missed reps twice", 7, "Sleep ran short Thursday"],
       "proposals": [
         {"id": "p1", "kind": "reset", "lift": "strict-press", "title": "Strict press: 70 lb for 3 x 8",
          "why": ["Missed reps twice"], "rule": "Two misses in a row", "status": "pending"},
         {"nope": true},
         {"id": "p2", "kind": "deload", "title": "Deload next week", "why": [], "rule": "", "status": "skipped"}],
       "chapter": "steer"},
      {"id": "close", "type": "close"}
     ]}
    """

    func testTrainingCardTypeDecodes() throws {
        let deck = try DailyDeck.decode(Self.deckJSON)
        XCTAssertEqual(deck.cards.map(\.type), [.training, .close])
        let card = deck.cards[0]
        XCTAssertEqual(card.headline, "Three sessions, press stalled")
        XCTAssertEqual(card.bullets, ["Push, legs, pull all done", "Press missed reps twice", "Sleep ran short Thursday"],
                       "a bullet that isn't text is dropped alone")
        XCTAssertEqual(card.proposals.map(\.id), ["p1", "p2"], "a proposal that fails to decode is dropped alone")
        XCTAssertEqual(card.proposals[0].why, ["Missed reps twice"])
        XCTAssertEqual(card.chapter, "steer")
        XCTAssertFalse(card.takesFeedback)
        XCTAssertFalse(card.takesText)
        XCTAssertEqual(DeckPalette.of(card).name, "Training")
    }

    func testPendingProposalsOnly() throws {
        let card = try DailyDeck.decode(Self.deckJSON).cards[0]
        let model = WeekTrainingModel(client: FakeTrainingClient())
        XCTAssertEqual(model.visible(card.proposals).map(\.id), ["p1"])
    }

    func testUseHidesTheProposalAndSendsAccept() async throws {
        let client = FakeTrainingClient()
        let model = WeekTrainingModel(client: client)
        let proposal = try Self.proposal(id: "p1")
        await model.decide(proposal, accept: true)
        XCTAssertEqual(client.log, ["decide:p1:accept"])
        XCTAssertTrue(model.visible([proposal]).isEmpty)
        XCTAssertNil(model.error)
    }

    func testFailedDecisionRollsBack() async throws {
        let client = FakeTrainingClient()
        client.fails = true
        let model = WeekTrainingModel(client: client)
        let proposal = try Self.proposal(id: "p1")
        await model.decide(proposal, accept: false)
        XCTAssertEqual(model.visible([proposal]).map(\.id), ["p1"], "the proposal comes back when the server says no")
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.deciding.isEmpty)
    }

    func testWithoutAClientNothingIsDecided() async throws {
        let model = WeekTrainingModel(client: nil)
        let proposal = try Self.proposal(id: "p1")
        XCTAssertFalse(model.canDecide)
        await model.decide(proposal, accept: true)
        XCTAssertEqual(model.visible([proposal]).map(\.id), ["p1"])
    }

    func testReconcileHidesProposalsNoLongerPendingOnServer() async throws {
        let client = FakeTrainingClient()
        client.homeProposals = [try Self.proposal(id: "p2")]
        let model = WeekTrainingModel(client: client)
        let p1 = try Self.proposal(id: "p1"), p2 = try Self.proposal(id: "p2")
        XCTAssertEqual(model.visible([p1, p2]).map(\.id), ["p1", "p2"], "before the read, the deck's own list shows")
        await model.reconcile()
        XCTAssertEqual(model.visible([p1, p2]).map(\.id), ["p2"])
    }

    func testFailedReconcileLeavesTheDeckList() async throws {
        let model = WeekTrainingModel(client: FakeTrainingClient())
        let p1 = try Self.proposal(id: "p1")
        await model.reconcile()
        XCTAssertEqual(model.visible([p1]).map(\.id), ["p1"])
    }

    func testAlreadyDecidedStaysHiddenWithoutAnError() async throws {
        for status in [404, 409] {
            let client = FakeTrainingClient()
            client.fails = true
            client.failure = APIError.http(statusCode: status, body: nil)
            let model = WeekTrainingModel(client: client)
            let proposal = try Self.proposal(id: "p1")
            await model.decide(proposal, accept: true)
            XCTAssertTrue(model.visible([proposal]).isEmpty, "HTTP \(status)")
            XCTAssertNil(model.error, "HTTP \(status)")
        }
    }
}
