import SwiftData
import XCTest
import Foundation
@testable import HermesMobile

@MainActor
final class BrainViewModelTests: XCTestCase {
    // MARK: - Frontmatter (shared with the Daily Deck journal reader)

    func testFrontmatterIsStrippedFromTheNote() {
        let note = "---\ntype: person\nname: Kevin Tam\n---\n# Kevin Tam\n\nRelationship: Friend\n"
        XCTAssertEqual(DailyDeckJournal.strippingFrontmatter(note), "# Kevin Tam\n\nRelationship: Friend")
    }

    func testNoteWithoutFrontmatterIsUnchanged() {
        let note = "# James Lilley\n\n---\n\nNotes"
        XCTAssertEqual(DailyDeckJournal.strippingFrontmatter(note), note)
    }

    // MARK: - Library view models

    private func makeCache(server: URL = URL(string: "https://a.example")!) throws -> BrainCacheHandle {
        let container = try ModelContainer(
            for: CachedBrainEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return BrainCacheHandle(server: server, context: ModelContext(container))
    }

    private let samplePage = BrainPage(item: BrainItem(module: .wiki, id: "p1", title: "Page One"), content: "Body")

    func testSearchDebouncesAndCancelsStaleQueries() async {
        let client = FakeBrainClient()
        let viewModel = BrainSearchViewModel(client: client, debounce: .zero)
        viewModel.query = "ma"
        viewModel.query = "mar"
        viewModel.query = "marc"
        await viewModel.settled()
        XCTAssertEqual(client.searchQueries, ["marc"])
        XCTAssertNotNil(viewModel.result)
        XCTAssertFalse(viewModel.isSearching)
    }

    func testShortQueryMakesNoCall() async {
        let client = FakeBrainClient()
        let viewModel = BrainSearchViewModel(client: client, debounce: .zero)
        viewModel.query = "marc"
        await viewModel.settled()
        viewModel.query = " m "
        await viewModel.settled()
        XCTAssertEqual(client.searchQueries, ["marc"])
        XCTAssertNil(viewModel.result)
        XCTAssertFalse(viewModel.isSearching)
    }

    func testPageFallsBackToCacheWhenOffline() async throws {
        let cache = try makeCache()
        try BrainCache.store(samplePage, server: cache.server, kind: "page", id: "p1", in: try XCTUnwrap(cache.context))
        let client = FakeBrainClient()
        client.pageResult = .failure(URLError(.notConnectedToInternet))
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: cache, onAPIError: { _ in })
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(samplePage))
        XCTAssertTrue(viewModel.isShowingCachedCopy)
        XCTAssertEqual(viewModel.page, samplePage)
    }

    func testPageOfflineWithoutCacheFails() async throws {
        let client = FakeBrainClient()
        client.pageResult = .failure(URLError(.notConnectedToInternet))
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: try makeCache(), onAPIError: { _ in })
        await viewModel.load()
        guard case .failed = viewModel.state else { return XCTFail("Expected failure, got \(viewModel.state)") }
    }

    func testSuccessfulPageIsCachedAndNotMarkedCached() async throws {
        let cache = try makeCache()
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: cache, onAPIError: { _ in })
        await viewModel.load()
        XCTAssertFalse(viewModel.isShowingCachedCopy)
        XCTAssertEqual(try BrainCache.load(BrainPage.self, server: cache.server, kind: "page", id: "p1", in: try XCTUnwrap(cache.context)), samplePage)
    }

    func testPage404SetsMissing() async {
        let client = FakeBrainClient()
        client.pageResult = .failure(APIError.http(statusCode: 404, body: nil))
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        XCTAssertTrue(viewModel.isMissing)
        XCTAssertEqual(viewModel.state, .failed("This page moved or was removed"))
    }

    func testModules404IsUnavailable() async {
        let client = FakeBrainClient()
        client.modulesResult = .failure(APIError.http(statusCode: 404, body: nil))
        let viewModel = BrainHomeViewModel(client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .unavailable)
    }

    /// Home refreshes on every appear; a reload over shown modules must never flash a spinner.
    func testHomeReloadWithModulesNeverPassesThroughLoading() async {
        let client = FakeBrainClient()
        let first = [BrainModule(id: .wiki, title: "Wiki", count: 1)]
        let second = [BrainModule(id: .wiki, title: "Wiki", count: 2)]
        client.modulesResult = .success(first)
        let viewModel = BrainHomeViewModel(client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(first))

        let gate = Gate()
        client.modulesGate = gate
        client.modulesResult = .success(second)
        let reload = Task { await viewModel.load() }
        await gate.waitEntered()
        XCTAssertEqual(viewModel.state, .loaded(first))
        XCTAssertEqual(viewModel.modules, first)
        gate.open()
        await reload.value
        XCTAssertEqual(viewModel.state, .loaded(second))
    }

    func testSearchResumeRerunsTheCurrentQueryAfterCancel() async {
        let client = FakeBrainClient()
        let viewModel = BrainSearchViewModel(client: client, debounce: .zero)
        viewModel.query = "marcus"
        viewModel.cancel()
        XCTAssertFalse(viewModel.isSearching)
        viewModel.resume()
        XCTAssertTrue(viewModel.isSearching)
        await viewModel.settled()
        XCTAssertEqual(client.searchQueries, ["marcus"])
        XCTAssertNotNil(viewModel.result)

        viewModel.query = "m"
        viewModel.resume()
        XCTAssertFalse(viewModel.isSearching)
    }

    func testGraphFailureDoesNotFailPage() async {
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        client.graphResult = .failure(URLError(.timedOut))
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(samplePage))
        XCTAssertNil(viewModel.graph)
    }

    func testTagSelectionReloadsWithTag() async {
        let client = FakeBrainClient()
        let viewModel = BrainListViewModel(module: .wiki, client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        viewModel.selectedTag = "swift"
        await viewModel.settled()
        XCTAssertEqual(client.listCalls.map(\.tag), [nil, "swift"])
        XCTAssertEqual(client.listCalls.map(\.cursor), [nil, nil])
    }

    func testLoadMoreAppendsUsingCursorAndStopsWhenNil() async {
        let client = FakeBrainClient()
        client.listResults = [
            .success(BrainList(items: [BrainItem(module: .wiki, id: "a")], nextCursor: 20)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "b")], nextCursor: nil)),
        ]
        let viewModel = BrainListViewModel(module: .wiki, client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        await viewModel.loadMore()
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.list?.items.map(\.id), ["a", "b"])
        XCTAssertEqual(client.listCalls.map(\.cursor), [nil, 20])
    }

    func testLoadMoreFailureIsFlaggedAndClearedByRetryOrReload() async {
        let client = FakeBrainClient()
        let first = BrainList(items: [BrainItem(module: .highlights, id: "a")], nextCursor: 20)
        client.listResults = [
            .success(first),
            .failure(URLError(.timedOut)),
            .success(BrainList(items: [BrainItem(module: .highlights, id: "b")], nextCursor: 40)),
            .failure(URLError(.timedOut)),
            .success(first),
        ]
        let viewModel = BrainListViewModel(module: .highlights, client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        XCTAssertFalse(viewModel.loadMoreFailed)

        await viewModel.loadMore()
        XCTAssertTrue(viewModel.loadMoreFailed, "a failing page is flagged")
        XCTAssertFalse(viewModel.isLoadingMore)

        await viewModel.loadMore()
        XCTAssertFalse(viewModel.loadMoreFailed, "a later success clears it")
        XCTAssertEqual(viewModel.list?.items.map(\.id), ["a", "b"])

        await viewModel.loadMore()
        XCTAssertTrue(viewModel.loadMoreFailed)
        await viewModel.load()
        XCTAssertFalse(viewModel.loadMoreFailed, "a reload clears it")
        XCTAssertEqual(client.listCalls.map(\.cursor), [nil, 20, 20, 40, nil])
    }

    func testPage404WithCachedCopyStillShowsIt() async throws {
        let cache = try makeCache()
        try BrainCache.store(samplePage, server: cache.server, kind: "page", id: "p1", in: try XCTUnwrap(cache.context))
        let client = FakeBrainClient()
        client.pageResult = .failure(APIError.http(statusCode: 404, body: nil))
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: cache, onAPIError: { _ in })
        await viewModel.load()
        XCTAssertTrue(viewModel.isMissing)
        XCTAssertEqual(viewModel.state, .loaded(samplePage))
        XCTAssertTrue(viewModel.isShowingCachedCopy)
    }

    func testLoadMoreDuringTagChangeCannotOverwriteTheNewList() async {
        let client = FakeBrainClient()
        client.listResults = [
            .success(BrainList(items: [BrainItem(module: .wiki, id: "a")], nextCursor: 20)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "x1")], nextCursor: nil)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "stale")], nextCursor: nil)),
        ]
        let viewModel = BrainListViewModel(module: .wiki, client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        viewModel.selectedTag = "x"
        await viewModel.loadMore()
        await viewModel.settled()
        XCTAssertEqual(viewModel.list?.items.map(\.id), ["x1"])
        XCTAssertEqual(client.listCalls.map(\.cursor), [nil, nil])
    }

    func testCancelledLoadMoreDoesNotWedgeLaterLoadMore() async {
        let client = FakeBrainClient()
        client.listResults = [
            .success(BrainList(items: [BrainItem(module: .wiki, id: "a")], nextCursor: 20)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "b")], nextCursor: nil)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "c")], nextCursor: nil)),
        ]
        let viewModel = BrainListViewModel(module: .wiki, client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        let gate = Gate()
        client.pagedListGate = gate
        let task = Task { await viewModel.loadMore() }
        await gate.waitEntered()
        task.cancel()
        gate.open()
        await task.value
        client.pagedListGate = nil
        await viewModel.loadMore()
        XCTAssertEqual(client.listCalls.map(\.cursor), [nil, 20, 20])
        XCTAssertEqual(viewModel.list?.items.map(\.id), ["a", "c"])
    }

    func testLoadMoreAlreadyInFlightWhenTagChangesCannotOverwrite() async {
        let client = FakeBrainClient()
        client.listResults = [
            .success(BrainList(items: [BrainItem(module: .wiki, id: "a")], nextCursor: 20)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "stale")], nextCursor: nil)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "x1")], nextCursor: nil)),
        ]
        let viewModel = BrainListViewModel(module: .wiki, client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        let gate = Gate()
        client.pagedListGate = gate
        let task = Task { await viewModel.loadMore() }
        await gate.waitEntered()
        viewModel.selectedTag = "x"
        await viewModel.settled()
        gate.open()
        await task.value
        XCTAssertEqual(viewModel.list?.items.map(\.id), ["x1"])
    }

    func testCancelledFirstLoadDoesNotWedgeLoading() async {
        let client = FakeBrainClient()
        client.listResults = [
            .success(BrainList(items: [BrainItem(module: .wiki, id: "a")], nextCursor: 20)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "a")], nextCursor: 20)),
            .success(BrainList(items: [BrainItem(module: .wiki, id: "b")], nextCursor: nil)),
        ]
        let viewModel = BrainListViewModel(module: .wiki, client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        let gate = Gate()
        client.firstListGate = gate
        let task = Task { await viewModel.load() }
        await gate.waitEntered()
        task.cancel()
        gate.open()
        await task.value
        XCTAssertFalse(viewModel.isLoading)
        client.firstListGate = nil
        await viewModel.load()
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.list?.items.map(\.id), ["a", "b"])
    }

    func testSearchFailureClearsResultAndFlagsFailure() async {
        let client = FakeBrainClient()
        client.failingSearches = ["mark"]
        var reported = 0
        let viewModel = BrainSearchViewModel(client: client, debounce: .zero, onAPIError: { _ in reported += 1 })
        viewModel.query = "marc"
        await viewModel.settled()
        XCTAssertNotNil(viewModel.result)
        XCTAssertFalse(viewModel.didFail)
        viewModel.query = "mark"
        await viewModel.settled()
        XCTAssertNil(viewModel.result)
        XCTAssertTrue(viewModel.didFail)
        XCTAssertEqual(reported, 1)
        viewModel.query = "mar"
        XCTAssertFalse(viewModel.didFail)
    }

    func testPagePublishesBeforeGraphArrives() async {
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        let graph = BrainGraph(nodes: [BrainGraphNode(module: .wiki, id: "p1")])
        client.graphResult = .success(graph)
        let gate = Gate()
        client.graphGate = gate
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        let published = expectation(description: "page published")
        withObservationTracking {
            _ = viewModel.page
        } onChange: {
            // onChange fires before the write lands; hop so the assertions see it.
            Task { @MainActor in published.fulfill() }
        }
        let task = Task { await viewModel.load() }
        await fulfillment(of: [published], timeout: 10)
        XCTAssertEqual(viewModel.state, .loaded(samplePage))
        XCTAssertNil(viewModel.graph, "graph is still suspended")
        gate.open()
        await task.value
        XCTAssertEqual(viewModel.graph, graph)
    }
}

extension BrainViewModelTests {
    func testLoadGraphIfNeededRefetchesALostGraph() async {
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        client.graphResult = .failure(CancellationError())
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        XCTAssertNotNil(viewModel.page)
        XCTAssertNil(viewModel.graph, "the graph was lost")
        let graph = BrainGraph(nodes: [BrainGraphNode(module: .wiki, id: "p1"), BrainGraphNode(module: .wiki, id: "p2")])
        client.graphResult = .success(graph)
        await viewModel.loadGraphIfNeeded()
        XCTAssertEqual(viewModel.graph, graph)
        XCTAssertEqual(client.graphCalls, 2)
        await viewModel.loadGraphIfNeeded()
        XCTAssertEqual(client.graphCalls, 2, "a graph already shown is not fetched again")
    }

    func testLoadGraphIfNeededDoesNothingWithoutAPage() async {
        let client = FakeBrainClient()
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.loadGraphIfNeeded()
        XCTAssertEqual(client.graphCalls, 0)
        XCTAssertNil(viewModel.graph)
    }

    func testLoadGraphIfNeededFailureLeavesThePageAlone() async {
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        client.graphResult = .failure(URLError(.timedOut))
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        await viewModel.loadGraphIfNeeded()
        XCTAssertNil(viewModel.graph)
        XCTAssertEqual(viewModel.state, .loaded(samplePage))
    }

    func testStaleGraphRefetchIsDroppedWhenALoadStarts() async {
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        client.graphResult = .failure(URLError(.timedOut))
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        let stale = BrainGraph(nodes: [BrainGraphNode(module: .wiki, id: "stale")])
        client.graphResult = .success(stale)
        let gate = Gate()
        client.graphGate = gate
        let refetch = Task { await viewModel.loadGraphIfNeeded() }
        await gate.waitEntered()
        // A newer load starts (and its own graph fetch fails) while the refetch is suspended.
        client.graphGate = nil
        client.graphResult = .failure(URLError(.timedOut))
        await viewModel.load()
        gate.open()
        await refetch.value
        XCTAssertNil(viewModel.graph, "the older refetch must not land after a newer load")
    }
}

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var opened = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var openWaiter: CheckedContinuation<Void, Never>?

    /// Called by the fake: marks the request as started and suspends until `open()`.
    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entered = true
            let waiter = enteredWaiter
            enteredWaiter = nil
            if opened { lock.unlock(); waiter?.resume(); continuation.resume(); return }
            openWaiter = continuation
            lock.unlock()
            waiter?.resume()
        }
    }

    func waitEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered { lock.unlock(); continuation.resume(); return }
            enteredWaiter = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let waiter = openWaiter
        openWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

final class FakeBrainClient: BrainDataClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _searchQueries: [String] = []
    private var _listCalls: [(tag: String?, cursor: Int?)] = []
    var modulesResult: Result<[BrainModule], Error> = .success([])
    var pageResult: Result<BrainPage, Error> = .failure(URLError(.badServerResponse))
    var graphResult: Result<BrainGraph, Error> = .success(BrainGraph())
    var listResults: [Result<BrainList, Error>] = []
    var failingSearches: Set<String> = []
    var graphGate: Gate?
    private var _graphCalls = 0
    var graphCalls: Int { lock.withLock { _graphCalls } }
    var pagedListGate: Gate?
    var modulesGate: Gate?
    var firstListGate: Gate?

    var searchQueries: [String] { lock.withLock { _searchQueries } }
    var listCalls: [(tag: String?, cursor: Int?)] { lock.withLock { _listCalls } }

    func modules() async throws -> [BrainModule] {
        let result = modulesResult
        if let gate = modulesGate { await gate.pass() }
        return try result.get()
    }
    func list(module: BrainModuleID, tag: String?, cursor: Int?) async throws -> BrainList {
        let next: Result<BrainList, Error>? = lock.withLock {
            _listCalls.append((tag, cursor))
            return listResults.isEmpty ? nil : listResults.removeFirst()
        }
        if cursor != nil, let gate = pagedListGate { await gate.pass() }
        if cursor == nil, let gate = firstListGate { await gate.pass() }
        return try (next ?? .success(BrainList())).get()
    }
    func page(module: BrainModuleID, id: String) async throws -> BrainPage { try pageResult.get() }
    func search(query: String, module: BrainModuleID?) async throws -> BrainSearchResult {
        lock.withLock { _searchQueries.append(query) }
        if failingSearches.contains(query) { throw URLError(.timedOut) }
        return BrainSearchResult()
    }
    func graph(module: BrainModuleID, id: String) async throws -> BrainGraph {
        lock.withLock { _graphCalls += 1 }
        if let gate = graphGate { await gate.pass() }
        return try graphResult.get()
    }
}
