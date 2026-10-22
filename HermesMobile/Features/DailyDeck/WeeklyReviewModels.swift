import Foundation

// The v2 weekly review's deck pieces and the week record the app reads back. The vault writes both
// (`tools/daily_deck.py` for the deck, `tools/brain/commands/brief.py` for the record); every
// field decodes tolerantly, so a newer vault never costs the deck or the page.

/// One chapter on the cover: "Remember", with the minutes it should take.
struct DeckChapter: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let minutes: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        minutes = try? c.decodeIfPresent(Int.self, forKey: .minutes)
    }

    private enum CodingKeys: String, CodingKey { case id, label, minutes }
}

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

/// One day on the filmstrip: its weekday, a line about it, who you saw, hours slept, and a run.
struct DeckDay: Decodable, Equatable {
    let label: String
    let line: String?
    let people: [String]
    let sleepHours: Double?
    let run: String?

    init(label: String, line: String?, people: [String] = [], sleepHours: Double?, run: String?) {
        self.label = label
        self.line = line
        self.people = people
        self.sleepHours = sleepHours
        self.run = run
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        line = try? c.decodeIfPresent(String.self, forKey: .line)
        people = (try? c.decodeIfPresent([String].self, forKey: .people)) ?? []
        sleepHours = try? c.decodeIfPresent(Double.self, forKey: .sleepHours)
        run = try? c.decodeIfPresent(String.self, forKey: .run)
    }

    private enum CodingKeys: String, CodingKey { case label, line, people, sleepHours, run }
}

/// A row to grade on the commitments card (`carried` counts the weeks it has rolled over) or the
/// predictions card (`probability`, `due`, and the Sunday it was `madeWeek`).
struct DeckReviewItem: Decodable, Equatable, Identifiable {
    let id: String
    let text: String
    let carried: Int?
    let probability: Int?
    let due: String?
    let madeWeek: String?

    init(id: String, text: String, carried: Int? = nil, probability: Int? = nil, due: String? = nil, madeWeek: String? = nil) {
        self.id = id
        self.text = text
        self.carried = carried
        self.probability = probability
        self.due = due
        self.madeWeek = madeWeek
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        carried = try? c.decodeIfPresent(Int.self, forKey: .carried)
        probability = try? c.decodeIfPresent(Int.self, forKey: .probability)
        due = try? c.decodeIfPresent(String.self, forKey: .due)
        madeWeek = try? c.decodeIfPresent(String.self, forKey: .madeWeek)
    }

    private enum CodingKeys: String, CodingKey { case id, text, carried, probability, due, madeWeek }
}

/// One of the five values on the values card, with the evidence the brief found for it.
struct DeckValue: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let evidence: String?

    init(id: String, name: String, evidence: String? = nil) {
        self.id = id
        self.name = name
        self.evidence = evidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        evidence = try? c.decodeIfPresent(String.self, forKey: .evidence)
    }

    private enum CodingKeys: String, CodingKey { case id, name, evidence }
}

/// A prediction made on the keepsakes card: what, how sure, and when it can be graded.
struct DeckPrediction: Codable, Equatable {
    var text: String
    var probability: Int
    var due: String
}

extension DeckPrediction {
    static let defaultProbability = 70

    /// A new prediction's due day, `yyyy-MM-dd`: four weeks after the deck's day.
    static func defaultDue(deckDate: String, calendar: Calendar = .current) -> String {
        let start = date(day: deckDate, calendar: calendar) ?? Date()
        return DailyDeckPaths.day(calendar.date(byAdding: .day, value: 28, to: start) ?? start, calendar: calendar)
    }

    /// A `yyyy-MM-dd` day as a date in `calendar`, nil when it doesn't read as one.
    static func date(day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// A commitment's grade on the commitments card. Tapping a row steps through the cycle.
enum CommitmentStatus {
    static let kept = "kept"
    static let missed = "missed"
    static let dropped = "dropped"

    /// None, kept, missed, dropped, and back to none.
    static let cycle: [String?] = [nil, kept, missed, dropped]

    /// The status after `status`; an unknown one starts over at kept.
    static func next(after status: String?) -> String? {
        let index = cycle.firstIndex(of: status) ?? 0
        return cycle[(index + 1) % cycle.count]
    }
}

extension DeckCard {
    /// The v2 weekly chapters, in the order the review walks them.
    static let weeklyChapters = ["remember", "understand", "account", "steer"]

    /// The card's chapter as it shows in place of the reason line: "1 · Remember". Nil on the
    /// cover, the close, and any card off the v2 weekly deck.
    var chapterLabel: String? {
        guard let chapter, !chapter.isEmpty else { return nil }
        let name = chapter.prefix(1).uppercased() + chapter.dropFirst()
        guard let index = Self.weeklyChapters.firstIndex(of: chapter) else { return name }
        return "\(index + 1) · \(name)"
    }
}

/// The five values, scored 1–10 each week, and which two the week is remembered by.
enum WeeklyValues {
    /// The fixed order the vault uses; a tie goes to the earlier value.
    static let order = ["present", "people", "dad", "potential", "body"]

    /// The highest-scored value, then the lowest. When every score is equal (or only one is
    /// scored) only the top one counts. Scores for ids outside `order` are ignored.
    static func topAndBottom(_ scores: [String: Int], order: [String]) -> [String] {
        let scored = order.compactMap { id in scores[id].map { (id: id, score: $0) } }
        guard var top = scored.first, var bottom = scored.first else { return [] }
        for entry in scored.dropFirst() {
            if entry.score > top.score { top = entry }
            if entry.score < bottom.score { bottom = entry }
        }
        return top.score == bottom.score ? [top.id] : [top.id, bottom.id]
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
    struct Value: Decodable, Equatable, Identifiable {
        let id: String
        let name: String?
        let score: Int?
        let evidence: String?
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
    }

    /// An entry that fails to decode is dropped, never the record.
    private static func list<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        ((try? c.decodeIfPresent([Lossy<T>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    static func decode(_ data: Data) throws -> WeekRecord {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WeekRecord.self, from: data)
    }
}
