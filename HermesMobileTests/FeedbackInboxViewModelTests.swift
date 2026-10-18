import XCTest
@testable import HermesMobile

@MainActor
final class FeedbackInboxViewModelTests: XCTestCase {
    func test409WithServerMessageShowsIt() async throws {
        let client = InboxStubClient(entries: [entry("r", status: "ready", ts: "2026-10-02T10:00:00Z")])
        await client.failDecisions(with: APIError.http(statusCode: 409, body: #"{"error": "Not on master yet. Merge the branch first, then mark merged."}"#))
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "r")), .merged)

        XCTAssertEqual(viewModel.error, "Not on master yet. Merge the branch first, then mark merged.")
        XCTAssertNil(viewModel.pendingID)
    }

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
        XCTAssertEqual(sections.map(\.group), [.toApprove, .toMerge, .toRetry, .inProgress, .done])
        XCTAssertEqual(sections[0].entries.map(\.id), ["b"])
        XCTAssertEqual(sections[1].entries.map(\.id), ["g"])
        XCTAssertEqual(sections[2].entries.map(\.id), ["d"])
        XCTAssertEqual(sections[3].entries.map(\.id), ["c", "f"])
        XCTAssertEqual(sections[4].entries.map(\.id), ["e", "a"])
        guard case .loaded(let groups) = viewModel.state else { return XCTFail("not loaded") }
        XCTAssertEqual(groups[.toApprove]?.map(\.id), ["b"])
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

    func testNewPlannedReadyAndFailedCanBeRejected() {
        let rejectable = [FeedbackStatus.new, .planning, .planned, .approved, .building, .ready, .failed, .rejected, .merged,
                          .shipped, .reverted, .unknown]
            .filter(\.canReject)
        XCTAssertEqual(rejectable, [.new, .planned, .ready, .failed])
    }

    func testRejectAvailableForNew() {
        XCTAssertTrue(FeedbackStatus.new.canReject)
        XCTAssertFalse(FeedbackStatus.new.hasDecisions, "a new note has no decisions to make")
        XCTAssertTrue(FeedbackStatus.new.hasActions, "its Drop sits alone in the action bar")
        XCTAssertEqual(FeedbackStatus.new.rejectConfirmation.title, "Drop this note?")
    }

    func testOnlyShippedCanBeUndone() {
        let undoable = [FeedbackStatus.new, .planning, .planned, .approved, .building, .ready, .failed, .rejected, .merged,
                        .shipped, .reverted, .unknown]
            .filter(\.canUndo)
        XCTAssertEqual(undoable, [.shipped])
    }

    func testUndoReplacesEntryWithTheServersUndone() async throws {
        let client = InboxStubClient(entries: [entry("s", status: "shipped", ts: "2026-10-02T10:00:00Z")])
        await client.setDecisionResult(entry("s", status: "reverted", ts: "2026-10-02T10:00:00Z"))
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "s")), .undo)

        let decisions = await client.decisions
        XCTAssertEqual(decisions.map(\.decision), [.undo])
        XCTAssertEqual(viewModel.entry(id: "s")?.status, .reverted)
        XCTAssertNil(viewModel.error)
    }

    func testMissingPlanTextTellsAFailedEntryWhatToDo() {
        XCTAssertEqual(FeedbackStatus.failed.noPlanText, "No plan. Retry to try again, or reject it.")
        XCTAssertEqual(FeedbackStatus.new.noPlanText, "No plan yet. One comes back tonight.")
        XCTAssertEqual(FeedbackStatus.planning.noPlanText, "No plan yet. One comes back tonight.")
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

    func testApproveSendsAnswersAsNote() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "b")), .approveAnswering("Q1 Keep? → No"))

        let decisions = await client.decisions
        XCTAssertEqual(decisions.map(\.decision), [.approveAnswering("Q1 Keep? → No")])
    }

    func testRequestCardActionsAndWords() throws {
        func make(_ json: String) throws -> FeedbackEntry {
            try FeedbackDecoding.decode(FeedbackEntry.self, from: Data(json.utf8))
        }
        // A plan with questions opens to answer them; only a plan without any builds from the card.
        XCTAssertEqual(try make(#"{"id":"a","status":"planned","question_count":1}"#).quickAction, .answer)
        XCTAssertEqual(try make(#"{"id":"a","status":"planned"}"#).quickAction, .build)
        XCTAssertEqual(try make(#"{"id":"a","status":"ready"}"#).quickAction, .review)
        XCTAssertEqual(try make(#"{"id":"a","status":"failed"}"#).quickAction, .retry)
        XCTAssertNil(try make(#"{"id":"a","status":"building"}"#).quickAction)
        XCTAssertEqual(try make(#"{"id":"a","after":"Cards lead with the gist","summary":"s"}"#).outcome, "Cards lead with the gist")
        XCTAssertEqual(try make(#"{"id":"a","after":" ","summary":"The summary"}"#).outcome, "The summary")
        XCTAssertEqual(try make(#"{"id":"a","error":"\nBlocked by a rule\nmore"}"#).errorLine, "Blocked by a rule")
        XCTAssertEqual(try make(#"{"id":"a","plan_repo":"second-brain","size":"S"}"#).placeLine, "second-brain · Small")
        XCTAssertNil(try make(#"{"id":"a"}"#).placeLine)
        let built = try make(#"{"id":"a","checks":[{"state":"ok","text":"a"},{"state":"ok","text":"b"},{"state":"warn","text":"c"}]}"#)
        XCTAssertEqual([built.checkCount(.ok), built.checkCount(.warn), built.checkCount(.fail)], [2, 1, 0])
        XCTAssertEqual(try make(#"{"id":"a","status":"new"}"#).progressWord, "Tonight")
        XCTAssertEqual(try make(#"{"id":"a","feature":"Daily Deck","size":"S","plan_repo":"second-brain"}"#).detailMetaLine,
                       "Daily Deck · small change · second-brain")
        XCTAssertEqual(try make(#"{"id":"a","feature":"Prep","size":"huge"}"#).detailMetaLine, "Prep")
    }

    func testPlanLoadsFromClient() async throws {
        let client = InboxStubClient(entries: [entry("b", status: "planned", ts: "2026-10-02T10:00:00Z")])
        await client.setPlan("# Plan\n\nDo the thing.")
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        let plan = await viewModel.plan(for: try XCTUnwrap(viewModel.entry(id: "b")))

        XCTAssertEqual(plan, .loaded(FeedbackPlan(markdown: "# Plan\n\nDo the thing.")))
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

    func testMergedEntryNamesAndOpensItsMainEntry() async throws {
        let client = InboxStubClient(entries: [
            entry("m", status: "planned", ts: "2026-10-02T10:00:00Z", title: "Shared fix"),
            entry("d", status: "rejected", ts: "2026-10-01T10:00:00Z", mergedInto: "m"),
        ])
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        let merged = try XCTUnwrap(viewModel.entry(id: "d"))
        XCTAssertEqual(viewModel.metaLine(for: merged), "Prep · Merged into Shared fix")
        XCTAssertEqual(viewModel.openedID(for: merged), "m")
        XCTAssertEqual(viewModel.sections.last?.group, .done)
    }

    func testMergedIntoAnEntryNotLoadedFallsBack() async throws {
        let client = InboxStubClient(entries: [
            entry("d", status: "rejected", ts: "2026-10-01T10:00:00Z", mergedInto: "0123456789ab"),
            entry("r", status: "rejected", ts: "2026-10-01T09:00:00Z"),
        ])
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        let merged = try XCTUnwrap(viewModel.entry(id: "d"))
        XCTAssertEqual(viewModel.metaLine(for: merged), "Prep · Merged into another note")
        XCTAssertEqual(viewModel.openedID(for: merged), "d")
        let rejected = try XCTUnwrap(viewModel.entry(id: "r"))
        XCTAssertEqual(viewModel.metaLine(for: rejected), "Prep · Rejected")
        XCTAssertEqual(viewModel.openedID(for: rejected), "r")
    }

    func testMainEntryListsItsMergedNotesOldestFirst() async {
        let client = InboxStubClient(entries: [
            entry("m", status: "new", ts: "2026-10-03T10:00:00Z"),
            entry("d2", status: "rejected", ts: "2026-10-02T10:00:00Z", mergedInto: "m"),
            entry("d1", status: "rejected", ts: "2026-10-01T10:00:00Z", mergedInto: "m"),
            entry("x", status: "rejected", ts: "2026-10-01T09:00:00Z", mergedInto: "other"),
            entry("r", status: "rejected", ts: "2026-10-01T08:00:00Z"),
        ])
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        XCTAssertEqual(viewModel.mergedNotes(into: "m").map(\.id), ["d1", "d2"])
        XCTAssertTrue(viewModel.mergedNotes(into: "r").isEmpty)
    }

    func testUnmergeWaitsForTheServerAndMovesTheNoteBack() async throws {
        let client = InboxStubClient(entries: [
            entry("m", status: "planned", ts: "2026-10-02T10:00:00Z", title: "Shared fix"),
            entry("d", status: "rejected", ts: "2026-10-01T10:00:00Z", mergedInto: "m"),
        ])
        await client.holdDecisions()
        await client.setDecisionResult(entry("d", status: "new", ts: "2026-10-01T10:00:00Z"))
        let viewModel = FeedbackInboxViewModel(client: client)
        await viewModel.load()

        let decision = Task { await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "d")), .unmerge) }
        await client.waitForDecision()
        XCTAssertEqual(viewModel.mergedNotes(into: "m").map(\.id), ["d"], "not optimistic")
        await client.releaseDecisions()
        try await decision.value

        let decisions = await client.decisions
        XCTAssertEqual(decisions.map(\.decision), [.unmerge])
        XCTAssertTrue(viewModel.mergedNotes(into: "m").isEmpty)
        XCTAssertEqual(viewModel.entry(id: "d")?.status, .new)
        XCTAssertNil(viewModel.entry(id: "d")?.mergedInto)
    }

    private func entry(_ id: String, status: String, ts: String, title: String? = nil, mergedInto: String? = nil) -> FeedbackEntry {
        var object: [String: Any] = ["id": id, "status": status, "ts": ts, "feature": "Prep", "text": "Note \(id)"]
        if let title { object["title"] = title }
        if let mergedInto { object["merged_into"] = mergedInto }
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

    func plan(id: String) async throws -> FeedbackPlan { FeedbackPlan(markdown: planMarkdown) }

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

/// Decisions through the real `APIClient` against `URLProtocol` mocks.
final class FeedbackDecisionHTTPTests: APIClientTestCase {
    @MainActor
    func testConflictShowsServerMessage() async throws {
        let shipped = #"{"entries": [{"id": "fb-1", "status": "ready", "ts": "2026-10-02T10:00:00Z", "text": "Fix it"}]}"#
        let client = makeClient { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/feedback/fb-1/decision")
                return apiTestJSONResponse(#"{"error": "Not on master yet. Merge the branch first, then mark merged."}"#, for: request, status: 409)
            }
            return apiTestJSONResponse(shipped, for: request)
        }
        let viewModel = FeedbackInboxViewModel(client: APIClientFeedbackAdapter(apiClient: client))
        await viewModel.load()

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "fb-1")), .merged)

        XCTAssertEqual(viewModel.error, "Not on master yet. Merge the branch first, then mark merged.")
    }

    @MainActor
    func testUndoConflictShowsTheVaultReason() async throws {
        let list = #"{"entries": [{"id": "fb-2", "status": "shipped", "ts": "2026-10-02T10:00:00Z", "text": "Fix it"}]}"#
        let client = makeClient { request in
            if request.httpMethod == "POST" {
                let body = apiTestBodyData(from: request) ?? Data()
                XCTAssertEqual(try? JSONSerialization.jsonObject(with: body) as? [String: String], ["decision": "undo"])
                return apiTestJSONResponse(#"{"error": "The vault has uncommitted edits to tools/deck_pool.py.", "revert_sha": null}"#, for: request, status: 409)
            }
            return apiTestJSONResponse(list, for: request)
        }
        let viewModel = FeedbackInboxViewModel(client: APIClientFeedbackAdapter(apiClient: client))
        await viewModel.load()

        await viewModel.decide(try XCTUnwrap(viewModel.entry(id: "fb-2")), .undo)

        XCTAssertEqual(viewModel.error, "The vault has uncommitted edits to tools/deck_pool.py.")
        XCTAssertEqual(viewModel.entry(id: "fb-2")?.status, .shipped)
    }
}
