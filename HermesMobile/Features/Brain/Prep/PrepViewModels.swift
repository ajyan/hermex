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
        do {
            let home = try await client.home()
            var course: PrepCourse?
            if let summary = home.course {
                course = (try? await client.course()) ?? summary
            }
            let gaps = await gapsLoad
            guard token == generation, !Task.isCancelled else { return }
            self.gaps = gaps
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
    @ObservationIgnored private var tally = PrepDaySummary()

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

    /// A review rep: a learned lesson's check, asked again on its spaced-repetition day.
    func isReview(_ rep: PrepRep) -> Bool {
        rep.drill == .lesson && rep.block == "review"
    }

    func showIdea() {
        revealedLesson = true
    }

    /// A course run teaches lessons, quizzes a boss or runs a mock; the rest are the older DSA and warm-up runs.
    static func isCourse(_ run: PrepRun, kind: PrepRunKind) -> Bool {
        kind != .daily || run.reps.contains { $0.drill == .lesson || $0.drill == .boss }
    }

    /// The XP an answer earned, mirroring the server's rules: 10 for a new lesson and 5 more when its
    /// check is right, 5 for a right review, 50 for the answer that passes a boss sitting.
    static func xp(for rep: PrepRep, result: PrepAttemptResult) -> Int? {
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
        guard !isAdvancing, case let .result(_, result, answered) = phase, let run else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        await advance(in: run, to: result.nextIndex, after: answered, token: generation)
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
            let xp = try? await client.home().course?.xp
            if token == generation { xpBefore = xp }
        } else {
            let map = try? await client.map(track: Self.track(of: run))
            if token == generation { mapBefore = map }
        }
    }

    private func count(_ rep: PrepRep, _ result: PrepAttemptResult) {
        guard rep.drill == .lesson, !result.isUngraded else { return }
        if isReview(rep) {
            tally.reviews += 1
        } else {
            tally.learned.append(rep.item.title)
        }
        if result.verdict == "miss" { tally.missedChecks += 1 }
    }

    private func show(_ rep: PrepRep) {
        revealedLesson = false
        lastXP = nil
        hintsShown = 0
        submitError = nil
        flagError = nil
        shownAt = now()
        phase = .rep(rep, index: rep.index)
    }

    private func submit(_ answer: PrepAnswer) async {
        guard !isSubmitting, case let .rep(rep, _) = phase, let run else { return }
        let token = generation
        isSubmitting = true
        submitError = nil
        let elapsed = max(0, Int(now().timeIntervalSince(shownAt) * 1000))
        let request = PrepAttemptRequest(
            date: run.date, index: rep.index, item: rep.item.id, drill: rep.drill,
            answer: answer, elapsedMS: elapsed, hintsUsed: hintsShown,
            run: runKind, unit: runKind == .testout ? unit : nil)
        do {
            let result = try await client.attempt(request)
            guard token == generation, !Task.isCancelled else {
                isSubmitting = false
                return
            }
            if let streak = result.streak { lastStreak = streak }
            if rep.drill == .primer {
                // A primer has nothing to grade: advance as `continue()` would, staying
                // locked until the next rep is in place so "Got it" can't post twice.
                await advance(in: run, to: result.nextIndex, after: rep.index, token: token)
                isSubmitting = false
            } else {
                isSubmitting = false
                lastXP = Self.xp(for: rep, result: result)
                count(rep, result)
                phase = .result(rep, result, index: rep.index)
            }
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
            let home = try? await client.home()
            guard token == generation, !Task.isCancelled else { return }
            var summary = tally
            summary.isCourse = true
            summary.streak = lastStreak ?? home?.streak ?? PrepStreak()
            if let before = xpBefore, let after = home?.course?.xp { summary.xpGained = max(0, after - before) }
            summary.nextUp = PrepCopy.nextUp(home?.course)
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

    static func bossNode(_ state: PrepBossState, next: String?) -> String {
        if state == .ready { return "Boss quiz · ready" }
        return next.map { "Boss quiz · unlocks \($0)" } ?? "Boss quiz"
    }

    static func starsLabel(_ stars: Int) -> String { "\(stars) of 3 stars" }
    static func xpLabel(_ xp: Int) -> String { "+\(xp) XP" }
    static func xpSpoken(_ xp: Int) -> String { "Plus \(xp) XP" }
    static func percent(_ score: Double) -> String { "\(Int((score * 100).rounded()))%" }

    static func sittingHeadline(_ sitting: PrepBossSitting) -> String {
        if sitting.score == nil { return "Grading tonight" }
        return sitting.passed ? "Boss passed" : "Not yet"
    }

    static func unlockLine(_ sitting: PrepBossSitting, xp: Int?) -> String {
        guard sitting.passed else {
            return sitting.score == nil ? "Atlas grades it tonight; the unit unlocks if it passes."
                : "The lessons below come back tomorrow, then the boss again."
        }
        let parts = [sitting.unlocked.map { "\($0) unlocked" }, xp.map(xpLabel)].compactMap { $0 }
        return parts.isEmpty ? "Course complete" : parts.joined(separator: " · ")
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

    /// The Brain home row's subtitle; the streak part only when there is one.
    static func homeRowSubtitle(streakDays: Int, remaining: Int) -> String {
        let run = remaining == 0 ? "run done" : "today's run is ready"
        if streakDays == 0 { return run == "run done" ? "Run done" : "Today's run is ready" }
        return "\(streak(days: streakDays)) · " + run
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
        guard text.unicodeScalars.count > approachMaxLength else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(approachMaxLength)))
    }

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
