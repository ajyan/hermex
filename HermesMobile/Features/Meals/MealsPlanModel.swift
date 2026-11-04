import Foundation
import Observation

/// The weekend planner's four steps: review the week (each open night defaults to eaten, by the
/// weekend rule), tick what's left, fill the target week's nights, then groceries to Reminders.
/// Step 3 edits the target week through the Meals screen's own view model, so every edit is saved
/// as it's made and the screen shows what the server saved.
@MainActor
@Observable
final class MealsPlanModel {
    enum Step: Hashable {
        case left, fill, groceries
        case dish(MealsDishRoute)
    }

    private(set) var review: BrainLoadState<MealsPlanReview> = .loading
    /// His answers for the nights that need a look, by day.
    private(set) var answers: [String: MealsReviewAnswer] = [:]
    private(set) var leftovers: BrainLoadState<[MealsLeftover]> = .loading
    private(set) var checked: Set<String> = []
    private(set) var suggestions = MealsSuggestions()
    private(set) var suggestionsLoaded = false
    /// Suggestions passed over with Another, by day.
    private(set) var passed: [String: Set<String>] = [:]
    private(set) var groceries: BrainLoadState<MealsGroceries> = .loading
    private(set) var finished: MealsPlanFinish?
    private(set) var isSaving = false
    /// Why the last save didn't take; cleared by the next one.
    private(set) var error: String?

    /// The week being filled, as the Meals screen's model for that week.
    let week: MealsHomeViewModel
    /// The target week's Monday (YYYY-MM-DD).
    let target: String
    let today: String

    @ObservationIgnored private let client: MealsPlanClient
    @ObservationIgnored private let onAPIError: (Error) -> Void

    init(client: MealsPlanClient & MealsScreenClient, onAPIError: @escaping (Error) -> Void = { _ in },
         now: Date = Date(), calendar: Calendar = .current) {
        self.client = client
        self.onAPIError = onAPIError
        today = MealsCopy.localDay(now, calendar: calendar)
        let monday = MealsCopy.planTarget(now, calendar: calendar)
        target = MealsCopy.localDay(monday, calendar: calendar)
        week = MealsHomeViewModel(client: client, onAPIError: onAPIError, now: { monday })
    }

    // MARK: 1. How was this week?

    func loadReview() async {
        do {
            let loaded = try await client.review(day: today)
            review = .loaded(loaded)
            answers = Dictionary(uniqueKeysWithValues: loaded.needs.map {
                ($0.day, MealsReviewAnswer(day: $0.day, choice: $0.choice, carry: $0.carry))
            })
        } catch {
            fail(error, into: &review)
        }
    }

    func answer(for day: String) -> MealsReviewAnswer? { answers[day] }

    /// Ate it, Skipped or Ate out. A meal not eaten carries to next week unless he says not.
    func choose(_ choice: String, for day: String) {
        guard var answer = answers[day], answer.choice != choice else { return }
        answer.choice = choice
        answer.carry = choice == "skipped"
        answers[day] = answer
    }

    func toggleCarry(_ day: String) {
        answers[day]?.carry.toggle()
    }

    /// Saves his answers; true when there was nothing to save or the server took them.
    func finishReview() async -> Bool {
        guard case .loaded(let loaded) = review else { return false }
        guard !loaded.needs.isEmpty else { return true }
        let request = MealsReviewRequest(week: loaded.week, answers: loaded.needs.compactMap { answers[$0.day] })
        return await save { try await self.client.finishReview(request) }
    }

    // MARK: 2. What's left?

    func loadLeftovers() async {
        do {
            let items = try await client.leftovers(target: target).items
            leftovers = .loaded(items)
            checked = Set(items.filter(\.checked).map(\.text))
        } catch {
            fail(error, into: &leftovers)
        }
    }

    func toggle(_ text: String) {
        if checked.contains(text) { checked.remove(text) } else { checked.insert(text) }
    }

    /// Something he has that the list didn't think of; added ticked.
    func addLeftover(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, case .loaded(var items) = leftovers else { return }
        if !items.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            items.append(MealsLeftover(text: text, why: "Added"))
            leftovers = .loaded(items)
        }
        checked.insert(items.first { $0.text.caseInsensitiveCompare(text) == .orderedSame }?.text ?? text)
    }

    /// Replaces the on-hand list with what he ticked, in the list's order.
    func saveLeftovers() async -> Bool {
        guard case .loaded(let items) = leftovers else { return false }
        let kept = items.map(\.text).filter(checked.contains)
        return await save { try await self.client.saveLeftovers(kept) }
    }

    // MARK: 3. Fill the nights

    /// Places last week's carried meals, then loads the week and the suggestions.
    func startFill() async {
        do {
            suggestions = try await client.start(target: target)
            suggestionsLoaded = true
        } catch {
            if !mealsPlanIsCancellation(error) {
                onAPIError(error)
                self.error = "Couldn't load suggestions. Pick dishes yourself, or go back and try again."
            }
            suggestionsLoaded = true
        }
        await week.load()
    }

    /// Atlas's suggestion for an open night: the best main not on the week, not suggested for an
    /// earlier open night, and not passed over here.
    func suggestion(for day: String, in home: MealsHome) -> MealsSuggestion? {
        var taken = Set(home.days.flatMap { $0.night?.dishes.map(\.slug) ?? [] })
        for open in home.days where open.night == nil {
            let pick = suggestions.candidates.first {
                !taken.contains($0.slug) && !(passed[open.day]?.contains($0.slug) ?? false)
            }
            if open.day == day { return pick }
            if let pick { taken.insert(pick.slug) }
        }
        return nil
    }

    func another(for day: String, in home: MealsHome) {
        guard let current = suggestion(for: day, in: home) else { return }
        passed[day, default: []].insert(current.slug)
    }

    /// The sides he usually eats with this night's main that aren't on it yet.
    func pairedSides(for night: MealsNight) -> [MealsSeasonPick] {
        guard let main = night.main else { return [] }
        let on = Set(night.dishes.map(\.slug))
        return (suggestions.sides[main.slug] ?? []).filter { !on.contains($0.slug) }
    }

    func filledCount(_ home: MealsHome) -> Int { home.days.filter { $0.night != nil }.count }

    /// A dish from This time last year goes on the first open night.
    func addToFirstOpenNight(_ pick: MealsSeasonPick) async {
        guard case .loaded(let home) = week.state, let open = home.days.first(where: { $0.night == nil }) else { return }
        await week.add(MealsDish(slug: pick.slug, name: pick.name), to: open.day)
    }

    // MARK: 4. Groceries

    func loadGroceries() async {
        do {
            groceries = .loaded(try await client.groceries(target: target))
        } catch {
            fail(error, into: &groceries)
        }
    }

    /// Saves the week's lists, and with `reminders` sends the groceries to Reminders.
    func finish(reminders: Bool) async -> Bool {
        var answer: MealsPlanFinish?
        let saved = await save { answer = try await self.client.finish(MealsPlanFinishRequest(target: self.target,
                                                                                            reminders: reminders)) }
        if saved { finished = answer }
        return saved
    }

    // MARK: -

    private func save(_ operation: @escaping () async throws -> Void) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await operation()
            return true
        } catch {
            if !mealsPlanIsCancellation(error) {
                onAPIError(error)
                self.error = "Couldn't save that. Try again."
            }
            return false
        }
    }

    private func fail<Value>(_ error: Error, into state: inout BrainLoadState<Value>) {
        guard !mealsPlanIsCancellation(error) else { return }
        onAPIError(error)
        state = (error as? APIError)?.isNotFound == true ? .unavailable : .failed(error.localizedDescription)
    }
}

private func mealsPlanIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}

extension MealsCopy {
    /// The Monday the planner fills from `date`: next week from Friday on, else this week.
    static func planTarget(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)  // 1 = Sunday
        let sinceMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: start) ?? start
        return sinceMonday >= 4 ? calendar.date(byAdding: .day, value: 7, to: monday) ?? monday : monday
    }

    /// "Plan next week" from Friday on, else "Plan this week".
    static func planTitle(_ date: Date, calendar: Calendar = .current) -> String {
        planTarget(date, calendar: calendar) > date ? "Plan next week" : "Plan this week"
    }

    /// "Nov 9–15", or "Nov 30–Dec 6".
    static func weekRange(_ monday: String) -> String {
        guard let start = date(monday),
              let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 6, to: start) else { return monday }
        let endDay = localDay(end, calendar: Calendar(identifier: .gregorian))
        let sameMonth = monthDay(monday).split(separator: " ").first == monthDay(endDay).split(separator: " ").first
        return "\(monthDay(monday))–\(sameMonth ? dayNumber(endDay) : monthDay(endDay))"
    }

    /// "For 6 dinners, Saturday scaled to 8, minus what you have."
    static func groceriesLine(_ groceries: MealsGroceries) -> String {
        let dinners = groceries.dinners == 1 ? "1 dinner" : "\(groceries.dinners) dinners"
        return (["For \(dinners)"] + groceries.scaled).joined(separator: ", ") + ", minus what you have."
    }
}
