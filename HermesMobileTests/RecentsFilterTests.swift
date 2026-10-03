import XCTest
@testable import HermesMobile

final class RecentsFilterTests: XCTestCase {
    func testKindClassificationOrder() {
        XCTAssertEqual(RecentsFilter.kind(of: SessionSummary(sessionId: "cron_1", sourceTag: "claude_code")), .scheduled)
        XCTAssertEqual(RecentsFilter.kind(of: SessionSummary(sessionId: "a", isCliSession: true, sourceTag: "claude_code")), .claudeCode)
        XCTAssertEqual(RecentsFilter.kind(of: SessionSummary(sessionId: "a", rawSource: "telegram")), .messaging)
        XCTAssertEqual(RecentsFilter.kind(of: SessionSummary(sessionId: "a", isCliSession: true)), .cli)
        XCTAssertEqual(RecentsFilter.kind(of: SessionSummary(sessionId: "a")), .hermes)
        XCTAssertEqual(RecentsFilter.kind(of: SessionSummary(sessionId: "a", isCliSession: true, sessionSource: "webui")), .hermes)
    }

    func testAllIncludesEveryKind() {
        XCTAssertTrue(RecentsFilter.all.includes(SessionSummary(sessionId: "cron_1")))
        XCTAssertFalse(RecentsFilter.hermes.includes(SessionSummary(sessionId: "cron_1")))
    }

    func testAvailableListsOnlyPresentKinds() {
        let sessions = [
            SessionSummary(sessionId: "a"),
            SessionSummary(sessionId: "b", sourceTag: "claude_code")
        ]
        XCTAssertEqual(RecentsFilter.available(in: sessions), [.all, .hermes, .claudeCode])
        XCTAssertEqual(RecentsFilter.available(in: []), [.all, .hermes])
    }

    func testSelectedFilterFallsBackToHermesWhenKindDisappears() {
        XCTAssertEqual(RecentsFilter.resolved(.claudeCode, available: [.all, .hermes]), .hermes)
        XCTAssertEqual(RecentsFilter.resolved(.all, available: [.all, .hermes]), .all)
        XCTAssertEqual(RecentsFilter.resolved(.cli, available: [.all, .hermes, .cli]), .cli)
    }

    @MainActor
    func testAvailableFiltersIgnoreKindsHiddenBySettings() async throws {
        let viewModel = try await loadedViewModel()
        XCTAssertEqual(viewModel.availableRecentsFilters, [.all, .hermes, .claudeCode])

        viewModel.recentsVisibility = AutomatedSessionVisibility(showsCron: true, showsCli: true, showsClaudeCode: false)

        XCTAssertEqual(viewModel.availableRecentsFilters, [.all, .hermes])
        XCTAssertEqual(RecentsFilter.resolved(.claudeCode, available: viewModel.availableRecentsFilters), .hermes)
    }

    @MainActor
    func testViewModelFilterAppliesOnlyWithoutSearch() async throws {
        let viewModel = try await loadedViewModel()

        XCTAssertEqual(
            viewModel.visibleSessions(searchText: "", selectedProjectID: nil, filter: .hermes).compactMap(\.sessionId),
            ["hermes-1"]
        )
        XCTAssertEqual(
            Set(viewModel.visibleSessions(searchText: "alpha", selectedProjectID: nil, filter: .hermes).compactMap(\.sessionId)),
            ["hermes-1", "claude-1"]
        )
        XCTAssertEqual(viewModel.availableRecentsFilters, [.all, .hermes, .claudeCode])
    }

    @MainActor
    private func loadedViewModel() async throws -> SessionListViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        MockURLProtocol.requestHandler = { request in
            apiTestJSONResponse("""
            {
              "sessions": [
                {"session_id": "hermes-1", "title": "alpha", "last_message_at": 20},
                {"session_id": "claude-1", "title": "alpha code", "source_tag": "claude_code", "raw_source": "claude_code", "is_cli_session": true, "last_message_at": 10}
              ]
            }
            """, for: request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = APIClient(baseURL: server, session: URLSession(configuration: configuration))
        let viewModel = SessionListViewModel(server: server, client: client)

        await viewModel.load()
        return viewModel
    }
}
