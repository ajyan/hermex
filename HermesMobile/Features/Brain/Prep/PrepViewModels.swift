import Foundation
import Observation

private func prepIsNotFound(_ error: Error) -> Bool {
    (error as? APIError)?.isNotFound ?? false
}

private func prepIsConflict(_ error: Error) -> Bool {
    if case let .http(statusCode, _)? = error as? APIError { return statusCode == 409 }
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
    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private var generation = 0

    init(client: PrepDataClient) {
        self.client = client
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let home = try await client.home()
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(home)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            state = prepFailureState(error)
        }
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

    init(track: String, client: PrepDataClient) {
        self.track = track
        self.client = client
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
            state = prepFailureState(error)
        }
    }
}

/// Tap-to-place Parsons answer. Lines are tracked by their index in the pool so
/// duplicate strings stay distinct.
struct ParsonsBoard: Equatable {
    let pool: [String]
    private(set) var placedIndices: [Int] = []

    init(pool: [String]) {
        self.pool = pool
    }

    var placed: [String] { placedIndices.map { pool[$0] } }

    /// Pool indices not yet placed, in pool order.
    var remaining: [Int] {
        pool.indices.filter { !placedIndices.contains($0) }
    }

    mutating func place(poolIndex: Int) {
        guard pool.indices.contains(poolIndex), !placedIndices.contains(poolIndex) else { return }
        placedIndices.append(poolIndex)
    }

    mutating func unplace(at position: Int) {
        guard placedIndices.indices.contains(position) else { return }
        placedIndices.remove(at: position)
    }

    func isFull(target: Int) -> Bool { placedIndices.count >= target }
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
        case finished(PrepStreak, moved: [PrepSkill])
        case unavailable
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var run: PrepRun?
    private(set) var board: ParsonsBoard?
    private(set) var hintsShown = 0
    private(set) var submitError: String?
    private(set) var isSubmitting = false

    @ObservationIgnored private let client: PrepDataClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var shownAt: Date
    @ObservationIgnored private var mapBefore: PrepTrackMap?
    @ObservationIgnored private var lastStreak: PrepStreak?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isAdvancing = false

    init(client: PrepDataClient, now: @escaping () -> Date = Date.init) {
        self.client = client
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
        do {
            let loaded = try await client.today()
            // Non-fatal: only used to show which skills moved at the end.
            let map = try? await client.map(track: "dsa")
            guard token == generation, !Task.isCancelled else { return }
            mapBefore = map
            run = loaded
            await advance(in: loaded, to: loaded.index, token: token)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            phase = prepIsNotFound(error) ? .unavailable : .failed(error.localizedDescription)
        }
    }

    func choose(_ answer: PrepAnswer) async {
        await submit(answer)
    }

    func acknowledgePrimer() async {
        await submit(.choice("seen"))
    }

    func checkParsons() async {
        guard let board else { return }
        await submit(.lines(board.placed))
    }

    func place(poolIndex: Int) {
        guard !isSubmitting else { return }
        board?.place(poolIndex: poolIndex)
    }

    func unplace(at position: Int) {
        guard !isSubmitting else { return }
        board?.unplace(at: position)
    }

    func showHint() {
        guard case let .rep(rep, _) = phase, hintsShown < rep.item.hints.count else { return }
        hintsShown += 1
    }

    func `continue`() async {
        guard !isAdvancing, case let .result(_, result, _) = phase, let run else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        await advance(in: run, to: result.nextIndex, token: generation)
    }

    // MARK: - Private

    private func advance(in run: PrepRun, to target: Int, token: Int) async {
        guard token == generation, !Task.isCancelled else { return }
        if let rep = run.reps.first(where: { $0.index >= target }) {
            show(rep)
        } else {
            await finish(token: token)
        }
    }

    private func show(_ rep: PrepRep) {
        hintsShown = 0
        submitError = nil
        board = rep.drill == .parsons ? ParsonsBoard(pool: rep.item.lines) : nil
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
            answer: answer, elapsedMS: elapsed, hintsUsed: hintsShown)
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
                await advance(in: run, to: result.nextIndex, token: token)
                isSubmitting = false
            } else {
                isSubmitting = false
                phase = .result(rep, result, index: rep.index)
            }
        } catch {
            if prepIsCancellation(error) {
                isSubmitting = false
            } else if prepIsConflict(error) {
                // Stay locked until the fresh run is in place, so no submit posts to the stale one.
                await restart(token: token)
                isSubmitting = false
            } else {
                isSubmitting = false
                submitError = "Couldn't save. Try again."
            }
        }
    }

    /// The plan belongs to another day: reload it and start at its index.
    private func restart(token: Int) async {
        guard token == generation else { return }
        mapBefore = nil
        lastStreak = nil
        do {
            let fresh = try await client.today()
            let map = try? await client.map(track: "dsa")
            guard token == generation, !Task.isCancelled else { return }
            mapBefore = map
            run = fresh
            await advance(in: fresh, to: fresh.index, token: token)
        } catch {
            guard token == generation, !prepIsCancellation(error) else { return }
            phase = prepIsNotFound(error) ? .unavailable : .failed(error.localizedDescription)
        }
    }

    private func finish(token: Int) async {
        var streak = lastStreak
        if streak == nil { streak = try? await client.home().streak }
        var moved: [PrepSkill] = []
        let after = mapBefore == nil ? nil : try? await client.map(track: "dsa")
        guard token == generation, !Task.isCancelled else { return }
        board = nil
        if let before = mapBefore, let after {
            let old = Dictionary(
                before.levels.flatMap(\.skills).map { ($0.id, $0.mastery) },
                uniquingKeysWith: { first, _ in first })
            moved = after.levels.flatMap(\.skills).filter { skill in
                old[skill.id].map { $0 != skill.mastery } ?? false
            }
        }
        phase = .finished(streak ?? PrepStreak(), moved: moved)
    }
}

// MARK: - Presentation

/// The Prep screens' copy and small derivations, kept out of the views so they stay
/// dumb and the wording is testable. English only, sentence case.
enum PrepCopy {
    /// What today's run button offers on Prep home.
    enum RunAction: Equatable { case start, resume, done }

    static func streak(days: Int) -> String { "\(days)-day streak" }

    static func freezes(_ count: Int) -> String {
        count == 1 ? "1 freeze saved" : "\(count) freezes saved"
    }

    /// The Brain home row's subtitle.
    static func homeRowSubtitle(streakDays: Int, remaining: Int) -> String {
        "\(streak(days: streakDays)) · " + (remaining == 0 ? "run done" : "today's run is ready")
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

    /// Lines a Parsons answer needs: the pool holds the solution plus one decoy.
    static func parsonsTarget(poolCount: Int) -> Int { max(1, poolCount - 1) }

    static func parsonsLineLabel(_ code: String) -> String { "Line: \(code). Double-tap to place." }

    static func parsonsPlacedLabel(position: Int, code: String) -> String {
        "Position \(position): \(code). Double-tap to remove."
    }

    /// A moved skill's subtitle on the run-complete screen.
    static func movedSubtitle(mastery: Double) -> String {
        "\(Int((mastery * 100).rounded()))% mastered"
    }

    /// The cover id for a Prep track or skill, seeded apart from Brain pages.
    static func coverID(_ id: String) -> String { "prep.\(id)" }
}
