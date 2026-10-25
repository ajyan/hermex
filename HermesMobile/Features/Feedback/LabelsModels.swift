import Foundation

// Good/not-good labels on generated content (`api/labels.py` on this user's `hermes-webui`
// fork). They feed the evals that measure whether the app's generators improve; a bad label
// with a note also lands in the feedback inbox. Keys are single words, so `FeedbackDecoding`
// reads them as written.

/// What a label says. `clear` takes a label back; the server then drops it from reads.
enum LabelVerdict: String, Codable, Hashable, Sendable {
    case good, bad, clear
}

/// One labeled thing: a part (`card`, `question`, `page`) of an item of a feature.
struct LabelKey: Hashable, Sendable {
    let feature: String
    let item: String
    let part: String

    static let dailyDeckFeature = "daily_deck"
    static let brainFeature = "brain"

    /// `<date>|<kind>|<card id>`, the Daily Deck eval's case key.
    static func deckItem(date: String, kind: String, cardID: String) -> String {
        "\(date)|\(kind)|\(cardID)"
    }

    static func deckCard(date: String, kind: String, cardID: String) -> LabelKey {
        LabelKey(feature: dailyDeckFeature, item: deckItem(date: date, kind: kind, cardID: cardID), part: "card")
    }

    static func deckQuestion(date: String, kind: String, cardID: String) -> LabelKey {
        LabelKey(feature: dailyDeckFeature, item: deckItem(date: date, kind: kind, cardID: cardID), part: "question")
    }

    /// `<module>/<page id>`.
    static func brainPage(module: BrainModuleID, id: String) -> LabelKey {
        LabelKey(feature: brainFeature, item: "\(module.rawValue)/\(id)", part: "page")
    }
}

/// A folded label from the server: the latest verdict for its key.
struct LabelRecord: Decodable, Hashable, Sendable {
    let ts: String?
    let feature: String
    let item: String
    let part: String
    /// Nil for a verdict this build doesn't know.
    let verdict: LabelVerdict?
    let note: String?
    let title: String?
    /// `feedback` for a ✗ the server made from a feedback note on the item; nil for a tapped label.
    let source: String?
    /// Why a ✗ is bad: a `LabelReason` key. The server keeps it only on a bad verdict.
    let reason: String?

    var key: LabelKey { LabelKey(feature: feature, item: item, part: part) }

    /// The label as it stands: good or bad, or nil when cleared.
    var currentVerdict: LabelVerdict? { verdict == .clear ? nil : verdict }

    private enum CodingKeys: String, CodingKey { case ts, feature, item, part, verdict, note, title, source, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feature = try c.decode(String.self, forKey: .feature)
        item = try c.decode(String.self, forKey: .item)
        part = try c.decode(String.self, forKey: .part)
        func str(_ key: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        ts = str(.ts)
        verdict = str(.verdict).flatMap(LabelVerdict.init(rawValue:))
        note = str(.note)
        title = str(.title)
        source = str(.source)
        reason = str(.reason)
    }
}

/// The `GET /api/labels` envelope `{labels: [...]}`. A missing key is an empty list, and a
/// label that fails to decode is dropped.
struct LabelList: Decodable, Sendable {
    let labels: [LabelRecord]

    private enum CodingKeys: String, CodingKey { case labels }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labels = ((try? c.decodeIfPresent([FeedbackLossy<LabelRecord>].self, forKey: .labels)) ?? []).compactMap(\.value)
    }
}

/// The body of `POST /api/labels`. `note`, `title`, and `reason` are left out when nil.
struct LabelCreate: Encodable, Equatable, Sendable {
    let feature: String
    let item: String
    let part: String
    let verdict: LabelVerdict
    let note: String?
    /// What the labeled thing is called, so the feedback inbox can name it.
    let title: String?
    /// A `LabelReason` key; the server accepts it only with a bad verdict.
    let reason: String?

    init(key: LabelKey, verdict: LabelVerdict, note: String? = nil, title: String? = nil, reason: String? = nil) {
        feature = key.feature
        item = key.item
        part = key.part
        self.verdict = verdict
        self.note = note
        self.title = title
        self.reason = reason
    }
}

/// A reason chip under a ✗: what's wrong, as the eval judge's criterion it points at. Daily Deck
/// labels only, one set per part; other features' labels have none.
struct LabelReason: Identifiable, Hashable, Sendable {
    /// The judge criterion, sent as the label's `reason`.
    let key: String
    let label: String
    var id: String { key }

    static func options(for key: LabelKey) -> [LabelReason] {
        guard key.feature == LabelKey.dailyDeckFeature else { return [] }
        switch key.part {
        case "question": return question
        case "card": return card
        default: return []
        }
    }

    static let question = [
        LabelReason(key: "on_idea", label: "Argues with the card"),
        LabelReason(key: "on_card", label: "Not about this card"),
        LabelReason(key: "thought_provoking", label: "Doesn't make me think"),
        LabelReason(key: "answerable", label: "Confusing"),
        LabelReason(key: "no_repeat", label: "Repeats the card")
    ]

    static let card = [
        LabelReason(key: "substantive", label: "Too thin"),
        LabelReason(key: "clean", label: "Messy text"),
        LabelReason(key: "no_repeat", label: "Repeats the title"),
        LabelReason(key: "grounded", label: "Gets facts wrong"),
        LabelReason(key: "readable", label: "Hard to read"),
        LabelReason(key: "selection", label: "Doesn't belong in the deck")
    ]
}
