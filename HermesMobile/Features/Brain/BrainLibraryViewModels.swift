import Foundation
import Observation
import SwiftData

/// Where a Brain screen keeps its offline copy: the active server plus a SwiftData
/// context. A nil context turns caching off (tests, previews). Cache failures never
/// surface; a missing or unreadable copy is just a miss.
@MainActor
struct BrainCacheHandle {
    let server: URL
    let context: ModelContext?

    func store<T: Encodable>(_ value: T, kind: String, id: String) {
        guard let context else { return }
        try? BrainCache.store(value, server: server, kind: kind, id: id, in: context)
    }

    func load<T: Decodable>(_ type: T.Type, kind: String, id: String) -> T? {
        guard let context else { return nil }
        return (try? BrainCache.load(type, server: server, kind: kind, id: id, in: context)) ?? nil
    }
}

/// How a failed fetch is treated: a 404 means the server has no such Brain
/// content; anything else is a network-style failure that may fall back to the cache.
private func brainIsNotFound(_ error: Error) -> Bool {
    if let apiError = error as? APIError { return apiError.isNotFound }
    return false
}

/// The module grid.
@MainActor
@Observable
final class BrainHomeViewModel {
    private(set) var state: BrainLoadState<[BrainModule]> = .loading
    private(set) var modules: [BrainModule] = []
    /// The daily deck. Best effort: empty on a server without the home route, and a failed
    /// refresh keeps what was shown.
    private(set) var home = BrainHome()
    /// Each bite's words, parsed once per deck: `CardStack` rebuilds its top cards on every drag frame.
    private(set) var biteTexts: [BrainBite.ID: BrainBiteText] = [:]
    private(set) var isShowingCachedCopy = false
    /// The deck couldn't load and none is shown, so the review says so instead of "Nothing to review".
    private(set) var deckFailed = false
    /// The last "Ten more" failed; the summary card says so, and the button tries again.
    private(set) var dealMoreFailed = false
    /// When modules and the deck last both landed; `refreshIfStale` skips the network until it ages.
    private var lastLoaded: Date?

    /// The deck's pages: the bites, then a summary once there are any.
    var reviewPages: [BrainReviewPage] {
        home.bites.isEmpty ? [] : home.bites.map(BrainReviewPage.bite) + [.summary]
    }

    /// The page the review pager shows. Setting it saves the position for this server and day.
    var reviewIndex = 0 {
        didSet {
            guard reviewIndex != oldValue else { return }
            persistPosition()
        }
    }

    private let client: any BrainDataClient
    private let cache: BrainCacheHandle
    private let onAPIError: (Error) -> Void
    private let reviewStore: BrainReviewStore
    private let today: () -> String
    /// The batch `home` holds, which is what the saved position refers to.
    private var currentBatch = 0
    /// The day the shown batch was loaded for. A deck left open overnight keeps saving under it.
    private(set) var deckDay: String?

    /// True once a deck is on screen and the day has moved on: the screen should `load()` again.
    var needsNewDay: Bool { deckDay.map { $0 != today() } ?? false }

    init(client: any BrainDataClient, cache: BrainCacheHandle, onAPIError: @escaping (Error) -> Void = { _ in },
         reviewStore: BrainReviewStore = BrainReviewStore(), today: @escaping () -> String = BrainReviewStore.today) {
        self.client = client
        self.cache = cache
        self.onAPIError = onAPIError
        self.reviewStore = reviewStore
        self.today = today
    }

    /// Bumped by every `load()` and `dealMore()`, so an older result never overwrites a newer one.
    private var generation = 0

    /// The saved position, if the user already started `day`'s deck.
    private func saved(on day: String) -> BrainReviewPosition? {
        guard let saved = reviewStore.position(for: cache.server), saved.day == day else { return nil }
        return saved
    }

    private func persistPosition() {
        reviewStore.save(BrainReviewPosition(day: deckDay ?? today(), batch: currentBatch, index: reviewIndex), for: cache.server)
    }

    /// Shows `deck` as `batch` of `day`, landing on `index` or the nearest page that exists.
    private func show(_ deck: BrainHome, day: String, batch: Int, index: Int) {
        if deck != home {
            biteTexts = Dictionary(deck.bites.map { ($0.id, BrainBiteText(bite: $0)) }, uniquingKeysWith: { first, _ in first })
        }
        home = deck
        deckDay = day
        currentBatch = batch
        reviewIndex = min(max(index, 0), max(reviewPages.count - 1, 0))
    }

    private static func attempt<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// What the home's appear calls: a full `load()` once the last one is a few minutes old or
    /// the day has moved on, else just the review position, which the Review screen may have moved.
    func refreshIfStale(now: Date = .now, maxAge: TimeInterval = 300) async {
        if let lastLoaded, now.timeIntervalSince(lastLoaded) < maxAge, !needsNewDay {
            syncPosition()
            return
        }
        await load()
    }

    /// Picks up the position the Review screen saved for the shown deck.
    func syncPosition() {
        guard let day = deckDay, let saved = saved(on: day), saved.batch == currentBatch else { return }
        reviewIndex = min(max(saved.index, 0), max(reviewPages.count - 1, 0))
    }

    func load() async {
        generation += 1
        let token = generation
        if modules.isEmpty { state = .loading }
        let day = today()
        let batch = saved(on: day)?.batch ?? 0
        if home.isEmpty, let cached = cache.load(BrainHome.self, kind: "home", id: "\(day)-\(batch)") {
            show(cached, day: day, batch: batch, index: saved(on: day)?.index ?? 0)
        }
        let client = self.client
        async let fetchedHome = Self.attempt { try await client.home(batch: batch) }
        var modulesLanded = false
        do {
            let fetched = try await client.modules()
            guard !Task.isCancelled, token == generation else { return }
            modules = fetched
            state = .loaded(fetched)
            isShowingCachedCopy = false
            modulesLanded = true
            cache.store(fetched, kind: "modules", id: "")
        } catch is CancellationError {
            return  // The screen went away; nothing to update.
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            if brainIsNotFound(error) {
                state = .unavailable
            } else if let cached = cache.load([BrainModule].self, kind: "modules", id: "") {
                modules = cached
                state = .loaded(cached)
                isShowingCachedCopy = true
            } else {
                state = .failed(error.localizedDescription)
            }
            onAPIError(error)
        }
        // The deck stands on its own: it shows even when the module list failed.
        let homeResult = await fetchedHome
        guard !Task.isCancelled, token == generation else { return }
        switch homeResult {
        case .success(let loadedHome):
            // Read the position now, not before the fetch, so a swipe made while it ran wins.
            show(loadedHome, day: day, batch: batch, index: saved(on: day)?.index ?? 0)
            cache.store(loadedHome, kind: "home", id: "\(day)-\(batch)")
            deckFailed = false
            if modulesLanded { lastLoaded = .now }
        case .failure(let error):
            // A server without the home route has no deck to miss; a failure with a deck shown keeps it.
            deckFailed = !brainIsNotFound(error) && !(error is CancellationError) && home.isEmpty
        }
    }

    /// "Deal me more": the next batch of ten, from the first page. A failed fetch keeps the
    /// current batch and position, and says so on the summary card.
    func dealMore() async {
        generation += 1
        let token = generation
        let batch = currentBatch + 1
        let day = deckDay ?? today()
        dealMoreFailed = false
        do {
            let more = try await client.home(batch: batch)
            guard !Task.isCancelled, token == generation else { return }
            show(more, day: day, batch: batch, index: 0)
            persistPosition()
            cache.store(more, kind: "home", id: "\(day)-\(batch)")
        } catch {
            guard !Task.isCancelled, token == generation, !(error is CancellationError) else { return }
            dealMoreFailed = true
            onAPIError(error)
        }
    }
}

/// One module's browsable list, with tag filtering and cursor paging.
@MainActor
@Observable
final class BrainListViewModel {
    let module: BrainModuleID
    private(set) var state: BrainLoadState<BrainList> = .loading
    private(set) var list: BrainList?
    private(set) var isShowingCachedCopy = false
    private(set) var isLoadingMore = false
    /// True while a first-page load is in flight; `loadMore` waits it out.
    private(set) var isLoading = false
    /// True when the last `loadMore` failed; cleared by the next attempt, `load()` or a tag change.
    private(set) var loadMoreFailed = false
    /// Counts finished first-page loads, so background paging that a reload cut short can restart.
    private(set) var loads = 0

    /// Setting a different tag drops the paging state and reloads.
    var selectedTag: String? {
        didSet {
            guard selectedTag != oldValue else { return }
            tagReloadTask?.cancel()
            // Drop the old tag's list and cursor so nothing can page or merge into it.
            generation += 1
            list = nil
            state = .loading
            isShowingCachedCopy = false
            isLoadingMore = false
            loadMoreFailed = false
            isLoading = true
            tagReloadTask = Task { [weak self] in await self?.load() }
        }
    }

    private let client: any BrainDataClient
    private let cache: BrainCacheHandle
    private let onAPIError: (Error) -> Void
    private var tagReloadTask: Task<Void, Never>?
    /// Bumped by every `load()`, so a superseded load or page never writes back.
    private var generation = 0

    init(module: BrainModuleID, client: any BrainDataClient, cache: BrainCacheHandle,
         onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.module = module
        self.client = client
        self.cache = cache
        self.onAPIError = onAPIError
    }

    /// Waits for a reload started by changing `selectedTag`.
    func settled() async { await tagReloadTask?.value }

    private var cacheKind: String { "list:\(module.rawValue)" }

    func load() async {
        generation += 1
        let token = generation
        isLoadingMore = false
        loadMoreFailed = false
        isLoading = true
        defer { if token == generation { isLoading = false } }
        let tag = selectedTag
        if list == nil { state = .loading }
        do {
            let fetched = try await client.list(module: module, tag: tag, cursor: nil)
            guard !Task.isCancelled, token == generation else { return }
            isLoading = false
            apply(fetched, cached: false)
            cache.store(fetched, kind: cacheKind, id: tag ?? "")
        } catch is CancellationError {
            // The screen went away; nothing to update.
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            isLoading = false
            if list != nil, !isShowingCachedCopy, !brainIsNotFound(error) {
                // A failed refresh keeps the pages already shown rather than dropping to the cache.
                loads += 1
            } else if brainIsNotFound(error) {
                state = .unavailable
            } else if let cached = cache.load(BrainList.self, kind: cacheKind, id: tag ?? "") {
                apply(cached, cached: true)
            } else {
                state = .failed(error.localizedDescription)
            }
            onAPIError(error)
        }
    }

    /// Appends the next page; a no-op without a cursor, while a page is in flight,
    /// or while a first-page load is running.
    func loadMore() async {
        guard !isLoading, !isLoadingMore, !isShowingCachedCopy,
              let cursor = list?.nextCursor else { return }
        let token = generation
        isLoadingMore = true
        loadMoreFailed = false
        defer { if token == generation { isLoadingMore = false } }
        do {
            let page = try await client.list(module: module, tag: selectedTag, cursor: cursor)
            guard !Task.isCancelled, token == generation, let current = list else { return }
            let merged = Self.merge(current, page)
            list = merged
            state = .loaded(merged)
        } catch {
            guard token == generation, !(error is CancellationError), !Task.isCancelled else { return }
            loadMoreFailed = true
            onAPIError(error)
        }
    }

    private func apply(_ value: BrainList, cached: Bool) {
        list = value
        state = .loaded(value)
        isShowingCachedCopy = cached
        loads += 1
    }

    private static func merge(_ first: BrainList, _ next: BrainList) -> BrainList {
        var groups = first.groups
        for group in next.groups {
            if let index = groups.firstIndex(where: { $0.title == group.title }) {
                groups[index] = BrainGroup(title: group.title, ids: groups[index].ids + group.ids,
                                           total: group.total ?? groups[index].total)
            } else {
                groups.append(group)
            }
        }
        return BrainList(
            items: first.items + next.items,
            tags: first.tags.isEmpty ? next.tags : first.tags,
            groups: groups,
            nextCursor: next.nextCursor
        )
    }
}

/// Debounced cross-module search. Each query change cancels the previous task, so a
/// stale response can never replace a newer one.
@MainActor
@Observable
final class BrainSearchViewModel {
    private(set) var result: BrainSearchResult?
    private(set) var isSearching = false
    private(set) var didFail = false

    var query = "" {
        didSet { if query != oldValue { restart() } }
    }
    var moduleFilter: BrainModuleID? {
        didSet { if moduleFilter != oldValue { restart() } }
    }

    private let client: any BrainDataClient
    private let debounce: Duration
    private let onAPIError: (Error) -> Void
    private var searchTask: Task<Void, Never>?

    init(client: any BrainDataClient, debounce: Duration = .milliseconds(250),
         onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.debounce = debounce
        self.onAPIError = onAPIError
    }

    /// Waits for the current search, if any.
    func settled() async { await searchTask?.value }

    /// Cancels in-flight work; call when the screen disappears.
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    /// Re-runs the current query (if it is long enough); call when the screen
    /// reappears after `cancel()`. Any shown result stays until the new one lands.
    func resume() { restart() }

    private func restart() {
        searchTask?.cancel()
        didFail = false
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchTask = nil
            result = nil
            isSearching = false
            return
        }
        isSearching = true
        let filter = moduleFilter
        searchTask = Task { [weak self, client, debounce, onAPIError] in
            do {
                try await Task.sleep(for: debounce)
                try Task.checkCancellation()
                let found = try await client.search(query: trimmed, module: filter)
                guard !Task.isCancelled, let self else { return }
                self.result = found
                self.isSearching = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.result = nil
                self.didFail = true
                self.isSearching = false
                onAPIError(error)
            }
        }
    }
}

/// One Brain page, optionally placed in a hub the reader is paging through.
@MainActor
@Observable
final class BrainPageViewModel {
    let module: BrainModuleID
    let id: String
    /// The hub the reader was paging through, so the server keeps the page in it.
    let hub: String?
    private(set) var state: BrainLoadState<BrainPage> = .loading
    private(set) var page: BrainPage? {
        // A person page is laid out and parsed here, once per load, not on every reader render.
        didSet { person = page.flatMap { page in page.person.map { BrainPersonPage(page: page, person: $0, today: Date()) } } }
    }
    private(set) var person: BrainPersonPage?
    private(set) var isShowingCachedCopy = false
    private(set) var isMissing = false

    private let client: any BrainDataClient
    private let cache: BrainCacheHandle
    private let onAPIError: (Error) -> Void

    init(module: BrainModuleID, id: String, hub: String? = nil, client: any BrainDataClient,
         cache: BrainCacheHandle, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.module = module
        self.id = id
        self.hub = hub
        self.client = client
        self.cache = cache
        self.onAPIError = onAPIError
    }

    /// The same client and cache for another page in the hub (the pager's next or previous).
    func sibling(module: BrainModuleID, id: String, hub: String) -> BrainPageViewModel {
        BrainPageViewModel(module: module, id: id, hub: hub, client: client, cache: cache, onAPIError: onAPIError)
    }

    /// The pager's next or previous page, loaded; nil when it couldn't load (offline with no
    /// saved copy, or gone), so the reader keeps the page it is on instead of an error screen.
    func loadedSibling(module: BrainModuleID, id: String, hub: String) async -> BrainPageViewModel? {
        let next = sibling(module: module, id: id, hub: hub)
        await next.load()
        return next.page == nil ? nil : next
    }

    /// Bumped by every `load()`, so an older failure never overwrites a newer success.
    private var generation = 0

    /// Logs a catch-up to this person, then reloads the page so the note, "seen" and the rhythm show
    /// it. Throws when the server didn't write it; the caller keeps the words so nothing is lost.
    func logCatchUp(_ text: String, kind: BrainPersonLogRequest.Kind, today: Date = Date()) async throws -> BrainPersonLogResult {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = calendar.dateComponents([.year, .month, .day], from: today)
        let date = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let result = try await client.logPerson(BrainPersonLogRequest(id: id, text: text, kind: kind, date: date))
        await load()
        return result
    }

    func load() async {
        generation += 1
        let token = generation
        if page == nil { state = .loading }
        do {
            let fetched = try await client.page(module: module, id: id, hub: hub)
            guard !Task.isCancelled, token == generation else { return }
            page = fetched
            state = .loaded(fetched)
            isShowingCachedCopy = false
            isMissing = false
            cache.store(fetched, kind: "page", id: id)
        } catch is CancellationError {
            // The screen went away; nothing to update.
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            let notFound = brainIsNotFound(error)
            isMissing = notFound
            if let cached = cache.load(BrainPage.self, kind: "page", id: id) {
                page = cached
                state = .loaded(cached)
                isShowingCachedCopy = true
            } else if notFound {
                state = .failed(String(localized: "This page moved or was removed"))
            } else {
                state = .failed(error.localizedDescription)
            }
            onAPIError(error)
        }
    }
}
