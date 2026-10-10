import Foundation
import Observation

private func goalsIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}

private func goalsFailureState<Value>(_ error: Error) -> BrainLoadState<Value> {
    ((error as? APIError)?.isNotFound ?? false) ? .unavailable : .failed(error.localizedDescription)
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
        } catch {
            guard token == generation, !goalsIsCancellation(error) else { return }
            onAPIError(error)
            state = goalsFailureState(error)
        }
    }

    func checkIn(commitment id: String, status: GoalStatus) async {
        await send(id: id) { detail, date in
            Self.apply(status, to: id, on: date, in: &detail)
            return .commitment(slug: self.slug, date: date, id: id, status: status)
        }
    }

    func checkIn(check id: String, value: String) async {
        await send(id: id) { detail, date in
            if let i = detail.summary.dailyChecks.firstIndex(where: { $0.id == id }) {
                if date == detail.today { detail.summary.dailyChecks[i].today = value }
                if date == detail.yesterday { detail.summary.dailyChecks[i].yesterday = value }
            }
            return .check(slug: self.slug, date: date, id: id, value: value)
        }
    }

    /// Applies the optimistic edit, posts, then takes the server's summary or restores the snapshot.
    private func send(id: String, edit: (inout GoalDetail, String) -> GoalCheckInRequest) async {
        guard case .loaded(let snapshot) = state, !pending.contains(id) else { return }
        // The server's dates, never the phone's: the server decides what "today" is.
        let date = day == .today ? snapshot.today : snapshot.yesterday
        var optimistic = snapshot
        let request = edit(&optimistic, date)
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
        } catch {
            guard !goalsIsCancellation(error) else { return }
            if case .http(409, _)? = error as? APIError {
                await load()
                return
            }
            onAPIError(error)
            state = .loaded(snapshot)
            self.error = "Couldn't save. Try again."
        }
    }

    /// Moves one day's status between this week's counts, as the server will.
    private static func apply(_ status: GoalStatus, to id: String, on date: String, in detail: inout GoalDetail) {
        guard let i = detail.summary.week.commitments.firstIndex(where: { $0.id == id }) else { return }
        var row = detail.summary.week.commitments[i]
        let old: GoalStatus? = date == detail.today ? row.today : row.yesterday
        if date >= detail.summary.week.start, date <= detail.summary.week.end {
            adjust(&row, old, by: -1)
            adjust(&row, status, by: 1)
            row.remaining = max(0, row.target - row.done - row.min)
            row.hit = row.done + row.min >= row.target
        }
        if date == detail.today { row.today = status } else { row.yesterday = status }
        detail.summary.week.commitments[i] = row
    }

    private static func adjust(_ row: inout GoalCommitmentProgress, _ status: GoalStatus?, by n: Int) {
        switch status {
        case .done: row.done += n
        case .min: row.min += n
        case .skip:
            if n > 0, row.skipped >= row.skips { row.missed += n } else { row.skipped += n }
        case .miss: row.missed += n
        default: break
        }
    }
}
