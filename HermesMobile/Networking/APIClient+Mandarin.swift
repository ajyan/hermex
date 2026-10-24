import Foundation

/// `POST /api/mandarin/answer` on this user's `hermes-webui` fork: files the Mandarin card's answer
/// the moment it is given and returns the local model's feedback in seconds.
struct MandarinAnswerRequest: Encodable, Sendable {
    let date: String
    let text: String
    /// "Ask my own question" replaces the card's; nil keeps it.
    let question: String?
}

/// The feedback (nil when the model couldn't answer in time: the next morning's deck retries it),
/// which of the card's phrases he used, and his progress after this answer.
struct MandarinAnswerResponse: Codable, Equatable, Sendable {
    let feedback: DeckMandarinFeedback?
    let used: [String]
    let progress: DeckMandarinProgress?

    init(feedback: DeckMandarinFeedback?, used: [String] = [], progress: DeckMandarinProgress? = nil) {
        self.feedback = feedback
        self.used = used
        self.progress = progress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feedback = try? c.decodeIfPresent(DeckMandarinFeedback.self, forKey: .feedback)
        used = (try? c.decodeIfPresent([String].self, forKey: .used)) ?? []
        progress = try? c.decodeIfPresent(DeckMandarinProgress.self, forKey: .progress)
    }

    private enum CodingKeys: String, CodingKey { case feedback, used, progress }
}

/// `POST /api/mandarin/recall`: Got it moves a phrasebook phrase to its next gap, Again starts it over.
struct MandarinRecallRequest: Encodable, Sendable {
    let date: String
    let hanzi: String
    let got: Bool
}

struct MandarinRecallResponse: Decodable, Equatable, Sendable {
    let ok: Bool?
    let progress: DeckMandarinProgress?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        progress = try? c.decodeIfPresent(DeckMandarinProgress.self, forKey: .progress)
    }

    private enum CodingKeys: String, CodingKey { case ok, progress }
}

extension APIClient {
    /// Waits up to 90 s: the server gives the local model 75 s before it answers without feedback.
    func answerMandarin(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse {
        try await send(endpoint: .mandarinAnswer, method: "POST", body: request, timeout: 90)
    }

    func recallMandarin(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse {
        try decode(MandarinRecallResponse.self, from: try await sendData(endpoint: .mandarinRecall, method: "POST", body: request))
    }
}
