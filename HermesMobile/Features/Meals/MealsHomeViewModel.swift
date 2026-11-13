import Foundation
import Observation

/// The log sheet after Eating it: the night already logged, waiting for an optional rating and
/// "change next time" note per dish.
struct MealsLogDraft: Equatable, Identifiable {
    let day: String
    let servings: Int
    var dishes: [Item]

    struct Item: Equatable, Identifiable {
        let dish: MealsDish
        var rating: Int?
        var note: String = ""
        var id: String { dish.slug }
    }

    var id: String { day }

    /// True once anything was rated or noted, which is worth logging the night again for.
    var hasDetails: Bool {
        dishes.contains { $0.rating != nil || !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var request: MealsLogRequest {
        MealsLogRequest(day: day, today: day, servings: servings, dishes: dishes.map {
            let note = $0.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return MealsLogDish(dish: $0.dish.slug, rating: $0.rating, note: note.isEmpty ? nil : note)
        })
    }
}

/// The Meals screen: tonight, the week, logging, and edits to the week. Nothing changes on screen
/// until the server answers with the saved week.
@MainActor
@Observable
final class MealsHomeViewModel {
    private(set) var state: BrainLoadState<MealsHome> = .loading
    /// True while a write is in flight; further writes wait for it.
    private(set) var isSaving = false
    /// Why the last write didn't take; cleared by the next one.
    private(set) var saveError: String?
    /// Set once Eating it has logged tonight, for the rating sheet.
    var logDraft: MealsLogDraft?
    /// The dish library for the picker, loaded on first use.
    private(set) var library: [MealsDish]?

    @ObservationIgnored private let client: MealsScreenClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    /// Hands every week the server answers to the Tonight widget.
    @ObservationIgnored private let onHome: (MealsHome) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = 0

    init(client: MealsScreenClient, onAPIError: @escaping (Error) -> Void = { _ in },
         onHome: @escaping (MealsHome) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.onAPIError = onAPIError
        self.onHome = onHome
        self.now = now
    }

    var today: String { MealsCopy.localDay(now()) }

    /// Loads the week around today. A refresh that fails (other than a 404) keeps what's on screen.
    func load() async {
        generation += 1
        let token = generation
        do {
            let home = try await client.home(day: today)
            guard token == generation, !Task.isCancelled else { return }
            show(home)
        } catch {
            guard token == generation, !mealsIsCancellation(error) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// Logs every dish of tonight's meal, then opens the sheet for ratings and notes.
    func eatTonight() async {
        guard case .loaded(let home) = state, let tonight = home.tonight, !tonight.dishes.isEmpty else { return }
        let request = MealsLogRequest(day: home.day, today: home.day, servings: tonight.servings,
                                      dishes: tonight.dishes.map { MealsLogDish(dish: $0.slug) })
        if await write({ try await self.client.log(request) }) {
            logDraft = MealsLogDraft(day: home.day, servings: tonight.servings,
                                     dishes: tonight.dishes.map { MealsLogDraft.Item(dish: $0) })
        }
    }

    /// Takes back a night logged by mistake (tonight's Not eaten, or a day's menu): nothing stays
    /// logged for `day`, and the planned meal goes back to waiting for Eating it.
    func unlog(_ day: String) async {
        guard case .loaded(let home) = state, home.days.contains(where: { $0.day == day && $0.logged != nil })
        else { return }
        await write({ try await self.client.log(.notEaten(day: day, today: home.day)) })
    }

    /// Opens the rating sheet for a night already logged (tonight's Rate button).
    func rateTonight() {
        guard case .loaded(let home) = state, let tonight = home.tonight else { return }
        let ratings = Dictionary(home.today?.logged?.dishes.compactMap { d in d.slug.map { ($0, d.rating) } } ?? [],
                                 uniquingKeysWith: { first, _ in first })
        logDraft = MealsLogDraft(day: home.day, servings: tonight.servings, dishes: tonight.dishes.map {
            MealsLogDraft.Item(dish: $0, rating: ratings[$0.slug] ?? nil)
        })
    }

    /// Saves the sheet's ratings and notes by logging the night again; closes it either way when
    /// there's nothing to add. Returns false (sheet stays) when the save fails.
    @discardableResult
    func finishLog(_ draft: MealsLogDraft) async -> Bool {
        guard draft.hasDetails else {
            logDraft = nil
            return true
        }
        let saved = await write({ try await self.client.log(draft.request) })
        if saved { logDraft = nil }
        return saved
    }

    func move(from: String, to: String) async {
        await saveNights { MealsWeekEdit.move($0, from: from, to: to) }
    }

    func add(_ dish: MealsDish, to day: String) async {
        await saveNights { MealsWeekEdit.add($0, dish: dish, to: day) }
    }

    func remove(_ slug: String, from day: String) async {
        await saveNights { MealsWeekEdit.remove($0, slug: slug, from: day) }
    }

    func clear(_ day: String) async {
        await saveNights { MealsWeekEdit.clear($0, day: day) }
    }

    func setServings(_ servings: Int, on day: String) async {
        await saveNights { MealsWeekEdit.servings($0, day: day, to: servings) }
    }

    /// The library for the picker; a failed read leaves it nil to try again.
    func loadLibrary() async {
        guard library == nil else { return }
        do {
            library = try await client.dishes()
        } catch {
            if !mealsIsCancellation(error) { onAPIError(error) }
        }
    }

    /// A dish typed into the picker that isn't in the library yet: saved without a recipe.
    func createDish(named name: String, side: Bool) async -> MealsDish? {
        do {
            let dish = try await client.addDish(name: name, side: side)
            if var library, !library.contains(dish) {
                library.append(dish)
                self.library = library.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            return dish
        } catch {
            if !mealsIsCancellation(error) {
                onAPIError(error)
                saveError = "Couldn't add that dish. Try again."
            }
            return nil
        }
    }

    private func saveNights(_ edit: (MealsHome) -> [MealsNightBody]) async {
        guard case .loaded(let home) = state else { return }
        let request = MealsNightsRequest(week: home.week, today: home.day, nights: edit(home))
        guard request.nights != MealsWeekEdit.nights(home) else { return }
        await write({ try await self.client.saveNights(request) })
    }

    /// Runs one write and shows the week it answers. Returns whether it took.
    @discardableResult
    private func write(_ operation: @escaping () async throws -> MealsHome) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        generation += 1
        do {
            show(try await operation())
            return true
        } catch {
            if !mealsIsCancellation(error) {
                onAPIError(error)
                saveError = "Couldn't save that. Try again."
            }
            return false
        }
    }

    private func show(_ home: MealsHome) {
        state = .loaded(home)
        onHome(home)
    }
}

private func mealsIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}
