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
            isSubmitting = false
            guard token == generation, !Task.isCancelled else { return }
            if let streak = result.streak { lastStreak = streak }
            phase = .result(rep, result, index: rep.index)
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
