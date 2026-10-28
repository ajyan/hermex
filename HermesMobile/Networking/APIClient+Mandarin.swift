import Foundation

/// `POST /api/mandarin/recall`: Got it moves a phrasebook phrase to its next gap, Again starts it over.
struct MandarinRecallRequest: Encodable, Sendable {
    let date: String
    let hanzi: String
    let got: Bool
}

struct MandarinRecallResponse: Decodable, Equatable, Sendable {
    let ok: Bool?

    init(from decoder: Decoder) throws {
        ok = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .ok)
    }

    private enum CodingKeys: String, CodingKey { case ok }
}

/// The Mandarin call with Mom or Dad: its brief, its review, pattern practice, and the phrasebook.
struct MandarinCallStartRequest: Encodable, Sendable {
    let date: String
}

/// The `[mandarin brief]` opening turn, who calls ("mom" or "dad"), and the Hermes profile to call on.
struct MandarinCallStart: Decodable, Equatable, Sendable {
    let brief: String
    let speaker: String?
    let profile: String
}

/// Encodes as `session_id` through the client's snake-case encoder.
struct MandarinCallReviewRequest: Encodable, Sendable {
    let date: String
    let sessionID: String
}

/// A sentence pattern taken away from a call: its name ("是…的"), when to use it, its form with the
/// slots in brackets, his line rebuilt with it, two examples and three practice prompts. The
/// phrasebook's copies also carry the day and whether he practiced it. A pattern without a name or a
/// form doesn't decode; bad examples and prompts drop.
struct MandarinPattern: Codable, Equatable, Hashable, Sendable {
    struct Example: Codable, Equatable, Hashable, Sendable {
        let hanzi: String
        let pinyin: String?
        let en: String?
    }

    struct Prompt: Codable, Equatable, Hashable, Sendable {
        let en: String
        /// The words in `en` that fill the pattern's slot, shown emphasized.
        let slot: String?
    }

    let name: String
    let use: String?
    let form: String
    let said: String?
    let rebuilt: String?
    let rebuiltPinyin: String?
    let examples: [Example]
    let prompts: [Prompt]
    let date: String?
    let practiced: Bool?

    init(name: String, use: String?, form: String, said: String? = nil, rebuilt: String? = nil,
         rebuiltPinyin: String? = nil, examples: [Example] = [], prompts: [Prompt] = [], date: String? = nil,
         practiced: Bool? = nil) {
        self.name = name
        self.use = use
        self.form = form
        self.said = said
        self.rebuilt = rebuilt
        self.rebuiltPinyin = rebuiltPinyin
        self.examples = examples
        self.prompts = prompts
        self.date = date
        self.practiced = practiced
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        form = try c.decode(String.self, forKey: .form)
        use = try? c.decodeIfPresent(String.self, forKey: .use)
        said = try? c.decodeIfPresent(String.self, forKey: .said)
        rebuilt = try? c.decodeIfPresent(String.self, forKey: .rebuilt)
        rebuiltPinyin = try? c.decodeIfPresent(String.self, forKey: .rebuiltPinyin)
        examples = ((try? c.decodeIfPresent([Lossy<Example>].self, forKey: .examples)) ?? []).compactMap(\.value)
        prompts = ((try? c.decodeIfPresent([Lossy<Prompt>].self, forKey: .prompts)) ?? []).compactMap(\.value)
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        practiced = try? c.decodeIfPresent(Bool.self, forKey: .practiced)
    }

    private enum CodingKeys: String, CodingKey {
        case name, use, form, said, rebuilt, rebuiltPinyin, examples, prompts, date, practiced
    }
}

/// After the call: the words he reached for (filed for tomorrow), one line said better, what to work
/// on next, and the day's pattern. `turns` counts his turns; 0 means he never spoke. Bad entries drop.
struct MandarinCallReview: Codable, Equatable, Sendable {
    struct Reached: Codable, Equatable, Hashable, Sendable {
        let said: String?
        let hanzi: String
        let pinyin: String?
        let en: String?
    }

    struct Better: Codable, Equatable, Hashable, Sendable {
        let said: String
        let natural: String
        let naturalPinyin: String?
    }

    struct Focus: Codable, Equatable, Hashable, Sendable {
        let advice: String
        let next: String?
    }

    let reached: [Reached]
    let better: Better?
    let focus: Focus?
    let pattern: MandarinPattern?
    let turns: Int?
    let sessionID: String?

    /// Nothing to show: the After never shows an empty review.
    var isEmpty: Bool { reached.isEmpty && better == nil && focus == nil && pattern == nil }

    init(reached: [Reached] = [], better: Better? = nil, focus: Focus? = nil, pattern: MandarinPattern? = nil,
         turns: Int? = nil, sessionID: String? = nil) {
        self.reached = reached
        self.better = better
        self.focus = focus
        self.pattern = pattern
        self.turns = turns
        self.sessionID = sessionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reached = ((try? c.decodeIfPresent([Lossy<Reached>].self, forKey: .reached)) ?? []).compactMap(\.value)
        better = try? c.decodeIfPresent(Better.self, forKey: .better)
        focus = try? c.decodeIfPresent(Focus.self, forKey: .focus)
        pattern = try? c.decodeIfPresent(MandarinPattern.self, forKey: .pattern)
        turns = try? c.decodeIfPresent(Int.self, forKey: .turns)
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
    }

    private enum CodingKeys: String, CodingKey {
        case reached, better, focus, pattern, turns
        case sessionID = "sessionId"
    }
}

/// One practice answer for the day's pattern prompt `index` (0...2); `said` is his words.
struct MandarinPatternCheckRequest: Encodable, Sendable {
    let date: String
    let sessionID: String
    let index: Int
    let said: String
}

/// How a practice answer went: right, close (one more try), or off, with a natural way to say it and
/// where the pattern's words go. An unknown verdict reads as close.
struct MandarinPatternCheck: Codable, Equatable, Sendable {
    enum Verdict: String, Codable, Sendable { case right, close, off }

    let verdict: Verdict
    let natural: String
    let naturalPinyin: String?
    let note: String?

    init(verdict: Verdict, natural: String, naturalPinyin: String? = nil, note: String? = nil) {
        self.verdict = verdict
        self.natural = natural
        self.naturalPinyin = naturalPinyin
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = (try? c.decodeIfPresent(String.self, forKey: .verdict)).flatMap { $0.flatMap(Verdict.init(rawValue:)) } ?? .close
        natural = (try? c.decodeIfPresent(String.self, forKey: .natural)) ?? ""
        naturalPinyin = try? c.decodeIfPresent(String.self, forKey: .naturalPinyin)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey { case verdict, natural, naturalPinyin, note }
}

/// One phrasebook phrase: the day it was added, where it came from ("call", "gap"…) and who was on the
/// call ("mom", "dad"); older phrases have neither.
struct MandarinBookPhrase: Codable, Equatable, Hashable, Identifiable, Sendable {
    let hanzi: String
    let pinyin: String?
    let en: String?
    let added: String?
    let source: String?
    let call: String?

    var id: String { hanzi }
}

/// Every phrase and pattern, newest first, and the phrases due for a Review round.
struct MandarinPhrasebook: Decodable, Equatable, Sendable {
    let phrases: [MandarinBookPhrase]
    let patterns: [MandarinPattern]
    let due: [DeckPhrase]

    init(phrases: [MandarinBookPhrase] = [], patterns: [MandarinPattern] = [], due: [DeckPhrase] = []) {
        self.phrases = phrases
        self.patterns = patterns
        self.due = due
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrases = ((try? c.decodeIfPresent([Lossy<MandarinBookPhrase>].self, forKey: .phrases)) ?? []).compactMap(\.value)
        patterns = ((try? c.decodeIfPresent([Lossy<MandarinPattern>].self, forKey: .patterns)) ?? []).compactMap(\.value)
        due = ((try? c.decodeIfPresent([Lossy<DeckPhrase>].self, forKey: .due)) ?? []).compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey { case phrases, patterns, due }
}

private struct MandarinEmptyRequest: Encodable, Sendable {}

extension APIClient {
    func recallMandarin(_ request: MandarinRecallRequest) async throws -> MandarinRecallResponse {
        try decode(MandarinRecallResponse.self, from: try await sendData(endpoint: .mandarinRecall, method: "POST", body: request))
    }

    func mandarinCallStart(_ request: MandarinCallStartRequest) async throws -> MandarinCallStart {
        try decode(MandarinCallStart.self, from: try await sendData(endpoint: .mandarinCallStart, method: "POST", body: request))
    }

    /// Waits up to 90 s: the review is one local-model call.
    func mandarinCallReview(_ request: MandarinCallReviewRequest) async throws -> MandarinCallReview {
        try await send(endpoint: .mandarinCallReview, method: "POST", body: request, timeout: 90)
    }

    /// Waits up to 90 s, like the review: one local-model call.
    func mandarinPatternCheck(_ request: MandarinPatternCheckRequest) async throws -> MandarinPatternCheck {
        try await send(endpoint: .mandarinPatternCheck, method: "POST", body: request, timeout: 90)
    }

    func mandarinPhrasebook() async throws -> MandarinPhrasebook {
        try decode(MandarinPhrasebook.self, from: try await sendData(endpoint: .mandarinPhrasebook, method: "POST",
                                                                       body: MandarinEmptyRequest()))
    }
}
