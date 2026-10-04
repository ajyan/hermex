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
    /// The workspace has no deck for today (the brief has not run, or was skipped).
    case noDeck
    case ready
    /// Today's answers are already filed.
    case filed
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
    private(set) var answers: [String: DeckAnswer] = [:]
    private(set) var filing: DailyDeckFilingState = .idle
    private(set) var sessionID: String?
    private(set) var workspace: String?
    /// The card on screen.
    var index = 0

    let server: URL
    let date: String
    let kind = "morning"
    private let client: any DailyDeckDataClient
    private let store: DailyDeckStore
    private let now: () -> Date

    init(server: URL, client: any DailyDeckDataClient, store: DailyDeckStore = DailyDeckStore(), now: @escaping () -> Date = Date.init) {
        self.server = server
        self.client = client
        self.store = store
        self.now = now
        self.date = DailyDeckPaths.day(now())
    }

    convenience init(server: URL) {
        self.init(server: server, client: APIClientDailyDeckAdapter(apiClient: APIClient(baseURL: server)))
    }

    var cards: [DeckCard] { deck?.cards ?? [] }

    /// Cards with something to send (the headline and close cards never count).
    var answeredCount: Int { cards.filter { answers[$0.id]?.isMeaningful(for: $0) == true }.count }

    func answer(for card: DeckCard) -> DeckAnswer? { answers[card.id] }

    // MARK: Loading

    func load() async {
        state = .loading
        do {
            guard let workspace = try await resolveWorkspace() else { return }
            self.workspace = workspace
            let (sessionID, names) = try await sessionAndBriefs(workspace: workspace)
            self.sessionID = sessionID
            guard let names else { state = .noDeck; return }
            if names.contains(fileName(DailyDeckPaths.answers(date: date, kind: kind))) {
                state = .filed
                return
            }
            guard names.contains(fileName(DailyDeckPaths.deck(date: date, kind: kind))) else {
                state = .noDeck
                return
            }
            let content = try await client.fileContent(sessionID: sessionID, path: DailyDeckPaths.deck(date: date, kind: kind))
            deck = try DailyDeck.decode(content)
            answers = store.answers(for: server, date: date, kind: kind)
            index = min(index, max(cards.count - 1, 0))
            state = .ready
        } catch is CancellationError {
            // A newer load owns the state.
        } catch {
            state = .failed(error.localizedDescription)
        }
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

    /// Today's session and the names in `briefs/` (nil when the folder is missing).
    /// A remembered session the server no longer knows is replaced once.
    private func sessionAndBriefs(workspace: String) async throws -> (String, [String]?) {
        if let stored = store.session(for: server, date: date) {
            do {
                return (stored, try await briefNames(sessionID: stored))
            } catch let error as APIError where error.isVanishedSession {
                // Fall through to a fresh session.
            }
        }
        let created = try await client.createSession(workspace: workspace)
        store.setSession(created, for: server, date: date)
        try? await client.renameSession(id: created, title: Self.sessionTitle(for: now()))
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

    static func sessionTitle(for date: Date) -> String {
        "Daily Brief · \(date.formatted(.dateTime.month(.abbreviated).day()))"
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

    func react(_ reaction: DeckReaction, for card: DeckCard) {
        update(card) { $0.reaction = $0.reaction == reaction ? nil : reaction }
    }

    private func update(_ card: DeckCard, _ change: (inout DeckAnswer) -> Void) {
        var answer = answers[card.id] ?? DeckAnswer(card: card.id)
        change(&answer)
        answers[card.id] = answer.isEmpty ? nil : answer
        store.setAnswers(answers, for: server, date: date, kind: kind)
    }

    // MARK: Filing

    /// Sends the answers to today's session. Returns that session's id on success so
    /// the caller can open it and watch the agent file them.
    func file() async -> String? {
        guard let deck, let sessionID, let workspace, filing != .filing else { return nil }
        filing = .filing
        do {
            let message = try DeckAnswersPayload(deck: deck, answers: answers, completedAt: now()).message()
            try await client.startChat(sessionID: sessionID, message: message, workspace: workspace)
            store.setAnswers([:], for: server, date: date, kind: kind)
            filing = .idle
            state = .filed
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
