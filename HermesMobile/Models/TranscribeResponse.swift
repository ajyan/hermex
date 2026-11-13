import Foundation

/// Tolerant response for `POST /api/transcribe` (server speech-to-text).
///
/// The server returns `{ok, transcript}` on success and `{error}` on failure —
/// and it sends a JSON `{error: ...}` body even with a non-2xx status (e.g. 503
/// when STT isn't configured). Every field is optional and unknown keys are
/// ignored, so a future server addition never crashes decoding.
struct TranscribeResponse: Codable {
    let ok: Bool?
    let transcript: String?
    let error: String?
}

/// `GET /api/voice/vocabulary`: contact names and dictionary terms for the call recognizer.
struct VoiceVocabularyResponse: Decodable {
    let terms: [String]?
}

/// `POST /api/dictation/tidy`: `{ok, text}`, or `{error}` when the local model is unavailable.
struct DictationTidyResponse: Decodable {
    let ok: Bool?
    let text: String?
    let error: String?
}

struct DictationTidyRequest: Encodable {
    let text: String
}

/// `POST /api/dictation/polish`: `{ok, id, text, transcript, used}`, or `{error}` when the local model is away.
struct DictationPolishResponse: Decodable {
    let ok: Bool?
    let id: String?
    let text: String?
    let error: String?
}

/// `POST /api/dictation/outcome`: what one mic session's words read when the box was saved or closed.
struct DictationOutcomeRequest: Encodable {
    let session: String
    let final: String
    let undone: Bool
    let waitMs: Int
    let ids: [String]
}

struct DictationOutcomeResponse: Decodable {
    let ok: Bool?
}
