import XCTest
@testable import HermesMobile

@MainActor
final class FeedbackInboxViewModelTests: XCTestCase {
    func testGroupsByStatus() async throws {
        let client = InboxStubClient(entries: [
            entry("a", status: "merged", ts: "2026-10-01T10:00:00Z"),
            entry("b", status: "planned", ts: "2026-10-02T10:00:00Z"),
            entry("c", status: "new", ts: "2026-10-03T10:00:00Z"),
            entry("d", status: "failed", ts: "2026-10-04T10:00:00Z"),
            entry("e", status: "rejected", ts: "2026-10-05T10:00:00Z"),
            entry("f", status: "building", ts: "2026-10-01T09:00:00Z"),
            entry("g", status: "ready", ts: "2026-10-03T09:00:00Z"),
        ])
        let viewModel = FeedbackInboxViewModel(client: client)

        await viewModel.load()

        let sections = viewModel.sections
        XCTAssertEqual(sections.map(\.group), [.needsReview, .inProgress, .done])
        XCTAssertEqual(sections[0].entries.map(\.id), ["d", "g", "b"])
        XCTAssertEqual(sections[1].entries.map(\.id), ["c", "f"])
        XCTAssertEqual(sections[2].entries.map(\.id), ["e", "a"])
        guard case .loaded(let groups) = viewModel.state else { return XCTFail("not loaded") }
        XCTAssertEqual(groups[.needsReview]?.map(\.id), ["d", "g", "b"])
    }

    func testEmptyGroupsAreLeftOut() async {
        let client = InboxStubClient(entries: [entry("a", status: "new", ts: "2026-10-01T10:00:00Z")])
        let viewModel = FeedbackInboxViewModel(client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.sections.map(\.group), [.inProgress])
    }

    func testNotFoundIsUnavailable() async {
        let client = InboxStubClient(entries: [])
        await client.failList(with: APIError.http(statusCode: 404, body: nil))
        let viewModel = FeedbackInboxViewModel(client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .unavailable)
    }

    func testApproveReplacesEntryFromServer() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        await client.setDecisionResult(entry("b", status: "approved", ts: "2026-10-02T10:00:00Z", title: "From the server"))
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "b")), .approve)

        let decisions = await client.decisions
        XCTAssertEqual(decisions.map(\.id), ["b"])
        XCTAssertEqual(decisions.map(\.decision), [.approve])
        XCTAssertEqual(viewModel.sections.map(\.group), [.inProgress])
        let replaced = try XCTUnwrap(viewModel.entry(id: "b"))
        XCTAssertEqual(replaced.status, .approved)
        XCTAssertEqual(replaced.title, "From the server")
        XCTAssertNil(viewModel.error)
        XCTAssertNil(viewModel.pendingID)
        let listCalls = await client.listCalls
        XCTAssertEqual(listCalls, 1, "a decision uses the returned entry, not a reload")
    }

    func testDecisionIsNotOptimistic() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        await client.holdDecisions()
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        let decision = Task { await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "b")), .approve) }
        await client.waitForDecision()

        XCTAssertEqual(viewModel.entry(id: "b")?.status, .planned)
        XCTAssertEqual(viewModel.pendingID, "b")
        await client.releaseDecisions()
        try await decision.value
        XCTAssertNil(viewModel.pendingID)
    }

    func test409ShowsErrorAndReloads() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        await client.failDecisions(with: APIError.http(statusCode: 409, body: nil))
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()
        await client.setEntries([entry("b", status: "approved", ts: "2026-10-02T10:00:00Z")])

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "b")), .reject)

        XCTAssertEqual(viewModel.error, "This changed on the server. Showing the latest.")
        let listCalls = await client.listCalls
        XCTAssertEqual(listCalls, 2)
        XCTAssertEqual(viewModel.entry(id: "b")?.status, .approved)
        XCTAssertNil(viewModel.pendingID)
    }

    func test409ErrorOutlivesTheEntryLeavingItsDecisions() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        await client.failDecisions(with: APIError.http(statusCode: 409, body: nil))
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()
        XCTAssertTrue(try XCTUnwrap(viewModel.entry(id: "b")).status.hasDecisions)
        await client.setEntries([entry("b", status: "building", ts: "2026-10-02T10:00:00Z")])

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "b")), .approve)

        let reloaded = try XCTUnwrap(viewModel.entry(id: "b"))
        XCTAssertFalse(reloaded.status.hasDecisions, "the detail's action bar goes away")
        XCTAssertNotNil(viewModel.error, "so the error must show outside it")
    }

    func testOnlyPlannedReadyAndFailedHaveDecisions() {
        let withDecisions = [FeedbackStatus.new, .planning, .planned, .approved, .building, .ready, .failed, .rejected, .merged, .unknown]
            .filter(\.hasDecisions)
        XCTAssertEqual(withDecisions, [.planned, .ready, .failed])
    }

    func testOtherFailureKeepsEntryAndShowsError() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        await client.failDecisions(with: APIError.http(statusCode: 500, body: nil))
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "b")), .approve)

        XCTAssertEqual(viewModel.error, "Couldn't save that. Try again.")
        XCTAssertEqual(viewModel.entry(id: "b")?.status, .planned)
        let listCalls = await client.listCalls
        XCTAssertEqual(listCalls, 1)
        viewModel.clearError()
        XCTAssertNil(viewModel.error)
    }

    func testReplyRequiresNote() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()
        let planned = try XCTUnwrap(viewModel.entry(id: "b"))

        await viewModel.decide(planned, .reply("  \n "))

        XCTAssertEqual(viewModel.error, "Write a reply first.")
        var decisions = await client.decisions
        XCTAssertTrue(decisions.isEmpty)

        viewModel.clearError()
        await viewModel.decide(planned, .reply("  Keep the old editor.\n"))

        decisions = await client.decisions
        XCTAssertEqual(decisions.map(\.decision), [.reply("Keep the old editor.")])
        XCTAssertNil(viewModel.error)
    }

    func testInboxReloadsPerClient() async {
        let first = InboxStubClient(entries: [entry("a", status: "new", ts: "2026-10-01T10:00:00Z")])
        let second = InboxStubClient(entries: [entry("z", status: "planned", ts: "2026-10-01T10:00:00Z")])
        let firstInbox = FeedbackInboxViewModel(client: first)
        let secondInbox = FeedbackInboxViewModel(client: second)

        await firstInbox.load()
        await secondInbox.load()

        XCTAssertNotNil(firstInbox.entry(id: "a"))
        XCTAssertNil(firstInbox.entry(id: "z"))
        XCTAssertNotNil(secondInbox.entry(id: "z"))
        XCTAssertNil(secondInbox.entry(id: "a"))

        await first.setEntries([entry("a", status: "planning", ts: "2026-10-01T10:00:00Z")])
        await firstInbox.load()

        XCTAssertEqual(firstInbox.entry(id: "a")?.status, .planning, "each load reads the server again")
        let listCalls = await first.listCalls
        XCTAssertEqual(listCalls, 2)
    }

    func testPlanLoadsFromClient() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        await client.setPlan("# Plan\n\nDo the thing.")
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        let plan = await viewModel.plan(for: try XCTUnwrap(viewModel.entry(id: "b")))

        XCTAssertEqual(plan, .loaded("# Plan\n\nDo the thing."))
    }

    func testRowTextFallsBackToFirstLine() throws {
        let titled = try FeedbackDecoding.decode(FeedbackEntry.self, from: Data(
            #"{"id":"a","status":"planned","feature":"Prep","size":"S","title":"Wait for hints","text":"Long note"}"#.utf8))
        XCTAssertEqual(titled.headline, "Wait for hints")
        XCTAssertEqual(titled.metaLine, "Prep · Plan ready · S")

        let untitled = try FeedbackDecoding.decode(FeedbackEntry.self, from: Data(
            #"{"id":"b","status":"new","feature":"Chat","text":"\n  First line\nSecond line"}"#.utf8))
        XCTAssertEqual(untitled.headline, "First line")
        XCTAssertEqual(untitled.metaLine, "Chat · Waiting for tonight")
    }

    private func entry(_ id: String, status: String, ts: String, title: String? = nil) -> FeedbackEntry {
        var object: [String: Any] = ["id": id, "status": status, "ts": ts, "feature": "Prep", "text": "Note \(id)"]
        if let title { object["title"] = title }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! FeedbackDecoding.decode(FeedbackEntry.self, from: data)
    }
}

private actor InboxStubClient: FeedbackDataClient {
    private var entries: [FeedbackEntry]
    private var listError: Error?
    private var decisionError: Error?
    private var decisionResult: FeedbackEntry?
    private var planMarkdown = ""
    private var holdsDecisions = false
    private var heldDecision: CheckedContinuation<Void, Never>?
    private var decisionWaiter: CheckedContinuation<Void, Never>?
    private(set) var listCalls = 0
    private(set) var decisions: [Decided] = []

    struct Decided: Sendable {
        let id: String
        let decision: FeedbackDecision
    }

    init(entries: [FeedbackEntry]) { self.entries = entries }

    func setEntries(_ value: [FeedbackEntry]) { entries = value }
    func failList(with error: Error) { listError = error }
    func failDecisions(with error: Error) { decisionError = error }
    func setDecisionResult(_ value: FeedbackEntry) { decisionResult = value }
    func setPlan(_ value: String) { planMarkdown = value }
    func holdDecisions() { holdsDecisions = true }

    func releaseDecisions() {
        holdsDecisions = false
        heldDecision?.resume()
        heldDecision = nil
    }

    /// Returns once a decision has reached the server.
    func waitForDecision() async {
        guard decisions.isEmpty else { return }
        await withCheckedContinuation { decisionWaiter = $0 }
    }

    func list() async throws -> [FeedbackEntry] {
        listCalls += 1
        if let listError { throw listError }
        return entries
    }

    func plan(id: String) async throws -> String { planMarkdown }

    func create(_ body: FeedbackCreate) async throws -> FeedbackEntry {
        throw APIError.http(statusCode: 500, body: nil)
    }

    func decide(id: String, _ decision: FeedbackDecision) async throws -> FeedbackEntry {
        decisions.append(Decided(id: id, decision: decision))
        decisionWaiter?.resume()
        decisionWaiter = nil
        if holdsDecisions { await withCheckedContinuation { heldDecision = $0 } }
        if let decisionError { throw decisionError }
        if let decisionResult { return decisionResult }
        return try XCTUnwrap(entries.first { $0.id == id })
    }

    func isAvailable() async -> Bool { true }
}
