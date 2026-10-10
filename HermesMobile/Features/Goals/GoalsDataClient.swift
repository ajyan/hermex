import Foundation

/// The Goals API on this user's `hermes-webui` fork (`api/vault_goals.py`):
/// `GET /api/goals`, `GET /api/goals/detail?slug=` and `POST /api/goals/checkin`. Stock
/// upstream servers answer 404, which screens treat as "no Goals on this server".
protocol GoalsDataClient: Sendable {
    func home() async throws -> GoalsHome
    func detail(slug: String) async throws -> GoalDetail
    func checkIn(_ r: GoalCheckInRequest) async throws -> GoalCheckInResult
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol, decoding with
/// `PrepDecoding` (literal snake_case keys).
struct APIClientGoalsAdapter: GoalsDataClient {
    let apiClient: APIClient

    func home() async throws -> GoalsHome {
        try decode(try await apiClient.sendData(endpoint: .goalsHome, method: "GET"))
    }

    func detail(slug: String) async throws -> GoalDetail {
        try decode(try await apiClient.sendData(endpoint: .goalDetail(slug: slug), method: "GET"))
    }

    func checkIn(_ r: GoalCheckInRequest) async throws -> GoalCheckInResult {
        try decode(try await apiClient.sendData(endpoint: .goalCheckIn, method: "POST", body: r))
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PrepDecoding.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}
