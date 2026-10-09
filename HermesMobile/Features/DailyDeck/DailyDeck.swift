import Foundation

/// A Daily Deck: the morning (or evening) brief as cards. The server writes it to
/// `briefs/<date>.<kind>.json` in the brief's workspace (second-brain
/// `tools/daily_deck.py`); the app only reads it and sends the answers back.
struct DailyDeck: Decodable, Equatable {
    let version: Int?
    let date: String
    let kind: String
    let advisor: String?
    let cards: [DeckCard]

    static func decode(_ content: String) throws -> DailyDeck {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DailyDeck.self, from: Data(content.utf8))
    }
}

/// One card. Every field but `id` and `type` is optional so a newer deck never
/// fails to decode; an unknown `type` renders its `fallback` text as a plain card.
struct DeckCard: Decodable, Equatable, Identifiable {
    enum CardType: Equatable {
        case headline, prompt, decision, reflect, item, close
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "headline": self = .headline
            case "prompt": self = .prompt
            case "decision": self = .decision
            case "reflect": self = .reflect
            case "item": self = .item
            case "close": self = .close
            default: self = .unknown(raw)
            }
        }
    }

    let id: String
    let type: CardType
    /// For `item` cards: book, insight, video, youtube, media.
    let itemKind: String?
    let title: String?
    let body: String?
    let source: String?
    let lines: [String]
    let question: String?
    let context: String?
    let voice: String?
    let why: String?
    let draft: DeckDraft?
    let actions: [DeckAction]
    let fallback: String?
    /// Why the brief picked this card today ("fits today's thread · unseen 3 weeks").
    let reason: String?
    /// Other questions for the same material; Regenerate steps through them.
    let altQuestions: [String]
    /// A recap's items (a review's days, answers, or last week's plan), each under an optional label.
    let entries: [DeckEntry]

    /// Whether answering this card means typing (prompt and reflect cards).
    var takesText: Bool { type == .prompt || type == .reflect }

    /// Whether "Not for Me" applies: material the brief chose, not the deck's own pages.
    var takesFeedback: Bool {
        switch type {
        case .prompt, .reflect, .item, .unknown: true
        case .headline, .decision, .close: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, body, source, lines, question, context, voice, why, draft, actions, fallback
        case reason, altQuestions, entries
        case itemKind = "kind"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = CardType((try? c.decode(String.self, forKey: .type)) ?? "")
        itemKind = try? c.decodeIfPresent(String.self, forKey: .itemKind)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        body = try? c.decodeIfPresent(String.self, forKey: .body)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
        question = try? c.decodeIfPresent(String.self, forKey: .question)
        context = try? c.decodeIfPresent(String.self, forKey: .context)
        voice = try? c.decodeIfPresent(String.self, forKey: .voice)
        why = try? c.decodeIfPresent(String.self, forKey: .why)
        draft = try? c.decodeIfPresent(DeckDraft.self, forKey: .draft)
        actions = (try? c.decodeIfPresent([DeckAction].self, forKey: .actions)) ?? []
        fallback = try? c.decodeIfPresent(String.self, forKey: .fallback)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        altQuestions = (try? c.decodeIfPresent([String].self, forKey: .altQuestions)) ?? []
        entries = ((try? c.decodeIfPresent([LossyEntry].self, forKey: .entries)) ?? []).compactMap(\.value)
    }
}

/// One item in a recap card. An entry that fails to decode is dropped, never the card.
struct DeckEntry: Decodable, Equatable, Hashable {
    let label: String?
    let text: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        text = try c.decode(String.self, forKey: .text)
    }

    private enum CodingKeys: String, CodingKey { case label, text }
}

/// Decodes one entry, or nothing when it is malformed, so a bad item never costs the list.
private struct LossyEntry: Decodable {
    let value: DeckEntry?
    init(from decoder: Decoder) throws { value = try? DeckEntry(from: decoder) }
}

struct DeckDraft: Decodable, Equatable {
    let to: String?
    let channel: String?
    let text: String?
}

/// A decision button. `input == "text"` asks for text before choosing it
/// (an answer, or an edited draft); the server maps the choice to its command.
struct DeckAction: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let input: String?

    var takesText: Bool { input == "text" }
}

/// What the user did with one card. Only non-empty answers are sent.
struct DeckAnswer: Codable, Equatable {
    var card: String
    var text: String?
    var action: String?
    /// The question answered, when it isn't the card's own (regenerated, or the user's).
    var question: String?
    /// "Not for Me" on this card; a card with feedback leaves the deck.
    var feedback: DeckFeedback?

    var isEmpty: Bool {
        !hasText && action == nil && question == nil && feedback == nil
    }

    private var hasText: Bool {
        !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Whether this answers `card`: a decision whose chosen action needs text
    /// (Answer, Edit) answers nothing until the text is there.
    func isAnswer(for card: DeckCard) -> Bool {
        if let action, card.actions.first(where: { $0.id == action })?.takesText == true { return hasText }
        return hasText || action != nil
    }

    /// Whether this says something worth filing: an answer, or feedback on the card.
    func isMeaningful(for card: DeckCard) -> Bool {
        feedback != nil || isAnswer(for: card)
    }
}

/// Why a card wasn't for the user. `brain brief file` weighs future picks by it.
struct DeckFeedback: Codable, Equatable {
    enum Verdict: String, Codable {
        /// Not today; no signal about the material.
        case skip
        /// Show this kind of thing less.
        case less
    }

    var verdict: Verdict
    /// Ids from `DeckFeedback.reasons`.
    var reasons: [String] = []
    var note: String?

    static let reasons: [(id: String, label: String)] = [
        ("topic", "Topic isn't me anymore"),
        ("question", "Question misses"),
        ("repeat", "Seen it too often"),
        ("length", "Too long")
    ]
}

/// What one swipe shows: a single card, or every follow-up together so they can be
/// cleared in one pass.
enum DeckPage: Identifiable, Equatable {
    case card(DeckCard)
    case followUps([DeckCard])

    var id: String {
        switch self {
        case .card(let card): card.id
        case .followUps(let cards): "followups-\(cards.first?.id ?? "")"
        }
    }

    /// Cards in deck order, with all decision cards gathered onto one page where the first sat.
    static func pages(for cards: [DeckCard]) -> [DeckPage] {
        let decisions = cards.filter { $0.type == .decision }
        var pages: [DeckPage] = []
        for card in cards {
            if card.type == .decision {
                if card.id == decisions.first?.id { pages.append(.followUps(decisions)) }
            } else {
                pages.append(.card(card))
            }
        }
        return pages
    }
}

/// The answers file the agent saves verbatim and files with `brain brief file`.
struct DeckAnswersPayload: Encodable, Equatable {
    let version = 1
    let date: String
    let kind: String
    let completedAt: String
    let answers: [DeckAnswer]

    private enum CodingKeys: String, CodingKey { case version, date, kind, completedAt, answers }

    /// Answers in deck order, empty ones dropped, text trimmed.
    init(deck: DailyDeck, answers: [String: DeckAnswer], completedAt: Date) {
        date = deck.date
        kind = deck.kind
        self.completedAt = ISO8601DateFormatter().string(from: completedAt)
        self.answers = deck.cards.compactMap { card in
            guard var answer = answers[card.id], answer.isMeaningful(for: card) else { return nil }
            answer.text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.text?.isEmpty == true { answer.text = nil }
            return answer
        }
    }

    /// The one chat message that files the deck: where to save the JSON, the
    /// command to run, then the JSON itself.
    func message(refiling: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        return """
        \(refiling ? "File my edits to the" : "File the") \(date) \(kind) brief: save the JSON below to \
        \(DailyDeckPaths.answers(date: date, kind: kind)) exactly (replacing any earlier copy), then run \
        `bin/brain brief file \(date) \(kind)` and do what it prints.
        ```json
        \(json)
        ```
        """
    }
}

/// The answers file the agent saved when a deck was filed: the same shape the app sends.
enum DeckAnswersFile {
    private struct Body: Decodable { let answers: [DeckAnswer]? }

    /// Card id → answer; empty when the file is unreadable.
    static func decodeAnswers(_ content: String) -> [String: DeckAnswer] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let answers = (try? decoder.decode(Body.self, from: Data(content.utf8)))?.answers ?? []
        return Dictionary(answers.map { ($0.card, $0) }, uniquingKeysWith: { _, last in last })
    }
}

enum DailyDeckPaths {
    static let directory = "briefs"

    static func deck(date: String, kind: String) -> String { "\(directory)/\(date).\(kind).json" }
    static func answers(date: String, kind: String) -> String { "\(directory)/\(date).\(kind).answers.json" }

    /// "Oct 5" for `2026-10-05`.
    static func label(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return day }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// `2026-10-04` in the device's time zone: the deck's day is the user's day.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Per-server Daily Deck state in UserDefaults: the brief's workspace, today's
/// session, and unsent answers per deck. Keys end in `|<server absoluteString>` like the
/// other per-server preferences; `remove(for:)` runs when a server is removed.
struct DailyDeckStore {
    var defaults: UserDefaults = .standard

    private func key(_ name: String, _ server: URL) -> String { "dailyDeck.\(name)|\(server.absoluteString)" }

    func workspace(for server: URL) -> String? { defaults.string(forKey: key("workspace", server)) }

    func setWorkspace(_ path: String?, for server: URL) {
        defaults.set(path, forKey: key("workspace", server))
        defaults.removeObject(forKey: key("session", server))
    }

    /// The session that reads `date`'s deck; one per day, so filing lands in that day's chat.
    func session(for server: URL, date: String) -> String? {
        let stored = defaults.dictionary(forKey: key("session", server)) as? [String: String]
        return stored?[date]
    }

    func setSession(_ sessionID: String, for server: URL, date: String) {
        defaults.set([date: sessionID], forKey: key("session", server))
    }

    /// Unsent answers per deck, kept for the most recent `draftDays` decks so editing an
    /// older deck never wipes today's.
    func answers(for server: URL, date: String, kind: String) -> [String: DeckAnswer] {
        drafts(for: server)["\(date).\(kind)"] ?? [:]
    }

    func setAnswers(_ answers: [String: DeckAnswer], for server: URL, date: String, kind: String) {
        var all = drafts(for: server)
        all["\(date).\(kind)"] = answers.isEmpty ? nil : answers
        for stale in all.keys.sorted(by: >).dropFirst(Self.draftDays) { all[stale] = nil }
        let k = key("drafts", server)
        if all.isEmpty {
            defaults.removeObject(forKey: k)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: k)
        }
    }

    static let draftDays = 7

    private func drafts(for server: URL) -> [String: [String: DeckAnswer]] {
        guard let data = defaults.data(forKey: key("drafts", server)),
              let all = try? JSONDecoder().decode([String: [String: DeckAnswer]].self, from: data)
        else { return [:] }
        return all
    }

    func remove(for server: URL) {
        let suffix = "|\(server.absoluteString)"
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("dailyDeck.") && k.hasSuffix(suffix) {
            defaults.removeObject(forKey: k)
        }
    }
}

/// How a card reads top to bottom: the line it leads with (the quote, the takeaway), the
/// line saying where it came from, and everything else to scroll into.
struct DeckCardText: Equatable {
    var lead: String?
    var attribution: String?
    var detail: String?
    /// The lead is the card's question (a check-in with no message), so it isn't asked twice.
    var leadIsQuestion = false

    init(_ card: DeckCard) {
        switch card.type {
        case .prompt:
            // The advisor's whole message leads; the question follows it.
            lead = card.context ?? card.question
            leadIsQuestion = card.context == nil
            attribution = card.voice
        case .reflect:
            switch card.itemKind {
            case "quote":
                lead = card.body
                attribution = [card.title, card.source].compactMap { $0 }.joined(separator: ", ")
                detail = card.context
            case "book":
                lead = card.body.map { "“\($0)”" }
                attribution = card.source ?? card.title
                detail = card.context
            default:
                let (first, rest) = Self.split(card.body)
                lead = first ?? card.title
                attribution = first == nil ? card.source : [card.title, card.source == card.title ? nil : card.source]
                    .compactMap { $0 }.joined(separator: " · ")
                detail = Self.join(rest, card.context)
            }
            if let why = card.why { detail = Self.join(detail, "Why you saved it: \(why)") }
        case .item, .unknown:
            lead = card.title ?? card.fallback
            attribution = card.source == card.title ? nil : card.source
            // A recap's entries are laid out as a list; its plain `body` copy is only for older builds.
            detail = card.entries.isEmpty ? (card.body ?? (card.title == nil ? nil : card.fallback)) : nil
        case .headline, .decision, .close:
            lead = card.title
            detail = card.body
        }
        if attribution?.isEmpty == true { attribution = nil }
    }

    /// The opening sentence (two, when the first is a fragment) and the rest of `text`.
    static func split(_ text: String?) -> (String?, String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return (nil, nil) }
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }
        var count = 1
        while count < sentences.count, sentences.prefix(count).joined().count < 40 { count += 1 }
        let lead = sentences.prefix(count).joined().trimmingCharacters(in: .whitespaces)
        let rest = sentences.dropFirst(count).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (lead, rest.isEmpty ? nil : rest)
    }

    private static func join(_ a: String?, _ b: String?) -> String? {
        let parts = [a, b].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}

/// A weekly or monthly review deck in `briefs/`: `<date>.weekly.json` (the Sunday that ends the
/// week) or `<date>.monthly.json` (the month's last day).
struct DeckReview: Identifiable, Equatable {
    let date: String
    let kind: String
    let isFiled: Bool

    var id: String { "\(date).\(kind)" }

    /// "Week ending Oct 4" or "September review".
    var label: String {
        if kind == "weekly" { return "Week ending \(DailyDeckPaths.label(date))" }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let day = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
        else { return "Month review" }
        return "\(day.formatted(.dateTime.month(.wide))) review"
    }

    static func all(in names: [String]) -> [DeckReview] {
        ["weekly", "monthly"].flatMap { kind in
            let filed = DailyDeckViewModel.filedDates(in: names, kind: kind)
            return DailyDeckViewModel.deckDates(in: names, kind: kind).map { DeckReview(date: $0, kind: kind, isFiled: filed.contains($0)) }
        }
        .sorted { ($0.date, $0.kind) > ($1.date, $1.kind) }
    }
}
