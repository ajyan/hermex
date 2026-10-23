import Foundation

/// A Daily Deck: the morning (or evening) brief as cards. The server writes it to
/// `briefs/<date>.<kind>.json` in the brief's workspace (second-brain
/// `tools/daily_deck.py`); the app only reads it and sends the answers back.
struct DailyDeck: Decodable, Equatable {
    let version: Int?
    let date: String
    let kind: String
    let advisor: String?
    /// A card that fails to decode (no `id`, say) is dropped, never the deck.
    let cards: [DeckCard]

    private enum CodingKeys: String, CodingKey { case version, date, kind, advisor, cards }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        date = try c.decode(String.self, forKey: .date)
        kind = try c.decode(String.self, forKey: .kind)
        advisor = try? c.decodeIfPresent(String.self, forKey: .advisor)
        cards = try c.decode([Lossy<DeckCard>].self, forKey: .cards).compactMap(\.value)
    }

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
        case headline, prompt, decision, reflect, item, sleep, goal, weekAhead, changes, ask, section, close
        /// The v2 weekly review's cards (`WeeklyReviewModels.swift`).
        case cover, filmstrip, story, energy, commitments, values, predictions, who, keepsakes
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "headline": self = .headline
            case "prompt": self = .prompt
            case "decision": self = .decision
            case "reflect": self = .reflect
            case "item": self = .item
            case "sleep": self = .sleep
            case "goal": self = .goal
            case "week_ahead": self = .weekAhead
            case "changes": self = .changes
            case "ask": self = .ask
            case "section": self = .section
            case "close": self = .close
            case "cover": self = .cover
            case "filmstrip": self = .filmstrip
            case "story": self = .story
            case "energy": self = .energy
            case "commitments": self = .commitments
            case "values": self = .values
            case "predictions": self = .predictions
            case "who": self = .who
            case "keepsakes": self = .keepsakes
            default: self = .unknown(raw)
            }
        }
    }

    let id: String
    let type: CardType
    /// For `item` cards: book, insight, video, youtube, media. A `prompt` card's is `letter` for the Dad card.
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
    /// On the headline card: one sentence about yesterday (a weekly review's: about the week), written by the brief.
    let recap: String?
    /// A recap's items (a review's days, answers, or last week's plan), each under an optional label;
    /// on a weekly review's headline, the week's highlights under their days.
    let entries: [DeckEntry]
    /// A weekly review's mood card: energy and mood per weekday, nil where nothing was written.
    let points: [DeckPoint]
    /// A weekly review's goals card: one meter per commitment.
    let meters: [DeckMeter]
    /// A goals card's paper name ("wiki"), as its goal sets it.
    let color: String?
    /// A sleep card's rating labels, worst to best; the answer's `rating` is a 1-based index.
    let scale: [String]
    /// A sleep card's numbers from the user's watch.
    let sleep: DeckSleep?
    /// A sleep card's tags: what might have shaped the night, tapped beside the rating.
    let tags: [DeckSleepTag]
    /// A goal card's personal goals (slugs). The card checks in on them live through the Goals API;
    /// `fallback` is the brief's text for when the server can't serve them.
    let goals: [String]
    /// A Week ahead card's goal (slug) and the Monday its proposed week starts.
    let goal: String?
    let start: String?
    /// A Week ahead card's proposal for next week, and last week's plan (for Ease off).
    let weekCommitments: [DeckWeekCommitment]
    let lastWeek: [DeckWeekCommitment]
    /// A Mandarin card's phrases to hear and say, the review one last.
    let phrases: [DeckPhrase]
    /// A Mandarin card's feedback on the last answer filed.
    let yesterday: DeckMandarinFeedback?
    /// A Mandarin card's question (in `question`, as characters) in pinyin and in English.
    let questionPinyin: String?
    let questionEn: String?
    /// A weekly review's What changed card: the fixes whose status moved this week, newest first.
    let rows: [DeckChangeRow]
    /// The headline's style rules learned or dropped since the last deck (`tools/style_learn.py`).
    let learned: [DeckLearned]
    /// A v2 weekly card's chapter ("remember", "understand", "account", "steer"); the cover and close have none.
    let chapter: String?
    /// The cover's week number, date range ("Oct 19–25"), chapter list, and the note a year-ago self left.
    let weekNumber: Int?
    let range: String?
    let chapters: [DeckChapter]
    let noteFromPast: DeckPastNote?
    /// The filmstrip's seven days.
    let days: [DeckDay]
    /// The story card's drafted paragraph. On the wire this is the card's `draft` key, a string here
    /// and a `DeckDraft` on the text-drafting cards, so it decodes under its own name.
    let storyDraft: String?
    /// The energy card's suggested chips.
    let gave: [String]
    let drained: [String]
    /// The deep question's rotation ("Examen").
    let rotation: String?
    /// The commitments and predictions cards' rows to grade.
    let items: [DeckReviewItem]
    /// The values card's five values, with the evidence the brief found for each.
    let values: [DeckValue]
    /// The who card's suggested people.
    let suggested: [String]
    /// A Piece card's argument and quotes, from the long piece's map (the vault's tools/piece_view.py).
    let piece: DeckPiece?

    /// The vault file the card came from (`ref.link`, "wiki/nyc-marathon"); nil for pooled
    /// material with no page of its own (books, quotes, videos).
    let link: String?
    /// The pool item the brief picked (`ref.pool`, "media:kafka", "video:<id>"); nil for cards it didn't pick from a pool.
    let pool: String?

    /// Which of the week's drafted questions this card's sources answer (`week.variant`, 0 the first);
    /// nil on every card that isn't one of the week's sources.
    let weekVariant: Int?

    /// The Brain page the card's source opens, by the vault folder its link lives in.
    var sourceRoute: BrainRoute? { link.flatMap(Self.brainRoute(forLink:)) }

    /// A vault path as the Brain page it is: the folder decides the module (the server's
    /// `brain_catalog` scans the same folders) and the page id is the path with `.md`.
    static func brainRoute(forLink link: String) -> BrainRoute? {
        let folders: [(String, BrainModuleID)] = [
            ("wiki/", .wiki), ("journal/", .journal), ("email_ingest/summaries/", .articles),
            ("crm/contacts/", .people), ("youtube_highlights/summaries/", .highlights),
            ("daughter/letters/", .letters),
        ]
        let path = link.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let module = folders.first(where: { path.hasPrefix($0.0) })?.1 else { return nil }
        return .page(module, path.hasSuffix(".md") ? path : path + ".md")
    }

    /// The open card's foot button for a source in `module`.
    static func openTitle(for route: BrainRoute) -> String {
        guard case .page(let module, _) = route else { return "Open in Brain" }
        switch module {
        case .wiki: return "Open the page"
        case .journal: return "Open the journal day"
        case .articles: return "Open the article"
        case .people: return "Open their page"
        case .highlights: return "Open the video"
        case .letters: return "Open the letter"
        }
    }

    /// What VoiceOver reads for a `section` divider: "This week, Being a father, <the question>".
    /// `lines[0]` is "This week · <area>"; the question is the title.
    var sectionSpokenLabel: String { sectionSpokenLabel(question: title) }

    /// The same label for the question on screen, which Regenerate may have changed.
    func sectionSpokenLabel(question: String?) -> String {
        let kicker = (lines.first ?? "This week").replacingOccurrences(of: " · ", with: ", ")
        return [kicker, question].compactMap { $0 }.joined(separator: ", ")
    }

    /// The placeholder of a decision card's answer box once `chosen` (a text action) is picked:
    /// the card's own question (the Sunday view-take's "Your take, in a sentence"), else "Your answer".
    func answerPrompt(chosen: String) -> String {
        chosen == "edit" ? "Your version" : (question ?? "Your answer")
    }

    /// The Sunday review's close of the week's question: his answers as `entries`, Still open / Settled.
    var isViewTake: Bool { type == .decision && itemKind == "view_take" }

    /// A decision that belongs on the shared follow-ups page: every decision but the view-take.
    var isFollowUp: Bool { type == .decision && !isViewTake }

    /// The prose a decision row shows under its title: none when it repeats the title, and none
    /// when the card has `entries`, since `body` is only their plain copy for older builds.
    var decisionBody: String? {
        guard entries.isEmpty, let body, body != title else { return nil }
        return body
    }

    /// The Dad card: a prompt to say something to his daughter, with the countdown to her birth
    /// (then her age) in `lines`. Its answer is filed as a letter to her, not into the journal.
    var isLetter: Bool { type == .prompt && itemKind == "letter" }

    /// The Mandarin practice card: phrases to hear and a question to answer out loud. Its answer is
    /// filed to the vault's Mandarin log, which writes the feedback shown on the next one.
    var isMandarin: Bool { type == .prompt && itemKind == "mandarin" }

    /// The weekly work-ethic card's traits, each rated 1–10 by tapping instead of typed. Keyed off
    /// the card's stable id, so decks already written get the picker too; the answer stays text.
    var selfRatings: [String]? {
        type == .prompt && id == "q-hormozi" ? ["Consistency", "Intensity", "Focus", "Boredom tolerance", "Sacrifice"] : nil
    }

    /// Whether answering this card means typing (prompt and reflect cards, and a sleep or goal card's note).
    var takesText: Bool { (type == .prompt && selfRatings == nil) || type == .reflect || type == .sleep || type == .goal }

    /// Whether "Not for Me" applies: material the brief chose, not the deck's own pages.
    var takesFeedback: Bool {
        switch type {
        case .prompt, .reflect, .item, .unknown: true
        case .headline, .decision, .sleep, .goal, .weekAhead, .changes, .ask, .section, .close: false
        case .cover, .filmstrip, .story, .energy, .commitments, .values, .predictions, .who, .keepsakes: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, body, source, lines, question, context, voice, why, draft, actions, fallback
        case reason, altQuestions, entries, recap, scale, sleep, tags, points, meters, color, goals, ref
        case goal, start, lastWeek, phrases, yesterday, questionPinyin, questionEn, rows, week
        case chapter, weekNumber, range, chapters, noteFromPast, days, gave, drained, rotation, items, values, suggested
        case piece, learned
        case weekCommitments = "commitments"
        case itemKind = "kind"
    }

    private struct Week: Decodable {
        let variant: Int?

        init(from decoder: Decoder) throws {
            variant = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Int.self, forKey: .variant)
        }

        private enum CodingKeys: String, CodingKey { case variant }
    }

    private struct Ref: Decodable {
        let link: String?
        let pool: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            link = try? c.decodeIfPresent(String.self, forKey: .link)
            pool = try? c.decodeIfPresent(String.self, forKey: .pool)
        }

        private enum CodingKeys: String, CodingKey { case link, pool }
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
        actions = ((try? c.decodeIfPresent([Lossy<DeckAction>].self, forKey: .actions)) ?? []).compactMap(\.value)
        fallback = try? c.decodeIfPresent(String.self, forKey: .fallback)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        recap = (try? c.decodeIfPresent(String.self, forKey: .recap))
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        altQuestions = (try? c.decodeIfPresent([String].self, forKey: .altQuestions)) ?? []
        entries = ((try? c.decodeIfPresent([Lossy<DeckEntry>].self, forKey: .entries)) ?? []).compactMap(\.value)
        points = ((try? c.decodeIfPresent([Lossy<DeckPoint>].self, forKey: .points)) ?? []).compactMap(\.value)
        meters = ((try? c.decodeIfPresent([Lossy<DeckMeter>].self, forKey: .meters)) ?? []).compactMap(\.value)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        scale = (try? c.decodeIfPresent([String].self, forKey: .scale)) ?? []
        sleep = try? c.decodeIfPresent(DeckSleep.self, forKey: .sleep)
        tags = ((try? c.decodeIfPresent([Lossy<DeckSleepTag>].self, forKey: .tags)) ?? []).compactMap(\.value)
        goals = (try? c.decodeIfPresent([String].self, forKey: .goals)) ?? []
        goal = try? c.decodeIfPresent(String.self, forKey: .goal)
        start = try? c.decodeIfPresent(String.self, forKey: .start)
        weekCommitments = ((try? c.decodeIfPresent([Lossy<DeckWeekCommitment>].self, forKey: .weekCommitments)) ?? [])
            .compactMap(\.value)
        lastWeek = ((try? c.decodeIfPresent([Lossy<DeckWeekCommitment>].self, forKey: .lastWeek)) ?? []).compactMap(\.value)
        phrases = ((try? c.decodeIfPresent([Lossy<DeckPhrase>].self, forKey: .phrases)) ?? []).compactMap(\.value)
        yesterday = try? c.decodeIfPresent(DeckMandarinFeedback.self, forKey: .yesterday)
        questionPinyin = try? c.decodeIfPresent(String.self, forKey: .questionPinyin)
        questionEn = try? c.decodeIfPresent(String.self, forKey: .questionEn)
        rows = ((try? c.decodeIfPresent([Lossy<DeckChangeRow>].self, forKey: .rows)) ?? []).compactMap(\.value)
        learned = ((try? c.decodeIfPresent([Lossy<DeckLearned>].self, forKey: .learned)) ?? []).compactMap(\.value)
        weekVariant = (try? c.decodeIfPresent(Week.self, forKey: .week))?.variant
        chapter = try? c.decodeIfPresent(String.self, forKey: .chapter)
        weekNumber = try? c.decodeIfPresent(Int.self, forKey: .weekNumber)
        range = try? c.decodeIfPresent(String.self, forKey: .range)
        chapters = ((try? c.decodeIfPresent([Lossy<DeckChapter>].self, forKey: .chapters)) ?? []).compactMap(\.value)
        noteFromPast = try? c.decodeIfPresent(DeckPastNote.self, forKey: .noteFromPast)
        days = ((try? c.decodeIfPresent([Lossy<DeckDay>].self, forKey: .days)) ?? []).compactMap(\.value)
        storyDraft = try? c.decodeIfPresent(String.self, forKey: .draft)
        gave = (try? c.decodeIfPresent([String].self, forKey: .gave)) ?? []
        drained = (try? c.decodeIfPresent([String].self, forKey: .drained)) ?? []
        rotation = try? c.decodeIfPresent(String.self, forKey: .rotation)
        items = ((try? c.decodeIfPresent([Lossy<DeckReviewItem>].self, forKey: .items)) ?? []).compactMap(\.value)
        values = ((try? c.decodeIfPresent([Lossy<DeckValue>].self, forKey: .values)) ?? []).compactMap(\.value)
        suggested = (try? c.decodeIfPresent([String].self, forKey: .suggested)) ?? []
        piece = (try? c.decodeIfPresent(DeckPiece.self, forKey: .piece)).flatMap { $0.steps.isEmpty ? nil : $0 }
        let ref = try? c.decodeIfPresent(Ref.self, forKey: .ref)
        link = ref?.link.flatMap { $0.isEmpty ? nil : $0 }
        pool = ref?.pool.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Last night from the user's watch, already written by the brief: `headline` is hours against need
/// ("8.5 h of 9 h needed", nil before the watch syncs), `lines` the timing and recovery (for decks
/// without tiles), `nights` the last seven, oldest first, for the charts. `tiles` are last night's
/// stats (asleep, woke, slept, wake-ups), `coach` the sleep coach's note and `insight` the one-line
/// fallback when there is no note. `hrvBand` is Garmin's normal range for HRV.
struct DeckSleep: Decodable, Equatable {
    let headline: String?
    let lines: [String]
    let nights: [DeckNight]
    let insight: String?
    let tiles: [DeckSleepTile]
    let coach: DeckSleepCoach?
    let hrvBand: ClosedRange<Double>?
    let hrvStatus: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = try? c.decodeIfPresent(String.self, forKey: .headline)
        lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
        nights = (try? c.decodeIfPresent([DeckNight].self, forKey: .nights)) ?? []
        insight = (try? c.decodeIfPresent(String.self, forKey: .insight)).flatMap { $0.isEmpty ? nil : $0 }
        tiles = ((try? c.decodeIfPresent([Lossy<DeckSleepTile>].self, forKey: .tiles)) ?? []).compactMap(\.value)
        coach = try? c.decodeIfPresent(DeckSleepCoach.self, forKey: .coach)
        let band = (try? c.decodeIfPresent([Double].self, forKey: .hrvBand)) ?? []
        hrvBand = band.count == 2 && band[0] < band[1] ? band[0]...band[1] : nil
        hrvStatus = (try? c.decodeIfPresent(String.self, forKey: .hrvStatus)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `hrv_band` and `hrv_status` on the wire: the deck decodes snake_case keys.
    private enum CodingKeys: String, CodingKey { case headline, lines, nights, insight, tiles, coach, hrvBand, hrvStatus }
}

/// One of last night's stats, already written by the brief: "Wake-ups", "4", "usually 2 · 54 min awake".
struct DeckSleepTile: Decodable, Equatable {
    let label: String
    let value: String
    let note: String?
}

/// The sleep coach's note on the card: who wrote it and what she said.
struct DeckSleepCoach: Decodable, Equatable {
    let name: String
    let text: String
}

/// Something that might have shaped the night ("Late meal"); `id` is what gets filed.
struct DeckSleepTag: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
}

/// One night on the charts: its weekday, hours slept against hours needed, and overnight HRV
/// (each nil when unknown).
struct DeckNight: Decodable, Equatable {
    let day: String
    let hours: Double?
    let need: Double?
    let hrv: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = (try? c.decode(String.self, forKey: .day)) ?? ""
        hours = try? c.decodeIfPresent(Double.self, forKey: .hours)
        need = try? c.decodeIfPresent(Double.self, forKey: .need)
        hrv = try? c.decodeIfPresent(Double.self, forKey: .hrv)
    }

    private enum CodingKeys: String, CodingKey { case day, hours, need, hrv }
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

/// A Piece card's long piece, laid out from its map: the argument in numbered steps, each with where it
/// sits in the piece ("Parts 3–5 · from 0:24"), then a few quotes from across it in its own words.
struct DeckPiece: Decodable, Equatable, Hashable {
    struct Step: Decodable, Equatable, Hashable {
        let name: String?
        let claim: String
        let span: String?
    }

    struct Quote: Decodable, Equatable, Hashable {
        let text: String
        let at: String?
    }

    /// "3 hours · 15 parts".
    let meta: String?
    let steps: [Step]
    let quotes: [Quote]

    init(meta: String?, steps: [Step], quotes: [Quote]) {
        self.meta = meta
        self.steps = steps
        self.quotes = quotes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try? c.decodeIfPresent(String.self, forKey: .meta)
        steps = ((try? c.decodeIfPresent([Lossy<Step>].self, forKey: .steps)) ?? []).compactMap(\.value)
            .filter { !$0.claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        quotes = ((try? c.decodeIfPresent([Lossy<Quote>].self, forKey: .quotes)) ?? []).compactMap(\.value)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private enum CodingKeys: String, CodingKey { case meta, steps, quotes }
}

/// One weekday on the mood card. Energy (Garmin Body Battery) and mood (read from what you
/// wrote, with the `quote` it rests on) run 1–10; sleep is hours. nil is a gap.
struct DeckPoint: Decodable, Equatable, Hashable {
    let label: String
    let energy: Int?
    let mood: Int?
    let sleep: Double?
    let quote: String?
    let note: String?
}

/// One commitment's week on the goals card, grouped under its goal.
struct DeckMeter: Decodable, Equatable, Hashable {
    let group: String?
    let label: String
    let done: Int
    let target: Int

    /// How full the meter is, 0–1.
    var fraction: Double { target > 0 ? min(1, Double(done) / Double(target)) : 0 }
}

/// One row of a weekly review's What changed card: a fix from the feedback loop whose status
/// moved this week. `id` is the feedback entry's, `said` the user's note (clipped), `change` the
/// plan's title. `undoable` is set while the fix is shipped; Undo posts the entry's `undo` decision.
struct DeckChangeRow: Decodable, Equatable, Identifiable {
    enum State: Equatable {
        case shipped, merged, held, recurred, reverted
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "shipped": self = .shipped
            case "merged": self = .merged
            case "held": self = .held
            case "recurred": self = .recurred
            case "reverted": self = .reverted
            default: self = .unknown(raw)
            }
        }

        /// The state chip's words: "Shipped", "Recurred ×2", "Undone".
        func label(recurred: Int?) -> String {
            switch self {
            case .shipped: "Shipped"
            case .merged: "Merged"
            case .held: "Held"
            case .recurred: (recurred ?? 0) > 0 ? "Recurred ×\(recurred ?? 0)" : "Recurred"
            case .reverted: "Undone"
            case .unknown(let raw): raw.prefix(1).uppercased() + raw.dropFirst()
            }
        }
    }

    let id: String
    let said: String
    let change: String
    let state: State
    let recurred: Int?
    let undoable: Bool?

    private enum CodingKeys: String, CodingKey { case id, said, change, state, recurred, undoable }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        said = (try? c.decodeIfPresent(String.self, forKey: .said)) ?? ""
        change = (try? c.decodeIfPresent(String.self, forKey: .change)) ?? ""
        state = State((try? c.decodeIfPresent(String.self, forKey: .state)) ?? "")
        recurred = try? c.decodeIfPresent(Int.self, forKey: .recurred)
        undoable = try? c.decodeIfPresent(Bool.self, forKey: .undoable)
    }
}

/// Decodes one item, or nothing when it is malformed, so a bad item never costs the list.
/// A Mandarin phrase: characters, pinyin over them, English on tap. `review` marks the one the
/// phrasebook brought back today.
struct DeckPhrase: Decodable, Equatable, Hashable {
    let hanzi: String
    let pinyin: String?
    let en: String?
    let review: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hanzi = try c.decode(String.self, forKey: .hanzi)
        pinyin = try? c.decodeIfPresent(String.self, forKey: .pinyin)
        en = try? c.decodeIfPresent(String.self, forKey: .en)
        review = (try? c.decodeIfPresent(Bool.self, forKey: .review)) ?? false
    }

    private enum CodingKeys: String, CodingKey { case hanzi, pinyin, en, review }
}

/// The local model's feedback on the last Mandarin answer: what he said, a more natural way to
/// say it, and a few notes. A block without `natural` doesn't decode, so nothing half-shows.
struct DeckMandarinFeedback: Decodable, Equatable {
    let said: String?
    let natural: String
    let naturalPinyin: String?
    let notes: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        said = try? c.decodeIfPresent(String.self, forKey: .said)
        natural = try c.decode(String.self, forKey: .natural)
        naturalPinyin = try? c.decodeIfPresent(String.self, forKey: .naturalPinyin)
        notes = (try? c.decodeIfPresent([String].self, forKey: .notes)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case said, natural, naturalPinyin, notes }
}

struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
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
    /// Set on a "Text <name>" action: the phone's own Messages sends it, and the
    /// card is answered only once the message went out.
    let message: DeckMessage?

    var takesText: Bool { input == "text" }
}

/// A text the phone sends itself: who to, and the suggested words (editable in the sheet).
struct DeckMessage: Decodable, Equatable {
    /// An iMessage phone number or email.
    let to: String
    let body: String?
}

/// What the user did with one card. Only non-empty answers are sent.
struct DeckAnswer: Codable, Equatable {
    var card: String
    var text: String?
    var action: String?
    /// A sleep card's rating: a 1-based index into the card's `scale`.
    var rating: Int?
    /// A sleep card's tapped tags (ids); nil for none. The vault reads a filed sleep answer without
    /// tags as none, so untapping them all and filing again clears them.
    var tags: [String]?
    /// The question answered, when it isn't the card's own (regenerated, or the user's).
    var question: String?
    /// "Not for Me" on this card; a card with feedback leaves the deck.
    var feedback: DeckFeedback?
    /// The v2 weekly cards' answers, each encoded only when set: the values card's 1–10 `scores` and
    /// its evidence `notes`, the energy and who cards' `lists`, the commitments and predictions cards'
    /// `statuses`, and the keepsakes card's `prediction`. Keys are the card's item ids. A list that is
    /// present but empty still answers: chips he removed are filed as none, not refilled from the draft.
    var scores: [String: Int]?
    var notes: [String: String]?
    var lists: [String: [String]]?
    var statuses: [String: String]?
    var prediction: DeckPrediction?

    /// Nothing typed or chosen. Text counts as typed, spaces too, so a field bound to it keeps a
    /// leading space while editing; filing trims, and a blank text files as none.
    var isEmpty: Bool {
        (text?.isEmpty ?? true) && action == nil && rating == nil && question == nil && feedback == nil && !hasTags && !hasWeeklyFields
    }

    private var hasWeeklyFields: Bool {
        !(scores?.isEmpty ?? true) || !(notes?.isEmpty ?? true) || prediction != nil
            || !(statuses?.isEmpty ?? true) || !(lists?.isEmpty ?? true)
    }

    private var hasTags: Bool { !(tags?.isEmpty ?? true) }

    private var hasText: Bool {
        !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Written about, or sent away with Not for Me: the card already says how it landed, so
    /// Label recent cards doesn't ask again.
    var saysHowItLanded: Bool { hasText || feedback != nil }

    /// Whether this answers `card`: a decision whose chosen action needs text
    /// (Answer, Edit) answers nothing until the text is there.
    func isAnswer(for card: DeckCard) -> Bool {
        // The week's divider holds a question choice and a note, never an answer.
        if card.type == .section { return false }
        if let action, card.actions.first(where: { $0.id == action })?.takesText == true { return hasText }
        return hasText || action != nil || rating != nil || hasTags || hasWeeklyFields
    }

    /// Whether this says something worth filing: an answer, or feedback on the card. On the week's
    /// divider that is the question chosen and the note on why.
    func isMeaningful(for card: DeckCard) -> Bool {
        if card.type == .section { return question != nil || hasText }
        return feedback != nil || isAnswer(for: card)
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

extension DeckFeedback {
    private enum CodingKeys: String, CodingKey { case verdict, reasons, note }

    /// `reasons` and `note` may be missing; an unknown verdict fails only this answer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decode(Verdict.self, forKey: .verdict)
        reasons = (try? c.decodeIfPresent([String].self, forKey: .reasons)) ?? []
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }
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

    /// Cards in deck order, with all follow-ups gathered onto one page where the first sat. The
    /// Sunday view-take is a decision too, but it is the week's question, so it keeps its own page.
    static func pages(for cards: [DeckCard]) -> [DeckPage] {
        let followUps = cards.filter(\.isFollowUp)
        var pages: [DeckPage] = []
        for card in cards {
            if card.isFollowUp {
                if card.id == followUps.first?.id { pages.append(.followUps(followUps)) }
            } else {
                pages.append(.card(card))
            }
        }
        return pages
    }

    /// Whether the page answers in place (a decision's answer box), so it needs the keyboard inset.
    var answersInPlace: Bool {
        switch self {
        case .followUps: true
        case .card(let card): card.type == .decision
        }
    }
}

/// The answers file the agent saves verbatim and files with `brain brief file`.
/// A self-rating card's scores as its answer text, "Consistency: 8, intensity: 6, …": the same
/// line the vault files under the question, and read back from text typed before the picker.
enum DeckSelfRatings {
    /// Each trait's score in `text`, case-insensitive, with or without the colon or space ("Consistency8").
    static func scores(in text: String?, traits: [String]) -> [String: Int] {
        guard let text else { return [:] }
        var scores: [String: Int] = [:]
        for trait in traits {
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: trait) + "\\s*:?\\s*(10|[1-9])\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            scores[trait] = Int(text[range])
        }
        return scores
    }

    /// The scores in trait order, unscored traits left out; nil when none is scored.
    static func text(_ scores: [String: Int], traits: [String]) -> String? {
        let parts = traits.enumerated().compactMap { index, trait in
            scores[trait].map { "\(index == 0 ? trait : trait.lowercased()): \($0)" }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct DeckAnswersPayload: Encodable, Equatable, Sendable {
    let version = 1
    let date: String
    let kind: String
    let completedAt: String
    let answers: [DeckAnswer]
    /// The style learner's signals (`DeckSignals`), each left out when empty.
    let style: [DeckSignalRows.Style]?
    let usage: [DeckSignalRows.Usage]?
    let pick: DeckPick?
    let undo: [String]?

    private enum CodingKeys: String, CodingKey { case version, date, kind, completedAt, answers, style, usage, pick, undo }

    /// Answers in deck order, empty ones dropped, text trimmed; then the signals in deck order.
    init(deck: DailyDeck, answers: [String: DeckAnswer], signals: DeckSignals = DeckSignals(), completedAt: Date) {
        date = deck.date
        kind = deck.kind
        self.completedAt = ISO8601DateFormatter().string(from: completedAt)
        let rows = DeckSignalRows(signals, cardOrder: deck.cards.map(\.id))
        (style, usage, pick, undo) = (rows.style, rows.usage, rows.pick, rows.undo)
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

    /// After the server filed the deck: the follow-ups only the agent can do, in order.
    /// Carries no JSON, since the answers are already filed.
    func followUpMessage(steps: [String]) -> String {
        (["Finish filing the \(date) \(kind) brief. Do these follow-up steps in order, per followups/AGENTS.md:"]
            + steps.map { "- \($0)" }).joined(separator: "\n")
    }
}

/// The answers file the agent saved when a deck was filed: the same shape the app sends.
enum DeckAnswersFile {
    private struct Body: Decodable { let answers: [Lossy<DeckAnswer>]? }

    /// Card id → answer; empty when the file is unreadable. A malformed answer is dropped alone.
    static func decodeAnswers(_ content: String) -> [String: DeckAnswer] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let answers = ((try? decoder.decode(Body.self, from: Data(content.utf8)))?.answers ?? []).compactMap(\.value)
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

    /// The newest stored day session, if any.
    func latestSession(for server: URL) -> (date: String, id: String)? {
        let stored = defaults.dictionary(forKey: key("session", server)) as? [String: String]
        return stored?.max { $0.key < $1.key }.map { ($0.key, $0.value) }
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

    /// The deck's style signals (`DeckSignals`), kept like the answers' drafts.
    func signals(for server: URL, date: String, kind: String) -> DeckSignals {
        guard let data = defaults.data(forKey: key("signals", server)),
              let all = try? JSONDecoder().decode([String: DeckSignals].self, from: data)
        else { return DeckSignals() }
        return all["\(date).\(kind)"] ?? DeckSignals()
    }

    func setSignals(_ signals: DeckSignals, for server: URL, date: String, kind: String) {
        let k = key("signals", server)
        var all = (defaults.data(forKey: k)).flatMap { try? JSONDecoder().decode([String: DeckSignals].self, from: $0) } ?? [:]
        all["\(date).\(kind)"] = signals.isEmpty ? nil : signals
        for stale in all.keys.sorted(by: >).dropFirst(Self.draftDays) { all[stale] = nil }
        if all.isEmpty {
            defaults.removeObject(forKey: k)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: k)
        }
    }

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
            // A recap's entries, a mood chart, or goal meters are drawn; the plain `body` copy is only
            // for older builds. A theme's summary is its `context`.
            let drawn = !card.entries.isEmpty || !card.points.isEmpty || !card.meters.isEmpty || card.piece != nil
            detail = card.context ?? (drawn ? nil : (card.body ?? (card.title == nil ? nil : card.fallback)))
        case .sleep:
            // The question leads; the numbers show after the rating so they don't decide it.
            lead = card.question
            leadIsQuestion = true
        case .cover, .filmstrip, .story, .energy, .commitments, .values, .predictions, .who, .keepsakes:
            // Each is drawn by its own view; the cover leads with its title and the story with its draft.
            lead = card.type == .story ? card.storyDraft : card.title
        case .goal, .weekAhead, .changes, .ask:
            // The check-ins, the week's plan, the week's fixes and the Ask are drawn (`DeckGoalCard`,
            // `DeckWeekAheadCard`, `DeckChangesCard`, `DeckAskCard`).
            lead = card.title ?? card.fallback
        case .headline, .decision, .section, .close:
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
