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

/// Settings › Feedback › Label recent cards: reflect cards from the last 14 days of Daily
/// Decks, newest first, without the ones already labeled. Decks are read the way the Daily
/// Deck reads them (its workspace and session, `DailyDeckPaths`). Built once; every tap saves
/// at once, so leaving at any point loses nothing.
@MainActor
@Observable
final class LabelQueueViewModel {
    enum State: Equatable {
        case idle, loading, ready
        /// The Daily Deck hasn't been told which workspace holds `briefs/` yet.
        case needsWorkspace
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

    /// Builds the queue once; a failed or unfinished build can run again.
    func build() async {
        guard state != .loading, state != .ready else { return }
        state = .loading
        do {
            try await labels.load(feature: LabelKey.dailyDeckFeature)
            let deck = DailyDeckViewModel(server: server, client: deckClient, store: store, now: now)
            await deck.load()
            if case .needsWorkspace = deck.state { state = .needsWorkspace; return }
            if case .failed(let message) = deck.state { state = .failed(message); return }
            guard let sessionID = deck.sessionID else { state = .failed("Couldn't open the briefs folder."); return }
            let dates = Self.windowDates(deck.availableDates, now: now())
            let decks = await read(dates: dates, sessionID: sessionID)
            items = Self.items(decks: decks) { labels.verdict(for: $0) != nil }
            index = 0
            state = .ready
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The morning decks for `dates`, in that order; one that can't be read or decoded is left out.
    private func read(dates: [String], sessionID: String) async -> [(date: String, kind: String, deck: DailyDeck)] {
        let client = deckClient
        let contents = await withTaskGroup(of: (String, String?).self) { group in
            for date in dates {
                group.addTask {
                    (date, try? await client.fileContent(sessionID: sessionID, path: DailyDeckPaths.deck(date: date, kind: "morning")))
                }
            }
            var byDate: [String: String] = [:]
            for await (date, content) in group { byDate[date] = content }
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
