import Foundation

/// The Goals API on this user's `hermes-webui` fork (`api/vault_goals.py`):
/// `GET /api/goals`, `GET /api/goals/detail?slug=`, `POST /api/goals/checkin`,
/// `POST /api/goals/week`, and for a finished goal `POST /api/goals/finish`,
/// `GET /api/goals/record?slug=`, `POST /api/goals/reflection` and `POST /api/goals/reopen`. Stock
/// upstream servers answer 404, which screens treat as "no Goals on this server".
protocol GoalsDataClient: Sendable {
    func home() async throws -> GoalsHome
    func detail(slug: String) async throws -> GoalDetail
    /// Posts one tap; `clientID` is fresh per tap, so the server ignores a repeat of it.
    func checkIn(_ r: GoalCheckInRequest, clientID: String) async throws -> GoalCheckInResult
    /// Confirms a goal's commitments for the week starting `r.start`; answers like a check-in.
    func confirmWeek(_ r: GoalWeekRequest) async throws -> GoalCheckInResult
    /// Closes the goal as achieved and returns its record.
    func finish(_ r: GoalFinishRequest) async throws -> GoalRecord
    func record(slug: String) async throws -> GoalRecord
    /// Reopens a finished goal and returns it as `detail(slug:)` would: 404 when it isn't a
    /// finished goal, 409 when an open goal already has its slug.
    func reopen(slug: String) async throws -> GoalDetail
    /// Saves his reflection on a finished goal and returns the record.
    func saveReflection(_ r: GoalReflectionRequest) async throws -> GoalRecord
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

    func checkIn(_ r: GoalCheckInRequest, clientID: String) async throws -> GoalCheckInResult {
        let body = GoalCheckInPost(request: r, clientID: clientID)
        return try decode(try await apiClient.sendData(endpoint: .goalCheckIn, method: "POST", body: body))
    }

    func confirmWeek(_ r: GoalWeekRequest) async throws -> GoalCheckInResult {
        try decode(try await apiClient.sendData(endpoint: .goalWeek, method: "POST", body: r))
    }

    func finish(_ r: GoalFinishRequest) async throws -> GoalRecord {
        try decode(try await apiClient.sendData(endpoint: .goalFinish, method: "POST", body: r))
    }

    func record(slug: String) async throws -> GoalRecord {
        try decode(try await apiClient.sendData(endpoint: .goalRecord(slug: slug), method: "GET"))
    }

    func reopen(slug: String) async throws -> GoalDetail {
        try decode(try await apiClient.sendData(endpoint: .goalReopen, method: "POST", body: GoalReopenRequest(slug: slug)))
    }

    func saveReflection(_ r: GoalReflectionRequest) async throws -> GoalRecord {
        try decode(try await apiClient.sendData(endpoint: .goalReflection, method: "POST", body: r))
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PrepDecoding.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}
