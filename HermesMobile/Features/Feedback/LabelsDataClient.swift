import Foundation

/// The labels API on this user's `hermes-webui` fork (`api/labels.py`). Servers without it
/// answer 404, which `isAvailable()` reads as "no labels here".
protocol LabelsDataClient: Sendable {
    /// The latest label per key for `feature`, narrowed to one `item` when given.
    func labels(feature: String, item: String?) async throws -> [LabelRecord]
    func save(_ body: LabelCreate) async throws -> LabelRecord
    func isAvailable() async -> Bool
}

/// Wraps the `APIClient` actor in a `Sendable` value, decoding with `FeedbackDecoding`.
struct APIClientLabelsAdapter: LabelsDataClient {
    let apiClient: APIClient

    func labels(feature: String, item: String?) async throws -> [LabelRecord] {
        let data = try await apiClient.sendData(endpoint: .labels(feature: feature, item: item), method: "GET")
        return try decode(LabelList.self, data).labels
    }

    func save(_ body: LabelCreate) async throws -> LabelRecord {
        let data = try await apiClient.sendData(endpoint: .labels(feature: nil, item: nil), method: "POST", body: body)
        return try decode(LabelRecord.self, data)
    }

    /// False only on a 404; other failures (offline, auth) are not evidence the feature is missing.
    func isAvailable() async -> Bool {
        do {
            _ = try await apiClient.sendData(endpoint: .labels(feature: LabelKey.brainFeature, item: "_"), method: "GET")
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
}
