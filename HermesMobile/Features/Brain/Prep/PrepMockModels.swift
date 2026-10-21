import Foundation
import Observation

// Models (and the screens' view model) for the voice mock ladders of Prep on this user's `hermes-webui` fork (`api/tutor_mock.py`):
// `GET /api/tutor/mocks` and `POST /api/tutor/mock/{start,grade}`. A mock is a voice call with the
// Hermes `interviewer` profile, graded after hang-up. Every field decodes tolerantly, like
// `PrepModels`; decode with `PrepDecoding`.

/// Decodes an element or yields nil, so one bad element never fails its array.
private struct PrepMockLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct PrepMockMissingID: Error {}

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }

    func requiredID(_ key: Key) throws -> String {
        guard let id = try? decodeIfPresent(String.self, forKey: key), !id.isEmpty else { throw PrepMockMissingID() }
        return id
    }

    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([PrepMockLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    /// A string-keyed map of numbers, dropping values that aren't numbers.
    func numbers(_ key: Key) -> [String: Double] {
        ((try? decodeIfPresent([String: PrepMockLossy<Double>].self, forKey: key)) ?? [:]).compactMapValues(\.value)
    }
}

/// The two ladders: behavioral B1–B4 and system design D1–D4.
enum PrepMockKind: String, CaseIterable, Hashable, Sendable {
    case behavioral, design

    /// "Behavioral", "System design".
    var title: String {
        switch self {
        case .behavioral: "Behavioral"
        case .design: "System design"
        }
    }
}

/// One rung: "D1", "Requirements", about 8 minutes (0 when the server didn't say).
struct PrepMockLevel: Decodable, Hashable, Sendable {
    let level: String
    let title: String
    let minutes: Int

    private enum CodingKeys: String, CodingKey { case level, title, minutes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.requiredID(.level)
        let title = c.string(.title)
        self.title = title.isEmpty ? level : title
        minutes = c.optional(Int.self, .minutes) ?? 0
    }
}

/// One kind's ladder: the level to take next (the highest unlocked), the highest passed (`best`,
/// nil before a pass), every level, and the latest graded score.
struct PrepLadder: Decodable, Hashable, Sendable {
    let level: String
    let unlocked: [String]
    let best: String?
    let levels: [PrepMockLevel]
    let lastScore: Double?

    private enum CodingKeys: String, CodingKey {
        case level, unlocked, best, levels
        case lastScore = "last_score"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = c.string(.level)
        unlocked = c.lossy(String.self, .unlocked)
        best = c.optional(String.self, .best)
        levels = c.lossy(PrepMockLevel.self, .levels)
        lastScore = c.optional(Double.self, .lastScore)
    }

    /// The level a Start call takes.
    var current: PrepMockLevel? { levels.first { $0.level == level } }
}

/// A point the grader named, missed or hit: its readable label (`point`, a frame point or a dim
/// name), the candidate's own words when it quoted them, and why it missed.
struct PrepMockMiss: Decodable, Hashable, Sendable {
    let concept: String?
    let quote: String?
    let why: String?
    let point: String?

    private enum CodingKeys: String, CodingKey { case concept, quote, why, point }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        concept = c.optional(String.self, .concept)
        quote = c.optional(String.self, .quote)
        why = c.optional(String.self, .why)
        point = c.optional(String.self, .point)
    }
}

/// One mock as the server last saw it. `status` is started, grading, graded, ungraded or too_short;
/// only a graded one has a score, dims, misses and hits.
struct PrepMockResult: Decodable, Identifiable, Hashable, Sendable {
    let mockID: String
    let kind: String
    let level: String
    let status: String
    let score: Double?
    let dims: [String: Double]
    let misses: [PrepMockMiss]
    let hits: [PrepMockMiss]
    let ttftP50MS: Int?
    let ts: String?

    var id: String { mockID }

    /// The score a mock passes at (`MOCK_PASS`).
    static let passMark = 4.0

    var passed: Bool { status == "graded" && (score ?? 0) >= Self.passMark }

    private enum CodingKeys: String, CodingKey {
        case kind, level, status, score, dims, misses, hits, ts
        case mockID = "mock_id"
        case ttftP50MS = "ttft_p50_ms"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mockID = try c.requiredID(.mockID)
        kind = c.string(.kind)
        level = c.string(.level)
        status = c.string(.status)
        score = c.optional(Double.self, .score)
        dims = c.numbers(.dims)
        misses = c.lossy(PrepMockMiss.self, .misses)
        hits = c.lossy(PrepMockMiss.self, .hits)
        ttftP50MS = c.optional(Int.self, .ttftP50MS)
        ts = c.optional(String.self, .ts)
    }
}

/// `GET /api/tutor/mocks`: both ladders by kind, and the newest mocks first.
struct PrepMocks: Decodable, Hashable, Sendable {
    let ladders: [String: PrepLadder]
    let recent: [PrepMockResult]

    private enum CodingKeys: String, CodingKey { case ladders, recent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ladders = ((try? c.decodeIfPresent([String: PrepMockLossy<PrepLadder>].self, forKey: .ladders)) ?? [:])
            .compactMapValues(\.value)
        recent = c.lossy(PrepMockResult.self, .recent)
    }

    func ladder(_ kind: PrepMockKind) -> PrepLadder? { ladders[kind.rawValue] }

    func recent(for kind: PrepMockKind) -> [PrepMockResult] { recent.filter { $0.kind == kind.rawValue } }
}

/// `POST /api/tutor/mock/start`: the brief the interviewer opens with, and the profile to call in.
struct PrepMockStart: Decodable, Hashable, Sendable {
    /// The Hermes profile every mock is called in (the server's `tutor_mock.PROFILE`).
    static let interviewerProfile = "interviewer"

    let mockID: String
    let level: String
    let brief: String
    let profile: String
    let title: String

    init(mockID: String, level: String, brief: String, profile: String, title: String) {
        self.mockID = mockID
        self.level = level
        self.brief = brief
        self.profile = profile
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case level, brief, profile, title
        case mockID = "mock_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mockID = try c.requiredID(.mockID)
        level = c.string(.level)
        brief = c.string(.brief)
        let profile = c.string(.profile)
        self.profile = profile.isEmpty ? Self.interviewerProfile : profile
        title = c.string(.title)
    }
}

/// `level` is left out when nil, and the server takes the ladder's current level.
struct PrepMockStartRequest: Encodable, Hashable, Sendable {
    let kind: String
    let level: String?
    /// A behavioral story to practice on its own; omitted for a ladder mock.
    var story: String?
}

struct PrepMockGradeRequest: Encodable, Hashable, Sendable {
    let mockID: String
    let sessionID: String
    let turnMS: [Int]

    private enum CodingKeys: String, CodingKey {
        case mockID = "mock_id"
        case sessionID = "session_id"
        case turnMS = "turn_ms"
    }
}

// MARK: - Copy

/// What the result screen shows for a mock's status.
enum PrepMockResultDisplay: Equatable {
    case grading
    case graded(PrepMockResult)
    case ungraded
    case tooShort
    /// The grade request never reached the server, so nothing will grade it.
    case notSent
    /// The mocks loaded without this one.
    case notFound
}

enum PrepMockCopy {
    static let grading = "Grading your mock…"
    static let ungraded = "Couldn't grade, saved for tonight"
    static let tooShort = "Too short to grade"
    static let notSent = "This call wasn't sent for grading."
    static let notFound = "Couldn't find this mock"
    static let noInterviewer = "Interviewer isn't set up on this server."

    /// What the result screen shows, once the mocks have loaded; nil is a mock they don't include.
    static func display(_ result: PrepMockResult?) -> PrepMockResultDisplay {
        guard let result else { return .notFound }
        return switch result.status {
        case "graded": .graded(result)
        case "ungraded": .ungraded
        case "too_short": .tooShort
        case "started": .notSent
        default: .grading
        }
    }

    /// "Behavioral · B2 Two probes".
    static func rowTitle(_ kind: PrepMockKind, ladder: PrepLadder) -> String {
        let level = [ladder.level, ladder.current?.title].compactMap { $0 }.filter { !$0.isEmpty }
        return ([kind.title] + [level.joined(separator: " ")].filter { !$0.isEmpty }).joined(separator: " \u{00B7} ")
    }

    static func levelTitle(_ level: String, in ladder: PrepLadder?) -> String {
        guard let title = ladder?.levels.first(where: { $0.level == level })?.title, title != level else { return level }
        return "\(level) \(title)"
    }

    /// "Next: D2 Through architecture" after a pass, nil at the top of the ladder.
    static func next(after level: String, in ladder: PrepLadder) -> String? {
        guard let index = ladder.levels.firstIndex(where: { $0.level == level }),
              ladder.levels.indices.contains(index + 1) else { return nil }
        let next = ladder.levels[index + 1]
        return "Next: \(next.level) \(next.title)"
    }

    static func score(_ value: Double) -> String { String(format: "%.1f", value) }

    static func minutes(_ minutes: Int) -> String? {
        minutes > 0 ? "About \(minutes) minutes" : nil
    }

    /// The median time to the interviewer's first word.
    static func firstWord(_ ms: Int) -> String {
        "First word in \(String(format: "%.1f", Double(ms) / 1000)) s (median)"
    }

    static func scored(_ kind: PrepMockKind) -> String {
        switch kind {
        case .behavioral:
            "Scored on each story's beats and how you hold up under the follow-ups. 4.0 passes."
        case .design:
            "Scored on each frame point in order, plus structure, depth and communication. 4.0 passes."
        }
    }

    static func statusWord(_ result: PrepMockResult) -> String {
        switch display(result) {
        case .graded: result.passed ? "Passed" : "Not yet"
        case .grading: "Grading"
        case .ungraded: "Saved for tonight"
        case .tooShort: "Too short"
        case .notSent, .notFound: "Not graded"
        }
    }

    /// "requirements" -> "Requirements".
    static func dimTitle(_ dim: String) -> String {
        let words = dim.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

// MARK: - View model

/// The mock ladders and recent mocks for one screen (home's section, a brief, a result). Each
/// screen owns its own, built for the active server, so nothing outlives a server switch.
@MainActor
@Observable
final class PrepMockViewModel {
    private(set) var state: BrainLoadState<PrepMocks> = .loading
    /// True from Start call until the call's chat is open (or the start failed).
    private(set) var isStarting = false
    /// The level the brief's picker is on; nil (or one not unlocked) means the ladder's current level.
    var chosenLevel: String?
    /// True while a result's Send for grading is on its way.
    private(set) var isSendingGrade = false
    /// Why the last start (or Send for grading) failed.
    private(set) var errorMessage: String?
    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(client: PrepDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    var mocks: PrepMocks? {
        if case .loaded(let mocks) = state { return mocks }
        return nil
    }

    /// Loads (or refreshes) the ladders. A failed refresh keeps what is already showing.
    func load() async {
        generation += 1
        let token = generation
        do {
            let mocks = try await client.mocks()
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(mocks)
        } catch {
            guard token == generation, !Self.isCancellation(error) else { return }
            onAPIError(error)
            guard mocks == nil else { return }
            state = (error as? APIError)?.isNotFound == true ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// The unlocked levels of a ladder, in ladder order: the ones a call can take (spec §6.3).
    func replayableLevels(_ kind: PrepMockKind) -> [PrepMockLevel] {
        guard let ladder = mocks?.ladder(kind) else { return [] }
        return ladder.levels.filter { ladder.unlocked.contains($0.level) }
    }

    /// The level Start call takes: the one picked when it is unlocked, else the ladder's current.
    func level(for kind: PrepMockKind) -> String? {
        guard let ladder = mocks?.ladder(kind) else { return nil }
        if let chosenLevel, ladder.unlocked.contains(chosenLevel) { return chosenLevel }
        return ladder.level.isEmpty ? nil : ladder.level
    }

    /// Starts a mock at `level`, else the kind's current level. A 409 means the server has no
    /// interviewer profile.
    func start(kind: PrepMockKind, level: String? = nil, story: String? = nil) async -> PrepMockStart? {
        errorMessage = nil
        do {
            return try await client.mockStart(kind: kind, level: level, story: story)
        } catch {
            guard !Self.isCancellation(error) else { return nil }
            if case .http(409, _)? = error as? APIError {
                errorMessage = PrepMockCopy.noInterviewer
            } else {
                onAPIError(error)
                errorMessage = error.localizedDescription
            }
            return nil
        }
    }

    /// Start call, at the picked level: the shell makes the interviewer profile active, then starts
    /// the mock through this view model and opens its call. A failed switch starts nothing.
    func startCall(kind: PrepMockKind, story: String? = nil, open: OpenMockCallAction) async {
        guard !isStarting else { return }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        let level = story == nil ? level(for: kind) : nil
        do {
            try await open { await self.start(kind: kind, level: level, story: story) }
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Asks again for the grade of a call whose request never got through, then reloads.
    func sendForGrading(_ grade: MockCallGrade) async {
        guard !isSendingGrade else { return }
        isSendingGrade = true
        errorMessage = nil
        defer { isSendingGrade = false }
        do {
            try await grade.post(to: client)
        } catch {
            guard !Self.isCancellation(error) else { return }
            onAPIError(error)
            errorMessage = error.localizedDescription
            return
        }
        await load()
    }

    /// One mock among the recent ones, as last loaded.
    func result(mockID: String) -> PrepMockResult? {
        mocks?.recent.first { $0.mockID == mockID }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }
}
