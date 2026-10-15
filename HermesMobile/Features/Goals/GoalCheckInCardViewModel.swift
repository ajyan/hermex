import Foundation
import Observation

/// The Daily Deck's goal card: today's state of the goals the card names, read live from
/// `GET /api/goals`, with one-tap check-ins that show at once and roll back if the server doesn't
/// take them. Commitments check in for the server's yesterday, daily checks for its today.
@MainActor
@Observable
final class GoalCheckInCardViewModel {
    private(set) var state: BrainLoadState<GoalsHome> = .loading
    /// "<slug>/<id>" for each commitment or check with a check-in in flight; more taps on it are ignored.
    private(set) var pending: Set<String> = []
    private(set) var error: String?

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
            guard token == generation, !Self.isCancellation(error) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }  // a failed reload keeps the card's goals
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// The card's goals as the server has them now, in the card's order; a goal closed since the
    /// deck was built drops out.
    func goals(for card: DeckCard) -> [GoalSummary] {
        guard case .loaded(let home) = state else { return [] }
        return card.goals.compactMap { slug in home.goals.first { $0.slug == slug } }
    }

    /// Yesterday's commitments: the ones due then, plus any already checked in for that day.
    static func yesterdayRows(_ goal: GoalSummary) -> [GoalCommitmentProgress] {
        goal.week.commitments.filter { $0.dueYesterday || $0.yesterday != nil }
    }

    /// Commitments due today whose cue is worth a reminder.
    static func todayCues(_ goal: GoalSummary) -> [GoalCommitmentProgress] {
        goal.week.commitments.filter { $0.dueToday && !$0.cue.isEmpty }
    }

    static func key(_ slug: String, _ id: String) -> String { "\(slug)/\(id)" }

    func checkIn(slug: String, commitment id: String, status: GoalStatus) async {
        await send(slug: slug, id: id) { goal, home in
            GoalCheckInEdit.apply(status, to: id, on: home.yesterday, today: home.today, yesterday: home.yesterday,
                                  in: &goal)
            return .commitment(slug: slug, date: home.yesterday, asOf: home.today, id: id, status: status)
        }
    }

    func checkIn(slug: String, check id: String, value: String) async {
        await send(slug: slug, id: id) { goal, home in
            GoalCheckInEdit.setCheck(value, id: id, on: home.today, today: home.today, yesterday: home.yesterday,
                                     in: &goal)
            return .check(slug: slug, date: home.today, asOf: home.today, id: id, value: value)
        }
    }

    /// Applies the optimistic edit, posts, then takes the server's summary of that goal or restores
    /// this item's pre-tap values.
    private func send(slug: String, id: String,
                      edit: (inout GoalSummary, GoalsHome) -> GoalCheckInRequest) async {
        let key = Self.key(slug, id)
        guard case .loaded(var home) = state, !pending.contains(key),
              let index = home.goals.firstIndex(where: { $0.slug == slug }) else { return }
        let snapshot = home.goals[index]
        let request = edit(&home.goals[index], home)
        state = .loaded(home)
        pending.insert(key)
        error = nil
        defer { pending.remove(key) }
        do {
            let result = try await client.checkIn(request)
            guard case .loaded(var current) = state,
                  let i = current.goals.firstIndex(where: { $0.slug == slug }) else { return }
            current.goals[i] = result.goal
            current.streak = result.streak
            state = .loaded(current)
        } catch {
            guard !Self.isCancellation(error) else { return }
            if case .http(409, _)? = error as? APIError {
                await load()
                self.error = "The day changed. Check in again."
                return
            }
            onAPIError(error)
            if case .loaded(var current) = state, let i = current.goals.firstIndex(where: { $0.slug == slug }) {
                GoalCheckInEdit.restore(id, from: snapshot, in: &current.goals[i])
                state = .loaded(current)
            }
            self.error = "Couldn't save. Try again."
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }
}
