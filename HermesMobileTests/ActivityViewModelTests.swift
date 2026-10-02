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

    func atlasRules() async throws -> AtlasRulesSnapshot {
        throw APIError.http(statusCode: 500, body: nil)
    }
}

/// A client that replays a scripted sequence of event pages, in order, and
/// stops when the pages run out.
final class ScriptedActivityClient: AtlasActivityDataClient, @unchecked Sendable {
    private var pages: [AtlasActivityPage]
    private(set) var requestedBefore: [Int?] = []
    private(set) var requestedFilters: [AtlasActivityFilter] = []
    private(set) var requestedLimits: [Int] = []

    init(pages: [AtlasActivityPage]) {
        self.pages = pages
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
