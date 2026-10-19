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

    /// New goal shows only once the server has served goals: a goal written on a server
    /// without the goals API would never appear.
    var offersNewGoal: Bool {
        if case .loaded = state { return true }
        return false
    }

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
    /// "I finished" is in flight.
    private(set) var isFinishing = false
    /// "Not yet" hides the finish prompt until the screen is opened again.
    var finishDeferred = false
    /// The record once the server has closed the goal; the screen then shows it.
    private(set) var finished: GoalRecord?

    /// Ask "I finished?" while the last milestone is due and he hasn't answered.
    var asksToFinish: Bool {
        guard case .loaded(let detail) = state else { return false }
        return detail.summary.finishDue && !finishDeferred && finished == nil
    }

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

    /// Closes the goal as achieved. Nothing changes on screen until the server says it's done.
    func finish() async {
        guard case .loaded(let detail) = state, !isFinishing, finished == nil else { return }
        isFinishing = true
        error = nil
        defer { isFinishing = false }
        do {
            finished = try await client.finish(GoalFinishRequest(slug: slug, asOf: detail.today))
        } catch {
            guard !goalsIsCancellation(error) else { return }
            if case .http(409, _)? = error as? APIError {
                await load()
                self.error = "The day changed. Try again."
                return
            }
            onAPIError(error)
            self.error = "Couldn't finish this goal. Try again."
        }
    }

    func checkIn(commitment id: String, status: GoalStatus) async {
        await send(id: id) { detail, date, asOf in
            GoalCheckInEdit.apply(status, to: id, on: date, today: detail.today, yesterday: detail.yesterday,
                                  in: &detail.summary)
            return .commitment(slug: self.slug, date: date, asOf: asOf, id: id, status: status)
        }
    }

    /// Counts one more item (with its optional note) on the selected day.
    func addItem(commitment id: String, note: String?) async {
        await send(id: id) { detail, date, asOf in
            GoalCheckInEdit.addItem(1, note: note, to: id, on: date, in: &detail.summary)
            return .item(slug: self.slug, date: date, asOf: asOf, id: id, n: 1, note: note)
        }
    }

    /// Takes the latest counted item back off.
    func removeLastItem(commitment id: String) async {
        await send(id: id) { detail, date, asOf in
            GoalCheckInEdit.addItem(-1, note: nil, to: id, on: date, in: &detail.summary)
            return .item(slug: self.slug, date: date, asOf: asOf, id: id, n: -1, note: nil)
        }
    }

    func checkIn(check id: String, value: String) async {
        await send(id: id) { detail, date, asOf in
            GoalCheckInEdit.setCheck(value, id: id, on: date, today: detail.today, yesterday: detail.yesterday,
                                     in: &detail.summary)
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
                GoalCheckInEdit.restore(id, from: snapshot.summary, in: &current.summary)
                state = .loaded(current)
            }
            self.error = "Couldn't save. Try again."
        }
    }
}

/// A finished goal's record, and his reflection on it.
@MainActor
@Observable
final class GoalRecordViewModel {
    private(set) var state: BrainLoadState<GoalRecord>
    private(set) var isSaving = false
    private(set) var error: String?

    let slug: String
    @ObservationIgnored private let client: GoalsDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void

    /// `record` is the one the finish just returned, so the screen needs no load.
    init(slug: String, record: GoalRecord? = nil, client: GoalsDataClient,
         onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.slug = slug
        self.client = client
        self.onAPIError = onAPIError
        state = record.map { .loaded($0) } ?? .loading
    }

    var reflection: String {
        if case .loaded(let record) = state { return record.reflection }
        return ""
    }

    func load() async {
        do {
            let record = try await client.record(slug: slug)
            guard !Task.isCancelled else { return }
            state = .loaded(record)
        } catch {
            guard !goalsIsCancellation(error) else { return }
            onAPIError(error)
            if goalsKeepsContent(state, after: error) { return }
            state = goalsFailureState(error)
        }
    }

    /// Saves `text` as his reflection (empty clears it); true once the server has it.
    @discardableResult
    func saveReflection(_ text: String) async -> Bool {
        guard case .loaded = state, !isSaving else { return false }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            state = .loaded(try await client.saveReflection(GoalReflectionRequest(slug: slug, text: text)))
            return true
        } catch {
            guard !goalsIsCancellation(error) else { return false }
            onAPIError(error)
            self.error = "Couldn't save your reflection. Try again."
            return false
        }
    }
}
