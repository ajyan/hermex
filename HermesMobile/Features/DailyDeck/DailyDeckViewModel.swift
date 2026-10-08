import Foundation
import Observation

/// The network surface the Daily Deck needs. File reads are session-scoped on the
/// server, so the deck owns one session per day in the brief's workspace; filing
/// sends one message to that same session.
protocol DailyDeckDataClient: Sendable {
    func workspacePaths() async throws -> [String]
    func createSession(workspace: String) async throws -> String
    func renameSession(id: String, title: String) async throws
    func entryNames(sessionID: String, path: String) async throws -> [String]
    func fileContent(sessionID: String, path: String) async throws -> String
    func startChat(sessionID: String, message: String, workspace: String) async throws
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
    /// Days with a deck in `briefs/`, newest first.
    private(set) var availableDates: [String] = []
    /// Days whose deck has been filed.
    private(set) var filedDates: Set<String> = []
    /// The page on screen.
    var index = 0

    let server: URL
    /// The user's today: its deck opens first.
    let today: String
    /// The day of the deck on screen.
    private(set) var date: String
    let kind = "morning"
    private let client: any DailyDeckDataClient
    private let store: DailyDeckStore
    private let now: () -> Date

    init(server: URL, client: any DailyDeckDataClient, store: DailyDeckStore = DailyDeckStore(), now: @escaping () -> Date = Date.init) {
        self.server = server
        self.client = client
        self.store = store
        self.now = now
        self.today = DailyDeckPaths.day(now())
        self.date = today
    }

    convenience init(server: URL) {
        self.init(server: server, client: APIClientDailyDeckAdapter(apiClient: APIClient(baseURL: server)))
    }

    var cards: [DeckCard] { deck?.cards ?? [] }

    /// Cards answered (the headline and close cards never count, nor feedback alone).
    var answeredCount: Int { cards.filter { answers[$0.id]?.isAnswer(for: $0) == true }.count }

    /// What the deck shows: every page but cards marked "Not for Me". `index` counts these.
    var visiblePages: [DeckPage] {
        pages.filter { page in
            guard case .card(let card) = page else { return true }
            return answers[card.id]?.feedback == nil
        }
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

    // MARK: Loading

    /// Finds the brief's folder, then opens the deck for `date` (today on first load).
    func load() async {
        state = .loading
        do {
            guard let workspace = try await resolveWorkspace() else { return }
            self.workspace = workspace
            let (sessionID, names) = try await sessionAndBriefs(workspace: workspace)
            self.sessionID = sessionID
            availableDates = Self.deckDates(in: names ?? [], kind: kind)
            filedDates = Self.filedDates(in: names ?? [], kind: kind)
            try await openDeck(names: names ?? [], sessionID: sessionID)
        } catch is CancellationError {
            // A newer load owns the state.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Opens another day's deck from `availableDates`, to reread or edit it.
    func show(date: String) async {
        guard date != self.date || state != .ready else { return }
        self.date = date
        index = 0
        await load()
    }

    /// Loads the deck and, when it was filed, the filed answers. Unsent edits on this
    /// device win over the filed copy, so leaving mid-edit loses nothing.
    private func openDeck(names: [String], sessionID: String) async throws {
        deck = nil
        pages = []
        filedAnswers = nil
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
        try? await client.renameSession(id: created, title: Self.sessionTitle(for: date))
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

    /// "Daily Brief · Oct 5" for the deck's day.
    static func sessionTitle(for day: String) -> String {
        "Daily Brief · \(DailyDeckPaths.label(day))"
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

    /// Chooses a decision action; choosing the chosen one again clears it.
    func choose(_ action: DeckAction, for card: DeckCard) {
        update(card) { answer in
            answer.action = answer.action == action.id ? nil : action.id
            if !action.takesText { answer.text = nil }
        }
    }

    /// The question on screen: the user's or a regenerated one, else the card's.
    func question(for card: DeckCard) -> String? {
        answers[card.id]?.question ?? card.question
    }

    /// Steps to the card's next question, wrapping back to its own.
    func regenerateQuestion(for card: DeckCard) {
        let options = [card.question].compactMap { $0 } + card.altQuestions
        guard options.count > 1 else { return }
        let current = options.firstIndex(of: question(for: card) ?? "") ?? 0
        let next = options[(current + 1) % options.count]
        update(card) { $0.question = next == card.question ? nil : next }
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

    /// Sends the answers in a fresh session, so the chat it opens holds only this filing
    /// (never an earlier, stopped attempt). Filing again sends every answer; the server
    /// updates only what changed. Returns the session id on success so the caller can
    /// open it and watch the agent file them.
    func file() async -> String? {
        guard let deck, let workspace, filing != .filing else { return nil }
        filing = .filing
        do {
            let message = try DeckAnswersPayload(deck: deck, answers: answers, completedAt: now()).message(refiling: isFiled)
            let sessionID = try await client.createSession(workspace: workspace)
            try? await client.renameSession(id: sessionID, title: Self.sessionTitle(for: date))
            store.setSession(sessionID, for: server, date: today)
            self.sessionID = sessionID
            try await client.startChat(sessionID: sessionID, message: message, workspace: workspace)
            store.setAnswers([:], for: server, date: date, kind: kind)
            filedAnswers = answers
            filing = .idle
            return sessionID
        } catch {
            filing = .failed(error.localizedDescription)
            return nil
        }
    }
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol.
private struct APIClientDailyDeckAdapter: DailyDeckDataClient {
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
}

private struct DailyDeckSendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
