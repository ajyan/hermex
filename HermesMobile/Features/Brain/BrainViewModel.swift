import Foundation

/// The read-only Brain API on this user's `hermes-webui` fork (`api/brain.py`):
/// `GET /api/brain/{modules,list,page,search,graph}`. Stock upstream servers
/// answer 404, which the screens show as "no Brain on this server".
/// Only GETs: the Second Brain is edited by the agent, never from the app.
protocol BrainDataClient: Sendable {
    func modules() async throws -> [BrainModule]
    func list(module: BrainModuleID, tag: String?, cursor: Int?) async throws -> BrainList
    func page(module: BrainModuleID, id: String) async throws -> BrainPage
    func search(query: String, module: BrainModuleID?) async throws -> BrainSearchResult
    func graph(module: BrainModuleID, id: String) async throws -> BrainGraph
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

    func page(module: BrainModuleID, id: String) async throws -> BrainPage {
        try await apiClient.send(endpoint: .brainPage(module: module.rawValue, id: id), method: "GET")
    }

    func search(query: String, module: BrainModuleID?) async throws -> BrainSearchResult {
        try await apiClient.send(endpoint: .brainSearch(query: query, module: module?.rawValue), method: "GET")
    }

    func graph(module: BrainModuleID, id: String) async throws -> BrainGraph {
        try await apiClient.send(endpoint: .brainGraph(module: module.rawValue, id: id), method: "GET")
    }
}
