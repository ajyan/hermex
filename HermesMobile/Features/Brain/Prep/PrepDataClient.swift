import Foundation

/// The Prep (interview tutor) API on this user's `hermes-webui` fork (`api/tutor.py`):
/// `GET /api/tutor/{home,today,map,gaps,gap}` and `POST /api/tutor/{attempt,flag}`. Stock upstream
/// servers answer 404, which screens treat as "no Prep on this server".
protocol PrepDataClient: Sendable {
    func home() async throws -> PrepHome
    func today() async throws -> PrepRun
    func map(track: String) async throws -> PrepTrackMap
    func attempt(_ r: PrepAttemptRequest) async throws -> PrepAttemptResult
    func gaps() async throws -> [PrepGapSummary]
    func gap(id: String) async throws -> PrepGapDetail
    func flag(item: String) async throws
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol. Responses decode
/// with `PrepDecoding` (literal snake_case keys) rather than `APIClient`'s decoder.
struct APIClientPrepAdapter: PrepDataClient {
    let apiClient: APIClient

    func home() async throws -> PrepHome {
        try await get(.tutorHome)
    }

    func today() async throws -> PrepRun {
        try await get(.tutorToday)
    }

    func map(track: String) async throws -> PrepTrackMap {
        try await get(.tutorMap(track: track))
    }

    func attempt(_ r: PrepAttemptRequest) async throws -> PrepAttemptResult {
        let data = try await apiClient.sendData(endpoint: .tutorAttempt, method: "POST", body: r)
        return try decode(data)
    }

    func gaps() async throws -> [PrepGapSummary] {
        let wrapper: PrepGaps = try await get(.tutorGaps)
        return wrapper.gaps
    }

    func gap(id: String) async throws -> PrepGapDetail {
        try await get(.tutorGap(id: id))
    }

    func flag(item: String) async throws {
        _ = try await apiClient.sendData(endpoint: .tutorFlag, method: "POST", body: PrepFlagRequest(item: item))
    }

    private func get<Value: Decodable>(_ endpoint: Endpoint) async throws -> Value {
        try decode(try await apiClient.sendData(endpoint: endpoint, method: "GET"))
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PrepDecoding.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}
