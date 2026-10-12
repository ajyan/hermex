import Foundation

// Models for the Prep (interview tutor) API on this user's `hermes-webui` fork
// (`api/tutor.py`): `GET /api/tutor/{home,today,map}` and `POST /api/tutor/attempt`.
// Every field decodes tolerantly: missing or mistyped values fall back to a default,
// and reps with a drill this app doesn't know stay as `.unknown` so the player can skip
// them; reps with no stable index are dropped.
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
    case approach
    case complexity
    case spotBug = "spot_bug"
    case trace
    case primer
    case fact
    case judgment
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PrepDrill.init(rawValue:)) ?? .unknown
    }
}

extension PrepDrill: Decodable {}

/// One answer choice. Complexity and trace drills send the display string itself, which
/// is both the id and the title and is POSTed as-is; `{id, title}` objects also decode.
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

/// The problem a rep is about. The server never includes the answer key: `hints` is set
/// for approach, `options` for complexity and trace, `code` (0-based lines) and `fixes`
/// for spot-the-bug, `code` and `input` for trace, and `primer` and `referenceMD` for primers.
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
    let code: [String]
    let fixes: [String]
    let input: String
    /// Anthropic-track reps: the interview loop stage ("1", "2a", ... "5"), the fact
    /// format ("choice" or "cloze") and who wrote the card ("ingest" or "coach").
    let stage: String
    let format: String
    let origin: String

    /// A card the nightly coach wrote for a gap; only these can be flagged.
    var isCoachWritten: Bool { origin == "coach" }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, example, difficulty, hints, links, primer, options, code, fixes, input
        case stage, format, origin
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
        code = c.strings(.code)
        fixes = c.strings(.fixes)
        input = c.string(.input)
        stage = c.string(.stage)
        format = c.string(.format)
        origin = c.string(.origin)
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
        reps = c.lossy(PrepRep.self, .reps).filter { $0.index >= 0 }
    }
}

// MARK: - Attempt

/// A submitted or revealed answer: one string (approach text, or the chosen complexity or
/// trace option), or a spot-the-bug `{line, fix}` where `line` is a 0-based index into `code`.
enum PrepAnswer: Codable, Hashable, Sendable {
    case choice(String)
    case bugFix(line: Int, fix: String)

    private enum CodingKeys: String, CodingKey { case line, fix }

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self = .choice(text)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = .bugFix(line: try c.decode(Int.self, forKey: .line), fix: c.string(.fix))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .choice(text):
            var c = encoder.singleValueContainer()
            try c.encode(text)
        case let .bugFix(line, fix):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(line, forKey: .line)
            try c.encode(fix, forKey: .fix)
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

struct PrepQuote: Decodable, Hashable, Sendable {
    let skill: String
    let quote: String

    private enum CodingKeys: String, CodingKey { case skill, quote }

    init(skill: String, quote: String) {
        self.skill = skill
        self.quote = quote
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = c.string(.skill)
        quote = c.string(.quote)
    }
}

struct PrepMiss: Decodable, Hashable, Sendable {
    let skill: String
    let why: String

    private enum CodingKeys: String, CodingKey { case skill, why }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = c.string(.skill)
        why = c.string(.why)
    }
}

/// The grader's read of an approach answer. An ungraded attempt can send just
/// `{"verdict": "ungraded"}`, so every field falls back to empty.
struct PrepOpenGrade: Decodable, Hashable, Sendable {
    let patternOK: Bool
    let scores: [String: Int]
    let skillsHit: [PrepQuote]
    let skillsMissed: [PrepMiss]
    let strongAnswer: String

    private enum CodingKeys: String, CodingKey {
        case scores
        case patternOK = "pattern_ok"
        case skillsHit = "skills_hit"
        case skillsMissed = "skills_missed"
        case strongAnswer = "strong_answer"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        patternOK = c.bool(.patternOK)
        scores = c.object([String: Int].self, .scores, default: [:])
        skillsHit = c.lossy(PrepQuote.self, .skillsHit)
        skillsMissed = c.lossy(PrepMiss.self, .skillsMissed)
        strongAnswer = c.string(.strongAnswer)
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
    let grade: PrepOpenGrade?
    /// A judgment card's grade: the reference points hit and missed. Nil for other drills.
    let judgment: PrepJudgmentGrade?
    /// The gaps this answer's misses belong to, and whether a miss belongs to none yet.
    let gapMatch: [PrepGapMatch]
    let logged: Bool

    /// The grader couldn't score the answer; there is no grade to show.
    var isUngraded: Bool { verdict == "ungraded" }

    private enum CodingKeys: String, CodingKey {
        case verdict, correct, feedback, credit, links, streak, grade, logged
        case referenceMD = "reference_md"
        case nextIndex = "next_index"
        case gapMatch = "gap_match"
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
        let judgment = c.optional(PrepJudgmentGrade.self, .grade)
        self.judgment = judgment?.hasPoints == true ? judgment : nil
        grade = self.judgment == nil ? c.optional(PrepOpenGrade.self, .grade) : nil
        gapMatch = c.lossy(PrepGapMatch.self, .gapMatch)
        logged = c.bool(.logged)
    }
}

struct PrepPointHit: Decodable, Hashable, Sendable {
    let pointID: String
    let quote: String

    private enum CodingKeys: String, CodingKey {
        case quote
        case pointID = "point_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pointID = c.string(.pointID)
        quote = c.string(.quote)
    }
}

struct PrepPointMiss: Decodable, Hashable, Sendable {
    let pointID: String
    let why: String

    private enum CodingKeys: String, CodingKey {
        case why
        case pointID = "point_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pointID = c.string(.pointID)
        why = c.string(.why)
    }
}

/// A judgment card's grade (`grade` on its attempt result): which reference points the answer made.
struct PrepJudgmentGrade: Decodable, Hashable, Sendable {
    let pointsHit: [PrepPointHit]
    let pointsMissed: [PrepPointMiss]
    let strongAnswer: String

    var hasPoints: Bool { !pointsHit.isEmpty || !pointsMissed.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case pointsHit = "points_hit"
        case pointsMissed = "points_missed"
        case strongAnswer = "strong_answer"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pointsHit = c.lossy(PrepPointHit.self, .pointsHit)
        pointsMissed = c.lossy(PrepPointMiss.self, .pointsMissed)
        strongAnswer = c.string(.strongAnswer)
    }
}

struct PrepGapMatch: Decodable, Hashable, Sendable {
    let id: String
    let label: String
    let misses: Int

    init(id: String, label: String, misses: Int) {
        self.id = id
        self.label = label
        self.misses = misses
    }

    private enum CodingKeys: String, CodingKey { case id, label, misses }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        label = c.string(.label)
        misses = c.int(.misses)
    }
}

struct PrepFlagRequest: Encodable, Hashable, Sendable {
    let item: String
}

// MARK: - Gaps

enum PrepGapStatus: String, Decodable, Hashable, Sendable {
    case open
    case improving
    case closed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PrepGapStatus.init(rawValue:)) ?? .unknown
    }
}

private struct PrepMissingID: Error {}

/// One row of `GET /api/tutor/gaps`: a recurring blind spot the coach named, with its status
/// derived from attempts. A gap with no id fails to decode and is dropped from the list.
struct PrepGapSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let stage: String
    let status: PrepGapStatus
    let misses: Int
    let hitsTowardClose: Int
    let lastSeen: String

    private enum CodingKeys: String, CodingKey {
        case id, label, stage, status, misses
        case hitsTowardClose = "hits_toward_close"
        case lastSeen = "last_seen"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        guard !id.isEmpty else { throw PrepMissingID() }
        label = c.string(.label)
        stage = c.string(.stage)
        status = c.optional(PrepGapStatus.self, .status) ?? .unknown
        misses = c.int(.misses)
        hitsTowardClose = c.int(.hitsTowardClose)
        lastSeen = c.string(.lastSeen)
    }
}

struct PrepGaps: Decodable, Hashable, Sendable {
    let gaps: [PrepGapSummary]

    private enum CodingKeys: String, CodingKey { case gaps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gaps = c.lossy(PrepGapSummary.self, .gaps)
    }
}

struct PrepGapEvidence: Decodable, Hashable, Sendable {
    let date: String
    let item: String
    let itemTitle: String
    let quote: String

    private enum CodingKeys: String, CodingKey {
        case date, item, quote
        case itemTitle = "item_title"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        item = c.string(.item)
        itemTitle = c.string(.itemTitle)
        quote = c.string(.quote)
    }
}

struct PrepGapCard: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let origin: String
    let due: String?

    var isCoachWritten: Bool { origin == "coach" }

    private enum CodingKeys: String, CodingKey { case id, title, origin, due }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        title = c.string(.title)
        origin = c.string(.origin)
        due = c.optional(String.self, .due)
    }
}

/// `GET /api/tutor/gap?id=`: one gap with the answers that showed it and the cards that target it.
struct PrepGapDetail: Decodable, Hashable, Sendable {
    let id: String
    let label: String
    let stage: String
    let status: PrepGapStatus
    let summary: String
    let misses: Int
    let hitsTowardClose: Int
    let evidence: [PrepGapEvidence]
    let cards: [PrepGapCard]

    private enum CodingKeys: String, CodingKey {
        case id, label, stage, status, summary, misses, evidence, cards
        case hitsTowardClose = "hits_toward_close"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        label = c.string(.label)
        stage = c.string(.stage)
        status = c.optional(PrepGapStatus.self, .status) ?? .unknown
        summary = c.string(.summary)
        misses = c.int(.misses)
        hitsTowardClose = c.int(.hitsTowardClose)
        evidence = c.lossy(PrepGapEvidence.self, .evidence)
        cards = c.lossy(PrepGapCard.self, .cards)
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
