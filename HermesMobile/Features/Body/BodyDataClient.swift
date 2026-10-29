import Foundation

/// The Body API on this user's `hermes-webui` fork (`api/vault_body.py`, over the vault's
/// `tools/gym.py`): home, today's prescription, saving and finishing a workout, history, a lift's
/// detail, the plan, Baki's proposals, and the sleep history. Stock upstream servers answer 404,
/// which screens treat as "no Body on this server".
protocol BodyDataClient: Sendable {
    func home() async throws -> BodyHome
    /// What to lift on `day` (push, legs or pull), or the next day in the rotation when nil. Today's
    /// saved, unfinished workout comes back with `resumed` true.
    func prescription(day: String?) async throws -> BodyPrescription
    /// Saves the whole in-progress workout and returns the stored document. A finished one answers 409.
    func save(_ session: BodySession) async throws -> BodySession
    func finish(id: String, check: BodyCheck) async throws -> BodyFinishResult
    func session(id: String) async throws -> BodySession
    /// Finished workouts, newest first; `before` is a date or session id.
    func sessions(before: String?) async throws -> [BodySessionSummary]
    func lift(id: String) async throws -> BodyLift
    func plan() async throws -> BodyPlan
    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan
    /// Accepts or skips one of Baki's proposals and returns it as decided.
    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal
    /// The Sleep screen's history, or nil when the server has none (404).
    func sleepHistory() async throws -> SleepHistory?
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol, decoding with
/// `PrepDecoding` (literal snake_case keys).
struct APIClientBodyAdapter: BodyDataClient {
    let apiClient: APIClient

    func home() async throws -> BodyHome {
        try decode(try await apiClient.sendData(endpoint: .bodyHome, method: "GET"))
    }

    func prescription(day: String?) async throws -> BodyPrescription {
        try decode(try await apiClient.sendData(endpoint: .bodyPrescription(day: day), method: "GET"))
    }

    func save(_ session: BodySession) async throws -> BodySession {
        try decode(try await apiClient.sendData(endpoint: .bodySession(id: nil), method: "POST", body: session))
    }

    func finish(id: String, check: BodyCheck) async throws -> BodyFinishResult {
        try decode(try await apiClient.sendData(
            endpoint: .bodySessionFinish, method: "POST", body: FinishRequest(id: id, check: check)))
    }

    func session(id: String) async throws -> BodySession {
        try decode(try await apiClient.sendData(endpoint: .bodySession(id: id), method: "GET"))
    }

    func sessions(before: String?) async throws -> [BodySessionSummary] {
        let rows: [BodyLossyRow] = try decode(
            try await apiClient.sendData(endpoint: .bodySessions(before: before), method: "GET"))
        return rows.compactMap(\.value)
    }

    func lift(id: String) async throws -> BodyLift {
        try decode(try await apiClient.sendData(endpoint: .bodyLift(id: id), method: "GET"))
    }

    func plan() async throws -> BodyPlan {
        try decode(try await apiClient.sendData(endpoint: .bodyPlan, method: "GET"))
    }

    func savePlan(_ plan: BodyPlan) async throws -> BodyPlan {
        try decode(try await apiClient.sendData(endpoint: .bodyPlan, method: "POST", body: plan))
    }

    func decide(proposalID: String, accept: Bool) async throws -> BodyProposal {
        try decode(try await apiClient.sendData(
            endpoint: .bodyProposal, method: "POST",
            body: DecideRequest(id: proposalID, decision: accept ? "accept" : "skip")))
    }

    func sleepHistory() async throws -> SleepHistory? {
        let data: Data
        do {
            data = try await apiClient.sendData(endpoint: .bodySleep, method: "GET")
        } catch let error as APIError where error.isNotFound {
            return nil
        }
        do {
            return try SleepHistory.decode(data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    private struct FinishRequest: Encodable {
        let id: String
        let check: BodyCheck
    }

    private struct DecideRequest: Encodable {
        let id: String
        let decision: String
    }

    /// One summary or nothing, so a bad row never fails the list.
    private struct BodyLossyRow: Decodable {
        let value: BodySessionSummary?
        init(from decoder: Decoder) throws {
            value = try? BodySessionSummary(from: decoder)
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PrepDecoding.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}
