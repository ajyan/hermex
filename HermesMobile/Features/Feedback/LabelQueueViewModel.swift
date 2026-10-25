import Foundation
import Observation

/// One card waiting in Rate earlier cards.
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

/// Rate earlier cards, on today's morning deck's closing card: a few reflect cards a day from the
/// last 14 days of morning Daily Decks that haven't said how they landed yet: not labeled (a
/// feedback note on a card labels it on the server), not written about, not sent away with Not
/// for Me. Cards the morning check doubted come first (see `items`), the rest newest first. It
/// asks until both Deck eval judges are calibrated on these labels. Read-only: it reads `briefs/` through the session
/// the Daily Deck already opened, and never creates or renames a session or stores a workspace.
/// Built once, by one task its entry points share; every tap saves at once, so leaving at any
/// point loses nothing.
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
    /// Cards to rate a day: a few, never a backlog. Cards labeled earlier today count.
    static let dailyBatch = 3
    /// The Deck eval judges' newest calibrations (`deck_evals.py calibrate`, Sundays), in the workspace.
    static let calibrationPaths = ["evals/deck/calibration.json", "evals/deck/calibration-card.json"]

    private(set) var state: State = .idle
    /// Fixed once built, so "N of M" holds still while cards are labeled.
    private(set) var items: [LabelQueueItem] = []
    private(set) var index = 0
    /// Whether both judges said calibrated at the last build; a missing or unreadable file says no.
    private(set) var judgesCalibrated = false
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

    var current: LabelQueueItem? { items.indices.contains(index) ? items[index] : nil }

    /// Cards in the queue still missing a label; drops as they are labeled.
    var unlabeledCount: Int { items.filter { !isLabeled($0) }.count }

    func isLabeled(_ item: LabelQueueItem) -> Bool {
        Self.hasLabel(item) { labels.verdict(for: $0) != nil }
    }

    /// Whether the evals still want labels: until both judges agree with them.
    var evalsWantLabels: Bool { !judgesCalibrated }

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
        judgesCalibrated = await readCalibrated(sessionID: sessionID)
        try Task.checkCancellation() // a stopped build fails to retry, never reads as calibrated or empty
        let today = DailyDeckPaths.day(now())
        let left = max(0, Self.dailyBatch - labels.tappedItemCount(feature: LabelKey.dailyDeckFeature, on: today))
        guard left > 0, !judgesCalibrated else { return [] }
        let dates = Self.windowDates(DailyDeckViewModel.deckDates(in: names, kind: "morning"), now: now())
        let filed = DailyDeckViewModel.filedDates(in: names, kind: "morning")
        let decks = try await read(dates: dates, sessionID: sessionID)
        let answers = await readAnswers(dates: dates.filter(filed.contains), sessionID: sessionID)
        return Self.items(decks: decks, limit: left,
                          isLabeled: { labels.verdict(for: $0) != nil },
                          landed: { date, cardID in
                              let unsent = store.answers(for: server, date: date, kind: "morning")[cardID]
                              return (unsent ?? answers[date]?[cardID])?.saysHowItLanded == true
                          },
                          answers: { date in
                              // The deck screen's rule: unsent answers when there are any, else what was filed.
                              let unsent = store.answers(for: server, date: date, kind: "morning")
                              return unsent.isEmpty ? answers[date] ?? [:] : unsent
                          })
    }

    /// Whether every judge's calibration file says `calibrated: true`.
    private func readCalibrated(sessionID: String) async -> Bool {
        for path in Self.calibrationPaths {
            guard !Task.isCancelled, let content = try? await deckClient.fileContent(sessionID: sessionID, path: path),
                  Self.isCalibrated(content) else { return false }
        }
        return true
    }

    /// A calibration file's verdict: `{"calibrated": true, …}`; anything else is not calibrated.
    static func isCalibrated(_ content: String) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        return object?["calibrated"] as? Bool == true
    }

    /// The filed answers for `dates` by day. A file that can't be read or decoded counts as none:
    /// at worst the queue asks about a card that was answered.
    private func readAnswers(dates: [String], sessionID: String) async -> [String: [String: DeckAnswer]] {
        let client = deckClient
        return await withTaskGroup(of: (String, String?).self) { group in
            for date in dates {
                group.addTask {
                    (date, try? await client.fileContent(sessionID: sessionID, path: DailyDeckPaths.answers(date: date, kind: "morning")))
                }
            }
            var byDate: [String: [String: DeckAnswer]] = [:]
            for await (date, content) in group {
                if let content { byDate[date] = DeckAnswersFile.decodeAnswers(content) }
            }
            return byDate
        }
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

    /// The first `limit` reflect cards that are neither labeled nor `landed` (answered or Not for
    /// Me'd, by date and card id), doubtful ones first: cards with a part the eval judge failed
    /// and the morning check `kept` (the judge disagreed with what he saw, so his label says the
    /// most), then cards with a judge-failed part that was `regenerated`, then the rest. Within
    /// each group, deck order, decks in the order given. Of the week's source cards only the shown
    /// question's count: the divider's choice comes from `answers` (the deck's answers by date),
    /// and the other questions' sources were never on screen.
    static func items(decks: [(date: String, kind: String, deck: DailyDeck)], limit: Int = .max,
                      isLabeled: (LabelKey) -> Bool,
                      landed: (String, String) -> Bool = { _, _ in false },
                      answers: (String) -> [String: DeckAnswer] = { _ in [:] }) -> [LabelQueueItem] {
        let candidates = decks.flatMap { entry in
            let variant = DailyDeckViewModel.shownWeekVariant(cards: entry.deck.cards, answers: answers(entry.date))
            return entry.deck.cards
                .filter { $0.type == .reflect && !DailyDeckViewModel.isHiddenWeekCard($0, shownVariant: variant) }
                .map { (item: LabelQueueItem(date: entry.date, kind: entry.kind, card: $0),
                        doubt: doubt(of: $0.id, checks: entry.deck.checks)) }
        }
        .filter { !hasLabel($0.item, isLabeled: isLabeled) && !landed($0.item.date, $0.item.card.id) }
        // The position breaks ties, since `sorted` promises no stability.
        let ordered = candidates.enumerated()
            .sorted { ($0.element.doubt, $0.offset) < ($1.element.doubt, $1.offset) }
            .map(\.element.item)
        return Array(ordered.prefix(limit))
    }

    /// 0 for a card with a judge-failed part shown as is, 1 for one regenerated, 2 otherwise.
    private static func doubt(of cardID: String, checks: [DeckCheck]) -> Int {
        let failed = checks.filter { $0.card == cardID && $0.judgeFailed }
        if failed.contains(where: { $0.action == "kept" }) { return 0 }
        if failed.contains(where: { $0.action == "regenerated" }) { return 1 }
        return 2
    }

    /// A label on its card or its question: either says how the card landed.
    private static func hasLabel(_ item: LabelQueueItem, isLabeled: (LabelKey) -> Bool) -> Bool {
        isLabeled(item.cardKey) || item.questionKey.map(isLabeled) == true
    }
}
