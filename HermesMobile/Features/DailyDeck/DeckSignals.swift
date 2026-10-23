import Foundation

/// How the user read a deck, filed beside its answers for the vault's style learner (`tools/style_learn.py`):
/// the style chips tapped per card, time and reach per card, the close card's pick between the two faces of the
/// day's variant card, and the learned rules undone from the headline. Kept per deck like the answers' draft.
struct DeckSignals: Codable, Equatable {
    /// Card id → the chips tapped on it in the swipe-up sheet.
    var style: [String: DeckStyleMark] = [:]
    /// Card id → how it was read.
    var usage: [String: DeckUsage] = [:]
    var pick: DeckPick?
    /// Learned rule ids undone from the headline.
    var undo: [String] = []

    var isEmpty: Bool { style.isEmpty && usage.isEmpty && pick == nil && undo.isEmpty }
}

struct DeckStyleMark: Codable, Equatable {
    /// `DeckStyleChip` raw values, in the order tapped.
    var chips: [String]
    /// The swipe-up note, kept when "Not my voice" is on so the learned rule carries the user's words.
    var note: String?
}

struct DeckUsage: Codable, Equatable {
    var seconds: Double = 0
    var reachedEnd = false
    /// "map", "diagram" or "source", each once, in the order first opened.
    var opened: [String] = []
    var answerChars = 0
}

struct DeckPick: Codable, Equatable {
    let card: String
    /// "a" or "b": the variant face chosen.
    let chose: String
}

/// The style chips in the swipe-up sheet. Raw values are the vault's chip ids (`style_learn.CHIPS`).
enum DeckStyleChip: String, CaseIterable, Identifiable {
    case tooLong = "too-long"
    case tooThin = "too-thin"
    case jargon
    case showQuotes = "show-quotes"
    case lessQuotes = "less-quotes"
    case structure
    case voice

    var id: String { rawValue }

    /// Cards with a writing style to learn: those with a kind (a reflection, an item). Not the headline, sleep,
    /// goals, Ask, follow-up decisions or the close.
    static func styleCards(_ type: DeckCard.CardType) -> Bool { type == .reflect || type == .item }

    var label: String {
        switch self {
        case .tooLong: "Too long"
        case .tooThin: "Too thin"
        case .jargon: "Too much jargon"
        case .showQuotes: "Show the quotes"
        case .lessQuotes: "Less quoting, more summary"
        case .structure: "Needs structure"
        case .voice: "Not my voice"
        }
    }
}

/// The signals as the answers file carries them: one row per card, in deck order, each key left out when empty.
struct DeckSignalRows: Encodable, Equatable {
    struct Style: Codable, Equatable { let card: String; let chips: [String]; let note: String? }
    struct Usage: Codable, Equatable {
        let card: String
        let seconds: Double
        let reachedEnd: Bool
        let opened: [String]
        let answerChars: Int
    }

    let style: [Style]?
    let usage: [Usage]?
    let pick: DeckPick?
    let undo: [String]?

    init(_ signals: DeckSignals, cardOrder: [String]) {
        let order = Dictionary(cardOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let inDeckOrder = { (ids: [String]) in ids.sorted { (order[$0] ?? .max, $0) < (order[$1] ?? .max, $1) } }
        let style = inDeckOrder(Array(signals.style.keys)).compactMap { id in
            signals.style[id].flatMap { $0.chips.isEmpty ? nil : Style(card: id, chips: $0.chips, note: $0.note) }
        }
        let usage = inDeckOrder(Array(signals.usage.keys)).compactMap { id in
            signals.usage[id].map { Usage(card: id, seconds: $0.seconds, reachedEnd: $0.reachedEnd, opened: $0.opened,
                                          answerChars: $0.answerChars) }
        }
        self.style = style.isEmpty ? nil : style
        self.usage = usage.isEmpty ? nil : usage
        pick = signals.pick
        undo = signals.undo.isEmpty ? nil : signals.undo
    }
}

extension DeckAnswersFile {
    private struct SignalsBody: Decodable {
        let style: [Lossy<DeckSignalRows.Style>]?
        let usage: [Lossy<DeckSignalRows.Usage>]?
        let pick: DeckPick?
        let undo: [String]?

        private enum CodingKeys: String, CodingKey { case style, usage, pick, undo }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            style = try? c.decodeIfPresent([Lossy<DeckSignalRows.Style>].self, forKey: .style)
            usage = try? c.decodeIfPresent([Lossy<DeckSignalRows.Usage>].self, forKey: .usage)
            pick = try? c.decodeIfPresent(DeckPick.self, forKey: .pick)
            undo = try? c.decodeIfPresent([String].self, forKey: .undo)
        }
    }

    /// The signals a filed answers file carries; empty when it has none or is unreadable. A malformed row drops alone.
    static func decodeSignals(_ content: String) -> DeckSignals {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let body = try? decoder.decode(SignalsBody.self, from: Data(content.utf8)) else { return DeckSignals() }
        var signals = DeckSignals()
        for row in (body.style ?? []).compactMap(\.value) {
            signals.style[row.card] = DeckStyleMark(chips: row.chips, note: row.note)
        }
        for row in (body.usage ?? []).compactMap(\.value) {
            signals.usage[row.card] = DeckUsage(seconds: row.seconds, reachedEnd: row.reachedEnd, opened: row.opened,
                                                answerChars: row.answerChars)
        }
        signals.pick = body.pick
        signals.undo = body.undo ?? []
        return signals
    }
}
