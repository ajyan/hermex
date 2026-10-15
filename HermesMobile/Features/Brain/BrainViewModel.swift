import Foundation

/// The read-only Brain API on this user's `hermes-webui` fork (`api/brain.py`):
/// `GET /api/brain/{modules,list,page,search,home,people/home}`. Stock upstream servers
/// answer 404, which the screens show as "no Brain on this server".
/// Only GETs: the Second Brain is edited by the agent, never from the app.
protocol BrainDataClient: Sendable {
    func modules() async throws -> [BrainModule]
    func list(module: BrainModuleID, tag: String?, cursor: Int?) async throws -> BrainList
    /// One page; `hub` asks the server to place it in that hub (the pager keeps its hub this way).
    func page(module: BrainModuleID, id: String, hub: String?) async throws -> BrainPage
    func search(query: String, module: BrainModuleID?) async throws -> BrainSearchResult
    func home(batch: Int) async throws -> BrainHome
    func peopleHome() async throws -> BrainPeopleHome
}

enum BrainLoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    /// The server has no Brain API (a stock `hermes-webui`, or another server).
    case unavailable
    case failed(String)
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol.
struct APIClientBrainAdapter: BrainDataClient {
    let apiClient: APIClient

    func modules() async throws -> [BrainModule] {
        let response: BrainModulesResponse = try await apiClient.send(endpoint: .brainModules, method: "GET")
        return response.modules
    }

    func list(module: BrainModuleID, tag: String?, cursor: Int?) async throws -> BrainList {
        try await apiClient.send(endpoint: .brainList(module: module.rawValue, tag: tag, cursor: cursor), method: "GET")
    }

    func page(module: BrainModuleID, id: String, hub: String?) async throws -> BrainPage {
        try await apiClient.send(endpoint: .brainPage(module: module.rawValue, id: id, hub: hub), method: "GET")
    }

    func search(query: String, module: BrainModuleID?) async throws -> BrainSearchResult {
        try await apiClient.send(endpoint: .brainSearch(query: query, module: module?.rawValue), method: "GET")
    }

    func home(batch: Int) async throws -> BrainHome {
        try await apiClient.send(endpoint: .brainHome(batch: batch), method: "GET")
    }

    func peopleHome() async throws -> BrainPeopleHome {
        try await apiClient.send(endpoint: .brainPeopleHome, method: "GET")
    }
}
