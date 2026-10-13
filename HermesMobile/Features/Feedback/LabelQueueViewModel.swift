import Foundation
import Observation

/// One card waiting in Label recent cards.
struct LabelQueueItem: Identifiable, Equatable {
    let date: String
    let kind: String
    let card: DeckCard

    /// The card's eval key, `<date>|<kind>|<card id>`.
    var id: String { cardKey.item }
    var cardKey: LabelKey { .deckCard(date: date, kind: kind, cardID: card.id) }
    /// Nil for a card with no question: its card label is all it needs.
    var questionKey: LabelKey? {
        card.question == nil ? nil : .deckQuestion(date: date, kind: kind, cardID: card.id)
    }
}

/// Settings › Feedback › Label recent cards: reflect cards from the last 14 days of morning
/// Daily Decks, newest first, without the ones already labeled. Read-only: it reads `briefs/`
/// through the session the Daily Deck already opened, and never creates or renames a session,
/// stores a workspace, or reads answers. Built once, by one task the row and the screen share;
/// every tap saves at once, so leaving at any point loses nothing.
@MainActor
@Observable
final class LabelQueueViewModel {
    enum State: Equatable {
        case idle, loading, ready
        /// No Daily Deck session to read through: the brief hasn't been opened in the window
        /// (or its session is gone). Opening the Daily Brief once sets one up.
        case needsBrief
        case failed(String)
    }

    static let windowDays = 14

    private(set) var state: State = .idle
    /// Fixed once built, so "N of M" holds still while cards are labeled.
    private(set) var items: [LabelQueueItem] = []
    private(set) var index = 0
    let labels: LabelsViewModel

    private let server: URL
    private let deckClient: any DailyDeckDataClient
    private let store: DailyDeckStore
    private let now: () -> Date
    /// The one build in flight. Unstructured, so leaving the screen that started it doesn't
    /// cancel it; `nil` once it ends.
    @ObservationIgnored private var buildTask: Task<Void, Never>?

    init(server: URL, deckClient: any DailyDeckDataClient, labels: LabelsViewModel,
         store: DailyDeckStore = DailyDeckStore(), now: @escaping () -> Date = Date.init) {
        self.server = server
        self.deckClient = deckClient
        self.labels = labels
        self.store = store
        self.now = now
    }

    convenience init(server: URL, labelsClient: any LabelsDataClient) {
        self.init(server: server,
                  deckClient: APIClientDailyDeckAdapter(apiClient: APIClient(baseURL: server)),
                  labels: LabelsViewModel(client: labelsClient))
    }

    var current: LabelQueueItem? { items.indices.contains(index) ? items[index] : nil }

    /// Cards in the queue still missing a label; drops as they are labeled.
    var unlabeledCount: Int { items.filter { !isLabeled($0) }.count }

    func isLabeled(_ item: LabelQueueItem) -> Bool {
        Self.isDone(item) { labels.verdict(for: $0) != nil }
    }

    /// Moves to the next card, labeled or skipped.
    func next() {
        if index < items.count { index += 1 }
    }

    /// Starts the build unless one is running or it is built. A failed build starts over.
    func start() {
        guard buildTask == nil, state != .ready else { return }
        state = .loading
        buildTask = Task { [weak self] in
            await self?.run()
            self?.buildTask = nil
        }
    }

    /// Starts the build if needed and waits for it.
    func build() async {
        start()
        await buildTask?.value
    }

    /// Stops the build in flight; it ends as a failure to retry, never as an empty queue.
    func cancelBuild() {
        buildTask?.cancel()
    }

    private func run() async {
        do {
            let built = try await readItems()
            try Task.checkCancellation()
            guard let built else {
                state = .needsBrief
                return
            }
            items = built
            index = 0
            state = .ready
        } catch is CancellationError {
            state = .failed("Stopped before the cards loaded.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The queue's items, or nil when there's no Daily Deck session to read through.
    private func readItems() async throws -> [LabelQueueItem]? {
        try await labels.load(feature: LabelKey.dailyDeckFeature)
        guard store.workspace(for: server) != nil, let sessionID = storedSession() else { return nil }
        let names: [String]
        do {
            names = try await deckClient.entryNames(sessionID: sessionID, path: DailyDeckPaths.directory)
        } catch let error as APIError where error.isVanishedSession {
            return nil
        } catch let error as APIError where error.isNotFound {
            return [] // No `briefs/` yet: nothing to label.
        }
        let dates = Self.windowDates(DailyDeckViewModel.deckDates(in: names, kind: "morning"), now: now())
        let decks = try await read(dates: dates, sessionID: sessionID)
        return Self.items(decks: decks) { labels.verdict(for: $0) != nil }
    }

    /// Today's Daily Deck session, else the newest stored one inside the window.
    private func storedSession() -> String? {
        let today = DailyDeckPaths.day(now())
        if let session = store.session(for: server, date: today) { return session }
        guard let latest = store.latestSession(for: server),
              Self.windowDates([latest.date], now: now()).isEmpty == false
        else { return nil }
        return latest.id
    }

    /// The morning decks for `dates`, in that order. A deck that doesn't decode is skipped; a
    /// read that fails fails the build.
    private func read(dates: [String], sessionID: String) async throws -> [(date: String, kind: String, deck: DailyDeck)] {
        let client = deckClient
        let contents = try await withThrowingTaskGroup(of: (String, String).self) { group in
            for date in dates {
                group.addTask {
                    (date, try await client.fileContent(sessionID: sessionID, path: DailyDeckPaths.deck(date: date, kind: "morning")))
                }
            }
            var byDate: [String: String] = [:]
            for try await (date, content) in group { byDate[date] = content }
            return byDate
        }
        return dates.compactMap { date in
            guard let content = contents[date], let deck = try? DailyDeck.decode(content) else { return nil }
            return (date, "morning", deck)
        }
    }

    /// Days from `dates` within the last `windowDays` (today included), newest first.
    static func windowDates(_ dates: [String], now: Date, calendar: Calendar = .current) -> [String] {
        let today = DailyDeckPaths.day(now, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: now).map { DailyDeckPaths.day($0, calendar: calendar) } ?? today
        return dates.filter { $0 >= start && $0 <= today }.sorted(by: >)
    }

    /// Reflect cards in deck order, decks in the order given, without the ones `isLabeled`
    /// says are done.
    static func items(decks: [(date: String, kind: String, deck: DailyDeck)],
                      isLabeled: (LabelKey) -> Bool) -> [LabelQueueItem] {
        decks.flatMap { entry in
            entry.deck.cards
                .filter { $0.type == .reflect }
                .map { LabelQueueItem(date: entry.date, kind: entry.kind, card: $0) }
                .filter { !isDone($0, isLabeled: isLabeled) }
        }
    }

    /// Labeled for its card, and for its question when it has one.
    private static func isDone(_ item: LabelQueueItem, isLabeled: (LabelKey) -> Bool) -> Bool {
        isLabeled(item.cardKey) && (item.questionKey.map(isLabeled) ?? true)
    }
}
