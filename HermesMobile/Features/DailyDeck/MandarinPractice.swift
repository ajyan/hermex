import Foundation
import Observation

/// The network surface the Mandarin card needs (`api/vault_mandarin.py` on this user's webui fork).
protocol MandarinPracticeClient: Sendable {
    func recall(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse
    func callStart(_ request: MandarinCallStartRequest) async throws -> MandarinCallStart
    func callReview(_ request: MandarinCallReviewRequest) async throws -> MandarinCallReview
    func patternCheck(_ request: MandarinPatternCheckRequest) async throws -> MandarinPatternCheck
    func phrasebook() async throws -> MandarinPhrasebook
}

struct APIClientMandarinAdapter: MandarinPracticeClient {
    let apiClient: APIClient

    func recall(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse {
        try await apiClient.recallMandarin(request)
    }

    func callStart(_ request: MandarinCallStartRequest) async throws -> MandarinCallStart {
        try await apiClient.mandarinCallStart(request)
    }

    func callReview(_ request: MandarinCallReviewRequest) async throws -> MandarinCallReview {
        try await apiClient.mandarinCallReview(request)
    }

    func patternCheck(_ request: MandarinPatternCheckRequest) async throws -> MandarinPatternCheck {
        try await apiClient.mandarinPatternCheck(request)
    }

    func phrasebook() async throws -> MandarinPhrasebook {
        try await apiClient.mandarinPhrasebook()
    }
}

/// What he has done on a day's Mandarin card: the latest call's session and its review, and the
/// pattern practice (the last check per prompt, and the prompts that already used their one retry
/// after a close answer).
/// Kept per server and day, so the card resumes. Keys from the earlier designs still decode, and are
/// ignored.
struct MandarinPracticeRecord: Codable, Equatable {
    /// A reviewed call set aside by a newer one, until the newer one's review arrives: a call where
    /// he never spoke gives it back.
    struct Kept: Codable, Equatable {
        var callSessionID: String
        var review: MandarinCallReview
        var practice: [Int: MandarinPatternCheck]
        var practiceRetried: [Int]
    }

    var callSessionID: String?
    var review: MandarinCallReview?
    var practice: [Int: MandarinPatternCheck] = [:]
    var practiceRetried: [Int] = []
    var previous: Kept?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callSessionID = try? c.decodeIfPresent(String.self, forKey: .callSessionID)
        review = try? c.decodeIfPresent(MandarinCallReview.self, forKey: .review)
        practice = (try? c.decodeIfPresent([Int: MandarinPatternCheck].self, forKey: .practice)) ?? [:]
        practiceRetried = (try? c.decodeIfPresent([Int].self, forKey: .practiceRetried)) ?? []
        previous = try? c.decodeIfPresent(Kept.self, forKey: .previous)
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

    /// Keeps a finished Mandarin call (or typed chat) on its day's record, for the card to ask for its
    /// review. A new session the same day replaces the last one's review and practice, keeping a
    /// reviewed one aside in case the new call turns out empty.
    func recordCall(server: URL, date: String, sessionID: String) {
        var saved = record(for: server, date: date) ?? MandarinPracticeRecord()
        if saved.callSessionID != sessionID {
            if let session = saved.callSessionID, let review = saved.review {
                saved.previous = .init(callSessionID: session, review: review, practice: saved.practice,
                                       practiceRetried: saved.practiceRetried)
            }
            saved.review = nil
            saved.practice = [:]
            saved.practiceRetried = []
        }
        saved.callSessionID = sessionID
        setRecord(saved, for: server, date: date)
    }
}

/// The Mandarin card's words, by who calls ("dad", else Mom).
enum MandarinCardCopy {
    static let couldntStart = "Couldn't start the call."
    static let noProfile = "The Mandarin profile isn't set up on this server."
    static let reviewMissing = "Review didn't arrive"
    static let checkFailed = "Couldn't check that. Try again."
    /// Words-coming-back pips: one per due phrase, at most five.
    static let maxPips = 5

    static func name(_ speaker: String?) -> String { speaker == "dad" ? "Dad" : "Mom" }
    static func pronoun(_ speaker: String?) -> String { speaker == "dad" ? "him" : "her" }
    static func subject(_ speaker: String?) -> String { speaker == "dad" ? "He" : "She" }

    static func turn(_ speaker: String?) -> String { "\(name(speaker))'s turn today" }
    static func asks(_ speaker: String?) -> String { "\(subject(speaker))'ll ask about your week." }
    static func call(_ speaker: String?) -> String { "Call \(name(speaker))" }
    static func type(_ speaker: String?) -> String { "Type to \(pronoun(speaker)) instead" }
    static func nextCall(_ speaker: String?) -> String { "\(name(speaker)) brings it up in your next call too" }
    static func pips(due: Int) -> Int { min(max(due, 0), maxPips) }
}

/// The card's week: seven day circles, Monday first, filled on days with a call. Today fills once
/// its call is reviewed, since the deck was built before it.
enum MandarinWeekCircles {
    static func dayIndex(date: String) -> Int? {
        guard let day = DateFormatter.mandarinDay.date(from: date) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = DateFormatter.mandarinDay.timeZone
        return (calendar.component(.weekday, from: day) + 5) % 7
    }

    static func filled(week: [Bool], date: String, after: Bool) -> [Bool] {
        var days = Array((week + Array(repeating: false, count: 7)).prefix(7))
        if after, let today = dayIndex(date: date) { days[today] = true }
        return days
    }
}

private extension DateFormatter {
    static let mandarinDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// One day's Mandarin card: a call (or typed chat) with Mom or Dad, then After: the call's review and
/// three prompts to practice its pattern. A check counts only once the server has it; a failure leaves
/// the prompt where it was.
@MainActor
@Observable
final class MandarinPractice {
    enum State: Equatable { case call, after }

    enum Answering: Equatable {
        case idle
        case waiting
        case failed(String)
    }

    let card: DeckCard
    let date: String
    private(set) var record: MandarinPracticeRecord
    /// Starting the call, why it couldn't start, the review request, and the latest practice check.
    private(set) var isStartingCall = false
    private(set) var startCallError: String?
    private(set) var reviewing: Answering = .idle
    private(set) var checking: Answering = .idle

    @ObservationIgnored private let server: URL
    @ObservationIgnored private let client: (any MandarinPracticeClient)?
    @ObservationIgnored private let store: MandarinPracticeStore

    init(card: DeckCard, date: String, server: URL, client: (any MandarinPracticeClient)?,
         store: MandarinPracticeStore = MandarinPracticeStore()) {
        self.card = card
        self.date = date
        self.server = server
        self.client = client
        self.store = store
        record = store.record(for: server, date: date) ?? MandarinPracticeRecord()
    }

    /// After once a call has ended with a session; the After asks for its review.
    var state: State { record.callSessionID == nil ? .call : .after }

    var speakerName: String { MandarinCardCopy.name(card.speaker) }
    var pronoun: String { MandarinCardCopy.pronoun(card.speaker) }
    var subject: String { MandarinCardCopy.subject(card.speaker) }

    // MARK: The call

    /// Opens the call on the `mandarin` profile (or, `typed`, the same chat in text): the opener enters
    /// the profile, then this asks the server for the brief. A server that refuses gets nil back, so the
    /// opener switches back.
    func startCall(open: OpenMockCallAction, typed: Bool) async {
        guard let client, !isStartingCall else { return }
        isStartingCall = true
        startCallError = nil
        defer { isStartingCall = false }
        let date = date
        let title = speakerName
        do {
            try await open(profile: MandarinCall.profile) { [weak self] in
                do {
                    let start = try await client.callStart(MandarinCallStartRequest(date: date))
                    return PrepMockStart(mockID: MandarinCall.id(date: date), level: "", brief: start.brief,
                                         profile: start.profile, title: title, startsCall: !typed)
                } catch {
                    self?.startCallError = Self.isMissingProfile(error) ? MandarinCardCopy.noProfile : MandarinCardCopy.couldntStart
                    return nil
                }
            }
        } catch {
            startCallError = Self.isMissingProfile(error) ? MandarinCardCopy.noProfile : MandarinCardCopy.couldntStart
        }
    }

    private static func isMissingProfile(_ error: Error) -> Bool {
        if (error as? PrepMockProfileError)?.isMissing == true { return true }
        if case .http(409, _)? = error as? APIError { return true }
        return false
    }

    // MARK: After

    /// Asks for the review of a call that ended with a session, once it is kept. A review with nothing
    /// in it isn't kept, so Retry asks again; a call where he never spoke goes back to the call.
    func reviewIfNeeded() async {
        // A call recorded after this card was built (or a later call the same day) is the one to review.
        if let saved = store.record(for: server, date: date), let session = saved.callSessionID,
           session != record.callSessionID {
            record = saved
        }
        guard let client, let sessionID = record.callSessionID, record.review == nil, reviewing != .waiting else { return }
        reviewing = .waiting
        do {
            let review = try await client.callReview(MandarinCallReviewRequest(date: date, sessionID: sessionID))
            if review.turns == 0 {
                if let kept = record.previous {
                    record.callSessionID = kept.callSessionID
                    record.review = kept.review
                    record.practice = kept.practice
                    record.practiceRetried = kept.practiceRetried
                } else {
                    record.callSessionID = nil
                }
                record.previous = nil
                save()
                reviewing = .idle
                return
            }
            guard !review.isEmpty else {
                reviewing = .failed(MandarinCardCopy.reviewMissing)
                return
            }
            record.review = review
            record.previous = nil
            save()
            reviewing = .idle
        } catch {
            reviewing = .failed(MandarinCardCopy.reviewMissing)
        }
    }

    // MARK: Pattern practice

    private var prompts: [MandarinPattern.Prompt] { record.review?.pattern?.prompts ?? [] }

    /// Whether a prompt's check is its last: right or off at once, close after its one retry.
    private func isFinal(_ index: Int) -> Bool {
        guard let check = record.practice[index] else { return false }
        return check.verdict != .close || record.practiceRetried.contains(index)
    }

    /// The prompt to answer now: the first without a final check; nil once all are done.
    var practicePrompt: (index: Int, prompt: MandarinPattern.Prompt)? {
        prompts.indices.first { !isFinal($0) }.map { ($0, prompts[$0]) }
    }

    var isPracticeDone: Bool { !prompts.isEmpty && practicePrompt == nil }

    /// Checks his answer to the current prompt. A close answer gets one more try on the same prompt.
    func check(_ said: String) async {
        let said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, let sessionID = record.callSessionID, let (index, _) = practicePrompt, !said.isEmpty,
              checking != .waiting else { return }
        checking = .waiting
        do {
            let check = try await client.patternCheck(
                MandarinPatternCheckRequest(date: date, sessionID: sessionID, index: index, said: said))
            // A second answer to a prompt that came back close is its retry: whatever it gets is final.
            if record.practice[index]?.verdict == .close, !record.practiceRetried.contains(index) {
                record.practiceRetried.append(index)
            }
            record.practice[index] = check
            save()
            checking = .idle
        } catch {
            checking = .failed(MandarinCardCopy.checkFailed)
        }
    }

    /// The phrasebook screen's model, on this card's server and day.
    func phrasebookModel() -> MandarinPhrasebookModel { MandarinPhrasebookModel(client: client, date: date) }

    private func save() { store.setRecord(record, for: server, date: date) }
}
