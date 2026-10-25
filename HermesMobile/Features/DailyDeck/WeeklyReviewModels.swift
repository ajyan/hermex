import Foundation

// The weekly review's deck pieces and the week record the app reads back. The vault writes both
// (`tools/daily_deck.py` for the deck, `tools/brain/commands/brief.py` for the record); every
// field decodes tolerantly, so a newer vault never costs the deck or the page.

/// The note an earlier week left for this one, shown sealed on the cover until tapped.
struct DeckPastNote: Decodable, Equatable {
    let weekEnding: String?
    let title: String?
    let text: String

    init(weekEnding: String?, title: String?, text: String) {
        self.weekEnding = weekEnding
        self.title = title
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekEnding = try? c.decodeIfPresent(String.self, forKey: .weekEnding)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
    }

    private enum CodingKeys: String, CodingKey { case weekEnding, title, text }
}

/// One moment of the week on the v3 cover (`moments`, or a `spares` one to swap in): its weekday,
/// a line about it, and the value it speaks to ("present", "people", "dad", "potential", "body").
struct DeckMoment: Decodable, Equatable, Identifiable {
    let id: String
    let day: String
    let line: String
    let value: String

    init(id: String, day: String, line: String, value: String) {
        self.id = id
        self.day = day
        self.line = line
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        line = (try? c.decodeIfPresent(String.self, forKey: .line)) ?? ""
        value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case id, day, line, value }
}

/// A v3 card's fact: a value card's `{big, line}` ("22 people", "Most: Meg, 3 days"). The last
/// intention's fact is a plain string on the wire, which reads as the line alone.
struct DeckFact: Decodable, Equatable {
    let big: String?
    let line: String?

    init(big: String?, line: String?) {
        self.big = big
        self.line = line
    }

    init(from decoder: Decoder) throws {
        if let line = try? decoder.singleValueContainer().decode(String.self) {
            self.init(big: nil, line: line)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(big: try? c.decodeIfPresent(String.self, forKey: .big),
                      line: try? c.decodeIfPresent(String.self, forKey: .line))
        }
    }

    private enum CodingKeys: String, CodingKey { case big, line }
}

/// One goal's change to next week on the v3 intention card: "Outreach 10 → 5" with the coach's
/// reason. Accepting confirms `commitments` (the proposal, dropped rows already left out) for the
/// week starting `start` through `POST /api/goals/week`.
struct DeckGoalChange: Decodable, Equatable, Identifiable {
    let goal: String
    let title: String
    let label: String
    let reason: String
    let start: String
    let commitments: [DeckWeekCommitment]

    var id: String { goal }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decode(String.self, forKey: .goal)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? goal
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
        start = (try? c.decodeIfPresent(String.self, forKey: .start)) ?? ""
        commitments = ((try? c.decodeIfPresent([Lossy<DeckWeekCommitment>].self, forKey: .commitments)) ?? []).compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey { case goal, title, label, reason, start, commitments }
}

extension DeckCard {
    /// The weekly chapters, in the order the review walks them.
    static let weeklyChapters = ["remember", "reflect", "values", "steer"]

    /// The card's chapter as it shows in place of the reason line: "1 · Remember". Nil on the
    /// cover, the close, and any card off the weekly deck.
    var chapterLabel: String? {
        guard let chapter, !chapter.isEmpty else { return nil }
        let name = chapter.prefix(1).uppercased() + chapter.dropFirst()
        guard let index = Self.weeklyChapters.firstIndex(of: chapter) else { return name }
        return "\(index + 1) · \(name)"
    }
}

/// The five values the weekly review walks, one card each, in the vault's order.
enum WeekValues {
    static let order = ["present", "people", "dad", "potential", "body"]

    /// The moment chip's name for a value: "People" for "people"; nil (no chip) for an id outside
    /// the five, or none ("", a plain moment the vault couldn't tag).
    static func shortName(_ id: String) -> String? {
        switch id {
        case "present": "Present"
        case "people": "People"
        case "dad": "Dad"
        case "potential": "Potential"
        case "body": "Body"
        default: nil
        }
    }

    /// A moment row as VoiceOver reads it: "Thu. Meg opened up. Present", without the value when it has no chip.
    static func spokenMoment(day: String, line: String, value: String) -> String {
        [day, line, shortName(value) ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// A sealed week: `weekly-checkins/<Sunday>-week-ending.json`. Only `weekEnding` is required; a
/// backfilled record has a title and story and nothing else.
struct WeekRecord: Decodable, Equatable {
    let weekEnding: String
    let weekNumber: Int?
    let title: String?
    let story: String?
    /// The photo's vault path ("weekly-checkins/photos/<Sunday>.jpg"), nil without one.
    let photo: String?
    let energy: Energy
    let deep: Deep?
    let commitments: [Commitment]
    let values: [Value]
    let oneThing: OneThing?
    let who: [Who]
    let note: Note?
    let prediction: Prediction?
    let graded: [Graded]
    /// The record's format (1 or 2); nil when the file doesn't say.
    let version: Int?
    /// A v2 record's moments of the week, in the order he kept them; a v1 record has none.
    let moments: [Moment]
    /// How the week ended, in his words.
    let ended: String?
    /// The intention the week began with and how it went; nil when there wasn't one.
    let lastIntention: LastIntention?
    let reflect: Reflect?
    /// What he meant to do next week.
    let intention: Intention?

    struct Energy: Decodable, Equatable {
        let gave: [String]
        let drained: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            gave = (try? c.decodeIfPresent([String].self, forKey: .gave)) ?? []
            drained = (try? c.decodeIfPresent([String].self, forKey: .drained)) ?? []
        }

        init(gave: [String] = [], drained: [String] = []) {
            self.gave = gave
            self.drained = drained
        }

        private enum CodingKeys: String, CodingKey { case gave, drained }
    }

    struct Deep: Decodable, Equatable {
        let rotation: String?
        let question: String?
        let answer: String?
    }

    /// Last week's word, graded: `status` is kept, missed, or dropped.
    struct Commitment: Decodable, Equatable, Identifiable {
        let id: String
        let text: String?
        let status: String?
        let carried: Int?
    }

    /// `score` and `evidence` are nil when the week didn't score it.
    /// A v2 record's value adds the question it asked, his `answer`, and the week's `fact` ("22 people").
    struct Value: Decodable, Equatable, Identifiable {
        let id: String
        let name: String?
        let score: Int?
        let evidence: String?
        let question: String?
        let answer: String?
        let fact: DeckFact?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            score = try? c.decodeIfPresent(Int.self, forKey: .score)
            evidence = try? c.decodeIfPresent(String.self, forKey: .evidence)
            question = try? c.decodeIfPresent(String.self, forKey: .question)
            answer = try? c.decodeIfPresent(String.self, forKey: .answer)
            fact = try? c.decodeIfPresent(DeckFact.self, forKey: .fact)
        }

        private enum CodingKeys: String, CodingKey { case id, name, score, evidence, question, answer, fact }
    }

    /// One moment on a v2 record: `day` ("Thu") and `value` ("present") are empty for his own words.
    struct Moment: Decodable, Equatable {
        let day: String
        let line: String
        let value: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
            line = try c.decode(String.self, forKey: .line)
            value = (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
        }

        private enum CodingKeys: String, CodingKey { case day, line, value }
    }

    /// The week's starting intention and how it went: `status` is held, partly, or didnt (nil unmarked).
    struct LastIntention: Decodable, Equatable {
        let text: String?
        let status: String?
        let note: String?
    }

    /// A reflect question and his answer to it.
    struct Reflection: Decodable, Equatable {
        let question: String?
        let answer: String?
    }

    struct Reflect: Decodable, Equatable {
        let proud: Reflection?
        let lesson: Reflection?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            proud = try? c.decodeIfPresent(Reflection.self, forKey: .proud)
            lesson = try? c.decodeIfPresent(Reflection.self, forKey: .lesson)
        }

        private enum CodingKeys: String, CodingKey { case proud, lesson }
    }

    /// Next week's intention: the thread it continues, the obstacle he named, and his if-then plan.
    struct Intention: Decodable, Equatable {
        let thread: String?
        let text: String?
        let obstacle: String?
        let ifThen: String?
    }

    struct OneThing: Decodable, Equatable {
        let text: String?
        let carried: Int?
    }

    struct Who: Decodable, Equatable {
        let name: String
        let carried: Int?
    }

    /// A note to the future, sealed until `opensOn`.
    struct Note: Decodable, Equatable {
        let text: String?
        let opensOn: String?
    }

    /// The prediction this week made.
    struct Prediction: Decodable, Equatable {
        let id: String?
        let text: String?
        let probability: Int?
        let due: String?
    }

    /// An earlier prediction graded this week (`grade`: hit, partly, miss).
    struct Graded: Decodable, Equatable {
        let id: String?
        let madeWeek: String?
        let grade: String?
        let text: String?
        let note: String?
    }

    private enum CodingKeys: String, CodingKey {
        case weekEnding, weekNumber, title, story, photo, energy, deep, commitments, values, oneThing, who, note, prediction, graded
        case version, moments, ended, lastIntention, reflect, intention
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekEnding = try c.decode(String.self, forKey: .weekEnding)
        weekNumber = try? c.decodeIfPresent(Int.self, forKey: .weekNumber)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        story = try? c.decodeIfPresent(String.self, forKey: .story)
        photo = (try? c.decodeIfPresent(String.self, forKey: .photo)).flatMap { $0.isEmpty ? nil : $0 }
        energy = (try? c.decodeIfPresent(Energy.self, forKey: .energy)) ?? Energy()
        deep = try? c.decodeIfPresent(Deep.self, forKey: .deep)
        commitments = Self.list(c, .commitments)
        values = Self.list(c, .values)
        oneThing = try? c.decodeIfPresent(OneThing.self, forKey: .oneThing)
        who = Self.list(c, .who)
        note = try? c.decodeIfPresent(Note.self, forKey: .note)
        prediction = try? c.decodeIfPresent(Prediction.self, forKey: .prediction)
        graded = Self.list(c, .graded)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        moments = Self.list(c, .moments)
        ended = try? c.decodeIfPresent(String.self, forKey: .ended)
        lastIntention = try? c.decodeIfPresent(LastIntention.self, forKey: .lastIntention)
        reflect = try? c.decodeIfPresent(Reflect.self, forKey: .reflect)
        intention = try? c.decodeIfPresent(Intention.self, forKey: .intention)
    }

    /// An entry that fails to decode is dropped, never the record.
    private static func list<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        ((try? c.decodeIfPresent([Lossy<T>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    /// Whether the week page uses the moments layout: a v2 record, even one with no moments, or
    /// any record that carries moments. Everything else renders as it always did.
    var isMomentsRecord: Bool { (version ?? 0) >= 2 || !moments.isEmpty }

    static func decode(_ data: Data) throws -> WeekRecord {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WeekRecord.self, from: data)
    }
}

/// The morning deck's This-week divider carries the intention he sealed on Sunday.
struct DeckIntentionLine: Decodable, Equatable {
    let text: String
    let ifThen: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        ifThen = try? c.decodeIfPresent(String.self, forKey: .ifThen)
    }

    private enum CodingKeys: String, CodingKey { case text, ifThen }

    init(text: String, ifThen: String? = nil) {
        self.text = text
        self.ifThen = ifThen
    }

    /// "Your intention: Send five asks · If it is 9am, then I write."
    var line: String {
        let plan = ifThen?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Your intention: \(text)" + (plan.isEmpty ? "" : " \u{b7} \(plan)")
    }
}
