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
    private(set) var isShowingCachedCopy = false

    private let client: any BrainDataClient
    private let cache: BrainCacheHandle
    private let onAPIError: (Error) -> Void

    init(client: any BrainDataClient, cache: BrainCacheHandle, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.cache = cache
        self.onAPIError = onAPIError
    }

    /// Bumped by every `load()`, so an older failure never overwrites a newer success.
    private var generation = 0

    func load() async {
        generation += 1
        let token = generation
        if modules.isEmpty { state = .loading }
        do {
            let fetched = try await client.modules()
            guard !Task.isCancelled, token == generation else { return }
            modules = fetched
            state = .loaded(fetched)
            isShowingCachedCopy = false
            cache.store(fetched, kind: "modules", id: "")
        } catch is CancellationError {
            // The screen went away; nothing to update.
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
        isLoading = true
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
            if brainIsNotFound(error) {
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
        defer { if token == generation { isLoadingMore = false } }
        do {
            let page = try await client.list(module: module, tag: selectedTag, cursor: cursor)
            guard !Task.isCancelled, token == generation, let current = list else { return }
            let merged = Self.merge(current, page)
            list = merged
            state = .loaded(merged)
        } catch {
            guard token == generation, !(error is CancellationError), !Task.isCancelled else { return }
            onAPIError(error)
        }
    }

    private func apply(_ value: BrainList, cached: Bool) {
        list = value
        state = .loaded(value)
        isShowingCachedCopy = cached
    }

    private static func merge(_ first: BrainList, _ next: BrainList) -> BrainList {
        var groups = first.groups
        for group in next.groups {
            if let index = groups.firstIndex(where: { $0.title == group.title }) {
                groups[index] = BrainGroup(title: group.title, ids: groups[index].ids + group.ids)
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

/// One Brain page, plus its link graph (best effort).
@MainActor
@Observable
final class BrainPageViewModel {
    let module: BrainModuleID
    let id: String
    private(set) var state: BrainLoadState<BrainPage> = .loading
    private(set) var page: BrainPage?
    private(set) var graph: BrainGraph?
    private(set) var isShowingCachedCopy = false
    private(set) var isMissing = false

    private let client: any BrainDataClient
    private let cache: BrainCacheHandle
    private let onAPIError: (Error) -> Void

    init(module: BrainModuleID, id: String, client: any BrainDataClient, cache: BrainCacheHandle,
         onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.module = module
        self.id = id
        self.client = client
        self.cache = cache
        self.onAPIError = onAPIError
    }

    /// Bumped by every `load()`, so an older failure never overwrites a newer success.
    private var generation = 0

    func load() async {
        generation += 1
        let token = generation
        if page == nil { state = .loading }
        async let fetchedGraph: BrainGraph? = try? client.graph(module: module, id: id)
        do {
            let fetched = try await client.page(module: module, id: id)
            guard !Task.isCancelled, token == generation else { return }
            page = fetched
            state = .loaded(fetched)
            isShowingCachedCopy = false
            isMissing = false
            cache.store(fetched, kind: "page", id: id)
            // The graph is best effort and never holds the page back; a failed
            // refresh keeps whatever graph was already shown.
            if let loadedGraph = await fetchedGraph, !Task.isCancelled, token == generation {
                graph = loadedGraph
            }
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
