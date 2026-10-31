import Foundation

// Models for the learn-first Prep course on this user's `hermes-webui` fork
// (`api/tutor_course.py`): the path in `GET /api/tutor/{home,course}`, one lesson from
// `GET /api/tutor/lesson`, and a boss answer's sitting and revisit lessons. Every field
// decodes tolerantly, like `PrepModels`; decode with `PrepDecoding`.

/// Decodes an element or yields nil, so one bad element never fails its array.
private struct PrepCourseLossy<Value: Decodable>: Decodable {
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

    func bool(_ key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }

    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([PrepCourseLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    /// A non-empty string, or nil.
    func text(_ key: Key) -> String? {
        let value = string(key)
        return value.isEmpty ? nil : value
    }
}

private struct PrepCourseMissingID: Error {}

/// Which run a set of reps belongs to. The daily run is the course; a test out asks one unit's
/// boss early; a mock is the optional critique run for passed units.
enum PrepRunKind: String, Codable, Hashable, Sendable {
    case daily
    case testout
    case mock
    case bonus
    case story
    /// "Practice this gap": up to three reps aimed at one gap (`unit` is the gap id).
    case gap
    /// "Try it now": one recall of one lesson (`unit` is the lesson id).
    case lesson
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PrepRunKind.init(rawValue:)) ?? .unknown
    }
}

// MARK: - Path

struct PrepDayCount: Decodable, Hashable, Sendable {
    let done: Int
    let total: Int

    init(done: Int = 0, total: Int = 0) {
        self.done = done
        self.total = total
    }

    private enum CodingKeys: String, CodingKey { case done, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        done = c.int(.done)
        total = c.int(.total)
    }
}

enum PrepUnitState: String, Decodable, Hashable, Sendable {
    case passed, current, locked, unknown

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PrepUnitState.init(rawValue:)) ?? .unknown
    }
}

enum PrepBossState: String, Decodable, Hashable, Sendable {
    /// `resting`: lessons learned but the boss isn't passed; it comes back a few days after a failed sitting.
    case locked, ready, resting, passed, unknown

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PrepBossState.init(rawValue:)) ?? .unknown
    }
}

enum PrepLessonState: String, Decodable, Hashable, Sendable {
    case learned, ready, shaky, next, locked, unknown

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(PrepLessonState.init(rawValue:)) ?? .unknown
    }
}

/// One lesson on the path. `reteach` is true while a re-teach of it waits in the run.
struct PrepLessonNode: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let state: PrepLessonState
    let due: String?
    let reteach: Bool

    private enum CodingKeys: String, CodingKey { case id, title, state, due, reteach }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        guard !id.isEmpty else { throw PrepCourseMissingID() }
        title = c.string(.title)
        state = c.optional(PrepLessonState.self, .state) ?? .unknown
        due = c.text(.due)
        reteach = c.bool(.reteach)
    }
}

/// One unit of the course. Home sends units without `lessons`; `GET /api/tutor/course` includes them.
struct PrepUnit: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let module: String?
    let stage: String?
    let state: PrepUnitState
    let stars: Int
    let lessonsDone: Int
    let lessonsTotal: Int
    let boss: PrepBossState
    let mock: Bool
    let lessons: [PrepLessonNode]
    /// Lessons in this unit that are interview-ready.
    let readyCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, title, module, stage, state, stars, boss, mock, lessons
        case lessonsDone = "lessons_done"
        case lessonsTotal = "lessons_total"
        case readyCount = "ready_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        guard !id.isEmpty else { throw PrepCourseMissingID() }
        title = c.string(.title)
        module = c.text(.module)
        stage = c.text(.stage)
        state = c.optional(PrepUnitState.self, .state) ?? .unknown
        stars = min(3, max(0, c.int(.stars)))
        lessonsDone = c.int(.lessonsDone)
        lessonsTotal = c.int(.lessonsTotal)
        boss = c.optional(PrepBossState.self, .boss) ?? .unknown
        mock = c.bool(.mock)
        lessons = c.lossy(PrepLessonNode.self, .lessons)
        readyCount = c.int(.readyCount)
    }
}

/// The course path: `course` on home (units without lessons) and `GET /api/tutor/course`.
struct PrepCourse: Decodable, Hashable, Sendable {
    let units: [PrepUnit]
    let xp: Int
    let today: PrepDayCount
    let reteach: [String]
    let needsRewrite: [String]
    /// Interview-ready lessons across the course, and how many lessons it has.
    let readyCount: Int
    let lessonTotal: Int

    /// The unit whose lessons are being taught now: the last current one, since earlier current units
    /// have only their boss left.
    var currentUnit: PrepUnit? { units.last { $0.state == .current } }

    private enum CodingKeys: String, CodingKey {
        case units, xp, today, reteach
        case needsRewrite = "needs_rewrite"
        case readyCount = "ready_count"
        case lessonTotal = "lesson_total"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        units = c.lossy(PrepUnit.self, .units)
        xp = c.int(.xp)
        today = c.optional(PrepDayCount.self, .today) ?? PrepDayCount()
        reteach = (try? c.decodeIfPresent([String].self, forKey: .reteach)) ?? []
        needsRewrite = (try? c.decodeIfPresent([String].self, forKey: .needsRewrite)) ?? []
        readyCount = c.int(.readyCount)
        lessonTotal = c.int(.lessonTotal)
    }
}

// MARK: - Lesson

/// A lesson's quick check. A run's excerpt never sends `answer` or `explain`; the reader does.
struct PrepCheck: Decodable, Hashable, Sendable {
    let format: String
    let prompt: String
    let options: [String]
    let answer: String?
    let explain: String?

    var isCloze: Bool { format == "cloze" }

    private enum CodingKeys: String, CodingKey { case format, prompt, options, answer, explain }
    private struct Option: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self.text = text
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = c.string(.text)
        }
        private enum CodingKeys: String, CodingKey { case text }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.text(.format) ?? "choice"
        prompt = c.string(.prompt)
        options = c.lossy(Option.self, .options).map(\.text).filter { !$0.isEmpty }
        answer = c.text(.answer)
        explain = c.text(.explain)
    }

    init(format: String = "choice", prompt: String = "", options: [String] = [], answer: String? = nil,
         explain: String? = nil) {
        self.format = format
        self.prompt = prompt
        self.options = options
        self.answer = answer
        self.explain = explain
    }
}

struct PrepSource: Decodable, Hashable, Sendable {
    let ref: String
    let path: String?

    private enum CodingKeys: String, CodingKey { case ref, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = c.string(.ref)
        guard !ref.isEmpty else { throw PrepCourseMissingID() }
        path = c.text(.path)
    }
}

/// A lesson's recall: the question the user answers from memory, picked from the lesson's pool, with its id and
/// type (apply, tradeoff, diagnose or open); an older lesson sends only a prompt. Key points arrive with the
/// graded result.
struct PrepRecall: Decodable, Hashable, Sendable {
    let prompt: String
    let questionID: String?
    let type: String

    /// A pool question, which gets the tutor dialogue after grading.
    var isQuestion: Bool { questionID != nil }

    private enum CodingKeys: String, CodingKey {
        case prompt, type
        case questionID = "question"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = c.string(.prompt)
        guard !prompt.isEmpty else { throw PrepCourseMissingID() }
        questionID = c.text(.questionID)
        type = c.string(.type)
    }
}

/// A lesson's example-first cards: the case, the idea in up to three bullets, an optional flow of boxes, and an
/// optional line on where it showed up in the user's own work.
struct PrepLessonCards: Decodable, Hashable, Sendable {
    struct Case: Decodable, Hashable, Sendable {
        let headline: String
        let body: String
        let ask: String
    }

    struct Bullet: Decodable, Hashable, Sendable {
        let lead: String
        let text: String
        /// A concrete instance of the point, usually continuing the case; shown on the point's own card.
        var example: String?
    }

    struct Picture: Decodable, Hashable, Sendable {
        let steps: [String]
        let startLabel: String?
        let endLabel: String?

        private enum CodingKeys: String, CodingKey {
            case steps
            case startLabel = "start_label"
            case endLabel = "end_label"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            steps = (c.optional([String].self, .steps) ?? []).filter { !$0.isEmpty }
            guard steps.count >= 2 else { throw PrepCourseMissingID() }
            startLabel = c.text(.startLabel)
            endLabel = c.text(.endLabel)
        }
    }

    /// The "In code" card: one short artifact (a prompt, Python, SQL) that makes the idea concrete.
    struct Code: Decodable, Hashable, Sendable {
        let lang: String
        let body: String
        let caption: String?

        private enum CodingKeys: String, CodingKey { case lang, body, caption }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lang = c.text(.lang) ?? "text"
            body = c.string(.body)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PrepCourseMissingID() }
            caption = c.text(.caption)
        }
    }

    let theCase: Case
    let idea: [Bullet]
    let picture: Picture?
    let code: Code?
    let inYourWork: String?

    private enum CodingKeys: String, CodingKey {
        case idea, picture, code
        case theCase = "case"
        case inYourWork = "in_your_work"
    }

    private struct Work: Decodable {
        let text: String
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theCase = try c.decode(Case.self, forKey: .theCase)
        idea = c.lossy(Bullet.self, .idea)
        guard !theCase.headline.isEmpty, !idea.isEmpty else { throw PrepCourseMissingID() }
        picture = c.optional(Picture.self, .picture)
        code = c.optional(Code.self, .code)
        inYourWork = c.optional(Work.self, .inYourWork).map(\.text).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A lesson: the idea, how you'd say it, and one check. Decodes from a lesson rep's item and from
/// `GET /api/tutor/lesson`.
struct PrepLesson: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let unit: String
    let title: String
    let ideaMD: String
    let sayItMD: String
    let check: PrepCheck
    let sources: [PrepSource]
    let origin: String
    let reteachOf: String?
    /// The recall prompt; nil for older lessons that only have a multiple-choice check.
    let recall: PrepRecall?
    /// The example-first cards; nil for a coach re-teach, which reads as the idea in Markdown.
    let cards: PrepLessonCards?
    /// A vault diagram that teaches this lesson, opened from "Open the diagram".
    let diagram: PrepDiagramRef?

    var hasRecall: Bool { recall != nil }

    /// A coach-written "another way to see it" lesson; only these can be flagged.
    var isReteach: Bool { reteachOf != nil }

    private enum CodingKeys: String, CodingKey {
        case id, unit, title, check, sources, origin, recall, cards, diagram
        case ideaMD = "idea_md"
        case sayItMD = "say_it_md"
        case reteachOf = "reteach_of"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        guard !id.isEmpty else { throw PrepCourseMissingID() }
        unit = c.string(.unit)
        title = c.string(.title)
        ideaMD = c.string(.ideaMD)
        sayItMD = c.string(.sayItMD)
        check = c.optional(PrepCheck.self, .check) ?? PrepCheck()
        sources = c.lossy(PrepSource.self, .sources)
        origin = c.text(.origin) ?? "course"
        reteachOf = c.text(.reteachOf)
        recall = c.optional(PrepRecall.self, .recall)
        cards = c.optional(PrepLessonCards.self, .cards)
        diagram = c.optional(PrepDiagramRef.self, .diagram)
    }
}

/// A lesson's diagram as the lesson names it: the vault topic and its title.
struct PrepDiagramRef: Decodable, Hashable, Sendable {
    let topic: String
    let title: String

    private enum CodingKeys: String, CodingKey { case topic, title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = c.string(.topic)
        guard !topic.isEmpty else { throw PrepCourseMissingID() }
        title = c.text(.title) ?? "Diagram"
    }
}

/// `GET /api/tutor/diagram?topic=`: the diagram's `atlas-ui` fragment.
struct PrepDiagram: Decodable, Sendable {
    let html: String
}

// MARK: - Boss

/// A boss sitting, sent with the answer that completes it. `score` is nil while an answer waits for
/// its grade; `unlocked` names the next unit when this sitting passed.
struct PrepBossSitting: Decodable, Hashable, Sendable {
    let score: Double?
    let passed: Bool
    let stars: Int
    let unlocked: String?

    init(score: Double?, passed: Bool, stars: Int, unlocked: String?) {
        self.score = score
        self.passed = passed
        self.stars = stars
        self.unlocked = unlocked
    }

    private enum CodingKeys: String, CodingKey { case score, passed, stars, unlocked }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = c.optional(Double.self, .score)
        passed = c.bool(.passed)
        stars = min(3, max(0, c.int(.stars)))
        unlocked = c.text(.unlocked)
    }
}

/// A lesson a boss answer points back to.
struct PrepRevisit: Decodable, Hashable, Sendable, Identifiable {
    let lessonID: String
    let title: String

    var id: String { lessonID }

    init(lessonID: String, title: String) {
        self.lessonID = lessonID
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case lessonID = "lesson_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lessonID = c.string(.lessonID)
        guard !lessonID.isEmpty else { throw PrepCourseMissingID() }
        title = c.string(.title)
    }
}

/// Decodes `[PrepRevisit]`, dropping bad entries, for `PrepAttemptResult`.
struct PrepRevisits: Decodable, Hashable, Sendable {
    let values: [PrepRevisit]

    init(from decoder: Decoder) throws {
        values = ((try? decoder.singleValueContainer().decode([PrepCourseLossy<PrepRevisit>].self)) ?? [])
            .compactMap(\.value)
    }
}
