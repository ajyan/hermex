import Foundation

// Models for the feedback loop on this user's `hermes-webui` fork (`api/feedback.py`).
// Entries decode tolerantly: every field may be missing or null. Keys are snake_case on
// the wire and matched literally, so decode with `FeedbackDecoding`, not `APIClient`'s decoder.

enum FeedbackDecoding {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

enum FeedbackGroup: Hashable, Sendable {
    case needsReview, inProgress, done
}

enum FeedbackStatus: String, Hashable, Sendable {
    case new, planning, planned, approved, building, ready, failed, rejected, merged
    case unknown

    init(wire: String?) {
        self = wire.flatMap(FeedbackStatus.init(rawValue:)) ?? .unknown
    }

    /// The status in words, shown in the inbox. Plain English like the rest of the fork-only screens.
    var label: String {
        switch self {
        case .new: "Waiting for tonight"
        case .planning: "Planning"
        case .planned: "Plan ready"
        case .approved: "Approved"
        case .building: "Building"
        case .ready: "Branch ready"
        case .failed: "Failed"
        case .rejected: "Rejected"
        case .merged: "Merged"
        case .unknown: "Unknown"
        }
    }

    var group: FeedbackGroup {
        switch self {
        case .planned, .ready, .failed: .needsReview
        case .new, .planning, .approved, .building, .unknown: .inProgress
        case .merged, .rejected: .done
        }
    }
}

struct FeedbackNote: Decodable, Hashable, Sendable {
    let ts: String?
    let text: String

    private enum CodingKeys: String, CodingKey { case ts, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try? c.decodeIfPresent(String.self, forKey: .ts)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
    }
}

/// An element that yields nil instead of failing its array.
struct FeedbackLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// A file the server stored with an entry: `screenshot.jpg` (kind `screenshot`) or
/// `context.json` (kind `context`). Listed only; the app doesn't fetch them in v1.
struct FeedbackAttachment: Decodable, Hashable, Sendable {
    let name: String
    let kind: String?

    private enum CodingKeys: String, CodingKey { case name, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
    }
}

struct FeedbackEntry: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let ts: String?
    let feature: String
    let screen: String
    let item: String?
    let build: String?
    let text: String
    let status: FeedbackStatus
    let updated: String?
    let notes: [FeedbackNote]
    let branch: String?
    let repo: String?
    let tests: String?
    let error: String?
    let title: String?
    let summary: String?
    let size: String?
    let planRepo: String?
    let attachments: [FeedbackAttachment]
    /// Set on a `rejected` entry the nightly job folded into another entry's plan: that entry's id.
    let mergedInto: String?
    /// How many questions the entry's plan asks; 0 without a plan or for an old-format plan.
    let questionCount: Int

    /// Whether the nightly job folded this entry into another entry's plan.
    var isMerged: Bool { status == .rejected && mergedInto != nil }

    private enum CodingKeys: String, CodingKey {
        case id, ts, feature, screen, item, build, text, status, updated, notes
        case branch, repo, tests, error, title, summary, size, attachments
        case planRepo = "plan_repo"
        case mergedInto = "merged_into"
        case questionCount = "question_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ key: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        id = str(.id) ?? ""
        ts = str(.ts)
        feature = str(.feature) ?? ""
        screen = str(.screen) ?? ""
        item = str(.item)
        build = str(.build)
        text = str(.text) ?? ""
        status = FeedbackStatus(wire: str(.status))
        updated = str(.updated)
        notes = ((try? c.decodeIfPresent([FeedbackLossy<FeedbackNote>].self, forKey: .notes)) ?? []).compactMap(\.value)
        branch = str(.branch)
        repo = str(.repo)
        tests = str(.tests)
        error = str(.error)
        title = str(.title)
        summary = str(.summary)
        size = str(.size)
        planRepo = str(.planRepo)
        attachments = ((try? c.decodeIfPresent([FeedbackLossy<FeedbackAttachment>].self, forKey: .attachments)) ?? []).compactMap(\.value)
        mergedInto = str(.mergedInto)
        questionCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .questionCount)) ?? 0)
    }
}

/// Where in the app the feedback is about. Each feature screen provides one.
struct FeedbackContext: Hashable, Sendable {
    /// The server rejects a state value longer than this.
    static let maxStateValueLength = 2000

    let feature: String
    let screen: String
    let item: String?
    /// Small facts about what the screen was showing, e.g. `session_id` on Chat. Nil and
    /// empty values are dropped and each value is capped at `maxStateValueLength`.
    let state: [String: String]

    init(feature: String, screen: String, item: String? = nil, state: [String: String?] = [:]) {
        self.feature = feature
        self.screen = screen
        self.item = item
        self.state = state.compactMapValues { value in
            guard let value, !value.isEmpty else { return nil }
            return String(value.prefix(Self.maxStateValueLength))
        }
    }

    /// Plain words for the sheet's About row, e.g. "Prep · Spot the bug · Longest Substring".
    var about: String {
        [feature, screen, item]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// The body of `POST /api/feedback`. `state` and `screenshot` are left out when empty;
/// servers that predate them ignore unknown fields.
struct FeedbackCreate: Encodable, Sendable {
    let feature: String
    let screen: String
    let item: String?
    let build: String?
    let text: String
    let state: [String: String]?
    /// Base64 JPEG.
    let screenshot: String?

    init(context: FeedbackContext, build: String?, text: String, screenshot: String? = nil) {
        feature = context.feature
        screen = context.screen
        item = context.item
        self.build = build
        self.text = text
        state = context.state.isEmpty ? nil : context.state
        self.screenshot = screenshot
    }
}

/// The body of `POST /api/feedback/<id>/decision`.
enum FeedbackDecision: Encodable, Hashable, Sendable {
    case approve
    /// Approve, with the plan's answers as a note the build follows.
    case approveAnswering(String)
    case reject
    case reply(String)
    case retry
    case merged
    /// Takes an entry the nightly job merged into another entry's plan back to `new`.
    case unmerge

    private enum CodingKeys: String, CodingKey { case decision, note }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approve: try c.encode("approve", forKey: .decision)
        case let .approveAnswering(note):
            try c.encode("approve", forKey: .decision)
            try c.encode(note, forKey: .note)
        case .reject: try c.encode("reject", forKey: .decision)
        case let .reply(note):
            try c.encode("reply", forKey: .decision)
            try c.encode(note, forKey: .note)
        case .retry: try c.encode("retry", forKey: .decision)
        case .merged: try c.encode("merged", forKey: .decision)
        case .unmerge: try c.encode("unmerge", forKey: .decision)
        }
    }
}

/// One answer the planner offers to a question.
struct FeedbackOption: Decodable, Hashable, Sendable {
    let text: String
    let recommended: Bool

    private enum CodingKeys: String, CodingKey { case text, recommended }

    init(text: String, recommended: Bool = false) {
        self.text = text
        self.recommended = recommended
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        recommended = (try? c.decodeIfPresent(Bool.self, forKey: .recommended)) ?? false
    }
}

/// A question from the plan's Questions section, with the answers to choose from.
struct FeedbackQuestion: Decodable, Hashable, Sendable {
    let text: String
    let options: [FeedbackOption]

    private enum CodingKeys: String, CodingKey { case text, options }

    init(text: String, options: [FeedbackOption]) {
        self.text = text
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        options = ((try? c.decodeIfPresent([FeedbackLossy<FeedbackOption>].self, forKey: .options)) ?? []).compactMap(\.value)
    }
}

/// `GET /api/feedback/<id>/plan`: the Markdown, plus the parts the server finds in a plan
/// written in the steering format (Questions, What changes, Details). An older plan has no
/// `changes`, and the app shows its Markdown whole.
struct FeedbackPlan: Decodable, Hashable, Sendable {
    let markdown: String
    let questions: [FeedbackQuestion]
    let changes: String?
    let details: String?

    /// Whether the plan has the steering parts; otherwise show `body` whole.
    var isSteerable: Bool { changes != nil }

    /// The Markdown without its `---` frontmatter, whose fields the entry already carries.
    /// Rendered raw, the fences turn the frontmatter into one giant heading.
    var body: String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return markdown }
        return lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey { case markdown, questions, changes, details }

    init(markdown: String, questions: [FeedbackQuestion] = [], changes: String? = nil, details: String? = nil) {
        self.markdown = markdown
        self.questions = questions
        self.changes = changes
        self.details = details
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markdown = (try? c.decodeIfPresent(String.self, forKey: .markdown)) ?? ""
        questions = ((try? c.decodeIfPresent([FeedbackLossy<FeedbackQuestion>].self, forKey: .questions)) ?? [])
            .compactMap(\.value)
            .filter { $0.options.count >= 2 }
        func text(_ key: CodingKeys) -> String? {
            let value = (try? c.decodeIfPresent(String.self, forKey: key))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        changes = text(.changes)
        details = text(.details)
    }
}

/// The user's answers to a plan's questions, by question index. They travel as one note, a
/// line per answered question (`Q1 <question> → <answer>`), which the planner and build read.
struct FeedbackAnswers: Equatable, Sendable {
    enum Pick: Equatable, Sendable {
        case option(Int)
        case other(String)
    }

    private(set) var picks: [Int: Pick] = [:]

    func pick(for question: Int) -> Pick? { picks[question] }

    /// Picks `option` for `question`, or clears it when it is already picked.
    mutating func toggle(_ option: Int, for question: Int) {
        picks[question] = picks[question] == .option(option) ? nil : .option(option)
    }

    /// Sets a typed answer; blank text clears the question.
    mutating func setOther(_ text: String, for question: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        picks[question] = trimmed.isEmpty ? nil : .other(trimmed)
    }

    /// The note for `questions`, or nil when nothing is answered.
    func note(for questions: [FeedbackQuestion]) -> String? {
        let lines = questions.indices.compactMap { index -> String? in
            let answer: String
            switch picks[index] {
            case .option(let option)? where questions[index].options.indices.contains(option):
                answer = questions[index].options[option].text
            case .other(let text)?:
                answer = text
            default:
                return nil
            }
            return "Q\(index + 1) \(questions[index].text) → \(answer)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// The `GET /api/feedback` envelope `{entries: [...]}`. A missing key is an empty list, and
/// an entry that fails to decode is dropped.
struct FeedbackList: Decodable, Sendable {
    let entries: [FeedbackEntry]

    private enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = ((try? c.decodeIfPresent([FeedbackLossy<FeedbackEntry>].self, forKey: .entries)) ?? []).compactMap(\.value)
    }
}
