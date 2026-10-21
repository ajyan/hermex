import Foundation
import Observation

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

/// A verdict on a candidate: draft it into a bench story, or set it aside.
enum PrepStoryCandidateAction: String, Sendable {
    case add, dismiss
}

/// `POST /api/tutor/stories/candidate`.
struct PrepStoryCandidateRequest: Encodable, Hashable, Sendable {
    let id: String
    let action: String
}

/// A story the nightly coach proposed, waiting for a verdict.
struct PrepStoryCandidate: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String?
    let forPrompt: String?
    let why: String?
    let verdict: String?
    /// "new" waits for a verdict; "drafting" is being written into a story; "dismissed" was set
    /// aside with Not now and can still be added.
    let status: String
    /// Why the last draft failed, when it did; the candidate is back to "new".
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, why, verdict, status, error
        case forPrompt = "for_prompt"
    }

    private init(copying other: PrepStoryCandidate, status: String) {
        id = other.id
        title = other.title
        summary = other.summary
        forPrompt = other.forPrompt
        why = other.why
        verdict = other.verdict
        self.status = status
        error = nil
    }

    /// The same candidate once the server has taken it to draft.
    var drafting: PrepStoryCandidate { PrepStoryCandidate(copying: self, status: "drafting") }

    /// The same candidate once set aside with Not now.
    var dismissed: PrepStoryCandidate { PrepStoryCandidate(copying: self, status: "dismissed") }

    /// Whether `action` can be taken on it: a verdict on a new candidate, or adding a dismissed one.
    func allows(_ action: PrepStoryCandidateAction) -> Bool {
        status == "new" || (status == "dismissed" && action == .add)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredID(.id)
        title = c.string(.title)
        summary = c.optional(String.self, .summary)
        forPrompt = c.optional(String.self, .forPrompt)
        why = c.optional(String.self, .why)
        verdict = c.optional(String.self, .verdict)
        status = c.string(.status)
        error = c.optional(String.self, .error)
    }
}

/// `GET /api/tutor/stories`.
struct PrepStoryList: Decodable, Hashable, Sendable {
    let stories: [PrepStorySummary]
    let readyCount: Int
    let activeTotal: Int
    let candidates: [PrepStoryCandidate]
    /// Candidates set aside with Not now, still addable; empty from a server that doesn't list them.
    let dismissed: [PrepStoryCandidate]

    private enum CodingKeys: String, CodingKey {
        case stories, candidates, dismissed
        case readyCount = "ready_count"
        case activeTotal = "active_total"
    }

    private init(stories: [PrepStorySummary], readyCount: Int, activeTotal: Int, candidates: [PrepStoryCandidate],
                 dismissed: [PrepStoryCandidate]) {
        self.stories = stories
        self.readyCount = readyCount
        self.activeTotal = activeTotal
        self.candidates = candidates
        self.dismissed = dismissed
    }

    /// The list with one candidate marked drafting, for a card just added; a dismissed one comes
    /// back to the cards.
    func markingCandidateDrafting(_ id: String) -> PrepStoryList {
        let revived = dismissed.filter { $0.id == id }.map(\.drafting)
        return PrepStoryList(stories: stories, readyCount: readyCount, activeTotal: activeTotal,
                             candidates: candidates.map { $0.id == id ? $0.drafting : $0 } + revived,
                             dismissed: dismissed.filter { $0.id != id })
    }

    /// The list with one candidate moved from the cards to the dismissed, for Not now.
    func dismissingCandidate(_ id: String) -> PrepStoryList {
        PrepStoryList(stories: stories, readyCount: readyCount, activeTotal: activeTotal,
                      candidates: candidates.filter { $0.id != id },
                      dismissed: dismissed + candidates.filter { $0.id == id }.map(\.dismissed))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stories = c.lossy(PrepStorySummary.self, .stories)
        readyCount = c.int(.readyCount)
        activeTotal = c.int(.activeTotal)
        candidates = c.lossy(PrepStoryCandidate.self, .candidates)
        dismissed = c.lossy(PrepStoryCandidate.self, .dismissed)
    }

    /// The stories being drilled.
    var activeStories: [PrepStorySummary] { stories.filter { $0.status == "active" } }
    /// The stories waiting their turn.
    var benchStories: [PrepStorySummary] { stories.filter { $0.status == "bench" } }
}

/// One behavioral story's page (`GET /api/tutor/story?id=`): the questions it answers, its beats as cues,
/// the full telling, the follow-ups an interviewer is likely to press with (and what a strong answer covers),
/// where the story lives in the vault, and its readiness.
struct PrepStoryPage: Decodable, Hashable, Sendable {
    struct Prompt: Decodable, Hashable, Sendable {
        let text: String
        let signal: String?

        private enum CodingKeys: String, CodingKey { case text, signal }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = c.string(.text)
            signal = c.optional(String.self, .signal)
            guard !text.isEmpty else { throw PrepStoryMissingID() }
        }
    }

    struct Probe: Decodable, Hashable, Sendable {
        let attack: String
        let points: [String]

        private enum CodingKeys: String, CodingKey { case attack, points }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            attack = c.string(.attack)
            points = c.lossy(String.self, .points).filter { !$0.isEmpty }
            guard !attack.isEmpty else { throw PrepStoryMissingID() }
        }
    }

    let id: String
    let title: String
    let status: String
    let primarySignal: String?
    let prompts: [Prompt]
    let cues: [PrepStoryCue]
    let sayItMD: String
    let probes: [Probe]
    /// The story file in the vault, relative to its root, for Atlas to read and update.
    let path: String?
    let ready: Bool
    let marks: PrepStoryMarks
    let last: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, status, prompts, cues, probes, path, ready, marks, last
        case primarySignal = "primary_signal"
        case sayItMD = "say_it_md"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.requiredID(.id)
        title = c.string(.title)
        status = c.string(.status)
        primarySignal = c.optional(String.self, .primarySignal)
        prompts = c.lossy(Prompt.self, .prompts)
        cues = c.lossy(PrepStoryCue.self, .cues)
        sayItMD = c.string(.sayItMD)
        probes = c.lossy(Probe.self, .probes)
        path = c.optional(String.self, .path)
        ready = c.bool(.ready)
        marks = c.optional(PrepStoryMarks.self, .marks) ?? PrepStoryMarks()
        last = c.optional(String.self, .last)
    }
}

extension PrepCopy {
    /// The first message of "Work on it with Atlas": Atlas reads the story file, coaches it like a hiring manager,
    /// and updates the file in place when the story changes. It lands in a new chat's composer, unsent.
    static func storyAtlasPrompt(_ page: PrepStoryPage) -> String {
        let file = page.path.map { " (\($0))" } ?? ""
        return "Let's work on my interview story \u{201C}\(page.title)\u{201D}\(file). Read it, then coach me on it "
            + "like a hiring manager: ask one question at a time, push on the weakest beats, and tell me what a "
            + "stronger version would say. When we change what the story says, update that file in place, keep "
            + "its JSON shape, and run tools/prep_course.py verify."
    }
}

/// A story's page: loads the story and starts a mock interview that practices it.
@MainActor
@Observable
final class PrepStoryPageViewModel {
    let id: String
    private(set) var state: BrainLoadState<PrepStoryPage> = .loading
    /// Starts the one-story mock (the shell switches to the interviewer and opens the call).
    let mock: PrepMockViewModel
    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(id: String, client: PrepDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.id = id
        self.client = client
        self.onAPIError = onAPIError
        mock = PrepMockViewModel(client: client, onAPIError: onAPIError)
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let page = try await client.story(id: id)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(page)
        } catch {
            guard token == generation else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled { return }
            onAPIError(error)
            guard case .loading = state else { return }  // a failed refresh keeps the page
            state = .failed((error as? APIError)?.isNotFound == true
                            ? "This story is no longer in the bank." : error.localizedDescription)
        }
    }

    func startMock(open: OpenMockCallAction) async {
        await mock.startCall(kind: .behavioral, story: id, open: open)
    }
}
