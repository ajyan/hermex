import Foundation
import Observation

/// A dish's page: the recipe scaled to the servings on screen, Atlas's fix, and his edits. The
/// servings start at the night it was opened from (or the recipe's own) and only scale the view;
/// a night's servings change from the week. Nothing shows as saved until the server answers.
@MainActor
@Observable
final class MealsDishViewModel {
    private(set) var state: BrainLoadState<MealsRecipe> = .loading
    private(set) var isSaving = false
    /// Why the last write didn't take; cleared by the next one.
    private(set) var saveError: String?
    /// The servings the ingredients are shown for.
    var servings: Int

    let route: MealsDishRoute
    @ObservationIgnored private let client: MealsRecipeClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var servingsChosen: Bool

    init(route: MealsDishRoute, client: MealsRecipeClient, onAPIError: @escaping (Error) -> Void = { _ in },
         now: @escaping () -> Date = Date.init) {
        self.route = route
        self.client = client
        self.onAPIError = onAPIError
        self.now = now
        servings = route.servings ?? MealsCopy.defaultServings
        servingsChosen = route.servings != nil
    }

    var today: String { MealsCopy.localDay(now()) }

    /// How much every amount is multiplied by.
    var factor: Double {
        guard case .loaded(let recipe) = state else { return 1 }
        return Double(servings) / Double(recipe.serves)
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let recipe = try await client.recipe(slug: route.slug)
            guard token == generation, !Task.isCancelled else { return }
            show(recipe)
        } catch {
            guard token == generation, !mealsRecipeIsCancellation(error) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }

    func setServings(_ value: Int) {
        servings = min(48, max(1, value))
        servingsChosen = true
    }

    /// Use this (`use`) or Keep as is on the waiting fix.
    func answerFix(use: Bool) async {
        await write { try await self.client.answerFix(MealsFixRequest(slug: self.route.slug, use: use, today: self.today)) }
    }

    /// Saves his edits; returns whether they took, so the editor knows to close.
    @discardableResult
    func save(_ request: MealsRecipeEditRequest) async -> Bool {
        await write { try await self.client.editRecipe(request) }
    }

    /// A link's recipe saved into this dish (the link sheet's answer).
    func linked(_ recipe: MealsRecipe) {
        show(recipe)
    }

    @discardableResult
    private func write(_ operation: @escaping () async throws -> MealsRecipe) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        generation += 1
        do {
            show(try await operation())
            return true
        } catch {
            if !mealsRecipeIsCancellation(error) {
                onAPIError(error)
                saveError = "Couldn't save that. Try again."
            }
            return false
        }
    }

    private func show(_ recipe: MealsRecipe) {
        state = .loaded(recipe)
        if !servingsChosen { servings = recipe.serves }
    }
}

/// The recipe book: search, the filter chips, and this season's card.
@MainActor
@Observable
final class MealsBookViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", mains = "Mains", sides = "Sides", want = "Want to try", occasions = "Occasions"
        var id: String { rawValue }
    }

    private(set) var state: BrainLoadState<MealsBook> = .loading
    var query = ""
    var filter: Filter = .all

    @ObservationIgnored private let client: MealsRecipeClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generation = 0

    init(client: MealsRecipeClient, onAPIError: @escaping (Error) -> Void = { _ in },
         now: @escaping () -> Date = Date.init) {
        self.client = client
        self.onAPIError = onAPIError
        self.now = now
    }

    var today: String { MealsCopy.localDay(now()) }

    func load() async {
        generation += 1
        let token = generation
        do {
            let book = try await client.book(day: today)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(book)
        } catch {
            guard token == generation, !mealsRecipeIsCancellation(error) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// True while the book shows its sections (season card, Good right now, Want to try);
    /// a search or a filter shows one list instead.
    var isBrowsing: Bool { filter == .all && trimmedQuery.isEmpty }

    /// The dishes a search or filter shows, A to Z.
    func matches(in book: MealsBook) -> [MealsBookDish] {
        let words = trimmedQuery.lowercased().split(separator: " ")
        return book.dishes.filter { dish in
            let name = dish.name.lowercased()
            guard words.allSatisfy({ name.contains($0) }) else { return false }
            switch filter {
            case .all: return true
            case .mains: return !dish.isSide && !dish.isWant
            case .sides: return dish.isSide && !dish.isWant
            case .want: return dish.isWant
            case .occasions: return !dish.occasions.isEmpty
            }
        }
    }

    /// Dishes he's made that belong to this season, most made first.
    static func inSeason(_ book: MealsBook) -> [MealsBookDish] {
        let season = book.season.seasonWord
        return book.dishes
            .filter { !$0.isWant && $0.seasons.contains(season) }
            .sorted { ($0.made, $1.name) > ($1.made, $0.name) }
    }

    static func wantToTry(_ book: MealsBook) -> [MealsBookDish] {
        book.dishes.filter(\.isWant).sorted { ($0.saved ?? "") > ($1.saved ?? "") }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The Add a recipe sheet: a link, what the server found on it, and how to file it.
@MainActor
@Observable
final class MealsLinkModel {
    enum Preview: Equatable {
        case idle
        case loading
        case found(MealsLinkPreview)
        case failed(String)
    }

    var url = ""
    private(set) var preview: Preview = .idle
    var side = false
    var seasons: Set<String> = []
    var occasions: Set<String> = []
    var ateTonight = false
    private(set) var isSaving = false
    private(set) var saveError: String?

    /// The dish whose missing recipe this link fills in (opened from its page), else nil.
    let fillsIn: MealsSeasonPick?
    @ObservationIgnored private let client: MealsRecipeClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var previewedURL: String?

    init(fillsIn: MealsSeasonPick? = nil, side: Bool = false, client: MealsRecipeClient,
         onAPIError: @escaping (Error) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        self.fillsIn = fillsIn
        self.side = side
        self.client = client
        self.onAPIError = onAPIError
        self.now = now
    }

    var today: String { MealsCopy.localDay(now()) }

    /// The link as typed or pasted, with https added when it has no scheme.
    var normalizedURL: String? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let full = text.contains("://") ? text : "https://" + text
        guard let parsed = URL(string: full), ["http", "https"].contains(parsed.scheme), parsed.host() != nil
        else { return nil }
        return full
    }

    /// The dish saving fills in: the one this sheet was opened for, else a library dish of the
    /// same name.
    var target: MealsSeasonPick? {
        if let fillsIn { return fillsIn }
        if case .found(let found) = preview { return found.existing }
        return nil
    }

    var canSave: Bool {
        if case .found = preview, !isSaving { return true }
        return false
    }

    func findRecipe() async {
        guard let link = normalizedURL, link != previewedURL || !isFound else { return }
        previewedURL = link
        preview = .loading
        do {
            let found = try await client.previewLink(url: link)
            guard previewedURL == link else { return }
            preview = .found(found)
        } catch {
            guard previewedURL == link, !mealsRecipeIsCancellation(error) else { return }
            onAPIError(error)
            preview = .failed(Self.reason(error))
        }
    }

    /// "Any time" clears the seasons; a season clears "Any time".
    func toggle(season: String) {
        if seasons.contains(season) { seasons.remove(season) } else { seasons.insert(season) }
    }

    func toggle(occasion: String) {
        if occasions.contains(occasion) { occasions.remove(occasion) } else { occasions.insert(occasion) }
    }

    var request: MealsLinkRequest? {
        guard case .found(let found) = preview else { return nil }
        return MealsLinkRequest(url: found.source.isEmpty ? (normalizedURL ?? url) : found.source,
                                slug: target?.slug, kind: side ? "side" : "main",
                                seasons: MealsCopy.seasons.filter(seasons.contains),
                                occasions: occasions.sorted(), ateOn: ateTonight ? today : nil, today: today)
    }

    /// Saves the recipe; answers its page, or nil when the save failed.
    func save() async -> MealsRecipe? {
        guard let request, !isSaving else { return nil }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            return try await client.saveLink(request)
        } catch {
            if !mealsRecipeIsCancellation(error) {
                onAPIError(error)
                saveError = Self.reason(error)
            }
            return nil
        }
    }

    private var isFound: Bool {
        if case .found = preview { return true }
        return false
    }

    /// The server's reason ("no recipe found on that page: …") when it gave one.
    private static func reason(_ error: Error) -> String {
        if case .http(400, let body)? = error as? APIError, let data = body?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty {
            return message.prefix(1).uppercased() + message.dropFirst() + "."
        }
        return "Couldn't read that link. Check it and try again."
    }
}

private func mealsRecipeIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}
