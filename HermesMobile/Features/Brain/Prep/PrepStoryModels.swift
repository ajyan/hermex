import Foundation

// Models for the behavioral story reps of Prep on this user's `hermes-webui` fork
// (`api/tutor_stories.py`): `GET /api/tutor/stories`, and the probe and pending-probe objects
// a story rep and its attempt results carry. A story rep itself is a `PrepRep` with drill
// `.story`; its attempt result is a `PrepAttemptResult`. Every field decodes tolerantly, like
// `PrepModels`; decode with `PrepDecoding`.

/// Decodes an element or yields nil, so one bad element never fails its array.
private struct PrepStoryLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct PrepStoryMissingID: Error {}

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
    }

    func int(_ key: Key) -> Int {
        (try? decodeIfPresent(Int.self, forKey: key)) ?? 0
    }

    func bool(_ key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }

    /// A string that is present and non-blank; the id every element must carry.
    func requiredID(_ key: Key) throws -> String {
        guard let id = try? decodeIfPresent(String.self, forKey: key), !id.isEmpty else { throw PrepStoryMissingID() }
        return id
    }

    /// An array that drops elements which fail to decode.
    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([PrepStoryLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

/// One follow-up attack on a story just told ("What was the number?").
struct PrepProbe: Decodable, Hashable, Sendable {
    let id: String
    let attack: String

    init(id: String, attack: String) {
        self.id = id
        self.attack = attack
    }

    private enum CodingKeys: String, CodingKey { case id, attack }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredID(.id)
        attack = c.string(.attack)
    }
}

/// A story named by id and title, for the "right story" lines after a wrong-story answer.
struct PrepStoryRef: Decodable, Hashable, Sendable {
    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case id, title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredID(.id)
        title = c.string(.title)
    }
}

/// A story rep already told whose probes are still open: which attempt they belong to, which
/// probe is next, and whether it is the first or second (`number`).
struct PrepStoryPending: Decodable, Hashable, Sendable {
    let attempt: String
    let number: Int
    let probe: PrepProbe

    init(attempt: String, number: Int, probe: PrepProbe) {
        self.attempt = attempt
        self.number = number
        self.probe = probe
    }

    private enum CodingKeys: String, CodingKey { case attempt, number, probe }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attempt = try c.requiredID(.attempt)
        number = c.int(.number)
        probe = try c.decode(PrepProbe.self, forKey: .probe)
    }
}

/// What a story has shown so far: told in time, scored 4 or better, and probes held. nil is "not yet".
struct PrepStoryMarks: Decodable, Hashable, Sendable {
    let time: Bool?
    let score: Bool?
    let probes: Bool?

    init(time: Bool? = nil, score: Bool? = nil, probes: Bool? = nil) {
        self.time = time
        self.score = score
        self.probes = probes
    }

    private enum CodingKeys: String, CodingKey { case time, score, probes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = c.optional(Bool.self, .time)
        score = c.optional(Bool.self, .score)
        probes = c.optional(Bool.self, .probes)
    }
}

/// The three marks a story earns toward ready.
enum PrepStoryMarkKind: String, CaseIterable, Sendable {
    case time, score, probes
}

struct PrepStorySummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// "active" stories are drilled; "bench" ones wait.
    let status: String
    let primarySignal: String?
    let ready: Bool
    let marks: PrepStoryMarks
    /// The day it was last told, when it has been.
    let last: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, status, ready, marks, last
        case primarySignal = "primary_signal"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredID(.id)
        title = c.string(.title)
        status = c.string(.status)
        primarySignal = c.optional(String.self, .primarySignal)
        ready = c.bool(.ready)
        marks = c.optional(PrepStoryMarks.self, .marks) ?? PrepStoryMarks()
        last = c.optional(String.self, .last)
    }
}

/// A story the nightly coach proposed, waiting for a verdict.
struct PrepStoryCandidate: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let forPrompt: String?
    let why: String?
    let verdict: String?
    let status: String

    private enum CodingKeys: String, CodingKey {
        case id, title, why, verdict, status
        case forPrompt = "for_prompt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredID(.id)
        title = c.string(.title)
        forPrompt = c.optional(String.self, .forPrompt)
        why = c.optional(String.self, .why)
        verdict = c.optional(String.self, .verdict)
        status = c.string(.status)
    }
}

/// `GET /api/tutor/stories`.
struct PrepStoryList: Decodable, Hashable, Sendable {
    let stories: [PrepStorySummary]
    let readyCount: Int
    let activeTotal: Int
    let candidates: [PrepStoryCandidate]

    private enum CodingKeys: String, CodingKey {
        case stories, candidates
        case readyCount = "ready_count"
        case activeTotal = "active_total"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stories = c.lossy(PrepStorySummary.self, .stories)
        readyCount = c.int(.readyCount)
        activeTotal = c.int(.activeTotal)
        candidates = c.lossy(PrepStoryCandidate.self, .candidates)
    }

    /// The stories being drilled.
    var activeStories: [PrepStorySummary] { stories.filter { $0.status == "active" } }
    /// The stories waiting their turn.
    var benchStories: [PrepStorySummary] { stories.filter { $0.status == "bench" } }
}
