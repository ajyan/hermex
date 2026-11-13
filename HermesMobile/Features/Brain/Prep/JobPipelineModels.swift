import Foundation
import Observation

/// The job pipeline from this user's `hermes-webui` fork (`api/vault_jobs.py` over the vault's
/// `tools/job_pipeline.py`): every application in motion, its stage, booked interviews, notes and an interview
/// one-pager. `GET /api/jobs/pipeline` is the search at a glance (Prep's Your search, the Brief's search card),
/// `GET /api/jobs/pipeline/<id>` one application, and `POST /api/jobs/pipeline` its actions. Stock servers
/// answer 404, which hides the section and the card.
struct JobPipeline: Decodable, Equatable, Sendable {
    let today: String
    let upcoming: [JobInterviewSlot]
    /// Open applications, furthest along first, then the stalest.
    let applications: [JobApplicationRow]
    let closed: [JobApplicationRow]
    let stages: [JobStage]
    let metrics: JobMetrics?
    /// This week's applications and outreach: the vault's one count (`job_pipeline.week`), which the Ask, the
    /// search card, the close card and Prep all show. Nil on a server that predates it.
    let week: JobWeek?
    /// The next interview's pack, which Prep's home leads with; nil with no interview booked (in the pipeline
    /// or on the calendar), and on a server that predates it.
    let pack: JobPack?

    private enum CodingKeys: String, CodingKey { case today, upcoming, applications, closed, stages, metrics, week, pack }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = try c.decode(String.self, forKey: .today)
        upcoming = Self.lossy(c, .upcoming)
        applications = Self.lossy(c, .applications)
        closed = Self.lossy(c, .closed)
        stages = Self.lossy(c, .stages)
        metrics = try? c.decodeIfPresent(JobMetrics.self, forKey: .metrics)
        week = try? c.decodeIfPresent(JobWeek.self, forKey: .week)
        pack = try? c.decodeIfPresent(JobPack.self, forKey: .pack)
    }

    private static func lossy<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        ((try? c.decodeIfPresent([PrepLossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }

    /// This week's applications against the goal. A server without `week` still sends the same number as
    /// `metrics.added_week`, with no target.
    var applicationsWeek: JobCount? {
        week?.applications ?? metrics.map { JobCount(done: $0.addedWeek, target: nil) }
    }
}

/// The week's two counts, Monday to today.
struct JobWeek: Decodable, Equatable, Sendable {
    let start: String?
    let applications: JobCount?
    let outreach: JobCount?

    private enum CodingKeys: String, CodingKey { case start, applications, outreach }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try? c.decodeIfPresent(String.self, forKey: .start)
        applications = try? c.decodeIfPresent(JobCount.self, forKey: .applications)
        outreach = try? c.decodeIfPresent(JobCount.self, forKey: .outreach)
    }
}

/// A count shown as pips: `done` of `target`. With no target every pip is filled.
struct JobCount: Decodable, Equatable, Sendable {
    let done: Int
    let target: Int?

    /// More pips than this read as a count beside them.
    static let maxPips = 10

    /// How many pips to draw.
    var total: Int { max(target ?? done, done) }
    var shown: Int { min(total, Self.maxPips) }
    var overflows: Bool { total > Self.maxPips }
    /// What VoiceOver reads after the label: "2 of 5", or "3" with no target.
    var spoken: String { target == nil ? "\(done)" : "\(done) of \(total)" }
}

/// What to practice for the next interview (the vault's `job_pipeline.pack`): who and when, the stories picked
/// for it, the mock for its round, whether its one-pager is written, and the step today's session starts with.
struct JobPack: Decodable, Equatable, Sendable {
    /// The application's pipeline id.
    let id: String
    let company: String?
    let role: String?
    /// The interview's own name ("First round").
    let label: String
    /// The round it prepares for ("Recruiter screen").
    let round: String?
    let on: String
    let time: String?
    let inDays: Int
    /// "calendar" when the interview was found on Google Calendar rather than booked in the pipeline.
    let source: String?
    /// The length of the daily session its button starts.
    let minutes: Int
    let stories: [JobPackStory]
    /// "onepager" (the stories behind the one-pager's questions) or "bank" (no one-pager: the active stories
    /// told longest ago).
    let storiesFrom: String?
    let mock: JobPackStep?
    let onePagerReady: Bool
    /// The first story or mock not done yet; nil once all are.
    let next: JobPackStep?

    private enum CodingKeys: String, CodingKey {
        case id, company, role, label, round, on, time, source, minutes, stories, mock, onepager, next
        case inDays = "in_days"
        case storiesFrom = "stories_from"
    }

    private struct OnePager: Decodable { let ready: Bool? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        on = try c.decode(String.self, forKey: .on)
        company = try? c.decodeIfPresent(String.self, forKey: .company)
        role = try? c.decodeIfPresent(String.self, forKey: .role)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? "Interview"
        round = try? c.decodeIfPresent(String.self, forKey: .round)
        time = try? c.decodeIfPresent(String.self, forKey: .time)
        inDays = (try? c.decodeIfPresent(Int.self, forKey: .inDays)) ?? 0
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        minutes = (try? c.decodeIfPresent(Int.self, forKey: .minutes)) ?? 20
        stories = ((try? c.decodeIfPresent([PrepLossy<JobPackStory>].self, forKey: .stories)) ?? nil)?.compactMap(\.value) ?? []
        storiesFrom = try? c.decodeIfPresent(String.self, forKey: .storiesFrom)
        mock = try? c.decodeIfPresent(JobPackStep.self, forKey: .mock)
        onePagerReady = ((try? c.decodeIfPresent(OnePager.self, forKey: .onepager)) ?? nil)?.ready ?? false
        next = try? c.decodeIfPresent(JobPackStep.self, forKey: .next)
    }

    /// The stories told so far, as pips.
    var told: JobCount { JobCount(done: stories.filter(\.done).count, target: stories.count) }

    /// What the pack's button does: tell the next story, start the round's mock, or (all done, or a step this
    /// build doesn't know) open the application's prep plan.
    var start: JobPackStart {
        guard let next else { return .plan }
        switch next.kind {
        case "story": return .route(.story(next.id))
        case "ladder": return PrepMockKind(rawValue: next.id).map { .route(.mockLadder($0)) } ?? .plan
        case "mock": return .call(part: "questions")
        case "pitch": return .call(part: "pitch")
        default: return .plan
        }
    }

    /// Where the mock row goes: a ladder's brief, or the prep plan, which holds the company mock call.
    var mockRoute: PrepRoute {
        if let mock, mock.kind == "ladder", let kind = PrepMockKind(rawValue: mock.id) { return .mockLadder(kind) }
        return .application(id)
    }
}

struct JobPackStory: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    /// The short name the one-pager gives it ("Retrieval quality").
    let name: String
    let title: String?
    /// Told in Prep since the application was added.
    let done: Bool

    private enum CodingKeys: String, CodingKey { case id, name, title, done }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? false
    }
}

/// A step of the pack: `kind` is story (`id` is the story's), ladder (`id` is the mock ladder's kind), or mock
/// (the company mock call over the one-pager's questions).
struct JobPackStep: Decodable, Equatable, Sendable {
    let id: String
    let kind: String
    let title: String
    let done: Bool?
}

enum JobPackStart: Equatable {
    case route(PrepRoute)
    /// A company mock call: pitch or questions.
    case call(part: String)
    case plan
}

/// The stages an open application moves through, Applied to Offer.
struct JobStage: Decodable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
}

/// A booked interview on the coming days, with whose it is.
struct JobInterviewSlot: Decodable, Equatable, Identifiable, Sendable {
    /// The application's id.
    let id: String
    let company: String?
    let role: String?
    let key: String
    let label: String
    let on: String
    let time: String?
    let inDays: Int

    private enum CodingKeys: String, CodingKey {
        case id, company, role, key, label, on, time
        case inDays = "in_days"
    }
}

/// An interview on one application: the latest booking per `key`.
struct JobInterview: Decodable, Equatable, Hashable, Sendable {
    let key: String
    let label: String
    let on: String
    let time: String?
}

struct JobApplicationRow: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let company: String?
    let role: String?
    let via: String?
    let stage: String
    let stageName: String
    /// For a closed one: rejected, withdrew, accepted, or no_reply (no movement in 30 days).
    let outcome: String?
    /// The last day it moved.
    let since: String
    let days: Int
    let open: Bool
    /// Its place among the open stages (0 is Applied); nil once closed.
    let step: Int?
    let next: JobInterview?
    /// What happens next, in plain words ("First round Thu", "Waiting to hear back"); nil once closed, and on
    /// a server that predates it.
    let nextStep: String?

    private enum CodingKeys: String, CodingKey {
        case id, company, role, via, stage, outcome, since, days, open, step, next
        case stageName = "stage_name"
        case nextStep = "next_step"
    }

    /// The company, or the recruiter a lead came through.
    var name: String { company ?? via.map { "Via \($0)" } ?? "Unnamed" }
}

struct JobMetrics: Decodable, Equatable, Sendable {
    /// Applications added since Monday.
    let addedWeek: Int
    /// Interviews booked in the coming weeks.
    let booked: Int
    /// Applications added in the last 30 days, and how many of them got past Applied.
    let recent: Int
    let replies: Int
    /// Open applications that haven't moved in 14 days, with no interview booked.
    let quiet: Int
    let quietNames: [String]

    private enum CodingKeys: String, CodingKey {
        case booked, recent, replies, quiet
        case addedWeek = "added_week"
        case quietNames = "quiet_names"
    }
}

/// One application on its company page.
struct JobApplication: Decodable, Equatable, Sendable {
    let row: JobApplicationRow
    let url: String?
    let comp: String?
    let location: String?
    /// Other roles at the company he means to ask about.
    let also: [JobOtherRole]
    let interviews: [JobInterview]
    /// Newest first.
    let timeline: [JobTimelineItem]
    let onepager: JobOnePager?
    /// The one-pager's stories, each marked told once he has told it in Prep since the application was added.
    let plan: [JobPlanStory]
    /// The round the plan prepares for ("Recruiter screen"), nil when there is nothing to prepare.
    let round: String?
    /// The round's prep plan in order: the pitch, the stories, the company mock, the ladder mocks.
    let steps: [JobPlanStep]
    let stages: [JobStage]

    private enum CodingKeys: String, CodingKey {
        case url, comp, location, also, interviews, timeline, onepager, plan, round, steps, stages
    }

    init(from decoder: Decoder) throws {
        row = try JobApplicationRow(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        comp = try? c.decodeIfPresent(String.self, forKey: .comp)
        location = try? c.decodeIfPresent(String.self, forKey: .location)
        also = Self.lossy(c, .also)
        interviews = Self.lossy(c, .interviews)
        timeline = Self.lossy(c, .timeline)
        onepager = try? c.decodeIfPresent(JobOnePager.self, forKey: .onepager)
        plan = Self.lossy(c, .plan)
        round = try? c.decodeIfPresent(String.self, forKey: .round)
        steps = Self.lossy(c, .steps)
        stages = Self.lossy(c, .stages)
    }

    private static func lossy<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        ((try? c.decodeIfPresent([PrepLossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}

struct JobOtherRole: Decodable, Equatable, Hashable, Sendable {
    let role: String
    let url: String?
    let comp: String?
    let note: String?
}

struct JobTimelineItem: Decodable, Equatable, Hashable, Sendable {
    let date: String?
    let text: String
    let note: Bool?
}

struct JobPlanStory: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let title: String?
    let told: Bool
}

/// One step of an application's prep plan. `kind` is pitch or mock (a company mock call, started here),
/// story (`id` is the story's), or ladder (`id` is the mock ladder's kind). Done once he did it in Prep this round.
struct JobPlanStep: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let done: Bool

    /// The company mock call's part for a pitch or mock step.
    var callPart: String? {
        switch kind {
        case "pitch": "pitch"
        case "mock": "questions"
        default: nil
        }
    }
}

/// A story the one-pager leans on, by its Prep id, with the short name it shows.
struct JobStoryRef: Decodable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// What they ask for, and his proof, with the stories that carry it. `gap` marks one he can't back yet.
struct JobProofRow: Decodable, Equatable, Hashable, Sendable {
    let need: String
    let proof: String
    let stories: [JobStoryRef]
    let gap: Bool

    private enum CodingKeys: String, CodingKey { case need, proof, stories, gap }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        need = try c.decode(String.self, forKey: .need)
        proof = (try? c.decodeIfPresent(String.self, forKey: .proof)) ?? ""
        stories = ((try? c.decodeIfPresent([PrepLossy<JobStoryRef>].self, forKey: .stories)) ?? nil)?.compactMap(\.value) ?? []
        gap = (try? c.decodeIfPresent(Bool.self, forKey: .gap)) ?? false
    }
}

struct JobOnePagerQuestion: Decodable, Equatable, Hashable, Sendable {
    let text: String
    let stories: [JobStoryRef]

    private enum CodingKeys: String, CodingKey { case text, stories }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        stories = ((try? c.decodeIfPresent([PrepLossy<JobStoryRef>].self, forKey: .stories)) ?? nil)?.compactMap(\.value) ?? []
    }
}

/// Another role at the company to raise in the interview: when, and why he fits it.
struct JobOnePagerRaise: Decodable, Equatable, Sendable {
    let role: String
    let comp: String?
    let when: String?
    let rows: [JobProofRow]

    private enum CodingKeys: String, CodingKey { case role, comp, when, rows }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        comp = try? c.decodeIfPresent(String.self, forKey: .comp)
        when = try? c.decodeIfPresent(String.self, forKey: .when)
        rows = ((try? c.decodeIfPresent([PrepLossy<JobProofRow>].self, forKey: .rows)) ?? nil)?.compactMap(\.value) ?? []
    }
}

struct JobSource: Decodable, Equatable, Hashable, Sendable {
    let title: String
    let url: String
}

/// The page to read before an interview: his pitch, the company in a few lines, their asks against his proof,
/// another role to raise, likely questions, his questions for them, and what to keep in mind.
struct JobOnePager: Decodable, Equatable, Sendable {
    /// Which conversation it is for, e.g. "First round · Tue Nov 10".
    let forLabel: String?
    let updated: String?
    let pitch: String?
    let company: [String]
    let proof: [JobProofRow]
    let raise: JobOnePagerRaise?
    let questions: [JobOnePagerQuestion]
    let ask: [String]
    let watch: [String]
    let sources: [JobSource]

    private enum CodingKeys: String, CodingKey {
        case updated, pitch, company, proof, raise, questions, ask, watch, sources
        case forLabel = "for"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forLabel = try? c.decodeIfPresent(String.self, forKey: .forLabel)
        updated = try? c.decodeIfPresent(String.self, forKey: .updated)
        pitch = try? c.decodeIfPresent(String.self, forKey: .pitch)
        company = (try? c.decodeIfPresent([String].self, forKey: .company)) ?? nil ?? []
        proof = Self.lossy(c, .proof)
        raise = try? c.decodeIfPresent(JobOnePagerRaise.self, forKey: .raise)
        questions = Self.lossy(c, .questions)
        ask = (try? c.decodeIfPresent([String].self, forKey: .ask)) ?? nil ?? []
        watch = (try? c.decodeIfPresent([String].self, forKey: .watch)) ?? nil ?? []
        sources = Self.lossy(c, .sources)
    }

    private static func lossy<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        ((try? c.decodeIfPresent([PrepLossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}

/// An action on the pipeline, as `POST /api/jobs/pipeline` takes it.
enum JobPipelineAction: Equatable, Sendable {
    case add(company: String?, role: String?, via: String?, url: String?, stage: String?)
    case stage(id: String, stage: String)
    case close(id: String, outcome: String)
    case reopen(id: String)
    /// Books (or moves) an interview; a nil `on` cancels it.
    case interview(id: String, label: String, on: String?, key: String?)
    case note(id: String, text: String)

    var request: JobPipelineRequest {
        switch self {
        case let .add(company, role, via, url, stage):
            return JobPipelineRequest(action: "add", company: company, role: role, via: via, url: url, stage: stage)
        case let .stage(id, stage):
            return JobPipelineRequest(action: "stage", id: id, stage: stage)
        case let .close(id, outcome):
            return JobPipelineRequest(action: "stage", id: id, stage: "closed", outcome: outcome)
        case let .reopen(id):
            return JobPipelineRequest(action: "reopen", id: id)
        case let .interview(id, label, on, key):
            return JobPipelineRequest(action: "interview", id: id, label: label, on: on, key: key)
        case let .note(id, text):
            return JobPipelineRequest(action: "note", id: id, text: text)
        }
    }
}

struct JobPipelineRequest: Encodable, Equatable, Sendable {
    let action: String
    var id: String?
    var company: String?
    var role: String?
    var via: String?
    var url: String?
    var stage: String?
    var outcome: String?
    var label: String?
    var on: String?
    var key: String?
    var text: String?
}

protocol JobPipelineDataClient: Sendable {
    func pipeline() async throws -> JobPipeline
    func application(_ id: String) async throws -> JobApplication
    func act(_ request: JobPipelineRequest) async throws -> JobApplication
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol, decoding with `PrepDecoding`.
struct APIClientJobPipelineAdapter: JobPipelineDataClient {
    let apiClient: APIClient

    func pipeline() async throws -> JobPipeline {
        try decode(try await apiClient.sendData(endpoint: .jobsPipeline, method: "GET", encodedBody: nil, timeout: 10))
    }

    func application(_ id: String) async throws -> JobApplication {
        try decode(try await apiClient.sendData(endpoint: .jobsPipelineItem(id: id), method: "GET", encodedBody: nil, timeout: 10))
    }

    func act(_ request: JobPipelineRequest) async throws -> JobApplication {
        try decode(try await apiClient.sendData(endpoint: .jobsPipeline, method: "POST", body: request))
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PrepDecoding.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}

/// The search at a glance, for Prep's Your search and the Brief's search card. A server without the pipeline
/// (404) leaves `pipeline` nil and the section hidden; any other failed first load sets `loadFailed`, so Prep
/// can offer a retry. A failed reload keeps the pipeline already on screen.
@MainActor
@Observable
final class JobPipelineModel {
    private(set) var pipeline: JobPipeline?
    private(set) var loadFailed = false
    private(set) var pending = false
    private(set) var error: String?

    @ObservationIgnored private let client: JobPipelineDataClient
    @ObservationIgnored private var generation = 0

    init(client: JobPipelineDataClient) {
        self.client = client
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let next = try await client.pipeline()
            guard token == generation, !Task.isCancelled else { return }
            pipeline = next
            loadFailed = false
        } catch {
            guard token == generation, !(error is CancellationError), !Task.isCancelled else { return }
            loadFailed = pipeline == nil && (error as? APIError)?.isNotFound != true
        }
    }

    /// Adds an application; returns its id once the server saved it, so the caller can open it.
    func add(_ action: JobPipelineAction) async -> String? {
        guard !pending else { return nil }
        pending = true
        error = nil
        defer { pending = false }
        do {
            let saved = try await client.act(action.request)
            await load()
            return saved.row.id
        } catch {
            self.error = "Couldn't save. Try again."
            return nil
        }
    }
}

/// One application's company page and one-pager.
@MainActor
@Observable
final class JobApplicationModel {
    private(set) var state: BrainLoadState<JobApplication> = .loading
    private(set) var pending = false
    private(set) var error: String?

    let id: String
    @ObservationIgnored private let client: JobPipelineDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(id: String, client: JobPipelineDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.id = id
        self.client = client
        self.onAPIError = onAPIError
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let app = try await client.application(id)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(app)
        } catch {
            guard token == generation, !(error is CancellationError) else { return }
            onAPIError(error)
            if case .loaded = state { return }  // a failed reload keeps the page on screen
            state = (error as? APIError)?.isNotFound == true ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// Whether the server saved it; the page shows what the server sent back.
    @discardableResult
    func act(_ action: JobPipelineAction) async -> Bool {
        guard !pending else { return false }
        pending = true
        error = nil
        defer { pending = false }
        do {
            let next = try await client.act(action.request)
            generation += 1
            state = .loaded(next)
            return true
        } catch {
            onAPIError(error)
            self.error = "Couldn't save. Try again."
            return false
        }
    }
}

enum JobCopy {
    static let outcomes: [(id: String, label: String)] = [
        ("rejected", "Rejected"), ("withdrew", "I withdrew"), ("accepted", "Accepted an offer"),
    ]

    static func outcomeLabel(_ outcome: String?) -> String {
        switch outcome {
        case "rejected": return "Rejected"
        case "withdrew": return "Withdrew"
        case "accepted": return "Accepted"
        case "no_reply": return "No reply in 30 days"
        default: return "Closed"
        }
    }

    /// "Tue Nov 10", from "2026-11-10".
    static func day(_ iso: String) -> String {
        guard let date = isoFormatter.date(from: iso) else { return iso }
        return dayFormatter.string(from: date)
    }

    /// "today", "tomorrow", "in 8 days".
    static func when(inDays days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }

    /// "Recruiter screen · 14 days", or the outcome for a closed one.
    static func stageLine(_ row: JobApplicationRow) -> String {
        guard row.open else { return outcomeLabel(row.outcome) }
        return row.days == 0 ? "\(row.stageName) · today" : "\(row.stageName) · \(row.days) day\(row.days == 1 ? "" : "s")"
    }

    /// A Pipeline row's second line: the next interview ("First round tomorrow"), else the stage and what it
    /// waits on ("Applied · waiting to hear back"). A server without `next_step` keeps the stage line.
    static func pipelineLine(_ row: JobApplicationRow) -> String {
        guard row.open, let step = row.nextStep, !step.isEmpty else { return stageLine(row) }
        if row.next != nil { return step }
        return "\(row.stageName) · \(step.prefix(1).lowercased())\(step.dropFirst())"
    }

    /// "Interview · Tue, Nov 10 · 10:00".
    static func packKicker(_ pack: JobPack) -> String {
        (["Interview", day(pack.on)] + [pack.time].compactMap { $0 }).joined(separator: " · ")
    }

    /// "Agentic AI Engineer, Obin AI".
    static func packTitle(_ pack: JobPack) -> String {
        let parts = [pack.role, pack.company].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? pack.label : parts.joined(separator: ", ")
    }

    /// "Recruiter screen · First round · tomorrow".
    static func packRound(_ pack: JobPack) -> String {
        var parts = [pack.round].compactMap { $0 }
        if !parts.contains(pack.label) { parts.append(pack.label) }
        return (parts + [when(inDays: pack.inDays)]).joined(separator: " · ")
    }

    /// "Start today's 20 minutes", or the way into the plan once every step is done.
    static func packStart(_ pack: JobPack) -> String {
        pack.next == nil ? "Open the prep plan" : "Start today's \(pack.minutes) minutes"
    }

    /// "Interview tomorrow", under Prep home's title while a pack leads.
    static func packSubtitle(_ pack: JobPack) -> String { "Interview \(when(inDays: pack.inDays))" }

    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f
    }()
}
