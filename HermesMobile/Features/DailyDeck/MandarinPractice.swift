import Foundation
import Observation

/// The network surface the Mandarin card needs (`api/vault_mandarin.py` on this user's webui fork).
protocol MandarinPracticeClient: Sendable {
    func answer(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse
    func recall(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse
}

struct APIClientMandarinAdapter: MandarinPracticeClient {
    let apiClient: APIClient

    func answer(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse {
        try await apiClient.answerMandarin(request)
    }

    func recall(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse {
        try await apiClient.recallMandarin(request)
    }
}

/// What he has done on a day's Mandarin card: fixes stepped through, phrases recalled (Got it is
/// true), and the answer the feedback is for. Kept per server and day, so the card resumes.
struct MandarinPracticeRecord: Codable, Equatable {
    var fixesSeen = 0
    var recalled: [String: Bool] = [:]
    var answeredText: String?
    var result: MandarinAnswerResponse?
}

/// The newest `days` records per server in UserDefaults; nothing here is a credential.
struct MandarinPracticeStore {
    var defaults: UserDefaults = .standard
    static let days = 3

    private func key(_ server: URL) -> String { "dailyDeck.mandarin|\(server.absoluteString)" }

    func record(for server: URL, date: String) -> MandarinPracticeRecord? {
        guard let data = (defaults.dictionary(forKey: key(server)) as? [String: Data])?[date] else { return nil }
        return try? JSONDecoder().decode(MandarinPracticeRecord.self, from: data)
    }

    func setRecord(_ record: MandarinPracticeRecord, for server: URL, date: String) {
        var all = (defaults.dictionary(forKey: key(server)) as? [String: Data]) ?? [:]
        all[date] = try? JSONEncoder().encode(record)
        for stale in all.keys.sorted(by: >).dropFirst(Self.days) { all[stale] = nil }
        defaults.set(all, forKey: key(server))
    }
}

/// One day's Mandarin card in four steps: fix yesterday's slips, recall due phrases (Got it / Again),
/// talk (answer the question, cues on hand), and the takeaways that come back seconds after answering.
/// Recalls and answers count only once the server has them; a failure leaves the step where it was.
@MainActor
@Observable
final class MandarinPractice {
    enum Step: String, CaseIterable { case fix, recall, talk }

    enum Answering: Equatable {
        case idle
        case waiting
        case failed(String)
    }

    let card: DeckCard
    let date: String
    var step: Step
    private(set) var record: MandarinPracticeRecord
    private(set) var answering: Answering = .idle
    private(set) var isSavingRecall = false
    private(set) var recallError: String?
    /// The latest progress the server reported: after an answer or a recall, else the deck's.
    private(set) var progress: DeckMandarinProgress?

    @ObservationIgnored private let server: URL
    @ObservationIgnored private let client: (any MandarinPracticeClient)?
    @ObservationIgnored private let store: MandarinPracticeStore
    @ObservationIgnored private var lastAttempt: (text: String, question: String?)?

    init(card: DeckCard, date: String, server: URL, client: (any MandarinPracticeClient)?,
         store: MandarinPracticeStore = MandarinPracticeStore()) {
        self.card = card
        self.date = date
        self.server = server
        self.client = client
        self.store = store
        let record = store.record(for: server, date: date) ?? MandarinPracticeRecord()
        self.record = record
        progress = record.result?.progress ?? card.progress
        step = .talk
        step = firstOpenStep
    }

    /// The steps this card has: a fix only after an answer with feedback, a recall only with phrases due.
    var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .fix: card.yesterday != nil
            case .recall: !card.recall.isEmpty
            case .talk: true
            }
        }
    }

    var fixes: [DeckMandarinFeedback.Fix] { card.yesterday?.fixes ?? [] }

    /// The fix on screen; nil once they've all been seen (or yesterday had none).
    var currentFix: DeckMandarinFeedback.Fix? {
        fixes.indices.contains(record.fixesSeen) ? fixes[record.fixesSeen] : nil
    }

    /// The phrase to recall now: the first one not answered yet.
    var currentRecall: DeckPhrase? { card.recall.first { record.recalled[$0.hanzi] == nil } }

    var result: MandarinAnswerResponse? { record.result }

    func isDone(_ step: Step) -> Bool {
        switch step {
        case .fix: record.fixesSeen >= max(fixes.count, 1)
        case .recall: currentRecall == nil
        case .talk: record.result != nil
        }
    }

    /// Moves past the fix on screen (or yesterday's natural version when there were no fixes).
    func nextFix() {
        record.fixesSeen += 1
        save()
        if isDone(.fix) { step = firstOpenStep }
    }

    func recall(_ phrase: DeckPhrase, got: Bool) async {
        guard !isSavingRecall else { return }
        isSavingRecall = true
        recallError = nil
        defer { isSavingRecall = false }
        if let client {
            do {
                let response = try await client.recall(MandarinRecallRequest(date: date, hanzi: phrase.hanzi, got: got))
                progress = response.progress ?? progress
            } catch {
                recallError = "Couldn't save that. Try again."
                return
            }
        }
        record.recalled[phrase.hanzi] = got
        save()
        if isDone(.recall) { step = firstOpenStep }
    }

    /// Sends the answer for feedback unless this exact text already has it. Called when the
    /// answer sheet closes.
    func submit(_ text: String, question: String?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, answering != .waiting else { return }
        guard text != record.answeredText || record.result?.feedback == nil else { return }
        lastAttempt = (text, question)
        answering = .waiting
        do {
            let response = try await client.answer(MandarinAnswerRequest(date: date, text: text, question: question))
            record.answeredText = text
            record.result = response
            progress = response.progress ?? progress
            save()
            answering = .idle
        } catch {
            answering = .failed("Couldn't reach the server. Try again.")
        }
    }

    /// Try again: the last answer sent, or the one that came back without feedback.
    func retry() async {
        guard let text = lastAttempt?.text ?? record.answeredText else { return }
        await submit(text, question: lastAttempt?.question)
    }

    private var firstOpenStep: Step { steps.first { !isDone($0) } ?? .talk }

    private func save() { store.setRecord(record, for: server, date: date) }
}
