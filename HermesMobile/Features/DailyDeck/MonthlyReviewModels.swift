import Foundation

/// A monthly review card's month (wire `month`, the vault's `review_deck.build_monthly`): what the
/// cover, the weeks arc, the dots, an insight, the November values card, and the close's year draw.
/// Every field is optional so a newer deck never fails to decode.
struct DeckMonth: Decodable, Equatable {
    /// The month's name ("October").
    let name: String?
    /// The cover's big numbers, counted up as it lands.
    let totals: [Total]
    /// The weeks arc, oldest first.
    let weeks: [Week]
    /// The month's first day as a weekday (0 Sunday) and its length, for the dots calendars.
    let firstWeekday: Int?
    let daysInMonth: Int?
    /// The dots card's calendars (a habit's done days) and its counted rows.
    let rows: [DotRow]
    let pips: [PipRow]
    /// An insight's mark, its stat, and the days it draws (`marked` ringed).
    let symbol: String?
    let stat: Stat?
    let days: [Int]
    let marked: [Int]
    /// A value card's score in each week of the month, oldest first; nil where that week has none.
    let weekScores: [Int?]
    /// The close's year: one tile per month, titled once its review is done.
    let year: Int?
    let months: [YearMonth]
    /// His own words behind a card: journal lines and answers, each with its day and what it answered.
    let snippets: [Snippet]
    /// What his advisors make of it, a line each.
    let advisors: [AdvisorNote]
    /// The month's highlights as tiles: a number or a few words, with what it was.
    let tiles: [Tile]
    /// The sleep card's month (`MonthSleepCard`).
    let sleep: Sleep?
    /// A weekly cover's days, one row each, to star the week's real moments.
    let dayLines: [DayLine]
    /// The calendar's column letters when they aren't S–S (a week runs M–S); with them, day 1 is column 1.
    let labels: [String]
    /// A weekly value card asks for a 1–10 score.
    let scored: Bool?
    /// The weekly review puts the card's answer (slider or words) right under its title, with the
    /// evidence below it to read if he wants.
    let inputFirst: Bool?
    /// The weekly "Did it hold?" card: last week's intention and what might have got in the way.
    let held: Held?
    /// The weekly intention Atlas proposes for next week, accepted or tweaked with a tap.
    let proposal: Proposal?
    /// What kept coming up in his entries, each a few words and a line on where it showed.
    let themes: [Theme]
    /// Quotes and highlights he saved in his second brain that speak to the card.
    let library: [LibraryQuote]

    struct Total: Decodable, Equatable {
        let value: Int
        let label: String
    }

    struct Week: Decodable, Equatable, Identifiable {
        let number: Int
        let range: String?
        let title: String
        let line: String?
        /// The month's last week, still being lived.
        let open: Bool?
        /// A title Atlas drafted for a week that had none.
        let drafted: Bool?
        var id: Int { number }
    }

    struct DotRow: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        let color: String?
        let days: [Int]
    }

    struct PipRow: Decodable, Equatable, Identifiable {
        let id: String
        let label: String
        let color: String?
        let count: Int
    }

    struct Stat: Decodable, Equatable {
        let value: Int
        let of: Int?
        let label: String
    }

    struct Snippet: Decodable, Equatable {
        let day: String?
        let text: String
        /// The question he was answering, when there was one.
        let asked: String?
    }

    struct AdvisorNote: Decodable, Equatable {
        let name: String
        let role: String?
        let text: String
    }

    struct LibraryQuote: Decodable, Equatable {
        let text: String
        let source: String?
    }

    struct DayLine: Decodable, Equatable, Identifiable {
        let day: String
        let date: String?
        let line: String
        let value: String?
        var id: String { day }
    }

    struct Held: Decodable, Equatable {
        let intention: String
        let ifThen: String?
        let reasons: [String]
    }

    struct Proposal: Decodable, Equatable {
        let intention: String
        let obstacle: String?
        let ifThen: String?
    }

    struct Theme: Decodable, Equatable {
        let title: String
        let line: String?
    }

    struct Tile: Decodable, Equatable {
        let value: Int?
        let unit: String?
        let text: String?
        let label: String
        let day: String?
    }

    /// The month's sleep: its average score against last month, a night per day by score tier, the
    /// HRV status per night, the month's numbers as tiles, and the sleep coach's read.
    struct Sleep: Decodable, Equatable {
        let score: Int
        let delta: Int?
        /// Each night (`day`) as `good` (80+), `fair` (70s) or `rough` (under 70); missing nights are blank.
        let nights: [Night]
        /// Each night's HRV status: `balanced`, `unbalanced`, or `low`.
        let hrv: [Night]
        let tiles: [NumberTile]
        let coach: AdvisorNote?

        struct Night: Decodable, Equatable {
            let day: Int
            let tier: String
        }

        struct NumberTile: Decodable, Equatable {
            let label: String
            let value: String
            let note: String?
        }

        private enum CodingKeys: String, CodingKey { case score, delta, nights, hrv, tiles, coach }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            score = try c.decode(Int.self, forKey: .score)
            delta = try? c.decodeIfPresent(Int.self, forKey: .delta)
            nights = ((try? c.decodeIfPresent([Lossy<Night>].self, forKey: .nights)) ?? []).compactMap(\.value)
            hrv = ((try? c.decodeIfPresent([Lossy<Night>].self, forKey: .hrv)) ?? []).compactMap(\.value)
            tiles = ((try? c.decodeIfPresent([Lossy<NumberTile>].self, forKey: .tiles)) ?? []).compactMap(\.value)
            coach = try? c.decodeIfPresent(AdvisorNote.self, forKey: .coach)
        }
    }

    struct YearMonth: Decodable, Equatable, Identifiable {
        let month: String
        let title: String?
        var id: String { month }
    }

    private enum CodingKeys: String, CodingKey {
        case name, totals, weeks, firstWeekday, daysInMonth, rows, pips, symbol, stat, days
        case marked, weekScores, year, months, snippets, advisors, tiles, sleep, themes, library
        case dayLines, labels, scored, inputFirst, held, proposal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list<T: Decodable>(_ key: CodingKeys) -> [T] {
            ((try? c.decodeIfPresent([Lossy<T>].self, forKey: key)) ?? []).compactMap(\.value)
        }
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        totals = list(.totals)
        weeks = list(.weeks)
        firstWeekday = try? c.decodeIfPresent(Int.self, forKey: .firstWeekday)
        daysInMonth = try? c.decodeIfPresent(Int.self, forKey: .daysInMonth)
        rows = list(.rows)
        pips = list(.pips)
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        stat = try? c.decodeIfPresent(Stat.self, forKey: .stat)
        days = (try? c.decodeIfPresent([Int].self, forKey: .days)) ?? []
        marked = (try? c.decodeIfPresent([Int].self, forKey: .marked)) ?? []
        weekScores = (try? c.decodeIfPresent([Int?].self, forKey: .weekScores)) ?? []
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        months = list(.months)
        snippets = list(.snippets)
        advisors = list(.advisors)
        tiles = list(.tiles)
        sleep = try? c.decodeIfPresent(Sleep.self, forKey: .sleep)
        themes = list(.themes)
        library = list(.library)
        dayLines = list(.dayLines)
        labels = (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? []
        scored = try? c.decodeIfPresent(Bool.self, forKey: .scored)
        inputFirst = try? c.decodeIfPresent(Bool.self, forKey: .inputFirst)
        held = try? c.decodeIfPresent(Held.self, forKey: .held)
        proposal = try? c.decodeIfPresent(Proposal.self, forKey: .proposal)
    }
}

extension HermexPaper {
    /// The paper a deck names ("wiki", "body"); nil for a name outside the papers.
    static func named(_ name: String?) -> HermexPaper? {
        switch name {
        case "opener": .opener
        case "quote": .quote
        case "book": .book
        case "wiki": .wiki
        case "reading": .reading
        case "notes": .notes
        case "video": .video
        case "past": .past
        case "advisor": .advisor
        case "plain": .plain
        case "mandarin": .mandarin
        case "ledger": .ledger
        case "dusk": .dusk
        case "kitchen": .kitchen
        case "body": .body
        default: nil
        }
    }
}
