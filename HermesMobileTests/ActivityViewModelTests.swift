import XCTest
import Foundation
import Observation
@testable import HermesMobile

final class ActivityViewModelTests: XCTestCase {
    // MARK: - Error mapping

    @MainActor
    func testNotConsentedAndDownMapToDistinctStates() async throws {
        let cases: [(Int, ActivityLoadState)] = [
            (403, .notConsented),
            (404, .notInstalled),
            (502, .serviceDown),
            (503, .serviceDown)
        ]

        for (status, expected) in cases {
            let client = HTTPStatusActivityClient(status: status)
            let viewModel = ActivityViewModel(client: client)

            await viewModel.reload()

            XCTAssertEqual(viewModel.state, expected, "status \(status)")
            XCTAssertTrue(viewModel.events.isEmpty, "status \(status)")
        }

        let failingClient = HTTPStatusActivityClient(status: 500)
        let failingViewModel = ActivityViewModel(client: failingClient)
        await failingViewModel.reload()

        guard case let .failed(message) = failingViewModel.state else {
            return XCTFail("Expected .failed, got \(failingViewModel.state)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Pagination

    @MainActor
    func testLoadMoreAppendsUsingNextBeforeAndStopsAtNil() async throws {
        let firstPage = pageJSON(
            events: [eventJSON(id: 3, summary: "First"), eventJSON(id: 2, summary: "Second")],
            nextBefore: 2
        )
        let secondPage = pageJSON(
            events: [eventJSON(id: 1, summary: "Third")],
            nextBefore: nil
        )
        let client = ScriptedActivityClient(pages: [firstPage, secondPage])
        let viewModel = ActivityViewModel(client: client)

        await viewModel.reload()

        XCTAssertEqual(viewModel.events.map(\.id), [3, 2])
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(client.requestedBefore, [nil])
        XCTAssertFalse(viewModel.isLoadingMore)

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.events.map(\.id), [3, 2, 1])
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(client.requestedBefore, [nil, 2])
        XCTAssertFalse(viewModel.isLoadingMore)

        // `nextBefore` is nil, so a further loadMore is a no-op.
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.events.map(\.id), [3, 2, 1])
        XCTAssertEqual(client.requestedBefore, [nil, 2])
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    // MARK: - Filter changes

    @MainActor
    func testChangingFilterReloadsFromTop() async throws {
        let firstPage = pageJSON(
            events: [eventJSON(id: 3, summary: "Attention one")],
            nextBefore: 3
        )
        let client = ScriptedActivityClient(pages: [firstPage, firstPage])
        let viewModel = ActivityViewModel(client: client)

        await viewModel.reload()
        XCTAssertEqual(viewModel.filter, .all)
        XCTAssertEqual(client.requestedFilters, [.all])

        viewModel.filter = .attention
        await viewModel.reload()

        XCTAssertEqual(viewModel.events.map(\.id), [3])
        XCTAssertEqual(viewModel.state, .loaded)
        // The second request starts from the top (no cursor) with the new filter.
        XCTAssertEqual(client.requestedFilters, [.all, .attention])
        XCTAssertEqual(client.requestedBefore, [nil, nil])
    }

    // MARK: - Episodes

    @MainActor
    func testAttentionWithEpisodesSuccess() async throws {
        let eventsPage = pageJSON(
            events: [eventJSON(id: 5, summary: "Event five")],
            nextBefore: 5
        )
        let episodeFirst = episodePageJSON(
            episodes: [episodeJSON(firstId: 9, lastId: 4, count: 6, actionNeeded: "Fix the script")],
            nextBefore: 4
        )
        let client = ScriptedActivityClient(pages: [eventsPage], episodePages: [episodeFirst])
        let viewModel = ActivityViewModel(client: client)
        viewModel.filter = .attention

        await viewModel.reload()

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.events.map(\.id), [5])
        XCTAssertTrue(viewModel.episodesAvailable)
        XCTAssertEqual(viewModel.episodes.map(\.id), [9])
        XCTAssertEqual(viewModel.episodes.first?.count, 6)
        XCTAssertEqual(viewModel.episodes.first?.actionNeeded, "Fix the script")
        // The episode request starts from the top with the attention filter.
        XCTAssertEqual(client.requestedEpisodeBefore, [nil])
        XCTAssertEqual(client.requestedEpisodeFilters, [.attention])
    }

    @MainActor
    func testEpisodes404LeavesEventsAlone() async throws {
        let eventsPage = pageJSON(
            events: [eventJSON(id: 5, summary: "Event five")],
            nextBefore: 5
        )
        let client = EpisodesErrorActivityClient(eventsPage: eventsPage, episodeStatus: 404)
        let viewModel = ActivityViewModel(client: client)
        viewModel.filter = .attention

        await viewModel.reload()

        // A 404 means the sidecar predates episodes: the feature is absent,
        // but the events state and data are untouched.
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.events.map(\.id), [5])
        XCTAssertFalse(viewModel.episodesAvailable)
        XCTAssertTrue(viewModel.episodes.isEmpty)
        XCTAssertEqual(client.episodeCallCount, 1)
    }

    @MainActor
    func testEpisodesOtherErrorLeavesEventsAlone() async throws {
        let eventsPage = pageJSON(
            events: [eventJSON(id: 5, summary: "Event five")],
            nextBefore: 5
        )
        let client = EpisodesErrorActivityClient(eventsPage: eventsPage, episodeStatus: 500)
        let viewModel = ActivityViewModel(client: client)
        viewModel.filter = .attention

        await viewModel.reload()

        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.events.map(\.id), [5])
        XCTAssertFalse(viewModel.episodesAvailable)
        XCTAssertTrue(viewModel.episodes.isEmpty)
    }

    @MainActor
    func testNonAttentionNeverCallsEpisodes() async throws {
        let eventsPage = pageJSON(
            events: [eventJSON(id: 3, summary: "All three")],
            nextBefore: 3
        )
        let client = ScriptedActivityClient(pages: [eventsPage, eventsPage])
        let viewModel = ActivityViewModel(client: client)

        for filter in [AtlasActivityFilter.all, .cron, .spending] {
            viewModel.filter = filter
            await viewModel.reload()
            XCTAssertEqual(viewModel.events.map(\.id), [3], "filter \(filter)")
            XCTAssertFalse(viewModel.episodesAvailable, "filter \(filter)")
            XCTAssertTrue(viewModel.episodes.isEmpty, "filter \(filter)")
        }

        XCTAssertEqual(client.requestedEpisodeBefore, [], "episodes should never be requested for non-attention filters")
        XCTAssertTrue(client.requestedEpisodeFilters.isEmpty)
    }

    @MainActor
    func testEpisodeLoadMoreAppendsAndStopsAtNil() async throws {
        let eventsFirst = pageJSON(events: [eventJSON(id: 3, summary: "First")], nextBefore: 2)
        let eventsSecond = pageJSON(events: [eventJSON(id: 1, summary: "Second")], nextBefore: nil)
        let episodesFirst = episodePageJSON(episodes: [episodeJSON(firstId: 9, lastId: 4, count: 6)], nextBefore: 4)
        let episodesSecond = episodePageJSON(episodes: [episodeJSON(firstId: 3, lastId: 1, count: 2)], nextBefore: nil)
        let client = ScriptedActivityClient(
            pages: [eventsFirst, eventsSecond],
            episodePages: [episodesFirst, episodesSecond]
        )
        let viewModel = ActivityViewModel(client: client)
        viewModel.filter = .attention

        await viewModel.reload()

        XCTAssertEqual(viewModel.episodes.map(\.id), [9])
        XCTAssertEqual(viewModel.events.map(\.id), [3])
        XCTAssertEqual(client.requestedEpisodeBefore, [nil])
        XCTAssertEqual(client.requestedBefore, [nil])

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.episodes.map(\.id), [9, 3])
        XCTAssertEqual(viewModel.events.map(\.id), [3, 1])
        // The episode page was fetched with its own cursor.
        XCTAssertEqual(client.requestedEpisodeBefore, [nil, 4])
        XCTAssertEqual(client.requestedBefore, [nil, 2])

        // The events cursor is now nil, so a further loadMore is a no-op and
        // no further episode page is fetched.
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.episodes.map(\.id), [9, 3])
        XCTAssertEqual(viewModel.events.map(\.id), [3, 1])
        XCTAssertEqual(client.requestedEpisodeBefore, [nil, 4])
        XCTAssertEqual(client.requestedBefore, [nil, 2])
    }

    @MainActor
    func testReloadResetsEpisodeCursor() async throws {
        let eventsPage = pageJSON(events: [eventJSON(id: 3, summary: "First")], nextBefore: 2)
        let episodesFirst = episodePageJSON(episodes: [episodeJSON(firstId: 9, lastId: 4, count: 6)], nextBefore: 4)
        let episodesSecond = episodePageJSON(episodes: [episodeJSON(firstId: 3, lastId: 1, count: 2)], nextBefore: nil)
        let client = ScriptedActivityClient(
            pages: [eventsPage, eventsPage],
            episodePages: [episodesFirst, episodesSecond, episodesFirst]
        )
        let viewModel = ActivityViewModel(client: client)
        viewModel.filter = .attention

        await viewModel.reload()
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.episodes.map(\.id), [9, 3])
        XCTAssertEqual(client.requestedEpisodeBefore, [nil, 4])

        await viewModel.reload()

        // The second reload starts episodes from the top again (no cursor).
        XCTAssertEqual(client.requestedEpisodeBefore, [nil, 4, nil])
        XCTAssertEqual(viewModel.episodes.map(\.id), [9])
        XCTAssertTrue(viewModel.episodesAvailable)
    }

    // MARK: - Service down keeps the last page

    @MainActor
    func testServiceDownKeepsPreviousEvents() async throws {
        let firstPage = pageJSON(
            events: [eventJSON(id: 5, summary: "Cached one"), eventJSON(id: 4, summary: "Cached two")],
            nextBefore: 4
        )
        let client = HTTPStatusActivityClient(status: 503, firstResponse: firstPage)
        let viewModel = ActivityViewModel(client: client)

        await viewModel.reload()
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.events.map(\.id), [5, 4])

        await viewModel.reload()

        XCTAssertEqual(viewModel.state, .serviceDown)
        // The last cached page stays on screen instead of being cleared.
        XCTAssertEqual(viewModel.events.map(\.id), [5, 4])
    }
}

// MARK: - Test doubles

/// A client that returns one fixed HTTP status (and optionally one good first
/// response before switching to it).
final class HTTPStatusActivityClient: AtlasActivityDataClient, @unchecked Sendable {
    private let status: Int
    private let firstResponse: AtlasActivityPage?
    private var responded = false

    init(status: Int, firstResponse: AtlasActivityPage? = nil) {
        self.status = status
        self.firstResponse = firstResponse
    }

    func atlasActivity(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasActivityPage {
        if let firstResponse, !responded {
            responded = true
            return firstResponse
        }

        throw APIError.http(statusCode: status, body: nil)
    }

    func atlasEpisodes(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasEpisodePage {
        throw APIError.http(statusCode: 404, body: nil)
    }

    func atlasRules() async throws -> AtlasRulesSnapshot {
        throw APIError.http(statusCode: 500, body: nil)
    }
}

/// A client that replays a scripted sequence of event pages, in order, and
/// stops when the pages run out.
final class ScriptedActivityClient: AtlasActivityDataClient, @unchecked Sendable {
    private var pages: [AtlasActivityPage]
    private var episodePages: [AtlasEpisodePage]
    private(set) var requestedBefore: [Int?] = []
    private(set) var requestedFilters: [AtlasActivityFilter] = []
    private(set) var requestedLimits: [Int] = []
    private(set) var requestedEpisodeBefore: [Int?] = []
    private(set) var requestedEpisodeFilters: [AtlasActivityFilter] = []

    init(pages: [AtlasActivityPage], episodePages: [AtlasEpisodePage] = []) {
        self.pages = pages
        self.episodePages = episodePages
    }

    func atlasActivity(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasActivityPage {
        requestedBefore.append(before)
        requestedFilters.append(filter)
        requestedLimits.append(limit)
        guard !pages.isEmpty else {
            throw APIError.http(statusCode: 500, body: nil)
        }
        return pages.removeFirst()
    }

    func atlasEpisodes(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasEpisodePage {
        requestedEpisodeBefore.append(before)
        requestedEpisodeFilters.append(filter)
        guard !episodePages.isEmpty else {
            throw APIError.http(statusCode: 500, body: nil)
        }
        return episodePages.removeFirst()
    }

    func atlasRules() async throws -> AtlasRulesSnapshot {
        AtlasRulesSnapshot(rules: [], error: nil)
    }
}

// MARK: - JSON fixtures

private func eventJSON(id: Int, summary: String, ts: String = "2026-10-02T17:08:14Z") -> String {
    """
    {
      "id": \(id),
      "ts": "\(ts)",
      "session_id": null,
      "source": "tool",
      "tool_name": "terminal",
      "summary": "\(summary)",
      "rule_id": null,
      "outcome": "ok",
      "duration_ms": 10
    }
    """
}

private func pageJSON(events: [String], nextBefore: Int?) -> AtlasActivityPage {
    let json = """
    {
      "events": [\(events.joined(separator: ","))],
      "next_before": \(nextBefore.map { String($0) } ?? "null")
    }
    """
    return try! AtlasActivityTimestampFormatter.decoder.decode(
        AtlasActivityPage.self,
        from: Data(json.utf8)
    )
}

private func episodeJSON(
    firstId: Int,
    lastId: Int,
    count: Int = 1,
    rulePlain: String? = "Plain rule",
    actionNeeded: String = "",
    firstTs: String = "2026-10-02T17:12:00Z",
    lastTs: String = "2026-10-02T17:14:00Z"
) -> String {
    """
    {
      "rule_id": "rule-\(firstId)",
      "rule_plain": \(rulePlain.map { "\"\($0)\"" } ?? "null"),
      "session_id": null,
      "first_ts": "\(firstTs)",
      "last_ts": "\(lastTs)",
      "count": \(count),
      "tools": ["terminal"],
      "outcomes": ["ok"],
      "sample_command": "ls",
      "action_needed": "\(actionNeeded)",
      "first_id": \(firstId),
      "last_id": \(lastId)
    }
    """
}

private func episodePageJSON(episodes: [String], nextBefore: Int?) -> AtlasEpisodePage {
    let json = """
    {
      "episodes": [\(episodes.joined(separator: ","))],
      "next_before": \(nextBefore.map { String($0) } ?? "null")
    }
    """
    return try! AtlasActivityTimestampFormatter.decoder.decode(
        AtlasEpisodePage.self,
        from: Data(json.utf8)
    )
}

/// A client that answers `atlasActivity` with one fixed page and
/// `atlasEpisodes` with a fixed HTTP status, so the tests can exercise the
/// episode feature-detection without scripting success pages.
final class EpisodesErrorActivityClient: AtlasActivityDataClient, @unchecked Sendable {
    private let eventsPage: AtlasActivityPage
    private let episodeStatus: Int
    private(set) var episodeCallCount = 0

    init(eventsPage: AtlasActivityPage, episodeStatus: Int) {
        self.eventsPage = eventsPage
        self.episodeStatus = episodeStatus
    }

    func atlasActivity(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasActivityPage {
        eventsPage
    }

    func atlasEpisodes(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasEpisodePage {
        episodeCallCount += 1
        throw APIError.http(statusCode: episodeStatus, body: nil)
    }

    func atlasRules() async throws -> AtlasRulesSnapshot {
        AtlasRulesSnapshot(rules: [], error: nil)
    }
}
