import Foundation
import Observation

private func prepIsNotFound(_ error: Error) -> Bool {
    (error as? APIError)?.isNotFound ?? false
}

/// 409 (another day's plan) and 400 (the rep no longer exists): both mean reload today.
private func prepIsConflict(_ error: Error) -> Bool {
    if case let .http(statusCode, _)? = error as? APIError { return statusCode == 409 || statusCode == 400 }
    return false
}

private func prepIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}

private func prepFailureState<Value>(_ error: Error) -> BrainLoadState<Value> {
    prepIsNotFound(error) ? .unavailable : .failed(error.localizedDescription)
}

/// The Prep landing screen: streak, today's run summary, tracks, needs-work.
@MainActor
@Observable
final class PrepHomeViewModel {
    private(set) var state: BrainLoadState<PrepHome> = .loading
    /// The gap ledger; nil when the server has no gaps route (an older fork) or it failed,
    /// in which case the home shows the older "Needs work" section instead.
    private(set) var gaps: [PrepGapSummary]?
    /// The course path with the current unit's lessons; nil on servers without a course. When the full
    /// path fails to load, home's summary (units without lessons) stands in.
    private(set) var course: PrepCourse?
    /// The story bank with each story's readiness marks; nil when the server has no stories route
    /// or it failed, in which case the Stories section hides.
    private(set) var stories: PrepStoryList?
    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private let onAPIError: (Error) -> Void

    init(client: PrepDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    func load() async {
        generation += 1
        let token = generation
        async let gapsLoad = try? await client.gaps()
        async let storiesLoad = try? await client.stories()
        do {
            let home = try await client.home()
            var course: PrepCourse?
            if let summary = home.course {
                course = (try? await client.course()) ?? summary
            }
            let gaps = await gapsLoad
            let stories = await storiesLoad
            guard token == generation, !Task.isCancelled else { return }
            self.gaps = gaps
            self.stories = stories
            self.course = course
            state = .loaded(home)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            state = prepFailureState(error)
        }
    }
}

/// One gap: the answers that showed it and the cards that target it.
@MainActor
@Observable
final class PrepGapViewModel {
    let id: String
    private(set) var state: BrainLoadState<PrepGapDetail> = .loading
    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let onAPIError: (Error) -> Void

    init(id: String, client: PrepDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.id = id
        self.client = client
        self.onAPIError = onAPIError
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let detail = try await client.gap(id: id)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(detail)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            state = prepFailureState(error)
        }
    }
}

/// One lesson to re-read: a learned node on the path or a boss's revisit chip.
@MainActor
@Observable
final class PrepLessonViewModel {
    let id: String
    private(set) var state: BrainLoadState<PrepLesson> = .loading
    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let onAPIError: (Error) -> Void

    init(id: String, client: PrepDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.id = id
        self.client = client
        self.onAPIError = onAPIError
    }

    func load() async {
        generation += 1
        let token = generation
        state = .loading
        do {
            let lesson = try await client.lesson(id: id)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(lesson)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            // A 404 here is one missing lesson, not a server without Prep.
            state = .failed(prepIsNotFound(error) ? "This lesson is no longer in the course." : error.localizedDescription)
        }
    }
}

/// What a finished run shows. Course runs fill the XP, lessons and next-up fields; a DSA run
/// fills `moved`.
struct PrepDaySummary: Equatable {
    var streak = PrepStreak()
    var moved: [PrepSkill] = []
    var isCourse = false
    var xpGained = 0
    /// Titles of the lessons taught this run, in order.
    var learned: [String] = []
    var reviews = 0
    var missedChecks = 0
    var nextUp: String?
    /// The run's rep count, for the done screen's full ring.
    var repCount = 0
    /// Lessons that became interview-ready during the run, and the course totals after it.
    var readyGained: [String] = []
    var readyCount = 0
    var lessonTotal = 0
    var milestones: [PrepMilestone] = []
    /// The run started after a missed day: the end screen says welcome back, never "streak lost".
    var welcomeBack = false
}

/// A moment the end screen celebrates once.
enum PrepMilestone: Equatable, Sendable {
    case bossPassed(String)
    case ready(Int)
    case streak(Int)

    static let readyMarks = [10, 25]
    static let streakMarks = [7, 30]

    /// What changed between home before and after a run: newly passed units, ready counts crossing 10,
    /// 25 or the whole course, and streaks crossing 7 or 30.
    static func detect(before: PrepHome?, after: PrepHome?) -> [PrepMilestone] {
        guard let after else { return [] }
        var out: [PrepMilestone] = []
        let passedBefore = Set((before?.course?.units ?? []).filter { $0.state == .passed }.map(\.id))
        for unit in after.course?.units ?? [] where unit.state == .passed && !passedBefore.contains(unit.id) {
            out.append(.bossPassed(unit.title))
        }
        let readyBefore = before?.course?.readyCount ?? 0
        let readyAfter = after.course?.readyCount ?? 0
        let total = after.course?.lessonTotal ?? 0
        for mark in readyMarks + (total > 0 ? [total] : []) where readyBefore < mark && readyAfter >= mark {
            out.append(.ready(mark))
        }
        let streakBefore = before?.streak.days ?? 0
        for mark in streakMarks where streakBefore < mark && after.streak.days >= mark {
            out.append(.streak(mark))
        }
        return out
    }
}

/// One track's skill map.
@MainActor
@Observable
final class PrepTrackViewModel {
    let track: String
    private(set) var state: BrainLoadState<PrepTrackMap> = .loading
    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private let onAPIError: (Error) -> Void

    init(track: String, client: PrepDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.track = track
        self.client = client
        self.onAPIError = onAPIError
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let map = try await client.map(track: track)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(map)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            state = prepFailureState(error)
        }
    }
}

/// Today's run: one rep at a time, a result after each answer. Reps are always
/// found by `rep.index`, never by array position.
@MainActor
@Observable
final class PrepRunViewModel {
    enum Phase: Equatable {
        case loading
        case rep(PrepRep, index: Int)
        case result(PrepRep, PrepAttemptResult, index: Int)
        case finished(PrepDaySummary)
        case unavailable
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var run: PrepRun?
    private(set) var hintsShown = 0
    private(set) var submitError: String?
    private(set) var isSubmitting = false
    /// Coach-written cards flagged this run, so the flag button reads as done.
    private(set) var flaggedItems: Set<String> = []
    private(set) var flagError: String?
    /// When the current rep appeared: the start of `elapsedMS` and of the approach clock.
    private(set) var shownAt: Date
    /// A review rep opens on its check; "Show the idea" reveals the lesson above it.
    private(set) var revealedLesson = false
    /// The XP the answer on screen earned, for the tick beside the result; nil when it earned none.
    private(set) var lastXP: Int?
    /// A lesson rep starts on its teaching, then "I'm ready" hides it and asks for recall.
    enum LessonStage: Equatable { case reading, recalling }
    private(set) var lessonStage: LessonStage = .reading
    /// The recall answer being dictated or typed, and how sure the user is.
    var recallDraft = ""
    var confidence: PrepConfidence?
    /// The result on screen came from "I don't know", which has no points to claim.
    private(set) var answeredDontKnow = false
    /// The missed point whose "I had that" is in flight; a second tap waits for it.
    private(set) var overridingPoint: String?
    /// A story rep: told against the clock, graded, then up to two spoken follow-up probes. The
    /// phase stays `.rep` throughout; "Next" leaves once `canFinishStory`.
    enum StoryStage: Equatable {
        case telling
        case told(PrepAttemptResult)
        case probing(PrepProbe, number: Int)
        case probed(PrepAttemptResult, number: Int)
    }
    private(set) var storyStage: StoryStage = .telling
    /// When the telling began (the first mic tap or first non-empty edit); nil until then.
    private(set) var storyStartedAt: Date?
    /// Story titles by id, loaded only to name the story told on a wrong-story result.
    private(set) var storyTitles: [String: String] = [:]
    let runKind: PrepRunKind
    /// The unit a test out quizzes.
    let unit: String?

    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var mapBefore: PrepTrackMap?
    @ObservationIgnored private var lastStreak: PrepStreak?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isAdvancing = false
    @ObservationIgnored private var xpBefore: Int?
    @ObservationIgnored private var homeBefore: PrepHome?
    @ObservationIgnored private var readyBefore: Set<String>?
    @ObservationIgnored private var tally = PrepDaySummary()
    /// The story attempt the probes answer to, and when the probe on screen was asked.
    @ObservationIgnored private var storyParent: String?
    @ObservationIgnored private var probeShownAt: Date?
    /// When the telling was sent; the clock holds there while it is graded, and runs on if the send fails.
    private(set) var storySubmittedAt: Date?
    /// The answer out for grading, so a conflict reload that shows the same story or probe again
    /// brings the words (and the story clock) back instead of an empty field.
    @ObservationIgnored private var storyDraftStash: StoryDraftStash?

    private struct StoryDraftStash {
        let item: String
        let prompt: String
        /// nil for the telling, else the probe being answered.
        let probe: String?
        let text: String
        let startedAt: Date?
    }

    @ObservationIgnored private let onAPIError: (Error) -> Void

    init(client: PrepDataClient, run: PrepRunKind = .daily, unit: String? = nil, now: @escaping () -> Date = Date.init,
         onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.runKind = run
        self.unit = unit
        self.onAPIError = onAPIError
        self.now = now
        self.shownAt = now()
    }

    func load() async {
        generation += 1
        let token = generation
        phase = .loading
        submitError = nil
        mapBefore = nil
        lastStreak = nil
        xpBefore = nil
        tally = PrepDaySummary()
        do {
            let loaded = try await client.today(run: runKind, unit: unit)
            await snapshot(loaded, token: token)
            guard token == generation, !Task.isCancelled else { return }
            run = loaded
            await advance(in: loaded, to: loaded.index, token: token)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            phase = prepIsNotFound(error) ? .unavailable : .failed(error.localizedDescription)
        }
    }

    func choose(_ answer: PrepAnswer) async {
        await submit(answer)
    }

    func acknowledgePrimer() async {
        await submit(.choice("seen"))
    }

    /// An approach rep's written answer, capped to the server's limit; graded by the server before it returns.
    func submitApproach(_ text: String) async {
        await submit(.choice(PrepCopy.cappedApproach(text)))
    }

    /// A judgment card's spoken or typed answer, trimmed and capped like an approach.
    func submitJudgment(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PrepCopy.canSubmitJudgment(trimmed) else { return }
        await submit(.choice(PrepCopy.cappedApproach(trimmed)))
    }

    /// A cloze fact's typed answer; the server compares it ignoring case, spaces and punctuation.
    func submitCloze(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await submit(.choice(trimmed))
    }

    /// A review rep: a learned lesson asked again on its spaced-repetition day.
    func isReview(_ rep: PrepRep) -> Bool {
        rep.drill == .recall || (rep.drill == .lesson && rep.block == "review")
    }

    /// "I'm ready": hide the lesson and ask for it from memory.
    func beginRecall() {
        guard case let .rep(rep, _) = phase, rep.item.lesson?.hasRecall == true else { return }
        lessonStage = .recalling
    }

    var canSubmitRecall: Bool {
        !recallDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && confidence != nil && !isSubmitting
    }

    /// Sends the dictated or typed recall with the confidence picked before grading.
    func submitRecall() async {
        guard canSubmitRecall, let confidence else { return }
        await submit(.choice(PrepCopy.cappedApproach(recallDraft.trimmingCharacters(in: .whitespacesAndNewlines))),
                     confidence: confidence)
    }

    /// "I don't know, show me": a recall with no answer, graded as a miss without the model.
    func dontKnow() async {
        await submit(.choice(""), confidence: .guess, dontKnow: true)
    }

    /// "I had that" is offered on a graded recall's or boss answer's misses, never on "I don't know".
    var canOverride: Bool { !answeredDontKnow }

    /// "I had that": count one missed key point as hit, keeping the rest of the result.
    func overridePoint(_ point: String) async {
        if case let .rep(rep, _) = phase, rep.drill == .story {
            await overrideStoryPoint(point)
            return
        }
        guard case let .result(rep, result, index) = phase, let attempt = result.attemptID,
              !answeredDontKnow, overridingPoint == nil else { return }
        let token = generation
        overridingPoint = point
        defer { if token == generation { overridingPoint = nil } }
        do {
            let updated = try await client.override(attempt: attempt, point: point)
            guard token == generation, case .result = phase else { return }
            let merged = PrepAttemptResult(merging: result, override: updated)
            phase = .result(rep, merged, index: index)
            lastXP = Self.xp(for: rep, result: merged)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            submitError = "Couldn't save that. Try again."
        }
    }

    func showIdea() {
        revealedLesson = true
    }

    // MARK: Story reps

    /// The telling so far, in ms; 0 until the clock starts, and held at the moment it was sent while
    /// it is graded.
    var storyElapsedMS: Int {
        storyStartedAt.map { Self.milliseconds(from: $0, to: storySubmittedAt ?? now()) } ?? 0
    }

    /// "I had that" on a told story's missed beat or a probe's missed point: re-scored by the server,
    /// laid over the result on screen. The probe that result leads to is kept, so the rep goes on.
    private func overrideStoryPoint(_ point: String) async {
        let shown: PrepAttemptResult
        switch storyStage {
        case let .told(result), let .probed(result, _): shown = result
        case .telling, .probing: return
        }
        guard let attempt = shown.attemptID, !shown.isUngraded, overridingPoint == nil else { return }
        let token = generation
        let stage = storyStage
        overridingPoint = point
        defer { if token == generation { overridingPoint = nil } }
        do {
            let updated = try await client.override(attempt: attempt, point: point)
            guard token == generation, storyStage == stage else { return }
            let merged = PrepAttemptResult(merging: shown, override: updated)
            switch stage {
            case .told: storyStage = .told(merged)
            case let .probed(_, number): storyStage = .probed(merged, number: number)
            case .telling, .probing: break
            }
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            submitError = "Couldn't save that. Try again."
        }
    }

    /// Starts the story clock once: on the first mic tap or the first non-empty edit.
    func markStoryStarted() {
        guard storyStartedAt == nil, storyStage == .telling, case let .rep(rep, _) = phase, rep.drill == .story
        else { return }
        storyStartedAt = now()
    }

    /// A story or probe answer as dictated or typed; non-empty words start the story clock.
    func editStory(_ text: String) {
        guard !isSubmitting else { return }
        recallDraft = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { markStoryStarted() }
    }

    var canSubmitStoryAnswer: Bool {
        !recallDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    /// The probe the result on screen leads to and its number; nil once the rep is done (two probes
    /// answered, or a result with no next probe, which an ungraded story never has).
    var nextProbe: (probe: PrepProbe, number: Int)? {
        guard storyParent != nil else { return nil }
        switch storyStage {
        case let .told(result): return result.probe.map { ($0, 1) }
        case let .probed(result, number) where number < 2: return result.probe.map { ($0, number + 1) }
        default: return nil
        }
    }

    /// The story rep has nothing left to answer: "Next" moves the run on.
    var canFinishStory: Bool {
        switch storyStage {
        case .told, .probed: nextProbe == nil
        case .telling, .probing: false
        }
    }

    /// Posts the telling with the time since the clock started (0 if it never did).
    func submitStory() async {
        guard canSubmitStoryAnswer, storyStage == .telling, case let .rep(rep, _) = phase, rep.drill == .story,
              let run else { return }
        let text = recallDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentAt = now()
        storySubmittedAt = sentAt
        storyDraftStash = StoryDraftStash(item: rep.item.id, prompt: rep.item.prompt, probe: nil,
                                          text: recallDraft, startedAt: storyStartedAt)
        let request = PrepAttemptRequest(
            date: run.date, index: rep.index, item: rep.item.id, drill: .story,
            answer: .choice(PrepCopy.capped(text, to: PrepCopy.storyMaxLength)),
            elapsedMS: storyStartedAt.map { Self.milliseconds(from: $0, to: sentAt) } ?? 0, hintsUsed: 0,
            run: runKind, unit: runKind == .testout ? unit : nil)
        let token = generation
        guard let result = await post(request, token: token) else {
            if token == generation, storySubmittedAt == sentAt { storySubmittedAt = nil }
            return
        }
        storyDraftStash = nil
        isSubmitting = false
        storyParent = result.attemptID
        storyStage = .told(result)
        if result.role == "wrong" { await loadStoryTitles(token: token) }
    }

    /// Asks the next follow-up probe, timed from now.
    func beginProbe() {
        guard !isSubmitting, let next = nextProbe else { return }
        recallDraft = ""
        probeShownAt = now()
        storyStage = .probing(next.probe, number: next.number)
    }

    /// Posts the probe answer against the story attempt it follows.
    func submitProbe() async {
        guard canSubmitStoryAnswer, case let .probing(probe, number) = storyStage, case let .rep(rep, _) = phase,
              let parent = storyParent, let run else { return }
        var request = PrepAttemptRequest(
            date: run.date, index: rep.index, item: rep.item.id, drill: .probe,
            answer: .choice(PrepCopy.cappedApproach(recallDraft.trimmingCharacters(in: .whitespacesAndNewlines))),
            elapsedMS: probeShownAt.map { Self.milliseconds(from: $0, to: now()) } ?? 0, hintsUsed: 0,
            run: runKind, unit: runKind == .testout ? unit : nil)
        request.parent = parent
        request.probe = probe.id
        storyDraftStash = StoryDraftStash(item: rep.item.id, prompt: rep.item.prompt, probe: probe.id,
                                          text: recallDraft, startedAt: nil)
        guard let result = await post(request, token: generation) else { return }
        storyDraftStash = nil
        isSubmitting = false
        storyStage = .probed(result, number: number)
    }

    private func loadStoryTitles(token: Int) async {
        guard let list = try? await client.stories(), token == generation else { return }
        storyTitles = Dictionary(list.stories.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1000))
    }

    /// A course run teaches lessons, quizzes a boss or runs a mock; the rest are the older DSA and warm-up runs.
    static func isCourse(_ run: PrepRun, kind: PrepRunKind) -> Bool {
        kind != .daily || run.reps.contains { [.lesson, .recall, .warmup, .boss].contains($0.drill) }
    }

    /// The XP an answer earned, mirroring the server's rules: 10 for a new lesson and 5 more when its
    /// check is right, 5 for a right review, 50 for the answer that passes a boss sitting.
    static func xp(for rep: PrepRep, result: PrepAttemptResult) -> Int? {
        if let xp = result.xp { return xp > 0 ? xp : nil }
        switch rep.drill {
        case .lesson where rep.block == "review":
            return result.verdict == "pass" ? 5 : nil
        case .lesson:
            return result.verdict == "pass" ? 15 : 10
        case .boss:
            return result.sitting?.passed == true ? 50 : nil
        default:
            return nil
        }
    }

    /// The answered card was written by the coach and isn't flagged yet.
    var canFlag: Bool {
        guard case let .result(rep, _, _) = phase else { return false }
        return rep.item.isCoachWritten && !flaggedItems.contains(rep.item.id)
    }

    func isFlagged(_ itemID: String) -> Bool { flaggedItems.contains(itemID) }

    /// Retires the answered coach-written card for good; the coach writes a replacement for its gap.
    func flagCurrent() async {
        guard canFlag, case let .result(rep, _, _) = phase else { return }
        let token = generation
        flagError = nil
        do {
            try await client.flag(item: rep.item.id)
            guard token == generation else { return }
            flaggedItems.insert(rep.item.id)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            flagError = "Couldn't flag this card. Try again."
        }
    }

    /// A spot-the-bug answer: `line` is a 0-based index into `item.code`.
    func submitBugFix(line: Int, fix: String) async {
        await submit(.bugFix(line: line, fix: fix))
    }

    /// Moves past a rep this build can't run (an unknown drill) without posting.
    func skip() async {
        guard !isSubmitting, !isAdvancing, case let .rep(rep, _) = phase, let run else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        await advance(in: run, to: rep.index + 1, after: rep.index, token: generation)
    }

    /// The track today's run drills, for the before/after skill map: `anth` once the run holds
    /// Anthropic-track reps (ids `anth.…`), otherwise `dsa`.
    static func track(of run: PrepRun) -> String {
        run.reps.contains { $0.item.id.hasPrefix("anth.") } ? "anth" : "dsa"
    }

    /// The user closed the run: any response still in flight is dropped.
    func leave() {
        generation += 1
    }

    func showHint() {
        guard case let .rep(rep, _) = phase, hintsShown < rep.item.hints.count else { return }
        hintsShown += 1
    }

    func `continue`() async {
        guard !isAdvancing, let run else { return }
        let target: Int
        let answered: Int
        switch (phase, storyStage) {
        case let (.result(_, result, index), _):
            (target, answered) = (result.nextIndex, index)
        case let (.rep(rep, index), .told(result)) where rep.drill == .story && canFinishStory,
             let (.rep(rep, index), .probed(result, _)) where rep.drill == .story && canFinishStory:
            (target, answered) = (result.nextIndex, index)
        default:
            return
        }
        isAdvancing = true
        defer { isAdvancing = false }
        await advance(in: run, to: target, after: answered, token: generation)
    }

    // MARK: - Private

    /// `answered` is the rep just graded: the server's `next_index` can point at a rep the
    /// app dropped (unknown drill), so never go back to or before the one just answered.
    private func advance(in run: PrepRun, to target: Int, after answered: Int? = nil, token: Int) async {
        guard token == generation, !Task.isCancelled else { return }
        let floor = answered.map { max(target, $0 + 1) } ?? target
        if let rep = run.reps.first(where: { $0.index >= floor }) {
            show(rep)
        } else {
            await finish(token: token)
        }
    }

    /// What the end of the run compares against: the XP before a course run, or the skill map before
    /// any other run. Both are non-fatal.
    private func snapshot(_ run: PrepRun, token: Int) async {
        if Self.isCourse(run, kind: runKind) {
            async let homeLoad = try? await client.home()
            async let courseLoad = try? await client.course()
            let (home, ready) = await (homeLoad, courseLoad)
            if token == generation {
                homeBefore = home
                xpBefore = home?.course?.xp
                readyBefore = ready.map(Self.readyLessons)
                tally.welcomeBack = PrepCopy.isWelcomeBack(lastDay: home?.streak.lastDay, today: now())
            }
        } else {
            let map = try? await client.map(track: Self.track(of: run))
            if token == generation { mapBefore = map }
        }
    }

    /// Lesson ids marked ready on the path.
    static func readyLessons(_ course: PrepCourse) -> Set<String> {
        Set(course.units.flatMap(\.lessons).filter { $0.state == .ready }.map(\.id))
    }

    private func count(_ rep: PrepRep, _ result: PrepAttemptResult) {
        guard rep.drill == .lesson || rep.drill == .recall, !result.isUngraded else { return }
        if isReview(rep) {
            tally.reviews += 1
        } else {
            tally.learned.append(rep.item.title)
        }
        if result.verdict == "miss" { tally.missedChecks += 1 }
    }

    private func show(_ rep: PrepRep) {
        revealedLesson = false
        lessonStage = rep.drill == .recall ? .recalling : .reading
        recallDraft = ""
        confidence = nil
        answeredDontKnow = false
        overridingPoint = nil
        lastXP = nil
        hintsShown = 0
        submitError = nil
        flagError = nil
        shownAt = now()
        storyStartedAt = nil
        storySubmittedAt = nil
        storyTitles = [:]
        if rep.drill == .story, let pending = rep.pending {
            // Told earlier with probes still open: resume at the next one.
            storyParent = pending.attempt
            probeShownAt = shownAt
            storyStage = .probing(pending.probe, number: max(1, pending.number))
        } else {
            storyParent = nil
            probeShownAt = nil
            storyStage = .telling
        }
        restoreStoryDraft(for: rep)
        phase = .rep(rep, index: rep.index)
    }

    /// After a reload, the same story or probe comes back with the words that were out for grading.
    private func restoreStoryDraft(for rep: PrepRep) {
        defer { storyDraftStash = nil }
        guard let stash = storyDraftStash, rep.drill == .story, stash.item == rep.item.id,
              stash.prompt == rep.item.prompt else { return }
        switch (storyStage, stash.probe) {
        case (.telling, nil):
            recallDraft = stash.text
            storyStartedAt = stash.startedAt
        case let (.probing(probe, _), id?) where probe.id == id:
            recallDraft = stash.text
        default:
            break
        }
    }

    private func submit(_ answer: PrepAnswer, confidence: PrepConfidence? = nil, dontKnow: Bool = false) async {
        guard !isSubmitting, case let .rep(rep, _) = phase, let run else { return }
        let token = generation
        let elapsed = Self.milliseconds(from: shownAt, to: now())
        let request = PrepAttemptRequest(
            date: run.date, index: rep.index, item: rep.item.id, drill: rep.drill,
            answer: answer, elapsedMS: elapsed, hintsUsed: hintsShown,
            run: runKind, unit: runKind == .testout ? unit : nil, confidence: confidence, dontKnow: dontKnow)
        guard let result = await post(request, token: token) else { return }
        if rep.drill == .primer {
            // A primer has nothing to grade: advance as `continue()` would, staying
            // locked until the next rep is in place so "Got it" can't post twice.
            await advance(in: run, to: result.nextIndex, after: rep.index, token: token)
            isSubmitting = false
        } else {
            isSubmitting = false
            answeredDontKnow = dontKnow
            lastXP = Self.xp(for: rep, result: result)
            count(rep, result)
            phase = .result(rep, result, index: rep.index)
        }
    }

    /// Posts one answer under the submit lock. On success the lock is still held, so the caller can
    /// put the next screen in place first; a failure, a dropped response or a reload releases it and
    /// returns nil.
    private func post(_ request: PrepAttemptRequest, token: Int) async -> PrepAttemptResult? {
        isSubmitting = true
        submitError = nil
        do {
            let result = try await client.attempt(request)
            guard token == generation, !Task.isCancelled else {
                isSubmitting = false
                return nil
            }
            if let streak = result.streak { lastStreak = streak }
            return result
        } catch {
            if token != generation || prepIsCancellation(error) {
                isSubmitting = false
            } else if prepIsConflict(error) {
                // Stay locked until the fresh run is in place, so no submit posts to the stale one.
                await restart(token: token)
                isSubmitting = false
            } else {
                isSubmitting = false
                onAPIError(error)
                submitError = "Couldn't save. Try again."
            }
            return nil
        }
    }

    /// The plan belongs to another day: reload it and start at its index.
    private func restart(token: Int) async {
        guard token == generation else { return }
        mapBefore = nil
        lastStreak = nil
        xpBefore = nil
        tally = PrepDaySummary()
        do {
            let fresh = try await client.today(run: runKind, unit: unit)
            await snapshot(fresh, token: token)
            guard token == generation, !Task.isCancelled else { return }
            run = fresh
            await advance(in: fresh, to: fresh.index, token: token)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            onAPIError(error)
            phase = prepIsNotFound(error) ? .unavailable : .failed(error.localizedDescription)
        }
    }

    private func finish(token: Int) async {
        if let run, Self.isCourse(run, kind: runKind) {
            async let homeLoad = try? await client.home()
            async let courseLoad = try? await client.course()
            let (home, course) = await (homeLoad, courseLoad)
            guard token == generation, !Task.isCancelled else { return }
            var summary = tally
            summary.isCourse = true
            summary.repCount = run.reps.count
            summary.streak = lastStreak ?? home?.streak ?? PrepStreak()
            if let before = xpBefore, let after = home?.course?.xp { summary.xpGained = max(0, after - before) }
            summary.nextUp = PrepCopy.nextUp(home?.course)
            summary.readyCount = home?.course?.readyCount ?? 0
            summary.lessonTotal = home?.course?.lessonTotal ?? 0
            if let before = readyBefore, let course {
                let titles = Dictionary(course.units.flatMap(\.lessons).map { ($0.id, $0.title) },
                                        uniquingKeysWith: { first, _ in first })
                summary.readyGained = Self.readyLessons(course).subtracting(before).sorted().compactMap { titles[$0] }
            }
            summary.milestones = PrepMilestone.detect(before: homeBefore, after: home)
            phase = .finished(summary)
            return
        }
        var streak = lastStreak
        if streak == nil { streak = try? await client.home().streak }
        var moved: [PrepSkill] = []
        let after = mapBefore == nil ? nil : try? await client.map(track: run.map(Self.track(of:)) ?? "dsa")
        guard token == generation, !Task.isCancelled else { return }
        if let before = mapBefore, let after {
            let old = Dictionary(
                before.levels.flatMap(\.skills).map { ($0.id, $0.mastery) },
                uniquingKeysWith: { first, _ in first })
            moved = after.levels.flatMap(\.skills).filter { skill in
                old[skill.id].map { $0 != skill.mastery } ?? false
            }
        }
        phase = .finished(PrepDaySummary(streak: streak ?? PrepStreak(), moved: moved))
    }
}

// MARK: - Presentation

/// The Prep screens' copy and small derivations, kept out of the views so they stay
/// dumb and the wording is testable. English only, sentence case.
enum PrepCopy {
    /// Pinned source refs by readable name; vault notes all read as "Your notes".
    private static let sourceNames: [String: String] = [
        "prompt-docs": "Anthropic prompting docs", "prompt-caching": "Prompt caching docs",
        "models": "Models overview", "effective-agents": "Building effective agents",
        "constitution": "Claude's constitution", "usage-policy": "Usage policy", "rsp": "Responsible Scaling Policy",
        "guide": "AI system design guide",
    ]
    private static let vaultRefs: Set<String> = [
        "playbook", "loop", "question-bank", "discovery", "safety", "prompt-oa", "prepared-answers",
        "story-refutation", "sysdesign", "roadmap", "evidence",
    ]

    /// A lesson's sources as one line, each name once, in order.
    static func sourceLine(_ sources: [PrepSource]) -> String? {
        var names: [String] = []
        for source in sources {
            let name = sourceNames[source.ref] ?? (vaultRefs.contains(source.ref) ? "Your notes" : source.ref)
            if !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    /// The done screen's review row: "2 reviews · 1 check to look at again".
    static func reviewLine(reviews: Int, missed: Int) -> String {
        let parts = [reviews > 0 ? "\(reviews) review\(reviews == 1 ? "" : "s")" : nil,
                     missed > 0 ? "\(missed) check\(missed == 1 ? "" : "s") to look at again" : nil]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    static func unitHeader(index: Int, title: String) -> String { "Unit \(index + 1) · \(title)" }

    /// The ring card's line: the streak once there is one, then XP.
    static func todayLine(days: Int, xp: Int) -> String {
        days > 0 ? "\(streak(days: days)) · \(xp) XP" : "\(xp) XP"
    }

    static func bossNode(_ state: PrepBossState) -> String {
        switch state {
        case .ready: "Boss quiz · ready"
        case .resting: "Boss quiz · back in a few days"
        case .locked, .passed, .unknown: "Boss quiz"
        }
    }

    static func starsLabel(_ stars: Int) -> String { "\(stars) of 3 stars" }
    static func confidenceLabel(_ c: PrepConfidence) -> String {
        switch c {
        case .guess: "Guess"
        case .fairly: "Fairly sure"
        case .certain: "Certain"
        }
    }

    static func lessonStateWord(_ state: PrepLessonState) -> String {
        switch state {
        case .ready: "interview-ready"
        case .shaky: "back in reviews"
        case .learned: "learned"
        case .next: "next"
        case .locked, .unknown: "locked"
        }
    }

    static func readyLine(ready: Int, total: Int) -> String { "\(ready) of \(total) ready" }

    static func keyPointsLine(hit: Int, total: Int) -> String { "\(hit) of \(total) key points" }

    static func calibrationLine(_ c: PrepCalibration) -> String {
        let percent = c.certainTotal > 0 ? Int((Double(c.certainRight) / Double(c.certainTotal) * 100).rounded()) : 0
        return "When you say certain, you're right \(percent)% of the time"
    }

    static func milestoneTitle(_ m: PrepMilestone) -> String {
        switch m {
        case .bossPassed(let unit): "\(unit) passed"
        case .ready(let n): "\(n) topics interview-ready"
        case .streak(let n): "\(n)-day streak"
        }
    }

    /// The last active day was before yesterday: greet, don't scold.
    static func isWelcomeBack(lastDay: String?, today: Date) -> Bool {
        guard let lastDay else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
        return lastDay < formatter.string(from: yesterday)
    }

    static func xpLabel(_ xp: Int) -> String { "+\(xp) XP" }
    static func xpSpoken(_ xp: Int) -> String { "Plus \(xp) XP" }
    static func percent(_ score: Double) -> String { "\(Int((score * 100).rounded()))%" }

    static func sittingHeadline(_ sitting: PrepBossSitting) -> String {
        if sitting.score == nil { return "Grading tonight" }
        return sitting.passed ? "Boss passed" : "Not yet"
    }

    /// The line under a boss result. A failed test out changes nothing, so it points at the lessons instead.
    static func unlockLine(_ sitting: PrepBossSitting, xp: Int?, testOut: Bool = false) -> String {
        guard sitting.passed else {
            if sitting.score == nil { return "Atlas grades it tonight; the unit unlocks if it passes." }
            return testOut ? "Not yet. Start with the lessons below."
                : "The next unit keeps going. This boss comes back in a few days."
        }
        let parts = [sitting.unlocked.map { "\($0) unlocked" }, xp.map(xpLabel)].compactMap { $0 }
        return parts.isEmpty ? "Unit passed" : parts.joined(separator: " · ")
    }

    /// The done screen's "Tomorrow" line: the current unit's boss once it is ready, else its lessons.
    static func nextUp(_ course: PrepCourse?) -> String? {
        guard let unit = course?.currentUnit else { return nil }
        if unit.boss == .ready { return "Boss quiz · \(unit.title)" }
        return "\(unit.title) · \(unit.lessonsDone) of \(unit.lessonsTotal) lessons"
    }

    /// What today's run button offers on Prep home.
    enum RunAction: Equatable { case start, resume, done }

    static func streak(days: Int) -> String { "\(days)-day streak" }

    /// A gap row's trailing detail: how often it was missed, or progress toward closing it.
    static func gapRowDetail(_ gap: PrepGapSummary) -> String {
        switch gap.status {
        case .improving: "\(gap.hitsTowardClose) of 3 hits"
        case .closed: "Closed"
        case .open, .unknown: "Seen \(gap.misses)×"
        }
    }

    static func gapsHeader(open: Int, improving: Int) -> String {
        switch (open, improving) {
        case (0, 0): "None open"
        case (_, 0): "\(open) open"
        default: "\(open) open · \(improving) improving"
        }
    }

    /// A reference point's id as a readable title: `p.harm-bearer` → "Harm bearer".
    static func pointTitle(_ id: String) -> String {
        let slug = id.hasPrefix("p.") ? String(id.dropFirst(2)) : id
        let words = slug.split(separator: "-").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A judgment answer needs something besides whitespace.
    static func canSubmitJudgment(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The interview-loop stage chip on an Anthropic-track rep; nil when the rep has no stage.
    static func stageChip(_ stage: String) -> String? {
        stage.isEmpty ? nil : "Stage \(stage)"
    }

    /// The line under a graded judgment: the gap this miss belongs to, or that it was logged
    /// for the nightly coach. Nil when nothing was missed.
    static func gapCallout(match: [PrepGapMatch], logged: Bool) -> String? {
        if let gap = match.first {
            return "Seen before: \(gap.label) · \(gap.misses) \(gap.misses == 1 ? "miss" : "misses")"
        }
        return logged ? "Logged · Atlas will review tonight" : nil
    }

    static func freezes(_ count: Int) -> String {
        count == 1 ? "1 freeze saved" : "\(count) freezes saved"
    }

    /// The streak row's title; a zero streak reads as not started.
    static func streakTitle(days: Int) -> String {
        days == 0 ? "No streak yet" : streak(days: days)
    }

    /// The streak row's subtitle: the nudge at zero, the freezes only when there are some.
    static func streakSubtitle(days: Int, freezes: Int) -> String? {
        if days == 0 { return "Finish a run to start one" }
        return freezes == 0 ? nil : Self.freezes(freezes)
    }

    /// "32 min · 14 reps · Sliding window, Stack" (the focus part only when present).
    static func runSubtitle(minutes: Double, reps: Int, focus: [String]) -> String {
        var parts = ["\(Int(minutes.rounded())) min", "\(reps) reps"]
        let focus = focus.filter { !$0.isEmpty }
        if !focus.isEmpty { parts.append(focus.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// Start a fresh run, resume one with answered reps, or nothing left today.
    static func runAction(reps: Int, remaining: Int) -> RunAction {
        if remaining <= 0 { return .done }
        return remaining < reps ? .resume : .start
    }

    static func runActionTitle(_ action: RunAction) -> String {
        switch action {
        case .start: "Start"
        case .resume: "Resume"
        case .done: "Done"
        }
    }

    /// Readiness arrives as a 0–1 fraction or a 0–100 score; shown as a whole score.
    static func readiness(_ value: Double) -> String {
        "Readiness \(Int((value <= 1 ? value * 100 : value).rounded()))"
    }

    static func blockTitle(_ block: String) -> String {
        switch block {
        case "warmup": "Warm-up"
        case "weak": "Weak spot"
        case "main": "Main rep"
        case "new": "New"
        case "reteach": "Another way to see it"
        case "review": "Review"
        case "boss": "Boss quiz"
        default: block.prefix(1).uppercased() + block.dropFirst()
        }
    }

    static func mapTitle(mastered: Int, total: Int) -> String {
        "\(mastered) of \(total) patterns mastered"
    }

    static func mapSubtitle(problems: Int, due: Int) -> String {
        "\(problems) problems · NeetCode order · \(due) reviews due"
    }

    static func stateWords(_ state: PrepSkillState) -> String {
        switch state {
        case .new: "not started"
        case .inProgress: "in progress"
        case .weak: "weak"
        case .locked: "locked"
        case .mastered: "mastered"
        case .unknown: ""
        }
    }

    /// The skill row's VoiceOver label: "{title}, {state words}, {detail}".
    static func skillLabel(title: String, state: PrepSkillState, detail: String) -> String {
        [title, stateWords(state), detail].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The feedback split after its first sentence, so the lead can be set in bold.
    static func feedbackParts(_ feedback: String) -> (lead: String, rest: String) {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = text.range(of: #"[.!?](\s|$)"#, options: .regularExpression) else {
            return (text, "")
        }
        let lead = String(text[..<end.lowerBound]) + String(text[end.lowerBound])
        let rest = String(text[end.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (lead, rest)
    }

    /// Whether an option is the graded answer, ignoring case and surrounding whitespace.
    static func isSameChoice(_ optionID: String, _ correctID: String?) -> Bool {
        guard let correctID else { return false }
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return norm(optionID) == norm(correctID)
    }

    /// A moved skill's subtitle on the run-complete screen.
    static func movedSubtitle(mastery: Double) -> String {
        "\(Int((mastery * 100).rounded()))% mastered"
    }

    /// The approach soft limit, in seconds; past it the server caps the rating.
    static let approachLimit: TimeInterval = 90

    /// The longest approach answer the server accepts. It counts Unicode scalars (Python `len`).
    static let approachMaxLength = 4000

    /// An approach draft cut to `approachMaxLength` scalars, so a submit is never rejected as too long.
    static func cappedApproach(_ text: String) -> String {
        capped(text, to: approachMaxLength)
    }

    /// Text cut to `limit` Unicode scalars (the server counts with Python `len`).
    static func capped(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }

    // MARK: Story reps

    /// A story's time limit and the point its clock turns to a warning.
    static let storyLimitMS = 240_000
    static let storyWarnMS = 210_000
    /// The longest telling the server accepts.
    static let storyMaxLength = 8000
    static let storyUngraded = "Couldn't grade, saved for tonight"

    enum StoryClockState: Equatable {
        case normal, warning, over

        /// Shown beside the clock once the telling runs past the limit.
        var text: String? { self == .over ? "Over 4:00" : nil }
    }

    /// Elapsed time as "m:ss".
    static func storyClock(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func storyClockState(_ ms: Int) -> StoryClockState {
        if ms > storyLimitMS { return .over }
        return ms >= storyWarnMS ? .warning : .normal
    }

    /// The Stories section's subtitle: "3 of 8 ready".
    static func storiesSubtitle(ready: Int, total: Int) -> String {
        "\(ready) of \(total) ready"
    }

    /// A readiness mark as one glyph: done, not yet, or no rep yet.
    static func storyMarkSymbol(_ mark: Bool?) -> String {
        switch mark {
        case true: "\u{2713}"
        case false: "\u{25CC}"
        default: "\u{2013}"
        }
    }

    /// A readiness mark as VoiceOver reads it: "Time: under 4 minutes", "Probes: no rep yet".
    static func storyMarkLabel(_ kind: PrepStoryMarkKind, _ mark: Bool?) -> String {
        switch kind {
        case .time: "Time: " + (mark.map { $0 ? "under 4 minutes" : "not yet" } ?? "no rep yet")
        case .score: "Score: " + (mark.map { $0 ? "4 or better" : "not yet" } ?? "no rep yet")
        case .probes: "Probes: " + (mark.map { $0 ? "held" : "not yet" } ?? "no rep yet")
        }
    }

    /// A told story's headline: "4/5 · 3:20", or the saved-for-tonight line when it wasn't graded.
    static func storyHeadline(_ result: PrepAttemptResult) -> String {
        if result.isUngraded { return storyUngraded }
        return "\(result.score ?? 0)/5 · \(storyClock(result.elapsedMS ?? 0))"
    }

    /// After telling a story that doesn't fit the prompt: which one was told and which to lead with.
    /// `titles` names stories by id; nil unless the role is "wrong".
    static func wrongStoryLine(_ result: PrepAttemptResult, titles: [String: String]) -> String? {
        guard result.role == "wrong" else { return nil }
        let told = result.storyTold.flatMap { titles[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? "another story"
        let right = [result.lead, result.backup].compactMap { $0?.title }.filter { !$0.isEmpty }
        guard !right.isEmpty else { return "You told \(told)." }
        return "You told \(told). For this prompt, lead with \(right.joined(separator: " or "))."
    }

    static func probeLabel(_ number: Int) -> String { "Follow-up \(number) of 2" }

    /// Whether the draft has reached the cap, to show the "4000 characters max" note.
    static func isAtApproachLimit(_ text: String) -> Bool {
        text.unicodeScalars.count >= approachMaxLength
    }

    /// The approach clock: time left as "m:ss", then the overrun as "+m:ss".
    static func approachClock(elapsed: TimeInterval) -> (text: String, isOver: Bool) {
        let seconds = Int(elapsed.rounded(.down))
        let limit = Int(approachLimit)
        func clock(_ total: Int) -> String { String(format: "%d:%02d", total / 60, total % 60) }
        return seconds > limit ? ("+" + clock(seconds - limit), true) : (clock(limit - seconds), false)
    }

    /// A code line's VoiceOver label; `index` is 0-based, the label counts from 1.
    static func codeLineLabel(index: Int, code: String) -> String {
        "Line \(index + 1): \(code)"
    }

    /// Whether a spot-the-bug answer is complete enough to submit.
    static func canSubmitBugFix(line: Int?, fix: String?) -> Bool {
        line != nil && !(fix ?? "").isEmpty
    }

    /// A grader rubric key as a title: "edge_cases" → "Edge cases".
    static func rubricTitle(_ key: String) -> String {
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The cover id for a Prep track or skill, seeded apart from Brain pages.
    static func coverID(_ id: String) -> String { "prep.\(id)" }
}
