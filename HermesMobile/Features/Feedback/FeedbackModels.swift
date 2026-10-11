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
private struct FeedbackLossy<Value: Decodable>: Decodable {
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

    private enum CodingKeys: String, CodingKey {
        case id, ts, feature, screen, item, build, text, status, updated, notes
        case branch, repo, tests, error, title, summary, size, attachments
        case planRepo = "plan_repo"
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
    case reject
    case reply(String)
    case retry
    case merged

    private enum CodingKeys: String, CodingKey { case decision, note }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approve: try c.encode("approve", forKey: .decision)
        case .reject: try c.encode("reject", forKey: .decision)
        case let .reply(note):
            try c.encode("reply", forKey: .decision)
            try c.encode(note, forKey: .note)
        case .retry: try c.encode("retry", forKey: .decision)
        case .merged: try c.encode("merged", forKey: .decision)
        }
    }
}

struct FeedbackPlan: Decodable, Sendable {
    let markdown: String

    private enum CodingKeys: String, CodingKey { case markdown }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        markdown = (try? c.decodeIfPresent(String.self, forKey: .markdown)) ?? ""
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
