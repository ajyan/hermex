import XCTest
@testable import HermesMobile

final class AutoArchivePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 86_400

    private func session(
        _ id: String,
        title: String = "Weather in Paris",
        idleDays: Double = 40,
        messages: Int = 2,
        pinned: Bool? = nil,
        isStreaming: Bool? = nil,
        activeStreamId: String? = nil,
        pending: Bool? = nil,
        readOnly: Bool? = nil,
        isCli: Bool? = nil,
        sourceTag: String? = nil,
        project: String? = nil
    ) -> SessionSummary {
        let last = now.timeIntervalSince1970 - idleDays * day
        return SessionSummary(
            sessionId: id,
            title: title,
            messageCount: messages,
            createdAt: last - 60,
            lastMessageAt: last,
            pinned: pinned,
            projectId: project,
            activeStreamId: activeStreamId,
            isStreaming: isStreaming,
            isCliSession: isCli,
            hasPendingUserMessage: pending,
            sourceTag: sourceTag,
            readOnly: readOnly
        )
    }

    private func plan(
        _ sessions: [SessionSummary],
        settings: AutoArchiveSettings = AutoArchiveSettings(),
        keptAt: [String: Double] = [:],
        excluded: Set<String> = [],
        model: KeepPreferenceModel = KeepPreferenceModel()
    ) -> AutoArchivePlan {
        AutoArchivePolicy.plan(
            sessions: sessions,
            now: now,
            settings: settings,
            keptAt: keptAt,
            excludedSessionIDs: excluded,
            scorer: model.scorer()
        )
    }

    func testPinnedRunningPendingReadOnlyExternalOpenAndUndatedChatsAreSkipped() {
        let undated = SessionSummary(sessionId: "undated", title: "x", messageCount: 2)
        let result = plan([
            session("pinned", pinned: true),
            session("streaming", isStreaming: true),
            session("active-stream", activeStreamId: "stream-1"),
            session("pending", pending: true),
            session("read-only", readOnly: true),
            session("cli", isCli: true),
            session("open"),
            undated,
            session("idle")
        ], excluded: ["open"])

        XCTAssertEqual(result.archive.compactMap(\.sessionId), ["idle"])
        XCTAssertTrue(result.review.isEmpty)
    }

    func testIdleThresholdIsInclusiveAtExactlyTheThreshold() {
        let atThreshold = session("at", idleDays: 30)
        let justUnder = SessionSummary(
            sessionId: "under",
            title: "Weather in Paris",
            messageCount: 2,
            lastMessageAt: now.timeIntervalSince1970 - 30 * day + 1
        )
        let result = plan([atThreshold, justUnder, session("fresh", idleDays: 3)])
        XCTAssertEqual(result.archive.compactMap(\.sessionId), ["at"])

        var weekly = AutoArchiveSettings()
        weekly.idleDays = 7
        XCTAssertEqual(
            plan([session("fresh", idleDays: 7)], settings: weekly).archive.compactMap(\.sessionId),
            ["fresh"]
        )
    }

    func testPriorSendsLongAndPersonalChatsToReviewAndArchivesTheRest() {
        let result = plan([
            session("long", title: "Refactor the parser", messages: 8),
            session("personal", title: "Career change thoughts", messages: 3),
            session("lookup", title: "Weather in Paris", messages: 2),
            session("short", title: "Hi", messages: 1),
            session("cron_daily", title: "Daily health report", messages: 20, sourceTag: "cron")
        ])

        XCTAssertEqual(Set(result.review.compactMap(\.sessionId)), ["long", "personal"])
        XCTAssertEqual(Set(result.archive.compactMap(\.sessionId)), ["lookup", "short", "cron_daily"])
    }

    func testAskingOffArchivesEveryIdleChatAndDisabledDoesNothing() {
        let sessions = [session("long", messages: 30), session("lookup")]
        var noAsk = AutoArchiveSettings()
        noAsk.asksBeforeArchivingKeepers = false
        XCTAssertEqual(plan(sessions, settings: noAsk).archive.count, 2)

        var off = AutoArchiveSettings()
        off.isEnabled = false
        XCTAssertEqual(plan(sessions, settings: off), AutoArchivePlan())
    }

    func testKeptChatIsNotOfferedAgainUntilAnotherFullThreshold() {
        let kept = session("kept", messages: 10)
        let recently = ["kept": now.timeIntervalSince1970 - 10 * day]
        XCTAssertEqual(plan([kept], keptAt: recently), AutoArchivePlan())

        let longAgo = ["kept": now.timeIntervalSince1970 - 30 * day]
        XCTAssertEqual(plan([kept], keptAt: longAgo).review.compactMap(\.sessionId), ["kept"])
    }

    func testPriorAppliesUntilThereAreEnoughDecisions() {
        var model = KeepPreferenceModel()
        for index in 0..<(KeepPreferenceModel.minimumExamples - 1) {
            model.train(session("toss-\(index)", title: "Weather in Paris"), kept: true)
        }
        XCTAssertEqual(model.score(session("new", title: "Weather in Rome")), 0.25)
    }

    func testRepeatedSummarizeDecisionsShiftATitleWordTowardKeeping() {
        var model = KeepPreferenceModel()
        for index in 0..<15 {
            model.train(session("bread-\(index)", title: "Sourdough starter \(index)", messages: 3), kept: true)
            model.train(session("weather-\(index)", title: "Weather in city \(index)", messages: 3), kept: false)
        }
        let sourdough = session("next-bread", title: "Sourdough hydration", messages: 3)
        let weather = session("next-weather", title: "Weather tomorrow", messages: 3)

        XCTAssertEqual(KeepPreferenceModel.priorScore(for: sourdough), 0.25)
        XCTAssertGreaterThan(model.score(sourdough), KeepPreferenceModel.candidateThreshold)
        XCTAssertLessThan(model.score(weather), KeepPreferenceModel.candidateThreshold)
        XCTAssertEqual(plan([sourdough, weather], model: model).review.compactMap(\.sessionId), ["next-bread"])
    }

    func testRepeatedPlainArchiveDecisionsShiftAPersonalWordTowardThrowaway() {
        var model = KeepPreferenceModel()
        for index in 0..<15 {
            model.train(session("interview-\(index)", title: "Interview slot \(index)", messages: 3), kept: false)
            model.train(session("novel-\(index)", title: "Novel outline \(index)", messages: 3), kept: true)
        }
        let interview = session("next", title: "Interview reschedule", messages: 3)

        XCTAssertEqual(KeepPreferenceModel.priorScore(for: interview), 0.75)
        XCTAssertLessThan(model.score(interview), KeepPreferenceModel.candidateThreshold)
    }

    func testANewerDecisionReplacesTheOlderOneAndExamplesAreCapped() {
        var model = KeepPreferenceModel()
        model.train(session("same"), kept: false)
        model.train(session("same"), kept: true)
        XCTAssertEqual(model.examples.count, 1)
        XCTAssertEqual(model.examples.first?.kept, true)

        for index in 0..<(KeepPreferenceModel.maximumExamples + 5) {
            model.train(session("s\(index)"), kept: false)
        }
        XCTAssertEqual(model.examples.count, KeepPreferenceModel.maximumExamples)
        XCTAssertEqual(model.examples.last?.sessionID, "s\(KeepPreferenceModel.maximumExamples + 4)")
    }

    func testStoreKeepsSettingsModelAndKeepMarksPerServer() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoArchivePolicyTests.\(UUID().uuidString)"))
        let store = AutoArchiveStore(defaults: defaults)
        let first = try XCTUnwrap(URL(string: "https://one.test"))
        let second = try XCTUnwrap(URL(string: "https://two.test"))

        XCTAssertEqual(store.settings(for: first), AutoArchiveSettings())
        defaults.set(false, forKey: AutoArchiveStore.isEnabledKey(for: first))
        defaults.set(7, forKey: AutoArchiveStore.idleDaysKey(for: first))
        var model = KeepPreferenceModel()
        model.train(session("a"), kept: true)
        store.setModel(model, for: first)
        store.markKept("a", at: now, for: first)

        XCTAssertFalse(store.settings(for: first).isEnabled)
        XCTAssertEqual(store.settings(for: first).idleDays, 7)
        XCTAssertEqual(store.settings(for: second), AutoArchiveSettings())
        XCTAssertEqual(store.model(for: first), model)
        XCTAssertEqual(store.model(for: second), KeepPreferenceModel())
        XCTAssertTrue(store.keptAt(for: second).isEmpty)

        store.setModel(model, for: second)
        store.remove(for: first)
        XCTAssertEqual(store.model(for: first), KeepPreferenceModel())
        XCTAssertTrue(store.keptAt(for: first).isEmpty)
        XCTAssertEqual(store.model(for: second), model)
    }
}

/// The runner on `SessionListViewModel`, against a scripted server.
final class AutoArchiveRunnerTests: XCTestCase {
    private let server = URL(string: "https://example.test")!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// A tiny thread-safe fake of the endpoints the runner touches.
    private final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [[String: Any]]
        private(set) var archivedIDs: [String] = []
        private(set) var unarchivedIDs: [String] = []
        private(set) var startedMessages: [String] = []
        private(set) var cancelledStreams: [String] = []
        var statusReplies: [String]

        init(sessions: [[String: Any]], statusReplies: [String] = []) {
            self.sessions = sessions
            self.statusReplies = statusReplies
        }

        var archived: [String] { lock.withLock { archivedIDs } }
        var unarchived: [String] { lock.withLock { unarchivedIDs } }
        var started: [String] { lock.withLock { startedMessages } }
        var cancelled: [String] { lock.withLock { cancelledStreams } }

        func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
            try lock.withLock {
                switch request.url?.path {
                case "/api/sessions":
                    let visible = sessions.filter { ($0["archived"] as? Bool) != true }
                    let data = try JSONSerialization.data(withJSONObject: ["sessions": visible])
                    return apiTestJSONResponse(String(decoding: data, as: UTF8.self), for: request)
                case "/api/session/archive":
                    let body = try apiTestJSONBody(from: request)
                    let id = try XCTUnwrap(body["session_id"] as? String)
                    let archived = try XCTUnwrap(body["archived"] as? Bool)
                    if archived { archivedIDs.append(id) } else { unarchivedIDs.append(id) }
                    for index in sessions.indices where sessions[index]["session_id"] as? String == id {
                        sessions[index]["archived"] = archived
                    }
                    return apiTestJSONResponse(#"{"ok": true}"#, for: request)
                case "/api/chat/start":
                    let body = try apiTestJSONBody(from: request)
                    startedMessages.append(try XCTUnwrap(body["message"] as? String))
                    return apiTestJSONResponse(#"{"stream_id": "stream-1"}"#, for: request)
                case "/api/chat/stream/status":
                    let reply = statusReplies.isEmpty ? #"{"active": true}"# : statusReplies.removeFirst()
                    return apiTestJSONResponse(reply, for: request)
                case "/api/chat/cancel":
                    cancelledStreams.append("stream-1")
                    return apiTestJSONResponse(#"{"ok": true, "cancelled": true}"#, for: request)
                default:
                    XCTFail("Unexpected request \(request.url?.path ?? "")")
                    return apiTestJSONResponse(#"{}"#, for: request)
                }
            }
        }
    }

    private func row(_ id: String, title: String, messages: Int, idleDays: Double) -> [String: Any] {
        let last = now.timeIntervalSince1970 - idleDays * 86_400
        return ["session_id": id, "title": title, "message_count": messages, "created_at": last - 60, "last_message_at": last]
    }

    @MainActor
    private func makeViewModel(_ fake: FakeServer) throws -> (SessionListViewModel, AutoArchiveStore) {
        MockURLProtocol.requestHandler = { try fake.handle($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoArchiveRunnerTests.\(UUID().uuidString)"))
        let store = AutoArchiveStore(defaults: defaults)
        let unread = SessionUnreadStore(defaults: defaults)
        let viewModel = SessionListViewModel(server: server, client: client, unreadStore: unread, autoArchiveStore: store) { [now] in now }
        viewModel.digestSummarizer = ChatDigestSummarizer(
            client: client,
            pollInterval: .seconds(1),
            timeout: .seconds(3),
            sleep: { _ in }
        )
        return (viewModel, store)
    }

    @MainActor
    func testPassArchivesThrowawaysHoldsCandidatesAndRunsOncePerForeground() async throws {
        let fake = FakeServer(sessions: [
            row("lookup", title: "Weather in Paris", messages: 2, idleDays: 40),
            row("long", title: "Planning the garden", messages: 12, idleDays: 40),
            row("fresh", title: "Weather today", messages: 2, idleDays: 1)
        ])
        let (viewModel, _) = try makeViewModel(fake)
        await viewModel.load()

        let archived = await viewModel.runAutoArchivePassIfDue(excludingSessionID: nil)

        XCTAssertEqual(archived.compactMap(\.sessionId), ["lookup"])
        XCTAssertEqual(fake.archived, ["lookup"])
        XCTAssertEqual(viewModel.archiveReviewCandidates.compactMap(\.sessionId), ["long"])
        XCTAssertEqual(Set(viewModel.sessions.compactMap(\.sessionId)), ["long", "fresh"])
        XCTAssertTrue(fake.started.isEmpty, "The pass never summarizes on its own")

        let second = await viewModel.runAutoArchivePassIfDue(excludingSessionID: nil)
        XCTAssertTrue(second.isEmpty)
        viewModel.noteAppForegrounded()
        XCTAssertTrue(viewModel.isAutoArchiveDue)
    }

    @MainActor
    func testUndoOfAnAutoArchiveRestoresTheBatchAndRecordsKeepSignals() async throws {
        let fake = FakeServer(sessions: [row("lookup", title: "Weather in Paris", messages: 2, idleDays: 40)])
        let (viewModel, store) = try makeViewModel(fake)
        await viewModel.load()
        let archived = await viewModel.runAutoArchivePassIfDue(excludingSessionID: nil)

        let didUndo = await viewModel.undoAutoArchive(archived)

        XCTAssertTrue(didUndo)
        XCTAssertEqual(fake.unarchived, ["lookup"])
        XCTAssertEqual(store.model(for: server).examples.map(\.kept), [true])
        XCTAssertNotNil(store.keptAt(for: server)["lookup"])
        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["lookup"])
    }

    @MainActor
    func testReviewArchiveAndKeepRecordTheirDecisions() async throws {
        let fake = FakeServer(sessions: [
            row("a", title: "Planning the garden", messages: 12, idleDays: 40),
            row("b", title: "Family trip", messages: 12, idleDays: 40)
        ])
        let (viewModel, store) = try makeViewModel(fake)
        await viewModel.load()
        _ = await viewModel.runAutoArchivePassIfDue(excludingSessionID: nil)
        XCTAssertEqual(viewModel.archiveReviewCandidates.count, 2)

        let a = try XCTUnwrap(viewModel.archiveReviewCandidates.first { $0.sessionId == "a" })
        let b = try XCTUnwrap(viewModel.archiveReviewCandidates.first { $0.sessionId == "b" })
        let failure = await viewModel.archiveFromReview(a)
        viewModel.keepFromReview(b)

        XCTAssertNil(failure)
        XCTAssertEqual(fake.archived, ["a"])
        XCTAssertTrue(fake.started.isEmpty)
        XCTAssertTrue(viewModel.archiveReviewCandidates.isEmpty)
        let examples = store.model(for: server).examples
        XCTAssertEqual(examples.first { $0.sessionID == "a" }?.kept, false)
        XCTAssertEqual(examples.first { $0.sessionID == "b" }?.kept, true)
        XCTAssertNotNil(store.keptAt(for: server)["b"])
    }

    @MainActor
    func testSummarizeArchivesOnlyAfterTheRunCompletes() async throws {
        let fake = FakeServer(
            sessions: [row("a", title: "Planning the garden", messages: 12, idleDays: 40)],
            statusReplies: [
                #"{"active": true}"#,
                #"{"active": false, "journal": {"terminal": true, "terminal_state": "completed"}}"#
            ]
        )
        let (viewModel, store) = try makeViewModel(fake)
        await viewModel.load()
        let session = try XCTUnwrap(viewModel.sessions.first)

        let failure = await viewModel.summarizeAndArchive(session)

        XCTAssertNil(failure)
        XCTAssertEqual(fake.started, [ChatDigestSummarizer.prompt])
        XCTAssertEqual(fake.archived, ["a"])
        XCTAssertEqual(store.model(for: server).examples.map(\.kept), [true])
        XCTAssertFalse(viewModel.isSummarizing(session))
    }

    @MainActor
    func testSummarizeFailureOrTimeoutLeavesTheChatUnarchived() async throws {
        let failed = FakeServer(
            sessions: [row("a", title: "Planning the garden", messages: 12, idleDays: 40)],
            statusReplies: [#"{"active": false, "journal": {"terminal": true, "terminal_state": "errored"}}"#]
        )
        let (failedModel, failedStore) = try makeViewModel(failed)
        await failedModel.load()
        let failure = await failedModel.summarizeAndArchive(try XCTUnwrap(failedModel.sessions.first))

        XCTAssertNotNil(failure)
        XCTAssertTrue(failed.archived.isEmpty)
        XCTAssertTrue(failedStore.model(for: server).examples.isEmpty)

        let stuck = FakeServer(sessions: [row("a", title: "Planning the garden", messages: 12, idleDays: 40)])
        let (stuckModel, _) = try makeViewModel(stuck)
        await stuckModel.load()
        let timeout = await stuckModel.summarizeAndArchive(try XCTUnwrap(stuckModel.sessions.first))

        XCTAssertNotNil(timeout)
        XCTAssertTrue(stuck.archived.isEmpty)
        XCTAssertEqual(stuck.cancelled, ["stream-1"], "A run still going at the timeout is stopped")
    }

    @MainActor
    func testShortChatIsArchivedWithoutASummary() async throws {
        let fake = FakeServer(sessions: [row("a", title: "Hi", messages: 1, idleDays: 40)])
        let (viewModel, _) = try makeViewModel(fake)
        await viewModel.load()

        let failure = await viewModel.summarizeAndArchive(try XCTUnwrap(viewModel.sessions.first))

        XCTAssertNil(failure)
        XCTAssertTrue(fake.started.isEmpty)
        XCTAssertEqual(fake.archived, ["a"])
    }
}
