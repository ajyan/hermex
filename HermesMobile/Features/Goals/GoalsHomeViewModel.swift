import Foundation
import Observation

/// Goals home as the server has it now (`GET /api/goals`), with one-tap check-ins that show at once
/// and roll back if the server doesn't take them. Goals home, its Finished list, and the Daily Deck's
/// goal card (and the deck's front rows) all read through it. Commitments check in for the server's
/// today or yesterday, daily checks and +1s for its today.
@MainActor
@Observable
final class GoalsHomeViewModel {
    private(set) var state: BrainLoadState<GoalsHome> = .loading
    /// The last reload failed while goals were on screen; they stay, with this said above them.
    private(set) var refreshFailed = false
    /// Each goal row with a check-in in flight; more taps on it are ignored.
    private(set) var pending: Set<Key> = []
    private(set) var error: String?

    /// One row of one goal.
    struct Key: Hashable {
        let slug: String
        let row: GoalRowKey
    }

    /// Shared with the deck's Week ahead cards, which confirm through the same server.
    @ObservationIgnored let client: GoalsDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0
    /// The server's home with the taps in flight on top; `state` shows `edits.shown`.
    @ObservationIgnored private var edits: GoalPendingEdits<GoalsHome, Key>?
    @ObservationIgnored private let onChange: @MainActor (GoalsHome) -> Void

    /// New goal shows only once the server has served goals: a goal written on a server
    /// without the goals API would never appear.
    var offersNewGoal: Bool {
        if case .loaded = state { return true }
        return false
    }

    /// `onChange` gets the server's home after each check-in lands (the widget saves it).
    init(client: GoalsDataClient, onAPIError: @escaping (Error) -> Void = { _ in },
         onChange: @escaping @MainActor (GoalsHome) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
        self.onChange = onChange
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let home = try await client.home()
            guard token == generation, !Task.isCancelled else { return }
            if edits == nil { edits = GoalPendingEdits(home) } else { edits?.base = home }
            refreshFailed = false
            publish()
        } catch {
            guard token == generation, !Self.isCancellation(error) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound {
                refreshFailed = true  // a failed reload keeps the goals on screen
                return
            }
            edits = nil
            refreshFailed = false
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// Whether the card shows live check-ins: only on the deck for the server's today. An older
    /// deck, or one left open past midnight until the reload lands, shows the brief's own text.
    func isLive(for deckDate: String) -> Bool {
        guard case .loaded(let home) = state else { return false }
        return home.today == deckDate
    }

    /// The card's goals as the server has them now, in the card's order; a goal closed since the
    /// deck was built drops out.
    func goals(for card: DeckCard) -> [GoalSummary] {
        guard case .loaded(let home) = state else { return [] }
        return card.goals.compactMap { slug in home.goals.first { $0.slug == slug } }
    }

    /// Yesterday's commitments: the ones due then, plus any already checked in for that day.
    /// Item rows count whenever, so they live under `itemRows` instead.
    static func yesterdayRows(_ goal: GoalSummary) -> [GoalCommitmentProgress] {
        goal.week.commitments.filter { !$0.isItem && ($0.dueYesterday || $0.yesterday != nil) }
    }

    /// Today's commitments: the ones due today, plus any already checked in for today.
    static func todayRows(_ goal: GoalSummary) -> [GoalCommitmentProgress] {
        goal.week.commitments.filter { !$0.isItem && ($0.dueToday || $0.today != nil) }
    }

    /// The commitments counted by +1 (applications, outreach), shown under "This week".
    static func itemRows(_ goal: GoalSummary) -> [GoalCommitmentProgress] {
        goal.week.commitments.filter(\.isItem)
    }

    /// Commitments due today whose cue is worth a reminder.
    static func todayCues(_ goal: GoalSummary) -> [GoalCommitmentProgress] {
        goal.week.commitments.filter { $0.dueToday && !$0.cue.isEmpty }
    }

    static func key(_ slug: String, _ row: GoalRowKey) -> Key { Key(slug: slug, row: row) }

    func isPending(_ slug: String, _ row: GoalRowKey) -> Bool { pending.contains(Self.key(slug, row)) }

    /// Checks a day commitment in for the server's today or yesterday.
    func checkIn(slug: String, commitment id: String, status: GoalStatus, day: GoalDay) async {
        await send(slug: slug, row: .commitment(id), request: {
            .commitment(slug: slug, date: day == .today ? $0.today : $0.yesterday, asOf: $0.today, id: id, status: status)
        }) { goal, home in
            GoalCheckInEdit.apply(status, to: id, on: day == .today ? home.today : home.yesterday, today: home.today,
                                  yesterday: home.yesterday, in: &goal)
        }
    }

    /// Counts one more item (with its optional note) for the server's today; true once the server has it.
    @discardableResult
    func addItem(slug: String, commitment id: String, note: String?) async -> Bool {
        await send(slug: slug, row: .commitment(id), request: {
            .item(slug: slug, date: $0.today, asOf: $0.today, id: id, n: 1, note: note)
        }) { goal, home in
            GoalCheckInEdit.addItem(1, note: note, to: id, on: home.today, in: &goal)
        }
    }

    /// Takes the latest counted item back off.
    func removeLastItem(slug: String, commitment id: String) async {
        await send(slug: slug, row: .commitment(id), request: {
            .item(slug: slug, date: $0.today, asOf: $0.today, id: id, n: -1, note: nil)
        }) { goal, home in
            GoalCheckInEdit.addItem(-1, note: nil, to: id, on: home.today, in: &goal)
        }
    }

    func checkIn(slug: String, check id: String, value: String) async {
        await send(slug: slug, row: .check(id), request: {
            .check(slug: slug, date: $0.today, asOf: $0.today, id: id, value: value)
        }) { goal, home in
            GoalCheckInEdit.setCheck(value, id: id, on: home.today, today: home.today, yesterday: home.yesterday,
                                     in: &goal)
        }
    }

    /// Takes a goal's summary from another write (a confirmed week), so the deck's cards agree.
    func apply(_ result: GoalCheckInResult) {
        take(result)
        publish()
    }

    /// Shows the tap at once, posts it, then takes the server's summary of that goal, or drops the
    /// tap (its rollback; other taps in flight stay). A 409 means the server's day moved on, so the
    /// card reloads.
    @discardableResult
    private func send(
        slug: String,
        row: GoalRowKey,
        request makeRequest: (GoalsHome) -> GoalCheckInRequest,
        edit: @escaping (_ goal: inout GoalSummary, _ home: GoalsHome) -> Void
    ) async -> Bool {
        let key = Self.key(slug, row)
        guard case .loaded = state, var pendingEdits = edits, !pendingEdits.contains(key),
              pendingEdits.base.goals.contains(where: { $0.slug == slug }) else { return false }
        let request = makeRequest(pendingEdits.base)
        pendingEdits.add(key) { home in
            guard let i = home.goals.firstIndex(where: { $0.slug == slug }) else { return }
            let dates = home
            edit(&home.goals[i], dates)
        }
        edits = pendingEdits
        error = nil
        publish()
        do {
            let result = try await client.checkIn(request, clientID: UUID().uuidString)
            edits?.remove(key)
            take(result)
            publish()
            if let home = edits?.base { onChange(home) }
            return true
        } catch {
            edits?.remove(key)
            publish()  // nothing was saved; a failed reload must not keep the tap
            guard !Self.isCancellation(error) else { return false }
            if case .http(409, _)? = error as? APIError {
                await load()
                self.error = "The day changed. Check in again."
                return false
            }
            onAPIError(error)
            self.error = "Couldn't save. Try again."
            return false
        }
    }

    private func take(_ result: GoalCheckInResult) {
        guard let i = edits?.base.goals.firstIndex(where: { $0.slug == result.goal.slug }) else { return }
        edits?.base.goals[i] = result.goal
        edits?.base.streak = result.streak
    }

    private func publish() {
        guard let edits else { return }
        state = .loaded(edits.shown)
        let keys = edits.keys
        if pending != keys { pending = keys }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }
}
