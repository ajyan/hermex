import Foundation
import Observation

/// The network surface the Mandarin card needs (`api/vault_mandarin.py` on this user's webui fork).
protocol MandarinPracticeClient: Sendable {
    func answer(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse
}

struct APIClientMandarinAdapter: MandarinPracticeClient {
    let apiClient: APIClient

    func answer(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse {
        try await apiClient.answerMandarin(request)
    }
}

/// What he has done on a day's Mandarin card: the telling the retelling is for, and his second
/// telling with the upgrades he used in it. Kept per server and day, so the card resumes. Records from
/// the warm-up card decode with what still applies.
struct MandarinPracticeRecord: Codable, Equatable {
    var answeredText: String?
    var result: MandarinAnswerResponse?
    var againText: String?
    var againResult: MandarinAnswerResponse?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answeredText = try? c.decodeIfPresent(String.self, forKey: .answeredText)
        result = try? c.decodeIfPresent(MandarinAnswerResponse.self, forKey: .result)
        againText = try? c.decodeIfPresent(String.self, forKey: .againText)
        againResult = try? c.decodeIfPresent(MandarinAnswerResponse.self, forKey: .againResult)
    }
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

/// One day's Mandarin card: he tells it, hears it retold naturally with its upgrades, and tells it
/// again without looking. A telling counts only once the server has it; a failure leaves the card where
/// it was, with Try again.
@MainActor
@Observable
final class MandarinPractice {
    enum Step: String, CaseIterable { case tell, hear, again }

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

    @ObservationIgnored private let server: URL
    @ObservationIgnored private let client: (any MandarinPracticeClient)?
    @ObservationIgnored private let store: MandarinPracticeStore
    @ObservationIgnored private var lastAttempt: (text: String, question: String?, again: Bool)?

    init(card: DeckCard, date: String, server: URL, client: (any MandarinPracticeClient)?,
         store: MandarinPracticeStore = MandarinPracticeStore()) {
        self.card = card
        self.date = date
        self.server = server
        self.client = client
        self.store = store
        let record = store.record(for: server, date: date) ?? MandarinPracticeRecord()
        self.record = record
        step = record.againText != nil ? .again : record.result?.feedback != nil ? .hear : .tell
    }

    var feedback: DeckMandarinFeedback? { record.result?.feedback }
    var result: MandarinAnswerResponse? { record.result }
    var againText: String? { record.againText }

    /// The upgrades' better words he said in his second telling.
    var used: [String] { record.againResult?.used ?? [] }

    func isDone(_ step: Step) -> Bool {
        switch step {
        case .tell: record.answeredText != nil
        case .hear: record.result?.feedback != nil
        case .again: record.againText != nil
        }
    }

    /// Whether a step can be opened from the step bar: Hear it once there's a retelling.
    func canOpen(_ step: Step) -> Bool {
        step == .tell || feedback != nil
    }

    /// Sends the telling for its retelling unless this exact text already has one; the retelling
    /// moves the card to Hear it.
    func submit(_ text: String, question: String?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, answering != .waiting else { return }
        guard text != record.answeredText || record.result?.feedback == nil else { return }
        lastAttempt = (text, question, false)
        answering = .waiting
        do {
            let response = try await client.answer(MandarinAnswerRequest(date: date, text: text, question: question))
            record.answeredText = text
            record.result = response
            record.againText = nil
            record.againResult = nil
            save()
            answering = .idle
            if response.feedback != nil { step = .hear }
        } catch {
            answering = .failed("Couldn't reach the server. Try again.")
        }
    }

    /// His second telling, with the retelling out of sight. Returns whether the server has it, so the
    /// mic keeps his words when not.
    @discardableResult
    func tellAgain(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, answering != .waiting, record.result?.feedback != nil else { return false }
        lastAttempt = (text, nil, true)
        answering = .waiting
        do {
            let response = try await client.answer(MandarinAnswerRequest(date: date, text: text, question: nil, again: true))
            record.againText = text
            record.againResult = response
            save()
            answering = .idle
            return true
        } catch {
            answering = .failed("Couldn't reach the server. Try again.")
            return false
        }
    }

    /// Try again: the last telling sent, or the one that came back without a retelling.
    func retry() async {
        if let lastAttempt, lastAttempt.again {
            await tellAgain(lastAttempt.text)
            return
        }
        guard let text = lastAttempt?.text ?? record.answeredText else { return }
        await submit(text, question: lastAttempt?.question)
    }

    private func save() { store.setRecord(record, for: server, date: date) }
}
