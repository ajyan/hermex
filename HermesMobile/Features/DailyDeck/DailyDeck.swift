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

    /// Whether answering this card means typing (prompt and reflect cards).
    var takesText: Bool { type == .prompt || type == .reflect }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, body, source, lines, question, context, voice, why, draft, actions, fallback
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
    }
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
    var reaction: DeckReaction?

    var isEmpty: Bool {
        !hasText && action == nil && reaction == nil
    }

    private var hasText: Bool {
        !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Whether this answer says something for `card`: a decision whose chosen
    /// action needs text (Answer, Edit) says nothing until the text is there.
    func isMeaningful(for card: DeckCard) -> Bool {
        if let action, card.actions.first(where: { $0.id == action })?.takesText == true { return hasText }
        return !isEmpty
    }
}

enum DeckReaction: String, Codable, Equatable {
    case resonates
    case skip
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
    func message() throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        return """
        File today's \(kind) brief: save the JSON below to \(DailyDeckPaths.answers(date: date, kind: kind)) \
        exactly, then run `bin/brain brief file \(date) \(kind)` and do what it prints.
        ```json
        \(json)
        ```
        """
    }
}

enum DailyDeckPaths {
    static let directory = "briefs"

    static func deck(date: String, kind: String) -> String { "\(directory)/\(date).\(kind).json" }
    static func answers(date: String, kind: String) -> String { "\(directory)/\(date).\(kind).answers.json" }

    /// `2026-10-04` in the device's time zone: the deck's day is the user's day.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Per-server Daily Deck state in UserDefaults: the brief's workspace, today's
/// session, and unsent answers. Keys end in `|<server absoluteString>` like the
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

    /// Unsent answers for one deck. Only the latest deck's answers are kept, so an
    /// abandoned day never lingers.
    func answers(for server: URL, date: String, kind: String) -> [String: DeckAnswer] {
        guard let data = defaults.data(forKey: key("answers", server)),
              let stored = try? JSONDecoder().decode(StoredAnswers.self, from: data),
              stored.deck == "\(date).\(kind)"
        else { return [:] }
        return stored.answers
    }

    func setAnswers(_ answers: [String: DeckAnswer], for server: URL, date: String, kind: String) {
        let k = key("answers", server)
        if answers.isEmpty {
            defaults.removeObject(forKey: k)
        } else if let data = try? JSONEncoder().encode(StoredAnswers(deck: "\(date).\(kind)", answers: answers)) {
            defaults.set(data, forKey: k)
        }
    }

    private struct StoredAnswers: Codable {
        let deck: String
        let answers: [String: DeckAnswer]
    }

    func remove(for server: URL) {
        let suffix = "|\(server.absoluteString)"
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("dailyDeck.") && k.hasSuffix(suffix) {
            defaults.removeObject(forKey: k)
        }
    }
}
