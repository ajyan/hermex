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
    /// Rows with a check-in in flight; further taps on them are ignored.
    private(set) var pending: Set<GoalRowKey> = []
    private(set) var error: String?
    /// The row whose check-in failed, so its section says so; nil for a screen-wide error.
    private(set) var errorRow: GoalRowKey?
    /// The consistency calendar for what's on screen, rebuilt only when its days change.
    private(set) var calendar = GoalCalendarModel.empty
    static let refreshFailed = "Couldn't refresh. Pull to try again."
    static let dayChanged = "The day changed. Check in again."
    static let saveFailed = "Couldn't save. Try again."
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
    @ObservationIgnored private let onChange: @MainActor () -> Void
    @ObservationIgnored private var generation = 0
    /// The server's detail with the taps in flight on top; `state` shows `edits.shown`.
    @ObservationIgnored private var edits: GoalPendingEdits<GoalDetail, GoalRowKey>?
    @ObservationIgnored private var inFlight = 0
    /// Since the last settle: a check-in saved, or one met a day that had moved on.
    @ObservationIgnored private var savedSinceSettle = false
    @ObservationIgnored private var dayChangedSinceSettle = false
    @ObservationIgnored private var calendarInput: CalendarInput?

    private struct CalendarInput: Equatable {
        let heatmap: [GoalHeatDay]
        let week: [GoalHeatDay]
        let today: String
        let deadline: String?
    }

    /// `onChange` runs once a check-in, finish or reopen has landed on the server (the widget
    /// refreshes from it).
    init(slug: String, client: GoalsDataClient, onAPIError: @escaping (Error) -> Void = { _ in },
         onChange: @escaping @MainActor () -> Void = {}) {
        self.slug = slug
        self.client = client
        self.onAPIError = onAPIError
        self.onChange = onChange
    }

    func isPending(_ key: GoalRowKey) -> Bool { pending.contains(key) }

    func load() async {
        generation += 1
        let token = generation
        do {
            let detail = try await client.detail(slug: slug)
            guard token == generation, !Task.isCancelled else { return }
            show(detail)
            if error == Self.refreshFailed { setError(nil) }
        } catch {
            guard token == generation, !goalsIsCancellation(error) else { return }
            onAPIError(error)
            if goalsKeepsContent(state, after: error) {
                setError(Self.refreshFailed)
                return
            }
            edits = nil
            state = goalsFailureState(error)
        }
    }

    /// Closes the goal as achieved. Nothing changes on screen until the server says it's done.
    /// When the answer is an error, the goal may have closed anyway (a lost response, or a
    /// finish from elsewhere), so its record decides before the error shows.
    func finish() async {
        guard case .loaded(let detail) = state, !isFinishing, finished == nil else { return }
        isFinishing = true
        setError(nil)
        defer { isFinishing = false }
        do {
            finished = try await client.finish(GoalFinishRequest(slug: slug, asOf: detail.today))
            onChange()
        } catch {
            guard !goalsIsCancellation(error) else { return }
            if let record = try? await client.record(slug: slug) {
                finished = record
                onChange()
                return
            }
            if case .http(409, _)? = error as? APIError {
                await load()
                setError("The day changed. Try again.")
                return
            }
            onAPIError(error)
            setError("Couldn't finish this goal. Try again.")
        }
    }

    /// The goal open again after its record's Reopen: the screen leaves the record for it.
    /// The finish prompt stays hidden until the screen is opened again.
    func reopened(_ detail: GoalDetail) {
        finished = nil
        finishDeferred = true
        setError(nil)
        show(detail)
    }

    func checkIn(commitment id: String, status: GoalStatus) async {
        await send(.commitment(id), request: { .commitment(slug: self.slug, date: $0, asOf: $1, id: id, status: status) }) {
            GoalCheckInEdit.apply(status, to: id, on: $1, today: $2, yesterday: $3, in: &$0)
        }
    }

    /// Counts one more item (with its optional note) on the selected day; true once the server has it.
    @discardableResult
    func addItem(commitment id: String, note: String?) async -> Bool {
        await send(.commitment(id), request: { .item(slug: self.slug, date: $0, asOf: $1, id: id, n: 1, note: note) }) { goal, date, _, _ in
            GoalCheckInEdit.addItem(1, note: note, to: id, on: date, in: &goal)
        }
    }

    /// Takes the latest counted item back off.
    func removeLastItem(commitment id: String) async {
        await send(.commitment(id), request: { .item(slug: self.slug, date: $0, asOf: $1, id: id, n: -1, note: nil) }) { goal, date, _, _ in
            GoalCheckInEdit.addItem(-1, note: nil, to: id, on: date, in: &goal)
        }
    }

    func checkIn(check id: String, value: String) async {
        await send(.check(id), request: { .check(slug: self.slug, date: $0, asOf: $1, id: id, value: value) }) {
            GoalCheckInEdit.setCheck(value, id: id, on: $1, today: $2, yesterday: $3, in: &$0)
        }
    }

    /// Shows the tap at once, posts it, then takes the server's summary, or drops the tap (its
    /// rollback; other taps in flight stay). The row is free again as soon as the post answers;
    /// the full detail (heatmap, consistency, history) reloads once, after the last tap in flight.
    @discardableResult
    private func send(
        _ key: GoalRowKey,
        request makeRequest: (_ date: String, _ asOf: String) -> GoalCheckInRequest,
        edit: @escaping (_ goal: inout GoalSummary, _ date: String, _ today: String, _ yesterday: String) -> Void
    ) async -> Bool {
        guard case .loaded = state, var pendingEdits = edits, !pendingEdits.contains(key) else { return false }
        // The server's dates, never the phone's: the server decides what "today" is.
        let base = pendingEdits.base
        let date = day == .today ? base.today : base.yesterday
        let request = makeRequest(date, base.today)
        pendingEdits.add(key) { edit(&$0.summary, date, $0.today, $0.yesterday) }
        edits = pendingEdits
        setError(nil)
        publish()
        inFlight += 1
        var saved = false
        do {
            let result = try await client.checkIn(request, clientID: UUID().uuidString)
            edits?.remove(key)
            edits?.base.summary = result.goal
            edits?.base.streak = result.streak
            savedSinceSettle = true
            saved = true
        } catch {
            edits?.remove(key)
            if goalsIsCancellation(error) {
                // The screen is gone; nothing to tell.
            } else if case .http(409, _)? = error as? APIError {
                dayChangedSinceSettle = true
            } else {
                onAPIError(error)
                setError(Self.saveFailed, row: key)
            }
        }
        publish()
        inFlight -= 1
        if inFlight == 0 { await settle() }
        return saved
    }

    /// After the last check-in in flight: one full reload when any saved or the day moved on.
    private func settle() async {
        let saved = savedSinceSettle, dayChanged = dayChangedSinceSettle
        savedSinceSettle = false
        dayChangedSinceSettle = false
        guard saved || dayChanged, !Task.isCancelled else { return }
        if saved { onChange() }
        await load()
        if dayChanged { setError(Self.dayChanged) }
    }

    /// Takes a detail from the server, keeping any taps still in flight on top of it.
    private func show(_ detail: GoalDetail) {
        if edits == nil { edits = GoalPendingEdits(detail) } else { edits?.base = detail }
        publish()
    }

    private func publish() {
        guard let edits else { return }
        let shown = edits.shown
        state = .loaded(shown)
        let keys = edits.keys
        if pending != keys { pending = keys }
        let input = CalendarInput(heatmap: shown.heatmap, week: shown.summary.week.days, today: shown.today,
                                  deadline: shown.summary.deadline)
        if input != calendarInput {
            calendarInput = input
            calendar = GoalCalendarModel(
                heatmap: GoalCalendar.merged(heatmap: input.heatmap, week: input.week, today: input.today),
                today: input.today, deadline: input.deadline)
        }
    }

    private func setError(_ message: String?, row: GoalRowKey? = nil) {
        error = message
        errorRow = message == nil ? nil : row
    }
}

/// A finished goal's record, and his reflection on it.
@MainActor
@Observable
final class GoalRecordViewModel {
    private(set) var state: BrainLoadState<GoalRecord>
    private(set) var isSaving = false
    private(set) var error: String?
    /// Reopen is in flight.
    private(set) var isReopening = false
    /// Why the last Reopen didn't happen.
    private(set) var reopenError: String?

    let slug: String
    @ObservationIgnored private let client: GoalsDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private let onChange: @MainActor () -> Void

    /// `record` is the one the finish just returned, so the screen needs no load. `onChange`
    /// runs once a reopen has landed on the server (the widget refreshes from it).
    init(slug: String, record: GoalRecord? = nil, client: GoalsDataClient,
         onAPIError: @escaping (Error) -> Void = { _ in }, onChange: @escaping @MainActor () -> Void = {}) {
        self.slug = slug
        self.client = client
        self.onAPIError = onAPIError
        self.onChange = onChange
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

    /// Reopens the finished goal: its open detail once the server has it, else nil with
    /// `reopenError` saying why.
    func reopen() async -> GoalDetail? {
        guard case .loaded = state, !isReopening else { return nil }
        isReopening = true
        reopenError = nil
        defer { isReopening = false }
        do {
            let detail = try await client.reopen(slug: slug)
            onChange()
            return detail
        } catch {
            guard !goalsIsCancellation(error) else { return nil }
            onAPIError(error)
            if case .http(409, _)? = error as? APIError {
                reopenError = "An open goal already has this name."
            } else if (error as? APIError)?.isNotFound == true {
                reopenError = "This goal can't be reopened."
            } else {
                reopenError = "Couldn't reopen this goal. Try again."
            }
            return nil
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
