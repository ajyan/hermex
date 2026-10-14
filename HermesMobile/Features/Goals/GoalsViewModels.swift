import Foundation
import Observation

private func goalsIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}

private func goalsFailureState<Value>(_ error: Error) -> BrainLoadState<Value> {
    ((error as? APIError)?.isNotFound ?? false) ? .unavailable : .failed(error.localizedDescription)
}

/// A reload that fails without a 404 keeps what's on screen; only a first load shows the error.
private func goalsKeepsContent<Value>(_ state: BrainLoadState<Value>, after error: Error) -> Bool {
    guard case .loaded = state else { return false }
    return !((error as? APIError)?.isNotFound ?? false)
}

/// The Goals landing screen (and Brain's Goals row): streak, active goals, agent goals.
@MainActor
@Observable
final class GoalsHomeViewModel {
    private(set) var state: BrainLoadState<GoalsHome> = .loading
    @ObservationIgnored private let client: GoalsDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(client: GoalsDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let home = try await client.home()
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(home)
        } catch {
            guard token == generation, !goalsIsCancellation(error) else { return }
            onAPIError(error)
            if goalsKeepsContent(state, after: error) { return }
            state = goalsFailureState(error)
        }
    }
}

/// Which day the detail screen's check-in buttons write to.
enum GoalDay: Hashable, Sendable {
    case today, yesterday
}

/// One goal: its week, daily checks and history, with one-tap check-ins that show at once
/// and roll back if the server doesn't take them.
@MainActor
@Observable
final class GoalDetailViewModel {
    private(set) var state: BrainLoadState<GoalDetail> = .loading
    var day: GoalDay = .today
    /// Commitment and check ids with a check-in in flight; further taps on them are ignored.
    private(set) var pending: Set<String> = []
    private(set) var error: String?
    static let refreshFailed = "Couldn't refresh. Pull to try again."

    let slug: String
    @ObservationIgnored private let client: GoalsDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(slug: String, client: GoalsDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.slug = slug
        self.client = client
        self.onAPIError = onAPIError
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let detail = try await client.detail(slug: slug)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(detail)
            if error == Self.refreshFailed { error = nil }
        } catch {
            guard token == generation, !goalsIsCancellation(error) else { return }
            onAPIError(error)
            if goalsKeepsContent(state, after: error) {
                self.error = Self.refreshFailed
                return
            }
            state = goalsFailureState(error)
        }
    }

    func checkIn(commitment id: String, status: GoalStatus) async {
        await send(id: id) { detail, date, asOf in
            Self.apply(status, to: id, on: date, in: &detail)
            return .commitment(slug: self.slug, date: date, asOf: asOf, id: id, status: status)
        }
    }

    func checkIn(check id: String, value: String) async {
        await send(id: id) { detail, date, asOf in
            if let i = detail.summary.dailyChecks.firstIndex(where: { $0.id == id }) {
                let shown = value == GoalCheckValue.clear ? nil : value
                if date == detail.today { detail.summary.dailyChecks[i].today = shown }
                if date == detail.yesterday { detail.summary.dailyChecks[i].yesterday = shown }
            }
            return .check(slug: self.slug, date: date, asOf: asOf, id: id, value: value)
        }
    }

    /// Applies the optimistic edit, posts, then takes the server's summary or restores this
    /// item's pre-tap values (never another check-in's, which may have landed meanwhile).
    private func send(id: String, edit: (inout GoalDetail, String, String) -> GoalCheckInRequest) async {
        guard case .loaded(let snapshot) = state, !pending.contains(id) else { return }
        // The server's dates, never the phone's: the server decides what "today" is.
        let date = day == .today ? snapshot.today : snapshot.yesterday
        var optimistic = snapshot
        let request = edit(&optimistic, date, snapshot.today)
        state = .loaded(optimistic)
        pending.insert(id)
        error = nil
        defer { pending.remove(id) }
        do {
            let result = try await client.checkIn(request)
            guard case .loaded(var current) = state else { return }
            current.summary = result.goal
            current.streak = result.streak
            state = .loaded(current)
            // The heatmap, consistency and check history come only with the full detail.
            await load()
        } catch {
            guard !goalsIsCancellation(error) else { return }
            if case .http(409, _)? = error as? APIError {
                await load()
                self.error = "The day changed. Check in again."
                return
            }
            onAPIError(error)
            if case .loaded(var current) = state {
                Self.restore(id, from: snapshot, in: &current)
                state = .loaded(current)
            }
            self.error = "Couldn't save. Try again."
        }
    }

    /// Puts one commitment's or daily check's values from `snapshot` back into `detail`.
    private static func restore(_ id: String, from snapshot: GoalDetail, in detail: inout GoalDetail) {
        if let old = snapshot.summary.week.commitments.first(where: { $0.id == id }),
           let i = detail.summary.week.commitments.firstIndex(where: { $0.id == id }) {
            detail.summary.week.commitments[i] = old
        }
        if let old = snapshot.summary.dailyChecks.first(where: { $0.id == id }),
           let i = detail.summary.dailyChecks.firstIndex(where: { $0.id == id }) {
            detail.summary.dailyChecks[i] = old
        }
    }

    /// Moves one day's status between this week's counts, as the server will.
    private static func apply(_ status: GoalStatus, to id: String, on date: String, in detail: inout GoalDetail) {
        guard let i = detail.summary.week.commitments.firstIndex(where: { $0.id == id }) else { return }
        var row = detail.summary.week.commitments[i]
        let old: GoalStatus? = date == detail.today ? row.today : row.yesterday
        let week = detail.summary.week
        if date >= week.start, date <= week.end {
            // Skip days this row is known to have: the counted ones, or today and yesterday.
            let shown = [(detail.today, row.today), (detail.yesterday, row.yesterday)]
                .filter { $0.1 == .skip && $0.0 >= week.start && $0.0 <= week.end }.count
            let skipDays = max(row.skipped, shown)
            adjust(&row, old, by: -1, skipDays: skipDays)
            if status != .clear { adjust(&row, status, by: 1, skipDays: skipDays) }
            row.remaining = max(0, row.target - row.done - row.min)
            row.hit = row.done + row.min >= row.target
        }
        let shown: GoalStatus? = status == .clear ? nil : status
        if date == detail.today { row.today = shown } else { row.yesterday = shown }
        detail.summary.week.commitments[i] = row
    }

    /// The server counts a week's skips in day order and any past the budget as misses, so
    /// adding one with the budget spent, or removing one while `skipDays` exceeds it, moves `missed`.
    private static func adjust(_ row: inout GoalCommitmentProgress, _ status: GoalStatus?, by n: Int, skipDays: Int) {
        switch status {
        case .done: row.done += n
        case .min: row.min += n
        case .skip:
            let overBudget = n > 0 ? row.skipped >= row.skips : skipDays > row.skips
            if overBudget { row.missed += n } else { row.skipped += n }
        case .miss: row.missed += n
        default: break
        }
    }
}
