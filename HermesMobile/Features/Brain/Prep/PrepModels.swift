import Foundation

// Models for the Prep (interview tutor) API on this user's `hermes-webui` fork
// (`api/tutor.py`): `GET /api/tutor/{home,today,map}` and `POST /api/tutor/attempt`.
// Every field decodes tolerantly: missing or mistyped values fall back to a default,
// and reps with a drill this app doesn't know (or no stable index) are dropped.
//
// These keys are snake_case on the wire and are matched literally, so decode with
// `PrepDecoding`, not with `APIClient`'s `convertFromSnakeCase` decoder.

enum PrepDecoding {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

/// Decodes an element or yields nil, so one bad element never fails its array.
private struct PrepLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
    }

    func int(_ key: Key) -> Int {
        (try? decodeIfPresent(Int.self, forKey: key)) ?? 0
    }

    func double(_ key: Key) -> Double {
        (try? decodeIfPresent(Double.self, forKey: key)) ?? 0
    }

    func bool(_ key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    func strings(_ key: Key) -> [String] {
        (try? decodeIfPresent([String].self, forKey: key)) ?? []
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }

    func object<Value: Decodable>(_ type: Value.Type, _ key: Key, default fallback: Value) -> Value {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? fallback
    }

    /// An array that drops elements which fail to decode.
    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([PrepLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

// MARK: - Home

struct PrepStreak: Decodable, Hashable, Sendable {
    let days: Int
    let freezes: Int

    private enum CodingKeys: String, CodingKey { case days, freezes }

    init(days: Int = 0, freezes: Int = 0) {
        self.days = days
        self.freezes = freezes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.int(.days)
        freezes = c.int(.freezes)
    }
}

struct PrepRunSummary: Decodable, Hashable, Sendable {
    let minutes: Double
    let reps: Int
    let remaining: Int
    let focus: [String]

    private enum CodingKeys: String, CodingKey { case minutes, reps, remaining, focus }

    init(minutes: Double = 0, reps: Int = 0, remaining: Int = 0, focus: [String] = []) {
        self.minutes = minutes
        self.reps = reps
        self.remaining = remaining
        self.focus = focus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minutes = c.double(.minutes)
        reps = c.int(.reps)
        remaining = c.int(.remaining)
        focus = c.strings(.focus)
    }
}

struct PrepTrackSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let mastered: Int
    let total: Int
    let progress: Double
    let subtitle: String

    private enum CodingKeys: String, CodingKey { case id, title, mastered, total, progress, subtitle }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        title = c.string(.title)
        mastered = c.int(.mastered)
        total = c.int(.total)
        progress = c.double(.progress)
        subtitle = c.string(.subtitle)
    }
}

struct PrepNeedsWork: Decodable, Identifiable, Hashable, Sendable {
    let skill: String
    let title: String
    let detail: String

    var id: String { skill }

    private enum CodingKeys: String, CodingKey { case skill, title, detail }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = c.string(.skill)
        title = c.string(.title)
        detail = c.string(.detail)
    }
}

/// `GET /api/tutor/home`. `readiness` is null until the server has enough history.
struct PrepHome: Decodable, Hashable, Sendable {
    let streak: PrepStreak
    let readiness: Double?
    let run: PrepRunSummary
    let tracks: [PrepTrackSummary]
    let needsWork: [PrepNeedsWork]

    private enum CodingKeys: String, CodingKey {
        case streak, readiness, run, tracks
        case needsWork = "needs_work"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streak = c.object(PrepStreak.self, .streak, default: PrepStreak())
        readiness = c.optional(Double.self, .readiness)
        run = c.object(PrepRunSummary.self, .run, default: PrepRunSummary())
        tracks = c.lossy(PrepTrackSummary.self, .tracks)
        needsWork = c.lossy(PrepNeedsWork.self, .needsWork)
    }
}

// MARK: - Today's run

enum PrepDrill: String, Encodable, Hashable, Sendable {
    case patternID = "pattern_id"
    case complexity
    case parsons
    case primer
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PrepDrill.init(rawValue:)) ?? .unknown
    }
}

extension PrepDrill: Decodable {}

/// One answer choice. Pattern drills send `{id, title}`; complexity drills send the
/// display string itself, which is both the id and the title and is POSTed as-is.
struct PrepOption: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case id, title }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            id = text
            title = text
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        title = c.string(.title)
    }
}

struct PrepPrimer: Decodable, Hashable, Sendable {
    let signals: [String]
    let template: String
    let invariant: String
    let complexity: String

    private enum CodingKeys: String, CodingKey { case signals, template, invariant, complexity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        signals = c.strings(.signals)
        template = c.string(.template)
        invariant = c.string(.invariant)
        complexity = c.string(.complexity)
    }
}

/// The problem a rep is about. The server never includes answers: `options` is set for
/// pattern and complexity drills, `lines` for parsons (solution lines plus a decoy,
/// shuffled), and `primer` and `referenceMD` for primers.
struct PrepItemExcerpt: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let example: String
    let difficulty: String
    let hints: [String]
    let links: [String: String]
    let skillTitle: String?
    let primer: PrepPrimer?
    let referenceMD: String?
    let options: [PrepOption]
    let lines: [String]

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, example, difficulty, hints, links, primer, options, lines
        case skillTitle = "skill_title"
        case referenceMD = "reference_md"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        title = c.string(.title)
        summary = c.string(.summary)
        example = c.string(.example)
        difficulty = c.string(.difficulty)
        hints = c.strings(.hints)
        links = c.object([String: String].self, .links, default: [:])
        skillTitle = c.optional(String.self, .skillTitle)
        primer = c.optional(PrepPrimer.self, .primer)
        referenceMD = c.optional(String.self, .referenceMD)
        options = c.lossy(PrepOption.self, .options)
        lines = c.strings(.lines)
    }
}

/// One step of today's run. `index` is the server's stable position, which the attempt
/// POST sends back; it is not the rep's position in `PrepRun.reps`.
struct PrepRep: Decodable, Identifiable, Hashable, Sendable {
    /// -1 when the server omitted it; such a rep cannot be answered and `PrepRun` drops it.
    let index: Int
    let block: String
    let drill: PrepDrill
    let item: PrepItemExcerpt

    var id: Int { index }

    private enum CodingKeys: String, CodingKey { case index, block, drill, item }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = (try? c.decodeIfPresent(Int.self, forKey: .index)) ?? -1
        block = c.string(.block)
        drill = c.optional(PrepDrill.self, .drill) ?? .unknown
        item = try c.decode(PrepItemExcerpt.self, forKey: .item)
    }
}

/// `GET /api/tutor/today`. `index` is the first unanswered rep's stable index.
struct PrepRun: Decodable, Hashable, Sendable {
    let date: String
    let index: Int
    let reps: [PrepRep]

    private enum CodingKeys: String, CodingKey { case date, index, reps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        index = c.int(.index)
        reps = c.lossy(PrepRep.self, .reps).filter { $0.drill != .unknown && $0.index >= 0 }
    }
}

// MARK: - Attempt

/// A submitted or revealed answer: one choice id/display string, or ordered parsons lines.
enum PrepAnswer: Codable, Hashable, Sendable {
    case choice(String)
    case lines([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) {
            self = .choice(text)
        } else {
            self = .lines(try c.decode([String].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .choice(text): try c.encode(text)
        case let .lines(lines): try c.encode(lines)
        }
    }
}

/// `POST /api/tutor/attempt` body.
struct PrepAttemptRequest: Encodable, Hashable, Sendable {
    let date: String
    let index: Int
    let item: String
    let drill: PrepDrill
    let answer: PrepAnswer
    let elapsedMS: Int
    let hintsUsed: Int

    private enum CodingKeys: String, CodingKey {
        case date, index, item, drill, answer
        case elapsedMS = "elapsed_ms"
        case hintsUsed = "hints_used"
    }
}

struct PrepAttemptResult: Decodable, Hashable, Sendable {
    let verdict: String
    let correct: PrepAnswer?
    let feedback: String
    let credit: Double
    let referenceMD: String?
    let links: [String: String]
    let nextIndex: Int
    let streak: PrepStreak?

    private enum CodingKeys: String, CodingKey {
        case verdict, correct, feedback, credit, links, streak
        case referenceMD = "reference_md"
        case nextIndex = "next_index"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = c.string(.verdict)
        correct = c.optional(PrepAnswer.self, .correct)
        feedback = c.string(.feedback)
        credit = c.double(.credit)
        referenceMD = c.optional(String.self, .referenceMD)
        links = c.object([String: String].self, .links, default: [:])
        nextIndex = c.int(.nextIndex)
        streak = c.optional(PrepStreak.self, .streak)
    }
}

// MARK: - Map

enum PrepSkillState: String, Decodable, Hashable, Sendable {
    case new
    case inProgress = "in_progress"
    case weak
    case locked
    case mastered
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PrepSkillState.init(rawValue:)) ?? .unknown
    }
}

struct PrepSkill: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let state: PrepSkillState
    let mastery: Double
    let detail: String

    private enum CodingKeys: String, CodingKey { case id, title, state, mastery, detail }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        title = c.string(.title)
        state = c.optional(PrepSkillState.self, .state) ?? .unknown
        mastery = c.double(.mastery)
        detail = c.string(.detail)
    }
}

struct PrepLevel: Decodable, Hashable, Sendable {
    let title: String
    let locked: Bool
    let skills: [PrepSkill]

    private enum CodingKeys: String, CodingKey { case title, locked, skills }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title)
        locked = c.bool(.locked)
        skills = c.lossy(PrepSkill.self, .skills)
    }
}

struct PrepMapSummary: Decodable, Hashable, Sendable {
    let mastered: Int
    let total: Int
    let problems: Int
    let due: Int

    private enum CodingKeys: String, CodingKey { case mastered, total, problems, due }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mastered = c.int(.mastered)
        total = c.int(.total)
        problems = c.int(.problems)
        due = c.int(.due)
    }
}

/// `GET /api/tutor/map?track=`.
struct PrepTrackMap: Decodable, Hashable, Sendable {
    let track: String
    let title: String
    let summary: PrepMapSummary
    let levels: [PrepLevel]

    private enum CodingKeys: String, CodingKey { case track, title, summary, levels }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = c.string(.track)
        title = c.string(.title)
        summary = c.object(PrepMapSummary.self, .summary, default: PrepMapSummary.empty)
        levels = c.lossy(PrepLevel.self, .levels)
    }
}

private extension PrepMapSummary {
    static let empty: PrepMapSummary = {
        // `{}` always decodes: every field defaults.
        // swiftlint:disable:next force_try
        try! PrepDecoding.decode(PrepMapSummary.self, from: Data("{}".utf8))
    }()
}
