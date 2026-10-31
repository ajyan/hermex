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

    func testLoggingACatchUpWritesItThenReloadsThePage() async throws {
        let client = FakeBrainClient()
        client.pageResult = .success(BrainPage(item: BrainItem(module: .people, id: "crm/contacts/Dara.md", title: "Dara"),
                                               person: BrainPerson()))
        let viewModel = BrainPageViewModel(module: .people, id: "crm/contacts/Dara.md", client: client,
                                           cache: try makeCache(), onAPIError: { _ in })
        await viewModel.load()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .current
        let today = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 30)))
        _ = try await viewModel.logCatchUp("Drinks Friday?", kind: .texted, today: today)
        XCTAssertEqual(client.logged, [BrainPersonLogRequest(id: "crm/contacts/Dara.md", text: "Drinks Friday?",
                                                             kind: .texted, date: "2026-10-31")])
        XCTAssertEqual(client.pageCalls.count, 2, "the page reloads with the new note")

        client.logResult = .failure(URLError(.notConnectedToInternet))
        do {
            _ = try await viewModel.logCatchUp("Coffee", kind: .note)
            XCTFail("a failed log throws, so the sheet keeps his words")
        } catch {}
        XCTAssertEqual(client.pageCalls.count, 2, "nothing written, nothing to reload")
    }

    func testAPersonPageIsLaidOutOnceWhenItLoads() async throws {
        let client = FakeBrainClient()
        let person = BrainPerson(encounters: [BrainEncounter(id: "2026-10-01#1", date: "2026-10-01", title: "Dinner",
                                                             bullets: ["Talked about **Lisbon**"], body: "")],
                                 catchup: "Moving to Lisbon.")
        client.pageResult = .success(BrainPage(item: BrainItem(module: .people, id: "crm/contacts/Dara.md", title: "Dara"),
                                               person: person))
        let viewModel = BrainPageViewModel(module: .people, id: "crm/contacts/Dara.md", client: client,
                                           cache: try makeCache(), onAPIError: { _ in })
        await viewModel.load()
        let built = try XCTUnwrap(viewModel.person)
        XCTAssertEqual(built.layout.timeline.map(\.id), ["2026-10-01#1"])
        XCTAssertEqual(built.layout.catchUp?.summary, "Moving to Lisbon.")

        client.pageResult = .success(samplePage)
        let wiki = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: try makeCache(), onAPIError: { _ in })
        await wiki.load()
        XCTAssertNil(wiki.person)
    }

    func testLoadedSiblingIsNilWhenTheNextPageFails() async throws {
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: try makeCache(), onAPIError: { _ in })
        await viewModel.load()
        client.pageResult = .failure(URLError(.notConnectedToInternet))
        let next = await viewModel.loadedSibling(module: .wiki, id: "p2", hub: "hub")
        XCTAssertNil(next)
        XCTAssertEqual(viewModel.page, samplePage)
    }

    func testLoadedSiblingFallsBackToItsSavedCopy() async throws {
        let cache = try makeCache()
        let saved = BrainPage(item: BrainItem(module: .wiki, id: "p2", title: "Page Two"), content: "Saved")
        try BrainCache.store(saved, server: cache.server, kind: "page", id: "p2", in: try XCTUnwrap(cache.context))
        let client = FakeBrainClient()
        client.pageResult = .failure(URLError(.notConnectedToInternet))
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: cache, onAPIError: { _ in })
        let next = await viewModel.loadedSibling(module: .wiki, id: "p2", hub: "hub")
        XCTAssertEqual(next?.page, saved)
        XCTAssertEqual(next?.hub, "hub")
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

    func testPagePassesItsHubToTheServer() async {
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", hub: "wiki/hub.md", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        XCTAssertEqual(client.pageCalls.map(\.hub), ["wiki/hub.md"])
    }

    func testSiblingLoadsTheNextPageInTheSameHub() async {
        let client = FakeBrainClient()
        client.pageResult = .success(samplePage)
        let viewModel = BrainPageViewModel(module: .wiki, id: "p1", client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        let next = viewModel.sibling(module: .people, id: "p2", hub: "wiki/hub.md")
        XCTAssertEqual(next.state, .loading)
        await next.load()
        XCTAssertEqual(client.pageCalls.map(\.id), ["p1", "p2"])
        XCTAssertEqual(client.pageCalls.map(\.hub), [nil, "wiki/hub.md"])
        XCTAssertEqual(next.module, .people)
        XCTAssertEqual(next.state, .loaded(samplePage))
    }
}

extension BrainViewModelTests {
    private var sampleHome: BrainHome {
        BrainHome(
            bites: [BrainBite(id: "b1", kind: .idea, text: "An idea", ref: BrainRef(module: .wiki, id: "wiki/a.md", title: "A"),
                              byline: "Wiki", index: 1, count: 3)],
            batch: 0,
            hasMore: true
        )
    }

    func testHomeLoadsTheDeckWithTheModules() async {
        let client = FakeBrainClient()
        client.modulesResult = .success([BrainModule(id: .wiki, title: "Wiki", count: 2)])
        client.homeResult = .success(sampleHome)
        let viewModel = BrainHomeViewModel(client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        XCTAssertEqual(viewModel.home, sampleHome)
    }

    func testHomeWithoutTheHomeRouteStillShowsTheModules() async {
        let client = FakeBrainClient()
        let modules = [BrainModule(id: .wiki, title: "Wiki", count: 2)]
        client.modulesResult = .success(modules)
        client.homeResult = .failure(URLError(.badServerResponse))
        var reported = 0
        let viewModel = BrainHomeViewModel(client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in reported += 1 })
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(modules))
        XCTAssertTrue(viewModel.home.isEmpty)
        XCTAssertEqual(reported, 0, "the home route is best effort and never reports an error")
    }

    func testFailedHomeRefreshKeepsWhatWasShown() async {
        let client = FakeBrainClient()
        client.modulesResult = .success([BrainModule(id: .wiki, title: "Wiki", count: 2)])
        client.homeResult = .success(sampleHome)
        let viewModel = BrainHomeViewModel(client: client, cache: BrainCacheHandle(server: URL(string: "https://a.example")!, context: nil), onAPIError: { _ in })
        await viewModel.load()
        client.homeResult = .failure(URLError(.timedOut))
        await viewModel.load()
        XCTAssertEqual(viewModel.home, sampleHome)
    }

    // MARK: Review position

    private var reviewServer: URL { URL(string: "https://a.example")! }

    private func makeReviewStore() -> BrainReviewStore {
        BrainReviewStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func bites(_ count: Int) -> [BrainBite] {
        (0..<count).map { BrainBite(id: "b\($0)", kind: .idea, text: "Idea \($0)", ref: BrainRef(module: .wiki, id: "wiki/\($0).md", title: "T\($0)")) }
    }

    private func makeReviewModel(client: FakeBrainClient, store: BrainReviewStore, today: String = "2026-10-14") -> BrainHomeViewModel {
        BrainHomeViewModel(client: client, cache: BrainCacheHandle(server: reviewServer, context: nil), onAPIError: { _ in },
                           reviewStore: store, today: { today })
    }

    func testReviewRestoresTodaysPosition() async {
        let store = makeReviewStore()
        store.save(BrainReviewPosition(day: "2026-10-14", batch: 1, index: 4), for: reviewServer)
        let client = FakeBrainClient()
        client.homeResult = .success(BrainHome(bites: bites(10), batch: 1, hasMore: true))
        let viewModel = makeReviewModel(client: client, store: store)
        await viewModel.load()
        XCTAssertEqual(client.requestedBatches, [1])
        XCTAssertEqual(viewModel.reviewIndex, 4)
    }

    func testReviewResetsOnANewDay() async {
        let store = makeReviewStore()
        store.save(BrainReviewPosition(day: "2026-10-13", batch: 1, index: 4), for: reviewServer)
        let client = FakeBrainClient()
        client.homeResult = .success(BrainHome(bites: bites(10), batch: 0, hasMore: true))
        let viewModel = makeReviewModel(client: client, store: store)
        await viewModel.load()
        XCTAssertEqual(client.requestedBatches, [0])
        XCTAssertEqual(viewModel.reviewIndex, 0)
    }

    func testReviewIndexClampsToAShorterBatch() async {
        let store = makeReviewStore()
        store.save(BrainReviewPosition(day: "2026-10-14", batch: 0, index: 9), for: reviewServer)
        let client = FakeBrainClient()
        client.homeResult = .success(BrainHome(bites: bites(3), batch: 0, hasMore: false))
        let viewModel = makeReviewModel(client: client, store: store)
        await viewModel.load()
        XCTAssertEqual(viewModel.reviewPages.count, 4)
        XCTAssertEqual(viewModel.reviewPages.last, .summary)
        XCTAssertEqual(viewModel.reviewIndex, 3)
    }

    func testReviewPagesAreEmptyWithoutBites() async {
        let viewModel = makeReviewModel(client: FakeBrainClient(), store: makeReviewStore())
        await viewModel.load()
        XCTAssertTrue(viewModel.reviewPages.isEmpty)
        XCTAssertEqual(viewModel.reviewIndex, 0)
    }

    func testReviewIndexPersistsWhenSet() async {
        let store = makeReviewStore()
        let client = FakeBrainClient()
        client.homeResult = .success(BrainHome(bites: bites(10), batch: 0, hasMore: true))
        let viewModel = makeReviewModel(client: client, store: store)
        await viewModel.load()
        viewModel.reviewIndex = 6
        XCTAssertEqual(store.position(for: reviewServer), BrainReviewPosition(day: "2026-10-14", batch: 0, index: 6))
    }

    func testDealMoreLoadsTheNextBatch() async {
        let store = makeReviewStore()
        let client = FakeBrainClient()
        client.homeResult = .success(BrainHome(bites: bites(10), batch: 0, hasMore: true))
        let viewModel = makeReviewModel(client: client, store: store)
        await viewModel.load()
        viewModel.reviewIndex = 10
        await viewModel.dealMore()
        XCTAssertEqual(client.requestedBatches.last, 1)
        XCTAssertEqual(viewModel.reviewIndex, 0)
        XCTAssertEqual(store.position(for: reviewServer), BrainReviewPosition(day: "2026-10-14", batch: 1, index: 0))
    }

    func testFailedDealMoreKeepsTheCurrentBatch() async {
        let store = makeReviewStore()
        let client = FakeBrainClient()
        client.homeResult = .success(BrainHome(bites: bites(10), batch: 0, hasMore: true))
        let viewModel = makeReviewModel(client: client, store: store)
        await viewModel.load()
        viewModel.reviewIndex = 10
        client.homeResult = .failure(URLError(.timedOut))
        await viewModel.dealMore()
        XCTAssertEqual(viewModel.reviewIndex, 10)
        XCTAssertEqual(viewModel.home.batch, 0)
        XCTAssertEqual(store.position(for: reviewServer), BrainReviewPosition(day: "2026-10-14", batch: 0, index: 10))
    }

    func testADeckLeftOpenOvernightKeepsItsOwnDay() async {
        let store = makeReviewStore()
        let client = FakeBrainClient()
        client.homeResult = .success(BrainHome(bites: bites(10), batch: 0, hasMore: true))
        var day = "2026-10-14"
        let viewModel = BrainHomeViewModel(
            client: client, cache: BrainCacheHandle(server: reviewServer, context: nil), onAPIError: { _ in },
            reviewStore: store, today: { day })
        XCTAssertFalse(viewModel.needsNewDay, "nothing on screen yet")
        await viewModel.load()
        await viewModel.dealMore()
        XCTAssertEqual(viewModel.deckDay, "2026-10-14")
        XCTAssertFalse(viewModel.needsNewDay)

        day = "2026-10-15"
        XCTAssertTrue(viewModel.needsNewDay)
        viewModel.reviewIndex = 3
        XCTAssertEqual(store.position(for: reviewServer), BrainReviewPosition(day: "2026-10-14", batch: 1, index: 3),
                       "a swipe on yesterday's deck is saved as yesterday's")

        await viewModel.load()
        XCTAssertEqual(client.requestedBatches.last, 0, "the new day starts at batch 0")
        XCTAssertEqual(viewModel.reviewIndex, 0)
        XCTAssertEqual(viewModel.deckDay, "2026-10-15")
        XCTAssertFalse(viewModel.needsNewDay)
    }

    func testReviewStoreIsPerServer() {
        let store = makeReviewStore()
        let a = URL(string: "https://a.example")!
        let b = URL(string: "https://b.example")!
        let position = BrainReviewPosition(day: "2026-10-14", batch: 1, index: 2)
        store.save(position, for: a)
        XCTAssertEqual(store.position(for: a), position)
        XCTAssertNil(store.position(for: b))
        store.save(position, for: b)
        store.remove(for: a)
        XCTAssertNil(store.position(for: a))
        XCTAssertEqual(store.position(for: b), position)
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
    var homeResult: Result<BrainHome, Error> = .success(BrainHome())
    private var _pageCalls: [(id: String, hub: String?)] = []
    var pageCalls: [(id: String, hub: String?)] { lock.withLock { _pageCalls } }
    var listResults: [Result<BrainList, Error>] = []
    var failingSearches: Set<String> = []
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
    func page(module: BrainModuleID, id: String, hub: String?) async throws -> BrainPage {
        lock.withLock { _pageCalls.append((id, hub)) }
        return try pageResult.get()
    }
    func search(query: String, module: BrainModuleID?) async throws -> BrainSearchResult {
        lock.withLock { _searchQueries.append(query) }
        if failingSearches.contains(query) { throw URLError(.timedOut) }
        return BrainSearchResult()
    }
    private var _requestedBatches: [Int] = []
    var requestedBatches: [Int] { lock.withLock { _requestedBatches } }
    func home(batch: Int) async throws -> BrainHome {
        lock.withLock { _requestedBatches.append(batch) }
        return try homeResult.get()
    }
    var peopleHomeResult: Result<BrainPeopleHome, Error> = .success(BrainPeopleHome())
    func peopleHome() async throws -> BrainPeopleHome {
        try peopleHomeResult.get()
    }
    var logResult: Result<BrainPersonLogResult, Error> = .success(BrainPersonLogResult())
    private var _logged: [BrainPersonLogRequest] = []
    var logged: [BrainPersonLogRequest] { lock.withLock { _logged } }
    func logPerson(_ request: BrainPersonLogRequest) async throws -> BrainPersonLogResult {
        lock.withLock { _logged.append(request) }
        return try logResult.get()
    }
}
