import Foundation

// The tutor dialogue after a question rep (`POST /api/tutor/dialogue` on the user's hermes-webui fork,
// `api/tutor_dialogue.py`): the tutor asks up to three follow-ups, each aimed at the first rubric line
// still missed, and its turns stream as SSE. "Show me" is `POST /api/tutor/dialogue/end`.

/// One turn of the dialogue: the tutor's question, or the user's reply.
struct PrepDialogueTurn: Decodable, Hashable, Sendable {
    let role: String
    let text: String

    var isTutor: Bool { role == "tutor" }

    init(role: String, text: String) {
        self.role = role
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case role, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = c.string(.role)
        text = c.string(.text)
    }
}

/// Where a rep's dialogue stands: open while lines are still missed and follow-ups remain.
struct PrepDialogueState: Decodable, Hashable, Sendable {
    let open: Bool
    let followups: Int
    let max: Int
    let turns: [PrepDialogueTurn]
    let closed: Bool

    /// The tutor's last question, when it is still waiting for a reply.
    var awaitingReply: Bool { turns.last?.isTutor == true }

    private enum CodingKeys: String, CodingKey { case open, followups, max, turns, closed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = c.bool(.open)
        followups = c.int(.followups)
        max = Swift.max(1, c.optional(Int.self, .max) ?? 3)
        turns = c.lossy(PrepDialogueTurn.self, .turns)
        closed = c.bool(.closed)
    }
}

/// One event of a dialogue step's stream.
enum PrepDialogueEvent: Hashable, Sendable {
    /// The rep after the user's reply was graded.
    case graded(PrepAttemptResult)
    /// A chunk of the tutor's turn as it streams.
    case delta(String)
    /// The tutor's whole turn.
    case turn(String)
    /// The step's final state.
    case done(PrepAttemptResult)
    /// The server couldn't take the step (a failed grade or reply, or a dialogue that moved on).
    case failed(status: Int, message: String)

    /// Decodes one SSE event; nil for an event this app doesn't know or data that doesn't parse.
    static func decode(event: String, data: String) -> PrepDialogueEvent? {
        let bytes = Data(data.utf8)
        switch event {
        case "graded":
            return (try? PrepDecoding.decode(PrepAttemptResult.self, from: bytes)).map(PrepDialogueEvent.graded)
        case "done":
            return (try? PrepDecoding.decode(PrepAttemptResult.self, from: bytes)).map(PrepDialogueEvent.done)
        case "delta", "turn":
            guard let text = (try? PrepDecoding.decode(PrepDialogueText.self, from: bytes))?.text else { return nil }
            return event == "delta" ? .delta(text) : .turn(text)
        case "error":
            let body = try? PrepDecoding.decode(PrepDialogueError.self, from: bytes)
            return .failed(status: body?.status ?? 0, message: body?.error ?? "")
        default:
            return nil
        }
    }
}

private struct PrepDialogueText: Decodable {
    let text: String
    private enum CodingKeys: String, CodingKey { case text }
    init(from decoder: Decoder) throws {
        text = try decoder.container(keyedBy: CodingKeys.self).string(.text)
    }
}

private struct PrepDialogueError: Decodable {
    let status: Int
    let error: String
    private enum CodingKeys: String, CodingKey { case status, error }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.int(.status)
        error = c.string(.error)
    }
}

/// Folds SSE lines into (event, data) pairs: `event:` names the next event, `data:` lines accumulate, and a
/// blank line ends it. Comments (`:`) are skipped.
struct PrepSSEParser {
    private var event = "message"
    private var data: [String] = []

    mutating func feed(_ line: String) -> (event: String, data: String)? {
        if line.isEmpty {
            defer { event = "message"; data = [] }
            return data.isEmpty ? nil : (event, data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            data.append(String(value))
        }
        return nil
    }

    /// The event left when the stream ended without a trailing blank line.
    mutating func finish() -> (event: String, data: String)? {
        feed("")
    }
}

private struct PrepDialogueLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String { (try? decodeIfPresent(String.self, forKey: key)) ?? "" }
    func int(_ key: Key) -> Int { (try? decodeIfPresent(Int.self, forKey: key)) ?? 0 }
    func bool(_ key: Key) -> Bool { (try? decodeIfPresent(Bool.self, forKey: key)) ?? false }
    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? { try? decodeIfPresent(Value.self, forKey: key) }
    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([PrepDialogueLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

struct PrepDialogueRequest: Encodable, Hashable, Sendable {
    let attempt: String
    let answer: String?
}

struct PrepDialogueEndRequest: Encodable, Hashable, Sendable {
    let attempt: String
}
