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

/// What he has done on a day's Mandarin card: whether the warm-up started, each warm-up phrase he
/// answered (Got it is true; a recall phrase's answer is in `recalled`, which the server has too), the
/// answer the feedback is for, and his second telling with its own. Kept per server and day, so the card resumes.
struct MandarinPracticeRecord: Codable, Equatable {
    var warmStarted = false
    var warmed: [String: Bool] = [:]
    var recalled: [String: Bool] = [:]
    var answeredText: String?
    var result: MandarinAnswerResponse?
    var againText: String?
    var againResult: MandarinAnswerResponse?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warmStarted = (try? c.decodeIfPresent(Bool.self, forKey: .warmStarted)) ?? false
        warmed = (try? c.decodeIfPresent([String: Bool].self, forKey: .warmed)) ?? [:]
        recalled = (try? c.decodeIfPresent([String: Bool].self, forKey: .recalled)) ?? [:]
        answeredText = try? c.decodeIfPresent(String.self, forKey: .answeredText)
        result = try? c.decodeIfPresent(MandarinAnswerResponse.self, forKey: .result)
        againText = try? c.decodeIfPresent(String.self, forKey: .againText)
        againResult = try? c.decodeIfPresent(MandarinAnswerResponse.self, forKey: .againResult)
    }
}

/// One phrase to warm up on before answering: today's cue (with its example), a fix from yesterday's
/// feedback, or a due phrasebook phrase that fits the question. Each is asked from its English.
struct MandarinWarmUp: Identifiable, Equatable {
    enum Source: Equatable { case cue, fix, recall }

    let source: Source
    let en: String
    let hanzi: String
    let pinyin: String?
    /// A line under it in the list and the card: the cue's note, the fix's why.
    let note: String?
    let example: String?
    let examplePinyin: String?
    let exampleEn: String?
    /// For a fix: what he said yesterday.
    let said: String?
    /// For a recall phrase: the phrasebook row Got it or Again moves.
    let phrase: DeckPhrase?

    var id: String { hanzi }

    /// The list's second line: what the phrase is for, or where it comes from.
    var listNote: String {
        switch source {
        case .cue: note ?? phrase?.kindLabel ?? "Today's phrase"
        case .fix: "From yesterday"
        case .recall: "From your phrasebook"
        }
    }

    /// Today's cues, then yesterday's fixes, then the recall phrases, each phrase once.
    static func items(for card: DeckCard) -> [MandarinWarmUp] {
        let cues = card.phrases.compactMap { p -> MandarinWarmUp? in
            guard let en = p.en else { return nil }
            return MandarinWarmUp(source: .cue, en: en, hanzi: p.hanzi, pinyin: p.pinyin, note: p.note,
                                  example: p.example, examplePinyin: p.examplePinyin, exampleEn: p.exampleEn,
                                  said: nil, phrase: p)
        }
        let fixes = (card.yesterday?.fixes ?? []).map { f in
            MandarinWarmUp(source: .fix, en: f.en ?? f.said, hanzi: f.natural, pinyin: f.naturalPinyin, note: f.why,
                           example: nil, examplePinyin: nil, exampleEn: nil, said: f.said, phrase: nil)
        }
        let recall = card.recall.compactMap { p -> MandarinWarmUp? in
            guard let en = p.en else { return nil }
            return MandarinWarmUp(source: .recall, en: en, hanzi: p.hanzi, pinyin: p.pinyin, note: nil,
                                  example: nil, examplePinyin: nil, exampleEn: nil, said: nil, phrase: p)
        }
        var seen = Set<String>()
        return (cues + fixes + recall).filter { seen.insert($0.hanzi).inserted }
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

/// One day's Mandarin card as one conversation: the family member's question first, a warm-up on the
/// phrases for that answer (say each from its English, see it, Got it or Again), the answer (checked once
/// he has seen what the dictation heard), and the feedback with telling it again. Recalls and answers count
/// only once the server has them; a failure leaves the card where it was.
@MainActor
@Observable
final class MandarinPractice {
    enum Step: String, CaseIterable { case warmUp, answer, again }

    enum Answering: Equatable {
        case idle
        case waiting
        case failed(String)
    }

    let card: DeckCard
    let date: String
    let warmUp: [MandarinWarmUp]
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
    @ObservationIgnored private var lastAttempt: (text: String, question: String?, again: Bool)?

    init(card: DeckCard, date: String, server: URL, client: (any MandarinPracticeClient)?,
         store: MandarinPracticeStore = MandarinPracticeStore()) {
        self.card = card
        self.date = date
        self.server = server
        self.client = client
        self.store = store
        warmUp = MandarinWarmUp.items(for: card)
        let record = store.record(for: server, date: date) ?? MandarinPracticeRecord()
        self.record = record
        progress = record.result?.progress ?? card.progress
        step = .answer
        step = firstOpenStep
    }

    /// The steps this card has: a warm-up only with phrases to warm up on.
    var steps: [Step] { Step.allCases.filter { $0 != .warmUp || !warmUp.isEmpty } }

    /// The warm-up phrase on screen: the first he hasn't answered. Nil before the warm-up starts
    /// (the card shows the list) and once every phrase is answered.
    var currentWarmUp: MandarinWarmUp? {
        guard record.warmStarted else { return nil }
        return warmUp.first { answer(for: $0) == nil }
    }

    /// Got it (true) or Again (false), once answered.
    func answer(for item: MandarinWarmUp) -> Bool? {
        item.source == .recall ? record.recalled[item.hanzi] : record.warmed[item.hanzi]
    }

    var result: MandarinAnswerResponse? { record.result }
    var againText: String? { record.againText }
    var againResult: MandarinAnswerResponse? { record.againResult }

    /// The card's cues he said in either telling.
    var usedCues: [String] {
        let again = record.againResult?.used ?? []
        return (record.result?.used ?? []) + again.filter { !(record.result?.used ?? []).contains($0) }
    }

    func isDone(_ step: Step) -> Bool {
        switch step {
        case .warmUp: warmUp.allSatisfy { answer(for: $0) != nil }
        case .answer: record.result?.feedback != nil
        case .again: record.againText != nil
        }
    }

    func startWarmUp() {
        record.warmStarted = true
        save()
        if isDone(.warmUp) { step = .answer }
    }

    /// Got it or Again on a warm-up phrase. A recall phrase's answer goes to the server's phrasebook
    /// first and stays on screen if it can't; a cue's or a fix's is kept on the phone.
    func warm(_ item: MandarinWarmUp, got: Bool) async {
        guard !isSavingRecall else { return }
        recallError = nil
        if item.source == .recall {
            isSavingRecall = true
            defer { isSavingRecall = false }
            if let client {
                do {
                    let response = try await client.recall(MandarinRecallRequest(date: date, hanzi: item.hanzi, got: got))
                    progress = response.progress ?? progress
                } catch {
                    recallError = "Couldn't save that. Try again."
                    return
                }
            }
            record.recalled[item.hanzi] = got
        } else {
            record.warmed[item.hanzi] = got
        }
        save()
        if isDone(.warmUp) { step = .answer }
    }

    /// Sends the answer for feedback unless this exact text already has it; the feedback moves the card on.
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
            progress = response.progress ?? progress
            save()
            answering = .idle
            if response.feedback != nil { step = .again }
        } catch {
            answering = .failed("Couldn't reach the server. Try again.")
        }
    }

    /// His second telling, after reading the first one's feedback, sent with its own feedback coming
    /// back beside the first. Returns whether the server has it, so the mic keeps his words when not.
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
            progress = response.progress ?? progress
            save()
            answering = .idle
            return true
        } catch {
            answering = .failed("Couldn't reach the server. Try again.")
            return false
        }
    }

    /// Try again: the last telling sent, or the one that came back without feedback.
    func retry() async {
        if let lastAttempt, lastAttempt.again {
            await tellAgain(lastAttempt.text)
            return
        }
        guard let text = lastAttempt?.text ?? record.answeredText else { return }
        await submit(text, question: lastAttempt?.question)
    }

    /// Where the card opens: the warm-up until it's done, then the answer until it has feedback.
    private var firstOpenStep: Step {
        if steps.contains(.warmUp), !isDone(.warmUp) { return .warmUp }
        return isDone(.answer) ? .again : .answer
    }

    private func save() { store.setRecord(record, for: server, date: date) }
}
