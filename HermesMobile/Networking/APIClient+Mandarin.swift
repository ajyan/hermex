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

/// The family call. `who` is "mom" or "dad".
struct MandarinCallPrepRequest: Encodable, Sendable {
    let date: String
    let who: String
}

struct MandarinCallAfterRequest: Encodable, Sendable {
    let date: String
    let text: String
}

/// One thing to say on the call: what it means in English and how he says it.
struct MandarinCallItem: Codable, Equatable, Hashable, Sendable {
    let en: String
    let hanzi: String
    let pinyin: String?
}

/// Prep's three things to say, or after-call's phrases (added to tomorrow's recall) with progress.
struct MandarinCallResponse: Decodable, Equatable, Sendable {
    let items: [MandarinCallItem]
    let progress: DeckMandarinProgress?

    init(items: [MandarinCallItem], progress: DeckMandarinProgress? = nil) {
        self.items = items
        self.progress = progress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items = (try? c.decodeIfPresent([Lossy<MandarinCallItem>].self, forKey: .items))
            ?? (try? c.decodeIfPresent([Lossy<MandarinCallItem>].self, forKey: .phrases)) ?? []
        self.items = items.compactMap(\.value)
        progress = try? c.decodeIfPresent(DeckMandarinProgress.self, forKey: .progress)
    }

    private enum CodingKeys: String, CodingKey { case items, phrases, progress }
}

/// The Mandarin call: his first telling of the day's story, the call's brief, and its review.
struct MandarinTellingRequest: Encodable, Sendable {
    let date: String
    let text: String
}

struct MandarinCallStartRequest: Encodable, Sendable {
    let date: String
}

/// The `[mandarin brief]` opening turn, who calls ("mom" or "dad"), and the Hermes profile to call on.
struct MandarinCallStart: Decodable, Equatable, Sendable {
    let brief: String
    let speaker: String?
    let profile: String
}

/// Encodes as `session_id` and `wait_ms` through the client's snake-case encoder.
struct MandarinCallReviewRequest: Encodable, Sendable {
    let date: String
    let sessionID: String
    let waitMS: [Int]
}

/// After the call: moments to say again, his best turns said natively, the chunks he used and
/// missed, and fluency for the call and for his first telling. Bad entries drop; the rest stay.
struct MandarinCallReview: Codable, Equatable, Sendable {
    struct Moment: Codable, Equatable, Hashable, Sendable {
        let said: String
        let natural: String
        let naturalPinyin: String?
        let en: String?
        let why: String?
    }

    struct Turn: Codable, Equatable, Hashable, Sendable {
        let said: String
        let natural: String
        let naturalPinyin: String?
    }

    let moments: [Moment]
    let naturalTurns: [Turn]
    let chunksUsed: [String]
    let chunksMissed: [String]
    let fluency: MandarinFluency?
    let telling: MandarinFluency?
    let progress: DeckMandarinProgress?

    init(moments: [Moment] = [], naturalTurns: [Turn] = [], chunksUsed: [String] = [], chunksMissed: [String] = [],
         fluency: MandarinFluency? = nil, telling: MandarinFluency? = nil, progress: DeckMandarinProgress? = nil) {
        self.moments = moments
        self.naturalTurns = naturalTurns
        self.chunksUsed = chunksUsed
        self.chunksMissed = chunksMissed
        self.fluency = fluency
        self.telling = telling
        self.progress = progress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        moments = ((try? c.decodeIfPresent([Lossy<Moment>].self, forKey: .moments)) ?? []).compactMap(\.value)
        naturalTurns = ((try? c.decodeIfPresent([Lossy<Turn>].self, forKey: .naturalTurns)) ?? []).compactMap(\.value)
        chunksUsed = ((try? c.decodeIfPresent([Lossy<String>].self, forKey: .chunksUsed)) ?? []).compactMap(\.value)
        chunksMissed = ((try? c.decodeIfPresent([Lossy<String>].self, forKey: .chunksMissed)) ?? []).compactMap(\.value)
        fluency = try? c.decodeIfPresent(MandarinFluency.self, forKey: .fluency)
        telling = try? c.decodeIfPresent(MandarinFluency.self, forKey: .telling)
        progress = try? c.decodeIfPresent(DeckMandarinProgress.self, forKey: .progress)
    }

    private enum CodingKeys: String, CodingKey {
        case moments, naturalTurns, chunksUsed, chunksMissed, fluency, telling, progress
    }
}

extension APIClient {
    /// Waits up to 90 s: the server gives the local model 75 s before it answers without feedback.
    func answerMandarin(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse {
        try await send(endpoint: .mandarinAnswer, method: "POST", body: request, timeout: 90)
    }

    func recallMandarin(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse {
        try decode(MandarinRecallResponse.self, from: try await sendData(endpoint: .mandarinRecall, method: "POST", body: request))
    }

    func mandarinCallPrep(_ request: MandarinCallPrepRequest) async throws -> MandarinCallResponse {
        try await send(endpoint: .mandarinCallPrep, method: "POST", body: request, timeout: 90)
    }

    func mandarinCallAfter(_ request: MandarinCallAfterRequest) async throws -> MandarinCallResponse {
        try await send(endpoint: .mandarinCallAfter, method: "POST", body: request, timeout: 90)
    }

    func tellMandarin(_ request: MandarinTellingRequest) async throws {
        _ = try await sendData(endpoint: .mandarinTelling, method: "POST", body: request)
    }

    func mandarinCallStart(_ request: MandarinCallStartRequest) async throws -> MandarinCallStart {
        try decode(MandarinCallStart.self, from: try await sendData(endpoint: .mandarinCallStart, method: "POST", body: request))
    }

    /// Waits up to 90 s, like an answer: the review is one local-model call.
    func mandarinCallReview(_ request: MandarinCallReviewRequest) async throws -> MandarinCallReview {
        try await send(endpoint: .mandarinCallReview, method: "POST", body: request, timeout: 90)
    }
}
