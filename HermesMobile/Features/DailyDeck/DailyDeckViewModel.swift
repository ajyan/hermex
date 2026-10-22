import Foundation
import Observation

/// The network surface the Daily Deck needs. File reads are session-scoped on the
/// server, so the deck owns one session per day in the brief's workspace. Filing goes
/// through the server's filer when it has one, else one message in a fresh session.
protocol DailyDeckDataClient: Sendable {
    func workspacePaths() async throws -> [String]
    func createSession(workspace: String) async throws -> String
    func renameSession(id: String, title: String) async throws
    func entryNames(sessionID: String, path: String) async throws -> [String]
    func fileContent(sessionID: String, path: String) async throws -> String
    func startChat(sessionID: String, message: String, workspace: String) async throws
    /// Files the answers on the server without the model; nil when the server has no filer.
    func fileBrief(_ request: BriefFileRequest) async throws -> BriefFileResponse?
}

enum DailyDeckState: Equatable {
    case idle
    case loading
    /// No workspace chosen yet and the server has several: the user picks one.
    case needsWorkspace([String])
    /// The workspace has no deck for that day (the brief has not run, or was skipped).
    case noDeck
    /// A deck is on screen: to answer, or to reread and edit once filed (`isFiled`).
    case ready
    case failed(String)
}

enum DailyDeckFilingState: Equatable {
    case idle
    case filing
    case failed(String)
}

/// Where a successful filing leaves the user.
enum DailyDeckFilingResult: Equatable {
    /// The server filed everything; the deck shows it as filed.
    case filed
    /// A session is working on the filing (the whole of it, or the follow-ups): open it.
    case openSession(String)
}

/// What the server's filer reported, shown quietly on the close card.
struct DailyDeckFiledNote: Equatable {
    var summary: String?
    /// Steps that failed, as "step: error".
    var failures: [String] = []
}

@MainActor
@Observable
final class DailyDeckViewModel {
    private(set) var state: DailyDeckState = .idle
    private(set) var deck: DailyDeck?
    /// What each swipe shows; set with the deck.
    private(set) var pages: [DeckPage] = []
    private(set) var answers: [String: DeckAnswer] = [:]
    private(set) var filing: DailyDeckFilingState = .idle
    private(set) var sessionID: String?
    private(set) var workspace: String?
    /// What was last filed for the deck on screen; nil until it is filed.
    private(set) var filedAnswers: [String: DeckAnswer]?
    /// The server filer's report from this screen's last filing; nil after a chat filing.
    private(set) var filedNote: DailyDeckFiledNote?
    /// Days with a deck in `briefs/`, newest first.
    private(set) var availableDates: [String] = []
    /// Days whose deck has been filed.
    private(set) var filedDates: Set<String> = []
    /// Weekly and monthly review decks in `briefs/`, newest first.
    private(set) var reviews: [DeckReview] = []
    /// The page on screen.
    var index = 0

    let server: URL
    /// The user's today: its deck opens first. Rolls forward in `refreshDay()`.
    private(set) var today: String
    /// The day of the deck on screen.
    private(set) var date: String
    /// "morning" for the Daily Brief; "weekly" or "monthly" for a review deck.
    private(set) var kind = "morning"

    var isReview: Bool { kind != "morning" }

    var title: String {
        switch kind {
        case "weekly": "Weekly Review"
        case "monthly": "Monthly Review"
        default: "Daily Brief"
        }
    }
    private let client: any DailyDeckDataClient
    private let store: DailyDeckStore
    /// The feedback API, for Undo on the What changed card; nil leaves the card read-only.
    private let feedback: (any FeedbackDataClient)?
    private let now: () -> Date

    init(server: URL, client: any DailyDeckDataClient, store: DailyDeckStore = DailyDeckStore(),
         feedback: (any FeedbackDataClient)? = nil, now: @escaping () -> Date = Date.init) {
        self.server = server
        self.client = client
        self.store = store
        self.feedback = feedback
        self.now = now
        let today = DailyDeckPaths.day(now())
        self.today = today
        self.date = today
    }

    convenience init(server: URL) {
        let apiClient = APIClient(baseURL: server)
        self.init(server: server, client: APIClientDailyDeckAdapter(apiClient: apiClient),
                  feedback: APIClientFeedbackAdapter(apiClient: apiClient))
    }

    var cards: [DeckCard] { deck?.cards ?? [] }

    /// Cards answered (the headline and close cards never count, nor feedback alone).
    var answeredCount: Int { cards.filter { answers[$0.id]?.isAnswer(for: $0) == true }.count }

    /// What the deck shows: every page but cards marked "Not for Me". `index` counts these.
    var visiblePages: [DeckPage] {
        let variant = Self.shownWeekVariant(cards: cards, answers: answers)
        return pages.filter { page in
            guard case .card(let card) = page else { return true }
            if Self.isHiddenWeekCard(card, shownVariant: variant) { return false }
            return answers[card.id]?.feedback == nil
        }
    }

    /// Which of the week's drafted questions is on the divider: its place among the question and
    /// the alternatives, 0 when the deck has no divider.
    var weekVariant: Int { Self.shownWeekVariant(cards: cards, answers: answers) ?? 0 }

    /// The variant the deck's week divider shows, given the deck's answers (filed or unsent): the
    /// divider's answered question's place among its question and alternatives, 0 when it names
    /// none of them. Nil when the deck has no divider. Label recent cards reads it too, so only
    /// the sources he could see are asked about.
    nonisolated static func shownWeekVariant(cards: [DeckCard], answers: [String: DeckAnswer]) -> Int? {
        guard let section = cards.first(where: { $0.type == .section }) else { return nil }
        guard let shown = answers[section.id]?.question ?? section.question else { return 0 }
        return questionOptions(for: section).firstIndex(of: shown) ?? 0
    }

    /// The divider's lines for the question on screen. The vault's second line ("Day 3 · 2 answers
    /// so far", or "No sources fit today") is about the deck's original question, so after "New
    /// question" it becomes the day alone, or "No sources fit today" when the shown question has
    /// no source cards; back on the original it is the vault's again.
    func sectionLines(for card: DeckCard) -> [String] {
        let variant = weekVariant
        let hasSources = cards.contains { $0.type != .section && $0.weekVariant == variant }
        return Self.sectionLines(card.lines, variant: variant, hasSources: hasSources, date: deck?.date ?? date)
    }

    nonisolated static func sectionLines(_ lines: [String], variant: Int, hasSources: Bool, date: String) -> [String] {
        guard variant != 0, lines.count > 1 else { return lines }
        var out = lines
        if !hasSources {
            out[1] = "No sources fit today"
        } else if lines[1].hasPrefix("Day "), let day = lines[1].components(separatedBy: " · ").first {
            out[1] = day
        } else if let day = weekDay(date) {
            out[1] = "Day \(day)"  // the vault's "No sources fit today" carries no day: count it from the date
        } else {
            out.remove(at: 1)
        }
        return out
    }

    /// The day of the week of `2026-10-28`, Monday as 1, as the vault counts it.
    nonisolated private static func weekDay(_ day: String) -> Int? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let calendar = Calendar(identifier: .gregorian)
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// A week source card for a question the divider isn't showing. The divider carries a variant
    /// too but always stays, and with no divider (`shownVariant` nil) every week card shows.
    nonisolated static func isHiddenWeekCard(_ card: DeckCard, shownVariant: Int?) -> Bool {
        guard let shownVariant, card.type != .section, let variant = card.weekVariant else { return false }
        return variant != shownVariant
    }

    var currentPage: DeckPage? {
        let visible = visiblePages
        return visible.indices.contains(index) ? visible[index] : nil
    }

    /// Cards on this deck marked "Not for Me".
    var skippedCount: Int { cards.filter { answers[$0.id]?.feedback != nil }.count }

    /// The last card marked "Not for Me" and its answer before that, for Undo.
    private(set) var lastDismissal: (card: DeckCard, previous: DeckAnswer?)?

    func answer(for card: DeckCard) -> DeckAnswer? { answers[card.id] }

    var isFiled: Bool { filedAnswers != nil }

    /// Whether the answers differ from what was filed (always true before the first filing).
    var hasChanges: Bool {
        guard let filedAnswers else { return true }
        return meaningful(answers) != meaningful(filedAnswers)
    }

    private func meaningful(_ answers: [String: DeckAnswer]) -> [String: DeckAnswer] {
        Dictionary(uniqueKeysWithValues: cards.compactMap { card in
            guard var answer = answers[card.id], answer.isMeaningful(for: card) else { return nil }
            answer.text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (card.id, answer)
        })
    }

    // MARK: What changed

    /// Feedback entries undone from a What changed card on this screen. Entry ids are the
    /// server's, so an undone row stays undone on any deck that lists it.
    private(set) var undoneChanges: Set<String> = []
    /// Each row's last Undo failure: the server's reason on a 409 ("The vault has uncommitted edits…").
    private(set) var changeErrors: [String: String] = [:]
    /// A row's note that isn't a failure: "Already undone" when a stale card's Undo finds the
    /// entry undone elsewhere.
    private(set) var changeNotices: [String: String] = [:]
    /// The row whose Undo is in flight. One at a time.
    private(set) var undoingChangeID: String?

    /// The row's state, with an Undo from this screen applied.
    func changeState(_ row: DeckChangeRow) -> DeckChangeRow.State {
        undoneChanges.contains(row.id) ? .reverted : row.state
    }

    /// Whether the row offers Undo: the server marked it undoable and it isn't undone yet.
    func canUndo(_ row: DeckChangeRow) -> Bool {
        feedback != nil && row.undoable == true && changeState(row) != .reverted
    }

    /// Posts the row's `undo` decision. The row shows Undone only once the server says so,
    /// including a 409 that finds it undone already (a stale card); a failure stays under the row.
    func undoChange(_ row: DeckChangeRow) async {
        guard let feedback, canUndo(row), undoingChangeID == nil else { return }
        undoingChangeID = row.id
        changeErrors[row.id] = nil
        defer { undoingChangeID = nil }
        do {
            _ = try await feedback.decide(id: row.id, .undo)
            undoneChanges.insert(row.id)
        } catch let conflict as APIError where FeedbackInboxViewModel.conflictStatus(conflict) == .reverted {
            undoneChanges.insert(row.id)
            changeNotices[row.id] = "Already undone"
        } catch let conflict as APIError where FeedbackInboxViewModel.isConflict(conflict) {
            changeErrors[row.id] = conflict.serverMessage ?? "This changed on the server. Check Feedback."
        } catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            changeErrors[row.id] = "Couldn't undo that. Try again."
        }
    }

    // MARK: Loading

    /// Finds the brief's folder, then opens the deck for `date` (today on first load).
    func load() async {
        state = .loading
        do {
            guard let workspace = try await resolveWorkspace() else { return }
            self.workspace = workspace
            let (sessionID, names) = try await sessionAndBriefs(workspace: workspace)
            self.sessionID = sessionID
            availableDates = Self.deckDates(in: names ?? [], kind: "morning")
            filedDates = Self.filedDates(in: names ?? [], kind: "morning")
            reviews = DeckReview.all(in: names ?? [])
            try await openDeck(names: names ?? [], sessionID: sessionID)
            await loadDiagrams(sessionID: sessionID)
        } catch is CancellationError {
            // A newer load owns the state.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Rolls `today` forward when the app comes back on a new day. A screen left on the old
    /// today's brief moves to the new one; a past day or review the user opened stays.
    func refreshDay() async {
        let day = DailyDeckPaths.day(now())
        guard day != today else { return }
        let wasOnToday = date == today && kind == "morning"
        today = day
        guard wasOnToday else { return }
        date = day
        index = 0
        await load()
    }

    /// Opens another deck: a past day's brief to reread or edit, or a review. With `cardID`, it
    /// lands on that card once loaded (the deck already on screen just moves to it).
    func show(date: String, kind: String = "morning", cardID: String? = nil) async {
        if date != self.date || kind != self.kind || state != .ready {
            self.date = date
            self.kind = kind
            index = 0
            await load()
        }
        guard let cardID, state == .ready, let i = visiblePages.firstIndex(where: { $0.id == cardID }) else { return }
        index = i
    }

    /// Loads the deck and, when it was filed, the filed answers. Unsent edits on this
    /// device win over the filed copy, so leaving mid-edit loses nothing.
    private func openDeck(names: [String], sessionID: String) async throws {
        deck = nil
        pages = []
        filedAnswers = nil
        filedNote = nil
        guard names.contains(fileName(DailyDeckPaths.deck(date: date, kind: kind))) else {
            state = .noDeck
            return
        }
        let content = try await client.fileContent(sessionID: sessionID, path: DailyDeckPaths.deck(date: date, kind: kind))
        let decoded = try DailyDeck.decode(content)
        if names.contains(fileName(DailyDeckPaths.answers(date: date, kind: kind))) {
            let filed = try await client.fileContent(sessionID: sessionID, path: DailyDeckPaths.answers(date: date, kind: kind))
            filedAnswers = DeckAnswersFile.decodeAnswers(filed)
        }
        deck = decoded
        pages = DeckPage.pages(for: decoded.cards)
        let draft = store.answers(for: server, date: date, kind: kind)
        answers = draft.isEmpty ? (filedAnswers ?? [:]) : draft
        index = min(index, max(visiblePages.count - 1, 0))
        lastDismissal = nil
        state = .ready
    }

    // MARK: Diagrams

    /// The vault's diagram index; empty until loaded, and when the vault has none.
    private(set) var diagrams: BriefDiagramIndex = .empty
    private var hasDiagramIndex = false
    private var diagramFragments: [String: String] = [:]

    /// The interactive diagram for a technical card, when the vault has one.
    func diagram(for card: DeckCard) -> BriefDiagramIndex.Entry? { diagrams.diagram(for: card) }

    /// Reads the index once per screen, after the first deck is up. A missing index means no Diagram
    /// chips; a failed read leaves none for now and tries again on the next load.
    private func loadDiagrams(sessionID: String) async {
        guard !hasDiagramIndex,
              let content = try? await client.fileContent(sessionID: sessionID, path: BriefDiagramIndex.path)
        else { return }
        diagrams = BriefDiagramIndex.decode(content)
        hasDiagramIndex = true
    }

    /// A diagram's `atlas-ui` fragment, read from the vault once per screen.
    func diagramFragment(_ entry: BriefDiagramIndex.Entry) async throws -> String {
        if let cached = diagramFragments[entry.topic] { return cached }
        guard let sessionID else { throw CancellationError() }
        let fragment = try await client.fileContent(sessionID: sessionID, path: entry.fragmentPath)
        diagramFragments[entry.topic] = fragment
        return fragment
    }

    /// Days with `<date>.<kind>.answers.json`, the file the agent saves when a deck is filed.
    nonisolated static func filedDates(in names: [String], kind: String) -> Set<String> {
        let suffix = ".\(kind).answers.json"
        return Set(names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) })
    }

    /// `2026-10-05` from `2026-10-05.morning.json`, newest first.
    nonisolated static func deckDates(in names: [String], kind: String) -> [String] {
        let suffix = ".\(kind).json"
        return names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }.sorted(by: >)
    }

    func chooseWorkspace(_ path: String) async {
        store.setWorkspace(path, for: server)
        await load()
    }

    /// Clears the chosen workspace so the next load asks again.
    func resetWorkspace() async {
        store.setWorkspace(nil, for: server)
        workspace = nil
        await load()
    }

    /// The stored workspace, or the server's only one. Sets `.needsWorkspace` and
    /// returns nil when the user has to choose.
    private func resolveWorkspace() async throws -> String? {
        if let stored = store.workspace(for: server) { return stored }
        let paths = try await client.workspacePaths()
        if paths.count == 1, let only = paths.first {
            store.setWorkspace(only, for: server)
            return only
        }
        state = .needsWorkspace(paths)
        return nil
    }

    /// A session to read `briefs/` through (today's, whichever deck is shown) and the names
    /// in it (nil when the folder is missing). A session the server lost is replaced once.
    private func sessionAndBriefs(workspace: String) async throws -> (String, [String]?) {
        if let stored = store.session(for: server, date: today) {
            do {
                return (stored, try await briefNames(sessionID: stored))
            } catch let error as APIError where error.isVanishedSession {
                // Fall through to a fresh session.
            }
        }
        let created = try await client.createSession(workspace: workspace)
        store.setSession(created, for: server, date: today)
        try? await client.renameSession(id: created, title: Self.sessionTitle(for: date, kind: kind))
        return (created, try await briefNames(sessionID: created))
    }

    private func briefNames(sessionID: String) async throws -> [String]? {
        do {
            return try await client.entryNames(sessionID: sessionID, path: DailyDeckPaths.directory)
        } catch let error as APIError where error.isNotFound && !error.isVanishedSession {
            return nil
        }
    }

    private func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// "Daily Brief · Oct 5" for the deck's day; reviews say which.
    static func sessionTitle(for day: String, kind: String = "morning") -> String {
        let name = kind == "weekly" ? "Weekly Review" : kind == "monthly" ? "Monthly Review" : "Daily Brief"
        return "\(name) · \(DailyDeckPaths.label(day))"
    }

    // MARK: Journal

    /// Days in `year`-`month` with a journal entry (`journal/YYYY/MM-Month/YYYY-MM-DD.md`).
    /// The month folder is found by its `MM-` prefix, whatever the month is spelled as.
    func journalDays(year: Int, month: Int) async -> Set<String> {
        guard let sessionID, let folder = await monthFolder(year: year, month: month, sessionID: sessionID),
              let names = try? await client.entryNames(sessionID: sessionID, path: folder)
        else { return [] }
        let prefix = String(format: "%04d-%02d-", year, month)
        return Set(names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
    }

    /// That day's journal entry as Markdown, without machine markers.
    func journalEntry(for day: String) async throws -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard let sessionID, parts.count == 3,
              let folder = await monthFolder(year: parts[0], month: parts[1], sessionID: sessionID)
        else { throw DailyDeckJournalError.missing }
        let text = try await client.fileContent(sessionID: sessionID, path: "\(folder)/\(day).md")
        return DailyDeckJournal.readable(text)
    }

    /// Every night's sleep numbers (`data/sleep/history.json`), or nil before the vault has written it.
    func sleepHistory() async throws -> SleepHistory? {
        guard let sessionID else { return nil }
        do {
            let text = try await client.fileContent(sessionID: sessionID, path: SleepHistoryPaths.history)
            return try SleepHistory.decode(Data(text.utf8))
        } catch let error as APIError where error.isNotFound {
            return nil
        }
    }

    private func monthFolder(year: Int, month: Int, sessionID: String) async -> String? {
        let base = "journal/\(year)"
        guard let names = try? await client.entryNames(sessionID: sessionID, path: base),
              let folder = names.first(where: { $0.hasPrefix(String(format: "%02d-", month)) })
        else { return nil }
        return "\(base)/\(folder)"
    }

    // MARK: Answering

    func setText(_ text: String, for card: DeckCard) {
        update(card) { $0.text = text }
    }

    /// Rates a sleep card (1-based into its scale); tapping the chosen rating again clears it.
    func rate(_ rating: Int, for card: DeckCard) {
        update(card) { $0.rating = $0.rating == rating ? nil : rating }
    }

    /// Scores one trait on a self-rating card (1–10); tapping its chosen score again clears it.
    /// The answer is rebuilt as text, so filing reads it like a typed one.
    func rateTrait(_ trait: String, _ score: Int, for card: DeckCard) {
        guard let traits = card.selfRatings else { return }
        update(card) { answer in
            var scores = DeckSelfRatings.scores(in: answer.text, traits: traits)
            scores[trait] = scores[trait] == score ? nil : score
            answer.text = DeckSelfRatings.text(scores, traits: traits)
        }
    }

    /// A self-rating card's scores so far, read from its answer text.
    func traitScores(for card: DeckCard) -> [String: Int] {
        DeckSelfRatings.scores(in: answers[card.id]?.text, traits: card.selfRatings ?? [])
    }

    /// Taps a sleep card's tag on or off.
    func toggleTag(_ tag: String, for card: DeckCard) {
        update(card) { answer in
            var tags = answer.tags ?? []
            if let index = tags.firstIndex(of: tag) { tags.remove(at: index) } else { tags.append(tag) }
            answer.tags = tags.isEmpty ? nil : tags
        }
    }

    /// Chooses a decision action; choosing the chosen one again clears it.
    func choose(_ action: DeckAction, for card: DeckCard) {
        update(card) { answer in
            answer.action = answer.action == action.id ? nil : action.id
            if !action.takesText { answer.text = nil }
        }
    }

    /// Records that the phone sent `action`'s message, so filing logs the contact. Only called
    /// after Messages reports the text went out; a cancelled sheet leaves the card as it was.
    /// The sheet doesn't say what was finally sent, so this records the words it opened with:
    /// `body` when given (edited on the card), else the suggestion.
    func markTexted(_ action: DeckAction, body: String? = nil, for card: DeckCard) {
        let body = (body ?? action.message?.body)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        update(card) { answer in
            answer.action = action.id
            answer.text = body.isEmpty ? nil : body
        }
    }

    /// The question on screen: the user's or a regenerated one, else the card's.
    func question(for card: DeckCard) -> String? {
        answers[card.id]?.question ?? card.question
    }

    /// Steps to the card's next question, wrapping back to its own.
    func regenerateQuestion(for card: DeckCard) {
        let options = Self.questionOptions(for: card)
        guard options.count > 1 else { return }
        let current = options.firstIndex(of: question(for: card) ?? "") ?? 0
        let next = options[(current + 1) % options.count]
        let anchor = currentPage?.id
        update(card) { $0.question = next == card.question ? nil : next }
        // The week's divider swaps the cards after it; stay on the page that was on screen.
        if let anchor, let position = visiblePages.firstIndex(where: { $0.id == anchor }) {
            index = position
        } else {
            index = min(index, max(visiblePages.count - 1, 0))
        }
    }

    nonisolated private static func questionOptions(for card: DeckCard) -> [String] {
        [card.question].compactMap { $0 } + card.altQuestions
    }

    /// Sets the note on why a question was chosen, kept exactly as typed (a leading space too);
    /// filing trims it, and a blank note files as none.
    func setNote(_ text: String, for card: DeckCard) {
        update(card) { $0.text = text.isEmpty ? nil : text }
    }

    /// Replaces the card's question with the user's own; an empty one restores the card's.
    func setOwnQuestion(_ text: String, for card: DeckCard) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update(card) { $0.question = trimmed.isEmpty || trimmed == card.question ? nil : trimmed }
    }

    /// Marks a card "Not for Me": it leaves the deck and its feedback is filed with the answers.
    func dismiss(_ card: DeckCard, feedback: DeckFeedback) {
        var feedback = feedback
        feedback.note = feedback.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if feedback.note?.isEmpty == true { feedback.note = nil }
        lastDismissal = (card, answers[card.id])
        update(card) { $0.feedback = feedback }
        index = min(index, max(visiblePages.count - 1, 0))
    }

    /// Puts the last dismissed card back where it was and shows it.
    func undoDismissal() {
        guard let (card, previous) = lastDismissal else { return }
        lastDismissal = nil
        update(card) { $0 = previous ?? DeckAnswer(card: card.id) }
        if let position = visiblePages.firstIndex(where: { $0.id == card.id }) { index = position }
    }

    func clearDismissal() { lastDismissal = nil }

    /// Brings back every card marked "Not for Me" on this deck, dropping their feedback.
    func restoreSkipped() {
        lastDismissal = nil
        for card in cards where answers[card.id]?.feedback != nil {
            update(card) { $0.feedback = nil }
        }
    }

    private func update(_ card: DeckCard, _ change: (inout DeckAnswer) -> Void) {
        var answer = answers[card.id] ?? DeckAnswer(card: card.id)
        change(&answer)
        answers[card.id] = answer.isEmpty ? nil : answer
        store.setAnswers(answers, for: server, date: date, kind: kind)
    }

    // MARK: Filing

    /// Files the answers. The server's filer does it without the model; when it leaves
    /// follow-ups for the agent, they go to a fresh session the caller opens. A server without
    /// the filer gets the whole filing as one message in a fresh session, as before. Filing
    /// again sends every answer; the server updates only what changed. Returns nil on failure.
    func file() async -> DailyDeckFilingResult? {
        guard let deck, let workspace, filing != .filing else { return nil }
        filing = .filing
        // What is sent: the user can type or open another day while it's in flight.
        let (date, kind, sent) = (date, kind, answers)
        let payload = DeckAnswersPayload(deck: deck, answers: sent, completedAt: now())
        let refiling = isFiled
        let filed: BriefFileResponse?
        do {
            filed = try await client.fileBrief(BriefFileRequest(date: deck.date, kind: deck.kind, answers: payload))
        } catch {
            filing = .failed(error.localizedDescription)
            return nil
        }
        guard let filed else {
            // No filer on this server: the agent files it from the message.
            do {
                let sessionID = try await startSession(
                    message: try payload.message(refiling: refiling), title: Self.sessionTitle(for: date, kind: kind), workspace: workspace)
                markFiled(sent, date: date, kind: kind, note: nil)
                return .openSession(sessionID)
            } catch {
                filing = .failed(error.localizedDescription)
                return nil
            }
        }
        if filed.ok == false {
            filing = .failed(filed.error ?? filed.summary ?? "The server couldn't file the brief.")
            return nil
        }
        // The answers are filed now; a failure below only loses the follow-ups.
        markFiled(sent, date: date, kind: kind, note: DailyDeckFiledNote(
            summary: Self.trimmed(filed.summary),
            failures: (filed.ran ?? []).filter { $0.ok == false }.map { step in
                [step.step, step.error].compactMap { $0 }.joined(separator: ": ")
            }))
        let steps = (filed.agentSteps ?? []).compactMap(Self.trimmed)
        guard !steps.isEmpty else { return .filed }
        do {
            return .openSession(try await startSession(
                message: payload.followUpMessage(steps: steps), title: Self.sessionTitle(for: date, kind: kind), workspace: workspace))
        } catch {
            filing = .failed("Filed, but the follow-ups didn't start: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Records `sent` as filed for its deck. The draft is cleared only if it still matches what
    /// was sent, so edits made while filing stay unsent; another deck on screen is left alone.
    private func markFiled(_ sent: [String: DeckAnswer], date: String, kind: String, note: DailyDeckFiledNote?) {
        if store.answers(for: server, date: date, kind: kind) == sent {
            store.setAnswers([:], for: server, date: date, kind: kind)
        }
        filing = .idle
        guard date == self.date, kind == self.kind else { return }
        filedAnswers = sent
        filedNote = note
    }

    /// A fresh session (so the chat holds only this filing, never an earlier stopped attempt)
    /// with `message` sent; it becomes today's session.
    private func startSession(message: String, title: String, workspace: String) async throws -> String {
        let sessionID = try await client.createSession(workspace: workspace)
        try? await client.renameSession(id: sessionID, title: title)
        store.setSession(sessionID, for: server, date: today)
        self.sessionID = sessionID
        try await client.startChat(sessionID: sessionID, message: message, workspace: workspace)
        return sessionID
    }
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol.
struct APIClientDailyDeckAdapter: DailyDeckDataClient {
    let apiClient: APIClient

    func workspacePaths() async throws -> [String] {
        try await apiClient.workspaces().workspaces?.compactMap(\.path) ?? []
    }

    func createSession(workspace: String) async throws -> String {
        let response = try await apiClient.createSession(workspace: workspace, model: nil, modelProvider: nil, profile: nil)
        guard let id = response.session?.sessionId, !id.isEmpty else {
            throw DailyDeckSendError(message: "The server did not return a session.")
        }
        return id
    }

    func renameSession(id: String, title: String) async throws {
        _ = try await apiClient.renameSession(id: id, title: title)
    }

    func entryNames(sessionID: String, path: String) async throws -> [String] {
        try await apiClient.directoryList(sessionID: sessionID, path: path).entries?.compactMap(\.name) ?? []
    }

    func fileContent(sessionID: String, path: String) async throws -> String {
        let response = try await apiClient.file(sessionID: sessionID, path: path)
        guard let content = response.content else { throw APIError.http(statusCode: 404, body: response.error) }
        return content
    }

    func startChat(sessionID: String, message: String, workspace: String) async throws {
        let response = try await apiClient.startChat(sessionID: sessionID, message: message, workspace: workspace, model: nil)
        // The server accepted the turn only if it started a stream.
        guard response.streamId?.isEmpty == false else {
            throw DailyDeckSendError(message: response.error ?? "The server did not return a stream ID.")
        }
    }

    func fileBrief(_ request: BriefFileRequest) async throws -> BriefFileResponse? {
        try await apiClient.fileBrief(request)
    }
}

private struct DailyDeckSendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
