import XCTest
@testable import HermesMobile

final class LabelsModelsTests: XCTestCase {
    func testRecordDecodesTolerantlyAndClearHasNoVerdict() throws {
        let data = Data(#"""
        {"labels": [
          {"ts": "2026-10-13T08:00:00", "feature": "daily_deck", "item": "2026-10-12|morning|quote-3",
           "part": "card", "verdict": "bad", "note": "Too long", "title": "Seneca", "extra": 1},
          {"feature": "daily_deck", "item": "2026-10-12|morning|quote-3", "part": "question", "verdict": "good"},
          {"feature": "brain", "item": "wiki/stoicism", "part": "page", "verdict": "clear"},
          {"feature": "brain", "item": "wiki/x", "part": "page", "verdict": "meh"},
          {"feature": 7},
          "junk"
        ]}
        """#.utf8)

        let records = try FeedbackDecoding.decode(LabelList.self, from: data).labels

        XCTAssertEqual(records.count, 4, "a record without its key is dropped, never the list")
        XCTAssertEqual(records[0].verdict, .bad)
        XCTAssertEqual(records[0].note, "Too long")
        XCTAssertEqual(records[0].title, "Seneca")
        XCTAssertEqual(records[0].key, LabelKey(feature: "daily_deck", item: "2026-10-12|morning|quote-3", part: "card"))
        XCTAssertEqual(records[1].verdict, .good)
        XCTAssertNil(records[1].ts)
        XCTAssertEqual(records[2].verdict, .clear)
        XCTAssertNil(records[2].currentVerdict, "a cleared label means unlabeled")
        XCTAssertNil(records[3].verdict, "an unknown verdict reads as none")
    }

    func testMissingLabelsKeyIsAnEmptyList() throws {
        XCTAssertEqual(try FeedbackDecoding.decode(LabelList.self, from: Data("{}".utf8)).labels, [])
    }

    func testDeckItemKeyIsDateKindCardID() {
        let card = LabelKey.deckCard(date: "2026-10-12", kind: "morning", cardID: "quote-3")
        let question = LabelKey.deckQuestion(date: "2026-10-12", kind: "morning", cardID: "quote-3")

        XCTAssertEqual(card.feature, "daily_deck")
        XCTAssertEqual(card.item, "2026-10-12|morning|quote-3")
        XCTAssertEqual(card.part, "card")
        XCTAssertEqual(question.item, "2026-10-12|morning|quote-3")
        XCTAssertEqual(question.part, "question")
    }

    func testBrainPageKeyIsModuleSlashID() {
        let key = LabelKey.brainPage(module: .wiki, id: "stoicism")
        XCTAssertEqual(key, LabelKey(feature: "brain", item: "wiki/stoicism", part: "page"))
    }

    func testCreateBodyOmitsMissingNoteAndTitle() throws {
        let key = LabelKey.brainPage(module: .wiki, id: "stoicism")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys

        let bare = String(decoding: try encoder.encode(LabelCreate(key: key, verdict: .good)), as: UTF8.self)
        let full = String(decoding: try encoder.encode(LabelCreate(key: key, verdict: .bad, note: "Thin", title: "Stoicism")), as: UTF8.self)

        XCTAssertEqual(bare, #"{"feature":"brain","item":"wiki\/stoicism","part":"page","verdict":"good"}"#)
        XCTAssertEqual(full, #"{"feature":"brain","item":"wiki\/stoicism","note":"Thin","part":"page","title":"Stoicism","verdict":"bad"}"#)
    }

    func testLabelsQueryEncodesPlusPipeSlashAndSpaces() throws {
        let item = "2026-10-12|morning|c++ notes/one two"
        let url = Endpoint.labels(feature: "daily_deck", item: item).url(relativeTo: URL(string: "https://brain.example.test")!)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)

        XCTAssertEqual(url.path, "/api/labels")
        XCTAssertFalse(query.contains("+"), "a raw + reads as a space on the server")
        XCTAssertFalse(query.contains(" "))
        // Decode the way the server's form parser does: `+` is a space, then percent-decoding.
        let pairs = query.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: pairs), ["feature": "daily_deck", "item": item])
    }

    func testFeatureOnlyQueryHasNoItem() {
        let url = Endpoint.labels(feature: "brain", item: nil).url(relativeTo: URL(string: "https://brain.example.test")!)
        XCTAssertEqual(url.query, "feature=brain")
    }
}

/// The adapter against `URLProtocol` mocks.
final class LabelsDataClientHTTPTests: APIClientTestCase {
    func testNotFoundMeansUnavailable() async {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/labels")
            return apiTestJSONResponse(#"{"error":"not found"}"#, for: request, status: 404)
        }
        let isAvailable = await APIClientLabelsAdapter(apiClient: client).isAvailable()
        XCTAssertFalse(isAvailable)
    }

    func testServerErrorStillCountsAsAvailable() async {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"error":"boom"}"#, for: request, status: 500)
        }
        let isAvailable = await APIClientLabelsAdapter(apiClient: client).isAvailable()
        XCTAssertTrue(isAvailable)
    }

    func testSavePostsTheBodyAndDecodesTheFoldedLabel() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/labels")
            XCTAssertNil(request.url?.query)
            return apiTestJSONResponse(
                #"{"ts":"t","feature":"brain","item":"wiki/a","part":"page","verdict":"bad","note":"Thin"}"#,
                for: request)
        }
        let record = try await APIClientLabelsAdapter(apiClient: client)
            .save(LabelCreate(key: .brainPage(module: .wiki, id: "a"), verdict: .bad, note: "Thin"))
        XCTAssertEqual(record.verdict, .bad)
        XCTAssertEqual(record.note, "Thin")
    }

    func testListReadsTheLabelsEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.query, "feature=daily_deck")
            return apiTestJSONResponse(
                #"{"labels":[{"feature":"daily_deck","item":"d|morning|c","part":"card","verdict":"good"}]}"#,
                for: request)
        }
        let records = try await APIClientLabelsAdapter(apiClient: client).labels(feature: "daily_deck", item: nil)
        XCTAssertEqual(records.map(\.key), [.deckCard(date: "d", kind: "morning", cardID: "c")])
    }
}

@MainActor
final class LabelsViewModelTests: XCTestCase {
    private let key = LabelKey.deckCard(date: "2026-10-12", kind: "morning", cardID: "quote-3")

    func testGoodSavesAndShowsOnlyAfterTheServerAnswers() async {
        let client = StubLabelsClient()
        await client.holdSaves()
        let labels = LabelsViewModel(client: client)

        let save = Task { await labels.tap(.good, for: key, title: "Seneca") }
        await client.waitForSave()

        XCTAssertNil(labels.verdict(for: key), "non-optimistic: nothing shows before the server answers")
        XCTAssertTrue(labels.isPending(key))
        XCTAssertEqual(labels.pending[key], .good)

        await client.releaseSaves()
        await save.value

        XCTAssertEqual(labels.verdict(for: key), .good)
        XCTAssertFalse(labels.isPending(key))
        let saved = await client.saved
        XCTAssertEqual(saved, [LabelCreate(key: key, verdict: .good, title: "Seneca")])
    }

    func testBadCarriesATrimmedNoteAndABlankNoteIsLeftOut() async {
        let client = StubLabelsClient()
        let labels = LabelsViewModel(client: client)

        await labels.tap(.bad, for: key, note: "  Misses the point \n", title: "Seneca")

        XCTAssertEqual(labels.verdict(for: key), .bad)
        await labels.tap(.bad, for: key) // clears
        await labels.tap(.bad, for: key, note: "   ")
        let saved = await client.saved
        XCTAssertEqual(saved.map(\.note), ["Misses the point", nil, nil])
    }

    func testTappingTheSelectedVerdictClearsIt() async {
        let client = StubLabelsClient()
        let labels = LabelsViewModel(client: client)
        await labels.tap(.good, for: key)

        await labels.tap(.good, for: key)

        XCTAssertNil(labels.verdict(for: key))
        let saved = await client.saved
        XCTAssertEqual(saved.map(\.verdict), [.good, .clear])
    }

    func testFailureKeepsThePreviousVerdictAndShowsAnInlineError() async {
        let client = StubLabelsClient()
        let labels = LabelsViewModel(client: client)
        await labels.tap(.good, for: key)
        await client.fail(with: APIError.http(statusCode: 500, body: nil))

        await labels.tap(.bad, for: key, note: "Nope")

        XCTAssertEqual(labels.verdict(for: key), .good, "reverts to what the server last confirmed")
        XCTAssertNotNil(labels.error(for: key))
        XCTAssertFalse(labels.isPending(key))

        await client.fail(with: nil)
        await labels.tap(.bad, for: key)
        XCTAssertNil(labels.error(for: key), "a later save clears the error")
        XCTAssertEqual(labels.verdict(for: key), .bad)
    }

    func testATapWhileSavingIsIgnored() async {
        let client = StubLabelsClient()
        await client.holdSaves()
        let labels = LabelsViewModel(client: client)

        let first = Task { await labels.tap(.good, for: key) }
        await client.waitForSave()
        await labels.tap(.bad, for: key)
        await client.releaseSaves()
        await first.value

        let saved = await client.saved
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(labels.verdict(for: key), .good)
    }

    func testLoadReplacesTheFeaturesLabelsAndDropsCleared() async throws {
        let client = StubLabelsClient()
        let other = LabelKey.brainPage(module: .wiki, id: "a")
        await client.setRecords([
            record(key, "good"),
            record(.deckQuestion(date: "2026-10-12", kind: "morning", cardID: "quote-3"), "clear"),
            record(other, "bad")
        ])
        let labels = LabelsViewModel(client: client)

        try await labels.load(feature: "daily_deck")

        XCTAssertEqual(labels.verdict(for: key), .good)
        XCTAssertNil(labels.verdict(for: .deckQuestion(date: "2026-10-12", kind: "morning", cardID: "quote-3")))
        XCTAssertNil(labels.verdict(for: other), "another feature's labels stay out")
        XCTAssertTrue(labels.hasLoaded)
    }

    func testUnavailableLabelsHideTheControls() async {
        let feedback = StubFeedbackOnlyClient()
        let labelsClient = StubLabelsClient()
        await labelsClient.setAvailable(false)
        let availability = FeedbackAvailability(client: feedback, labels: labelsClient)

        await availability.check()

        XCTAssertTrue(availability.isAvailable)
        XCTAssertFalse(availability.labelsAvailable, "a 404 on /api/labels hides every Rate control")

        await labelsClient.setAvailable(true)
        await availability.check()
        XCTAssertTrue(availability.labelsAvailable, "checked again until the server says yes")
        await availability.check()
        let checks = await labelsClient.availabilityChecks
        XCTAssertEqual(checks, 2)
    }

    func testWithoutALabelsClientLabelsStayHidden() async {
        let availability = FeedbackAvailability(client: StubFeedbackOnlyClient())
        await availability.check()
        XCTAssertFalse(availability.labelsAvailable)
    }

    private func record(_ key: LabelKey, _ verdict: String) -> LabelRecord {
        let json = #"{"feature":"\#(key.feature)","item":"\#(key.item)","part":"\#(key.part)","verdict":"\#(verdict)"}"#
        return try! FeedbackDecoding.decode(LabelRecord.self, from: Data(json.utf8))
    }
}

@MainActor
final class LabelQueueViewModelTests: XCTestCase {
    private let server = URL(string: "https://brain.example.test")!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LabelQueueTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 2026-10-13 09:00 in the device's calendar.
    private var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9))!
    }

    func testWindowIsTheLastFourteenDaysNewestFirst() {
        let dates = ["2026-09-28", "2026-09-29", "2026-10-13", "2026-10-01", "2026-10-14", "2026-09-30"]
        XCTAssertEqual(LabelQueueViewModel.windowDates(dates, now: now),
                       ["2026-10-13", "2026-10-01", "2026-09-30"],
                       "today and the 13 days before it; nothing older or in the future")
    }

    func testQueueKeepsReflectCardsInOrderAndSkipsFullyLabeledOnes() throws {
        let newer = try DailyDeck.decode(Self.deck(date: "2026-10-13", cards: [
            #"{"id":"head","type":"headline"}"#,
            #"{"id":"q1","type":"reflect","kind":"quote","body":"A","question":"Why?"}"#,
            #"{"id":"p1","type":"prompt","question":"Plan?"}"#,
            #"{"id":"b1","type":"reflect","kind":"book","body":"B","question":"How?"}"#,
            #"{"id":"w1","type":"reflect","kind":"wiki","body":"C"}"#
        ]))
        let older = try DailyDeck.decode(Self.deck(date: "2026-10-12", cards: [
            #"{"id":"q1","type":"reflect","kind":"quote","body":"D","question":"Who?"}"#
        ]))
        let labeled: Set<LabelKey> = [
            .deckCard(date: "2026-10-13", kind: "morning", cardID: "q1"),
            .deckQuestion(date: "2026-10-13", kind: "morning", cardID: "q1"),
            .deckCard(date: "2026-10-13", kind: "morning", cardID: "b1"),
            .deckCard(date: "2026-10-13", kind: "morning", cardID: "w1")
        ]

        let items = LabelQueueViewModel.items(
            decks: [(date: "2026-10-13", kind: "morning", deck: newer), (date: "2026-10-12", kind: "morning", deck: older)],
            isLabeled: { labeled.contains($0) })

        XCTAssertEqual(items.map(\.id), ["2026-10-13|morning|b1", "2026-10-12|morning|q1"],
                       "b1 still needs its question; w1 has no question so its card label is enough")
        XCTAssertNil(items.first?.questionKey.flatMap { labeled.contains($0) ? $0 : nil })
    }

    func testBuildReadsTheWindowsDecksAndCountsDownAsCardsAreLabeled() async throws {
        let names = ["2026-10-13.morning.json", "2026-10-10.morning.json", "2026-09-20.morning.json",
                     "2026-10-12.weekly.json"]
        let client = ScriptedDailyDeckClient(workspaces: ["/brain"], names: names, deck: "{}")
        client.files = [
            DailyDeckPaths.deck(date: "2026-10-13", kind: "morning"): Self.deck(date: "2026-10-13", cards: [
                #"{"id":"q1","type":"reflect","kind":"quote","body":"A","question":"Why?"}"#
            ]),
            DailyDeckPaths.deck(date: "2026-10-10", kind: "morning"): Self.deck(date: "2026-10-10", cards: [
                #"{"id":"w1","type":"reflect","kind":"wiki","body":"C"}"#,
                #"{"id":"w2","type":"reflect","kind":"wiki","body":"E","question":"So?"}"#
            ]),
            DailyDeckPaths.deck(date: "2026-09-20", kind: "morning"): Self.deck(date: "2026-09-20", cards: [
                #"{"id":"old","type":"reflect","kind":"wiki","body":"F"}"#
            ])
        ]
        let labelsClient = StubLabelsClient()
        let labeledJSON = #"{"feature":"daily_deck","item":"2026-10-10|morning|w2","part":"card","verdict":"good"}"#
        await labelsClient.setRecords([try FeedbackDecoding.decode(LabelRecord.self, from: Data(labeledJSON.utf8))])
        let queue = LabelQueueViewModel(
            server: server, deckClient: client, labels: LabelsViewModel(client: labelsClient),
            store: DailyDeckStore(defaults: defaults), now: { self.now })

        await queue.build()

        XCTAssertEqual(queue.state, .ready)
        XCTAssertEqual(queue.items.map(\.id), ["2026-10-13|morning|q1", "2026-10-10|morning|w1", "2026-10-10|morning|w2"])
        XCTAssertFalse(client.readPaths.contains(DailyDeckPaths.deck(date: "2026-09-20", kind: "morning")),
                       "decks outside the window are never read")
        XCTAssertEqual(queue.unlabeledCount, 3)

        await queue.labels.tap(.good, for: .deckCard(date: "2026-10-10", kind: "morning", cardID: "w1"))
        XCTAssertEqual(queue.unlabeledCount, 2, "a card with no question is done once its card is labeled")
        XCTAssertEqual(queue.items.count, 3, "the queue holds still while you label, so N of M stays put")

        XCTAssertEqual(queue.current?.id, "2026-10-13|morning|q1")
        queue.next()
        queue.next()
        queue.next()
        XCTAssertNil(queue.current, "past the last card the queue is done")
    }

    func testNoWorkspaceYetAsksToOpenTheBriefFirst() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/a", "/b"], names: [], deck: "{}")
        let queue = LabelQueueViewModel(
            server: server, deckClient: client, labels: LabelsViewModel(client: StubLabelsClient()),
            store: DailyDeckStore(defaults: defaults), now: { self.now })

        await queue.build()

        XCTAssertEqual(queue.state, .needsWorkspace)
        XCTAssertEqual(queue.items, [])
    }

    func testFailedLabelsLoadFailsTheQueueRatherThanShowingLabeledCards() async {
        let client = ScriptedDailyDeckClient(workspaces: ["/brain"], names: [], deck: "{}")
        let labelsClient = StubLabelsClient()
        await labelsClient.failLists()
        let queue = LabelQueueViewModel(
            server: server, deckClient: client, labels: LabelsViewModel(client: labelsClient),
            store: DailyDeckStore(defaults: defaults), now: { self.now })

        await queue.build()

        guard case .failed = queue.state else { return XCTFail("expected failed, got \(queue.state)") }
    }

    private static func deck(date: String, cards: [String]) -> String {
        #"{"date":"\#(date)","kind":"morning","cards":[\#(cards.joined(separator: ","))]}"#
    }
}

actor StubLabelsClient: LabelsDataClient {
    private(set) var saved: [LabelCreate] = []
    private(set) var availabilityChecks = 0
    private var records: [LabelRecord] = []
    private var available = true
    private var saveError: Error?
    private var listFails = false
    private var holdsSaves = false
    private var heldSave: CheckedContinuation<Void, Never>?
    private var saveWaiter: CheckedContinuation<Void, Never>?

    func setRecords(_ records: [LabelRecord]) { self.records = records }
    func setAvailable(_ value: Bool) { available = value }
    func fail(with error: Error?) { saveError = error }
    func failLists() { listFails = true }
    func holdSaves() { holdsSaves = true }

    func releaseSaves() {
        holdsSaves = false
        heldSave?.resume()
        heldSave = nil
    }

    func waitForSave() async {
        guard saved.isEmpty else { return }
        await withCheckedContinuation { saveWaiter = $0 }
    }

    func labels(feature: String, item: String?) async throws -> [LabelRecord] {
        if listFails { throw APIError.http(statusCode: 500, body: nil) }
        return records.filter { $0.feature == feature && (item == nil || $0.item == item) }
    }

    func save(_ body: LabelCreate) async throws -> LabelRecord {
        saved.append(body)
        saveWaiter?.resume()
        saveWaiter = nil
        if holdsSaves { await withCheckedContinuation { heldSave = $0 } }
        if let saveError { throw saveError }
        let json = #"{"feature":"\#(body.feature)","item":"\#(body.item)","part":"\#(body.part)","verdict":"\#(body.verdict.rawValue)"}"#
        return try FeedbackDecoding.decode(LabelRecord.self, from: Data(json.utf8))
    }

    func isAvailable() async -> Bool {
        availabilityChecks += 1
        return available
    }
}

private actor StubFeedbackOnlyClient: FeedbackDataClient {
    func list() async throws -> [FeedbackEntry] { [] }
    func plan(id: String) async throws -> FeedbackPlan { FeedbackPlan(markdown: "") }
    func create(_ body: FeedbackCreate) async throws -> FeedbackEntry {
        try FeedbackDecoding.decode(FeedbackEntry.self, from: Data(#"{"id":"x"}"#.utf8))
    }
    func decide(id: String, _ decision: FeedbackDecision) async throws -> FeedbackEntry {
        try FeedbackDecoding.decode(FeedbackEntry.self, from: Data(#"{"id":"x"}"#.utf8))
    }
    func isAvailable() async -> Bool { true }
}
