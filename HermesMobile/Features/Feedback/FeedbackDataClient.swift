import Foundation

/// The feedback API on this user's `hermes-webui` fork (`api/feedback.py`). Servers without
/// the vault answer 404 on every endpoint, which `isAvailable()` reads as "no feedback here".
protocol FeedbackDataClient: Sendable {
    func list() async throws -> [FeedbackEntry]
    func plan(id: String) async throws -> String
    func create(_ body: FeedbackCreate) async throws -> FeedbackEntry
    func decide(id: String, _ decision: FeedbackDecision) async throws -> FeedbackEntry
    func isAvailable() async -> Bool
}

/// Wraps the `APIClient` actor in a `Sendable` value, decoding with `FeedbackDecoding`.
struct APIClientFeedbackAdapter: FeedbackDataClient {
    let apiClient: APIClient

    func list() async throws -> [FeedbackEntry] {
        let data = try await apiClient.sendData(endpoint: .feedbackList, method: "GET")
        return try decodeList(data)
    }

    func plan(id: String) async throws -> String {
        let data = try await apiClient.sendData(endpoint: .feedbackPlan(id: id), method: "GET")
        return try decode(FeedbackPlan.self, data).markdown
    }

    func create(_ body: FeedbackCreate) async throws -> FeedbackEntry {
        let data = try await apiClient.sendData(endpoint: .feedbackList, method: "POST", body: body)
        return try decode(FeedbackEntry.self, data)
    }

    func decide(id: String, _ decision: FeedbackDecision) async throws -> FeedbackEntry {
        let data = try await apiClient.sendData(endpoint: .feedbackDecision(id: id), method: "POST", body: decision)
        return try decode(FeedbackEntry.self, data)
    }

    /// False only on a 404; other failures (offline, auth) are not evidence the feature is missing.
    func isAvailable() async -> Bool {
        do {
            _ = try await apiClient.sendData(endpoint: .feedbackList, method: "GET")
            return true
        } catch let APIError.http(statusCode, _) where statusCode == 404 {
            return false
        } catch {
            return true
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        do {
            return try FeedbackDecoding.decode(type, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    private func decodeList(_ data: Data) throws -> [FeedbackEntry] {
        try decode(FeedbackList.self, data).entries
    }
}
