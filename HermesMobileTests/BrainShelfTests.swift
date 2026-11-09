import SwiftData
import XCTest
@testable import HermesMobile

/// The shelf for his writing: Letters, My takes, Memories. Every word here is made up.
@MainActor
final class BrainShelfTests: XCTestCase {
    private let serverA = URL(string: "https://a.example")!
    private let serverB = URL(string: "https://b.example")!

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CachedBrainEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private let letters = BrainShelf(kind: "letters", entries: [
        BrainShelfEntry(id: "daughter/letters/2026-10-02.md", date: "2026-10-02", title: "October 2, 2026",
                        context: "15 weeks before you arrive", prompt: "What do you hope she finds funny?",
                        text: "Mira, I hope you laugh at the kettle.\n\nIt whistles one flat note."),
        BrainShelfEntry(id: "daughter/letters/2026-11-05.md", date: "2026-11-05", title: "November 5, 2026",
                        context: "10 weeks before you arrive", prompt: "What should she know about today?",
                        text: "I put your shelf up crooked."),
    ])

    private let en = Locale(identifier: "en_US")

    // MARK: - Decoding

    func testDecodesTheContract() throws {
        let json = """
        {"kind": "takes",
         "entries": [
           {"id": "takes/2026-W45.md", "date": "2026-11-04", "title": "", "context": null,
            "prompt": "What makes a tool worth keeping?", "text": "Half of this is right.\\n\\nThe seams are the work.",
            "group": "AI & the industry",
            "source": {"module": "wiki", "id": "wiki/sources/small-tools.md", "title": "Small tools, loosely joined"}},
           {"id": "takes/2026-W45.md", "date": "2026-11-06", "context": "Your take", "text": "The ones I stop noticing.",
            "group": "AI & the industry", "source": null}
         ]}
        """
        let shelf = try JSONDecoder().decode(BrainShelf.self, from: Data(json.utf8))
        XCTAssertEqual(shelf.kind, "takes")
        XCTAssertEqual(shelf.entries.count, 2)
        let first = shelf.entries[0]
        XCTAssertEqual(first.group, "AI & the industry")
        XCTAssertEqual(first.context, "")
        XCTAssertEqual(first.source, BrainShelfSource(module: .wiki, id: "wiki/sources/small-tools.md", title: "Small tools, loosely joined"))
        XCTAssertEqual(first.source?.route, .page(.wiki, "wiki/sources/small-tools.md"))
        XCTAssertNil(shelf.entries[1].source)
        XCTAssertEqual(shelf.entries[1].context, "Your take")
    }

    func testMissingNullAndUnknownFieldsNeverFail() throws {
        let json = """
        {"future": {"a": 1},
         "entries": [
           {},
           "not an entry",
           {"id": 7, "date": null, "text": "Only words.", "mood": "calm",
            "source": {"module": "podcasts", "id": "podcasts/x.md", "title": "A show"}},
           {"text": "No page.", "source": {"module": null, "id": null, "title": "The long proof"}},
           {"text": "Odd source.", "source": "wiki/x.md"}
         ]}
        """
        let shelf = try JSONDecoder().decode(BrainShelf.self, from: Data(json.utf8))
        XCTAssertEqual(shelf.kind, "")
        XCTAssertEqual(shelf.entries.map(\.text), ["", "Only words.", "No page.", "Odd source."])
        XCTAssertEqual(shelf.entries[1].id, "")
        // A module this build doesn't know keeps the title and opens nothing.
        XCTAssertEqual(shelf.entries[1].source?.title, "A show")
        XCTAssertNil(shelf.entries[1].source?.route)
        XCTAssertEqual(shelf.entries[2].source, BrainShelfSource(title: "The long proof"))
        XCTAssertNil(shelf.entries[2].source?.route)
        XCTAssertNil(shelf.entries[3].source)
        XCTAssertTrue(try JSONDecoder().decode(BrainShelf.self, from: Data("{}".utf8)).entries.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(BrainShelf.self, from: Data(#"{"entries": null}"#.utf8)).entries.isEmpty)
    }

    func testTheSavedCopyRoundTrips() throws {
        let data = try JSONEncoder().encode(BrainShelfFixtures.takes)
        XCTAssertEqual(try JSONDecoder().decode(BrainShelf.self, from: data), BrainShelfFixtures.takes)
    }

    // MARK: - Endpoint and client

    func testEndpointPathAndQuery() {
        for kind in BrainShelfKind.allCases {
            let endpoint = Endpoint.brainShelf(kind: kind.rawValue)
            XCTAssertEqual(endpoint.path, "/api/brain/shelf")
            XCTAssertEqual(endpoint.queryItems, [URLQueryItem(name: "kind", value: kind.rawValue)])
        }
        XCTAssertEqual(BrainShelfKind.allCases.map(\.rawValue), ["letters", "takes", "memories"])
    }

    private func makeClient(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> APIClientBrainAdapter {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClientBrainAdapter(apiClient: APIClient(
            baseURL: serverA, session: URLSession(configuration: configuration), customHeaderProvider: { [] }))
    }

    func testTheClientAsksForTheKindAndDecodesTheAnswer() async throws {
        addTeardownBlock { MockURLProtocol.requestHandler = nil }
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/brain/shelf")
            XCTAssertEqual(request.url?.query, "kind=memories")
            return apiTestJSONResponse("""
            {"kind": "memories", "entries": [{"id": "memories/2026-11-01.md", "date": "2026-11-01", "title": null,
              "context": "Uncle Teo", "prompt": "Who taught you to fix things?", "text": "He handed me the wrong wrench.",
              "group": null, "source": null}]}
            """, for: request)
        }
        let shelf = try await client.shelf(kind: .memories)
        XCTAssertEqual(shelf.entries, [BrainShelfEntry(id: "memories/2026-11-01.md", date: "2026-11-01", context: "Uncle Teo",
                                                       prompt: "Who taught you to fix things?", text: "He handed me the wrong wrench.")])
    }

    func testNoBrainIsUnavailableButAMissingRouteIsAFailureWithARetry() async throws {
        addTeardownBlock { MockURLProtocol.requestHandler = nil }
        let noBrain = BrainShelfViewModel(kind: .letters, client: makeClient { request in
            apiTestJSONResponse(#"{"error":"brain not found"}"#, for: request, status: 404)
        }, cache: BrainCacheHandle(server: serverA, context: nil))
        await noBrain.load()
        XCTAssertEqual(noBrain.state, .unavailable)

        // An older fork without the route: its own 404, not "no Brain".
        var answers = [(#"{"error":"not found"}"#, 404), (#"{"kind":"letters","entries":[{"text":"Hello, Mira."}]}"#, 200)]
        let lock = NSLock()
        let olderServer = BrainShelfViewModel(kind: .letters, client: makeClient { request in
            let (body, status) = lock.withLock { answers.removeFirst() }
            return apiTestJSONResponse(body, for: request, status: status)
        }, cache: BrainCacheHandle(server: serverA, context: nil))
        await olderServer.load()
        guard case .failed = olderServer.state else { return XCTFail("Expected a failure, got \(olderServer.state)") }
        await olderServer.load()  // Try again
        XCTAssertEqual(olderServer.cards.map(\.text), ["Hello, Mira."])
    }

    // MARK: - Page view model

    func testLoadShowsTheCardsAndSavesACopy() async throws {
        let context = try makeContext()
        let client = FakeBrainClient()
        client.shelfResults[.letters] = .success(letters)
        let viewModel = BrainShelfViewModel(kind: .letters, client: client, cache: BrainCacheHandle(server: serverA, context: context))
        XCTAssertEqual(viewModel.state, .loading)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(letters))
        XCTAssertEqual(viewModel.cards.map(\.title), ["October 2, 2026", "November 5, 2026"], "oldest first, as the server sent them")
        XCTAssertFalse(viewModel.isShowingCachedCopy)
        XCTAssertEqual(client.shelfCalls, [.letters])
        XCTAssertEqual(try BrainCache.load(BrainShelf.self, server: serverA, kind: "shelf", id: "letters", in: context), letters)
    }

    func testAnEmptyShelfIsLoadedWithNoCards() async {
        let viewModel = BrainShelfViewModel(kind: .memories, client: FakeBrainClient(),
                                            cache: BrainCacheHandle(server: serverA, context: nil))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(BrainShelf(kind: "memories")))
        XCTAssertTrue(viewModel.cards.isEmpty)
    }

    func testAFailureWithNoSavedCopyFailsAndReports() async throws {
        let client = FakeBrainClient()
        client.shelfResults[.takes] = .failure(URLError(.timedOut))
        var reported = 0
        let viewModel = BrainShelfViewModel(kind: .takes, client: client,
                                            cache: BrainCacheHandle(server: serverA, context: try makeContext()),
                                            onAPIError: { _ in reported += 1 })
        await viewModel.load()
        guard case .failed = viewModel.state else { return XCTFail("Expected a failure, got \(viewModel.state)") }
        XCTAssertTrue(viewModel.cards.isEmpty)
        XCTAssertEqual(reported, 1)
    }

    func testOfflineFallsBackToTheSavedCopy() async throws {
        let cache = BrainCacheHandle(server: serverA, context: try makeContext())
        let client = FakeBrainClient()
        client.shelfResults[.letters] = .success(letters)
        await BrainShelfViewModel(kind: .letters, client: client, cache: cache).load()

        client.shelfResults[.letters] = .failure(URLError(.notConnectedToInternet))
        let offline = BrainShelfViewModel(kind: .letters, client: client, cache: cache)
        await offline.load()
        XCTAssertEqual(offline.state, .loaded(letters))
        XCTAssertTrue(offline.isShowingCachedCopy)
        XCTAssertEqual(offline.cards.count, 2)

        // Back online: the fresh page replaces the saved one.
        client.shelfResults[.letters] = .success(BrainShelf(kind: "letters", entries: Array(letters.entries.prefix(1))))
        await offline.load()
        XCTAssertFalse(offline.isShowingCachedCopy)
        XCTAssertEqual(offline.cards.count, 1)
    }

    func testAFailedRefreshKeepsThePageShown() async {
        let client = FakeBrainClient()
        client.shelfResults[.letters] = .success(letters)
        let viewModel = BrainShelfViewModel(kind: .letters, client: client, cache: BrainCacheHandle(server: serverA, context: nil))
        await viewModel.load()
        client.shelfResults[.letters] = .failure(URLError(.timedOut))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(letters))
        XCTAssertFalse(viewModel.isShowingCachedCopy)
    }

    func testTheSavedCopyStaysWithItsServerAndItsPage() async throws {
        let context = try makeContext()
        let client = FakeBrainClient()
        client.shelfResults[.letters] = .success(letters)
        await BrainShelfViewModel(kind: .letters, client: client, cache: BrainCacheHandle(server: serverA, context: context)).load()

        client.shelfResults[.letters] = .failure(URLError(.notConnectedToInternet))
        client.shelfResults[.memories] = .failure(URLError(.notConnectedToInternet))
        let otherServer = BrainShelfViewModel(kind: .letters, client: client, cache: BrainCacheHandle(server: serverB, context: context))
        await otherServer.load()
        guard case .failed = otherServer.state else { return XCTFail("Server B showed server A's letters") }
        XCTAssertTrue(otherServer.cards.isEmpty)

        let otherPage = BrainShelfViewModel(kind: .memories, client: client, cache: BrainCacheHandle(server: serverA, context: context))
        await otherPage.load()
        guard case .failed = otherPage.state else { return XCTFail("Memories showed the letters") }

        let sameServer = BrainShelfViewModel(kind: .letters, client: client, cache: BrainCacheHandle(server: serverA, context: context))
        await sameServer.load()
        XCTAssertEqual(sameServer.state, .loaded(letters))
    }

    func testACancelledLoadChangesNothing() async {
        let client = FakeBrainClient()
        client.shelfResults[.takes] = .failure(CancellationError())
        var reported = 0
        let viewModel = BrainShelfViewModel(kind: .takes, client: client, cache: BrainCacheHandle(server: serverA, context: nil),
                                            onAPIError: { _ in reported += 1 })
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loading)
        XCTAssertEqual(reported, 0)
    }

    func testAFixturePageNeedsNoNetwork() async {
        let viewModel = BrainShelfViewModel(kind: .takes, shelf: BrainShelfFixtures.takes, cached: true)
        XCTAssertEqual(viewModel.cards.count, 3)
        XCTAssertTrue(viewModel.isShowingCachedCopy)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded(BrainShelfFixtures.takes))
    }

    // MARK: - Cards

    func testALetterLeadsWithItsDayUnderWhenItWasWritten() {
        let card = BrainShelfLayout.card(letters.entries[1], kind: .letters, index: 1, locale: en)
        XCTAssertEqual(card.kicker, "10 weeks before you arrive")
        XCTAssertEqual(card.title, "November 5, 2026")
        XCTAssertEqual(card.prompt, "What should she know about today?")
        XCTAssertEqual(card.text, "I put your shelf up crooked.")
        XCTAssertNil(card.source)

        // No title from the server: the day stands in, once.
        let untitled = BrainShelfLayout.card(BrainShelfEntry(date: "2026-11-05", context: "10 weeks before you arrive"),
                                             kind: .letters, index: 0, locale: en)
        XCTAssertEqual(untitled.title, "Nov 5, 2026")
        XCTAssertEqual(untitled.kicker, "10 weeks before you arrive")
    }

    func testATakeLeadsWithTheIdeaItAnswered() {
        let cards = BrainShelfLayout.cards(BrainShelfFixtures.takes, kind: .takes, locale: en)
        // The weekly summing-up has no idea.
        XCTAssertEqual(cards[0].title, "Your take")
        XCTAssertEqual(cards[0].kicker, "AI & the industry · Nov 6, 2026")
        XCTAssertEqual(cards[0].prompt, "What makes a tool worth keeping?")
        XCTAssertNil(cards[0].source)
        // An idea with a Brain page opens it.
        XCTAssertEqual(cards[1].title, "Small tools, loosely joined")
        XCTAssertEqual(cards[1].source, .page(.wiki, "wiki/sources/small-tools.md"))
        XCTAssertEqual(cards[1].sourceLabel, "Open the wiki page")
        XCTAssertEqual(cards[1].sourceModule, .wiki)
        // An idea without one still names it, and opens nothing.
        XCTAssertEqual(cards[2].title, "The long proof")
        XCTAssertNil(cards[2].source)
        XCTAssertEqual(cards[2].sourceLabel, "")
    }

    func testAMemoryLeadsWithItsQuestion() {
        let card = BrainShelfLayout.card(BrainShelfFixtures.memories.entries[1], kind: .memories, index: 1, locale: en)
        XCTAssertEqual(card.title, "Who taught you to fix things?")
        XCTAssertEqual(card.prompt, "", "the question is the title, so it isn't said twice")
        XCTAssertEqual(card.kicker, "Uncle Teo · Nov 1, 2026")
        let bare = BrainShelfLayout.card(BrainShelfEntry(date: "2026-11-01", prompt: "Who taught you to fix things?"),
                                         kind: .memories, index: 0, locale: en)
        XCTAssertEqual(bare.kicker, "Nov 1, 2026")
    }

    func testCardIdentityHoldsWhenIdsRepeat() {
        let twin = BrainShelfEntry(id: "takes/2026-W45.md", date: "2026-11-04", text: "Same file, same day.")
        let cards = BrainShelfLayout.cards(BrainShelf(entries: [twin, twin, twin]), kind: .takes)
        XCTAssertEqual(Set(cards.map(\.id)).count, 3)
    }

    func testEachPageWearsItsBriefCardsPaper() {
        XCTAssertEqual(BrainShelfKind.letters.paper, BrainModuleID.letters.paper)
        XCTAssertEqual(BrainShelfKind.letters.paper, DeckPalette.letter.colors)
        XCTAssertEqual(BrainShelfKind.takes.paper, .notes)
        XCTAssertEqual(BrainShelfKind.memories.paper, DeckPalette.lookingBack.colors)
        XCTAssertEqual(BrainShelfKind.memories.paper, .past)
        XCTAssertEqual(BrainShelfKind.letters.countLabel(1), "1 letter")
        XCTAssertEqual(BrainShelfKind.memories.countLabel(4), "4 memories")
    }

    // MARK: - Brain home

    func testHomeRowsCountEachPageAndWarmTheSavedCopies() async throws {
        let context = try makeContext()
        let client = FakeBrainClient()
        client.shelfResults[.letters] = .success(letters)
        client.shelfResults[.takes] = .success(BrainShelfFixtures.takes)
        let home = BrainShelfHomeViewModel(client: client, cache: BrainCacheHandle(server: serverA, context: context))
        XCTAssertTrue(home.rows.isEmpty)
        await home.load()
        XCTAssertEqual(home.rows, [
            BrainShelfLayout.HomeRow(kind: .letters, count: 2),
            BrainShelfLayout.HomeRow(kind: .takes, count: 3),
            BrainShelfLayout.HomeRow(kind: .memories, count: 0),
        ])
        XCTAssertEqual(Set(client.shelfCalls), Set(BrainShelfKind.allCases))
        // A page never opened still opens offline.
        client.shelfResults[.takes] = .failure(URLError(.notConnectedToInternet))
        let page = BrainShelfViewModel(kind: .takes, client: client, cache: BrainCacheHandle(server: serverA, context: context))
        await page.load()
        XCTAssertEqual(page.cards.count, 3)
        XCTAssertTrue(page.isShowingCachedCopy)
    }

    func testAServerWithoutTheShelfShowsNoSectionAndKeepsTheLettersModule() async throws {
        let client = FakeBrainClient()
        for kind in BrainShelfKind.allCases {
            client.shelfResults[kind] = .failure(APIError.http(statusCode: 404, body: #"{"error":"not found"}"#))
        }
        let home = BrainShelfHomeViewModel(client: client, cache: BrainCacheHandle(server: serverA, context: try makeContext()))
        await home.load()
        XCTAssertTrue(home.rows.isEmpty)

        let modules = [BrainModule(id: .wiki), BrainModule(id: .letters), BrainModule(id: .journal)]
        XCTAssertEqual(BrainShelfLayout.browseModules(modules, showingShelf: false).map(\.id), [.wiki, .letters, .journal])
        XCTAssertEqual(BrainShelfLayout.browseModules(modules, showingShelf: true).map(\.id), [.wiki, .journal],
                       "one Letters row on home: the shelf's book")
    }

    func testOfflineHomeRowsComeFromThisServersSavedCopiesOnly() async throws {
        let context = try makeContext()
        let client = FakeBrainClient()
        client.shelfResults[.letters] = .success(letters)
        await BrainShelfHomeViewModel(client: client, cache: BrainCacheHandle(server: serverA, context: context)).load()
        for kind in BrainShelfKind.allCases { client.shelfResults[kind] = .failure(URLError(.notConnectedToInternet)) }

        let sameServer = BrainShelfHomeViewModel(client: client, cache: BrainCacheHandle(server: serverA, context: context))
        await sameServer.load()
        XCTAssertEqual(sameServer.rows.first, BrainShelfLayout.HomeRow(kind: .letters, count: 2))
        let otherServer = BrainShelfHomeViewModel(client: client, cache: BrainCacheHandle(server: serverB, context: context))
        await otherServer.load()
        XCTAssertTrue(otherServer.rows.isEmpty)
    }

    func testAFreshHomeSkipsTheNetwork() async {
        let client = FakeBrainClient()
        let home = BrainShelfHomeViewModel(client: client, cache: BrainCacheHandle(server: serverA, context: nil))
        let start = Date(timeIntervalSince1970: 1_000)
        await home.load(now: start)
        await home.refreshIfStale(now: start.addingTimeInterval(60))
        XCTAssertEqual(client.shelfCalls.count, 3)
        await home.refreshIfStale(now: start.addingTimeInterval(600))
        XCTAssertEqual(client.shelfCalls.count, 6)
    }
}
