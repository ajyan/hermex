import Foundation
import Observation

/// The network surface the Mandarin card needs (`api/vault_mandarin.py` on this user's webui fork).
protocol MandarinPracticeClient: Sendable {
    func answer(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse
    func recall(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse
    func callPrep(_ request: MandarinCallPrepRequest) async throws -> MandarinCallResponse
    func callAfter(_ request: MandarinCallAfterRequest) async throws -> MandarinCallResponse
    func telling(_ request: MandarinTellingRequest) async throws
    func callStart(_ request: MandarinCallStartRequest) async throws -> MandarinCallStart
    func callReview(_ request: MandarinCallReviewRequest) async throws -> MandarinCallReview
}

struct APIClientMandarinAdapter: MandarinPracticeClient {
    let apiClient: APIClient

    func answer(_ request: MandarinAnswerRequest) async throws -> MandarinAnswerResponse {
        try await apiClient.answerMandarin(request)
    }

    func recall(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse {
        try await apiClient.recallMandarin(request)
    }

    func callPrep(_ request: MandarinCallPrepRequest) async throws -> MandarinCallResponse {
        try await apiClient.mandarinCallPrep(request)
    }

    func callAfter(_ request: MandarinCallAfterRequest) async throws -> MandarinCallResponse {
        try await apiClient.mandarinCallAfter(request)
    }

    func telling(_ request: MandarinTellingRequest) async throws {
        try await apiClient.tellMandarin(request)
    }

    func callStart(_ request: MandarinCallStartRequest) async throws -> MandarinCallStart {
        try await apiClient.mandarinCallStart(request)
    }

    func callReview(_ request: MandarinCallReviewRequest) async throws -> MandarinCallReview {
        try await apiClient.mandarinCallReview(request)
    }
}

/// What he has done on a day's Mandarin card: phrases recalled (Got it is true), chunks said and the
/// first telling, the call and its review, his retries and reveals, and the typed answer the feedback
/// is for. Kept per server and day, so the card resumes. (`fixesSeen` from the old Fix step still
/// decodes, and is ignored.)
struct MandarinPracticeRecord: Codable, Equatable {
    var fixesSeen = 0
    var recalled: [String: Bool] = [:]
    var answeredText: String?
    var result: MandarinAnswerResponse?
    /// The family call: three things to say per relative ("mom", "dad"), and what came back after it.
    var callPrep: [String: [MandarinCallItem]] = [:]
    var callPhrases: [MandarinCallItem] = []
    /// The Mandarin call: its session and the waits before each answer, kept when it ends.
    var callSessionID: String?
    var callWaitMS: [Int] = []
    var saidChunks: [String] = []
    var telling: String?
    var review: MandarinCallReview?
    /// Try again: what he said again for each moment, and the moments whose natural way is showing.
    var retries: [Int: String] = [:]
    var revealed: [Int] = []
    /// "Type it instead": the call step shows the typed answer.
    var isTyping = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fixesSeen = (try? c.decodeIfPresent(Int.self, forKey: .fixesSeen)) ?? 0
        recalled = (try? c.decodeIfPresent([String: Bool].self, forKey: .recalled)) ?? [:]
        answeredText = try? c.decodeIfPresent(String.self, forKey: .answeredText)
        result = try? c.decodeIfPresent(MandarinAnswerResponse.self, forKey: .result)
        callPrep = (try? c.decodeIfPresent([String: [MandarinCallItem]].self, forKey: .callPrep)) ?? [:]
        callPhrases = (try? c.decodeIfPresent([MandarinCallItem].self, forKey: .callPhrases)) ?? []
        callSessionID = try? c.decodeIfPresent(String.self, forKey: .callSessionID)
        callWaitMS = (try? c.decodeIfPresent([Int].self, forKey: .callWaitMS)) ?? []
        saidChunks = (try? c.decodeIfPresent([String].self, forKey: .saidChunks)) ?? []
        telling = try? c.decodeIfPresent(String.self, forKey: .telling)
        review = try? c.decodeIfPresent(MandarinCallReview.self, forKey: .review)
        retries = (try? c.decodeIfPresent([Int: String].self, forKey: .retries)) ?? [:]
        revealed = (try? c.decodeIfPresent([Int].self, forKey: .revealed)) ?? []
        isTyping = (try? c.decodeIfPresent(Bool.self, forKey: .isTyping)) ?? false
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

    /// Keeps a finished Mandarin call on its day's record, for the card to ask for its review. A new
    /// call the same day replaces the last one's review, retries and reveals.
    func recordCall(server: URL, date: String, sessionID: String, waitMS: [Int]) {
        var saved = record(for: server, date: date) ?? MandarinPracticeRecord()
        if saved.callSessionID != sessionID {
            saved.review = nil
            saved.retries = [:]
            saved.revealed = []
        }
        saved.callSessionID = sessionID
        saved.callWaitMS = waitMS
        setRecord(saved, for: server, date: date)
    }
}

/// Copy for the Mandarin call's states.
enum MandarinCallCopy {
    static let couldntStart = "Couldn't start the call."
    static let noProfile = "The Mandarin profile isn't set up on this server."
    static let reviewMissing = "Review didn't arrive"
}

/// One day's Mandarin card in four steps: recall due phrases (Got it / Again), prep (chunks said
/// aloud and a first telling of the day's story), a voice call with Mom or Dad (or the typed answer
/// instead), and after: the call's review. Recalls and answers count only once the server has them; a
/// failure leaves the step where it was.
@MainActor
@Observable
final class MandarinPractice {
    enum Step: String, CaseIterable { case recall, prep, call, after }

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
    /// The family call's request in flight ("mom", "dad", or "after"), and its last error.
    private(set) var callLoading: String?
    private(set) var callError: String?
    /// The latest progress the server reported: after an answer or a recall, else the deck's.
    private(set) var progress: DeckMandarinProgress?
    /// The Mandarin call: starting it, why it couldn't start, and its review request.
    private(set) var isStartingCall = false
    private(set) var startCallError: String?
    private(set) var reviewing: Answering = .idle

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
        progress = record.review?.progress ?? record.result?.progress ?? card.progress
        step = .call
        // A call kept without its review opens on After, which asks for it.
        step = record.callSessionID != nil && record.review == nil ? .after : firstOpenStep
    }

    /// The steps this card has: recall only with phrases due, prep only with chunks (cards built
    /// before the call have none), after only once a call has ended with a session.
    var steps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .recall: !card.recall.isEmpty
            case .prep: !card.chunks.isEmpty
            case .call: true
            case .after: record.review != nil || record.callSessionID != nil
            }
        }
    }

    /// Who calls: "Dad" on his days, else "Mom" (a call has one voice, so the parents' day is Mom's).
    var speakerName: String { card.speaker == "dad" ? "Dad" : "Mom" }

    /// The phrase to recall now: the first one not answered yet.
    var currentRecall: DeckPhrase? { card.recall.first { record.recalled[$0.hanzi] == nil } }

    var result: MandarinAnswerResponse? { record.result }

    func isDone(_ step: Step) -> Bool {
        switch step {
        case .recall: currentRecall == nil
        case .prep: card.chunks.allSatisfy { record.saidChunks.contains($0.hanzi) } && record.telling != nil
        case .call: record.callSessionID != nil || record.review != nil || record.result != nil
        case .after: (record.review?.moments.indices ?? 0..<0).allSatisfy { record.revealed.contains($0) }
                && record.review != nil
        }
    }

    // MARK: Prep

    func markSaid(_ hanzi: String) {
        guard !record.saidChunks.contains(hanzi) else { return }
        record.saidChunks.append(hanzi)
        save()
        if isDone(.prep) { step = firstOpenStep }
    }

    /// The first telling of the day's story: counted here at once, then saved on the server for the
    /// call's comparison. A failed save is let go; the review then has no telling to compare.
    func tell(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        record.telling = text
        save()
        if isDone(.prep) { step = firstOpenStep }
        try? await client?.telling(MandarinTellingRequest(date: date, text: text))
    }

    // MARK: The call

    /// Opens the call on the `mandarin` profile: the opener enters the profile, then this asks the
    /// server for the brief. A server that refuses gets nil back, so the opener switches back.
    func startCall(open: OpenMockCallAction) async {
        guard let client, !isStartingCall else { return }
        isStartingCall = true
        startCallError = nil
        defer { isStartingCall = false }
        let date = date
        let title = card.title ?? ""
        do {
            try await open(profile: MandarinCall.profile) { [weak self] in
                do {
                    let start = try await client.callStart(MandarinCallStartRequest(date: date))
                    return PrepMockStart(mockID: MandarinCall.id(date: date), level: "", brief: start.brief,
                                         profile: start.profile, title: title)
                } catch {
                    self?.startCallError = Self.isMissingProfile(error) ? MandarinCallCopy.noProfile : MandarinCallCopy.couldntStart
                    return nil
                }
            }
        } catch {
            startCallError = Self.isMissingProfile(error) ? MandarinCallCopy.noProfile : MandarinCallCopy.couldntStart
        }
    }

    private static func isMissingProfile(_ error: Error) -> Bool {
        if (error as? PrepMockProfileError)?.isMissing == true { return true }
        if case .http(409, _)? = error as? APIError { return true }
        return false
    }

    /// "Type it instead": the call step shows the typed answer, as before the call existed.
    func typeInstead() {
        record.isTyping = true
        save()
    }

    /// Back from typing to the call.
    func callInstead() {
        record.isTyping = false
        save()
    }

    // MARK: After

    /// Asks for the review of a call that ended with a session, once it is kept. A review with
    /// nothing in it isn't kept, so Retry asks again; a call where he never spoke goes back to the call.
    func reviewIfNeeded() async {
        // A call recorded after this card was built (or a later call the same day) is the one to review.
        if let saved = store.record(for: server, date: date), let session = saved.callSessionID,
           session != record.callSessionID {
            record.callSessionID = session
            record.callWaitMS = saved.callWaitMS
            record.review = saved.review
            record.retries = saved.retries
            record.revealed = saved.revealed
        }
        guard let client, let sessionID = record.callSessionID, record.review == nil, reviewing != .waiting else { return }
        reviewing = .waiting
        step = .after
        do {
            let review = try await client.callReview(
                MandarinCallReviewRequest(date: date, sessionID: sessionID, waitMS: record.callWaitMS))
            if review.fluency?.turns == 0 {
                record.callSessionID = nil
                record.callWaitMS = []
                save()
                reviewing = .idle
                step = firstOpenStep
                return
            }
            guard !review.moments.isEmpty || !review.naturalTurns.isEmpty else {
                reviewing = .failed(MandarinCallCopy.reviewMissing)
                return
            }
            record.review = review
            progress = review.progress ?? progress
            save()
            reviewing = .idle
        } catch {
            reviewing = .failed(MandarinCallCopy.reviewMissing)
        }
    }

    /// What he said again for a Try again moment.
    func retry(_ index: Int, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        record.retries[index] = text
        save()
    }

    func reveal(_ index: Int) {
        guard !record.revealed.contains(index) else { return }
        record.revealed.append(index)
        save()
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

    /// Three things from his week to tell `who` ("mom" or "dad"); asked once per day per relative.
    func prepareCall(_ who: String) async {
        guard let client, callLoading == nil, record.callPrep[who] == nil else { return }
        callLoading = who
        callError = nil
        defer { callLoading = nil }
        do {
            let items = try await client.callPrep(MandarinCallPrepRequest(date: date, who: who)).items
            guard !items.isEmpty else {
                callError = "Nothing came back. Try again."
                return
            }
            record.callPrep[who] = items
            save()
        } catch {
            callError = "Couldn't reach the server. Try again."
        }
    }

    /// What he couldn't say on the call, back in Mandarin and added to tomorrow's recall. Returns
    /// whether it was saved, so the sheet keeps his words when it wasn't.
    @discardableResult
    func saveAfterCall(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, callLoading == nil else { return false }
        callLoading = "after"
        callError = nil
        defer { callLoading = nil }
        do {
            let response = try await client.callAfter(MandarinCallAfterRequest(date: date, text: text))
            guard !response.items.isEmpty else {
                callError = "Nothing came back. Try again."
                return false
            }
            record.callPhrases += response.items
            progress = response.progress ?? progress
            save()
            return true
        } catch {
            callError = "Couldn't reach the server. Try again."
            return false
        }
    }

    /// Try again: the last answer sent, or the one that came back without feedback.
    func retry() async {
        guard let text = lastAttempt?.text ?? record.answeredText else { return }
        await submit(text, question: lastAttempt?.question)
    }

    private var firstOpenStep: Step { steps.first { !isDone($0) } ?? steps.last ?? .call }

    private func save() { store.setRecord(record, for: server, date: date) }
}
