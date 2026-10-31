import Foundation

/// A decoded person page turned into display-ready strings and one merged timeline.
/// Built once per page (not in a view body), so all date math and string building lives here.
struct BrainPersonLayout: Equatable {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case encounter(BrainEncounter), journal(BrainJournalMention) }
        /// The encounter id, or `"journal:" + journal id`.
        let id: String
        let kind: Kind
        /// "Encounter · Oct 8 · 6 days ago" or "Journal · Sep 25 · 3 weeks ago": the deck card's
        /// first line. The relative part drops when the date is not an ISO day.
        let kicker: String
        /// An encounter's title (else its first bullet); a journal day's snippet.
        let headline: String
        /// The bullets after the headline (encounters only).
        let bullets: [String]
        /// The body's other lines (prose, `_Source:` lines, `####` subheads), joined by newlines;
        /// shown as Markdown under the bullets. Empty when there are none.
        let extra: String
        /// A journal day with the encounter's date, opened from the card's footer instead of
        /// getting a card of its own. Its snippet has the list marker dropped.
        let journal: BrainJournalMention?
    }

    /// The Catch up card: the nightly digest's recap, then its lines (a near birthday first,
    /// then the open threads).
    struct CatchUp: Equatable {
        let summary: String?
        let lines: [String]
    }

    /// One month of the rhythm strip, oldest (`id` 0) to this month (`id` 11).
    struct RhythmMonth: Equatable, Identifiable {
        let id: Int
        /// "Nov"
        let label: String
        let seen: Bool
    }

    /// One titled group of profile lines in the About card ("Family", "Work", ...).
    struct AboutSection: Equatable, Identifiable {
        /// The title, lowercased.
        let id: String
        let title: String
        /// Every item, including those past the card's per-section cap.
        let items: [String]
    }

    /// Relationship, location, and "seen <relative>", non-empty parts joined by " · ".
    let subtitle: String
    /// At most three: "Birthday <MMM d>", the first Company item (else, or when it is over 32
    /// characters, the Industry fact), the first School item. A value over 32 characters is left
    /// out (it stays in About).
    let chips: [String]
    /// The profile less the chips: Family, Work, School, Likes, every other section under its own
    /// label (first letter capitalized) in server order, then the open questions. Same-title
    /// sections merge; empty ones drop.
    let aboutSections: [AboutSection]
    /// The recap and its lines (a birthday within 30 days, then the threads); nil when both are empty.
    let catchUp: CatchUp?
    /// The last twelve months, oldest first, ending with today's month; empty unless the server
    /// sent exactly twelve counts.
    let rhythm: [RhythmMonth]
    /// Encounters and journal days, newest first; on one date, encounters before journal. A
    /// journal day with an encounter on its date folds into the first such encounter. Ids are unique.
    let timeline: [Entry]
    /// Journal ids already shown in the timeline, to drop from "Mentioned in" and "Unlinked".
    let hiddenMentionIDs: Set<String>

    init(page: BrainPage, person: BrainPerson, today: Date, calendar: Calendar = .current) {
        let days = DayMath(today: today, calendar: calendar)
        subtitle = Self.subtitle(page: page, person: person, days: days)
        (chips, aboutSections) = Self.chipsAndAbout(page: page, person: person)
        catchUp = Self.catchUp(person: person, days: days)
        rhythm = Self.rhythm(person.rhythm, today: today, calendar: calendar)
        let journal = person.journal.filter { !$0.id.isEmpty }
        timeline = Self.timeline(encounters: person.encounters.filter { !$0.id.isEmpty }, journal: journal, days: days)
        hiddenMentionIDs = Set(journal.map(\.id))
    }

    /// "Seen in 4 of the last 12 months"; empty without a rhythm.
    var rhythmAccessibilityLabel: String {
        rhythm.isEmpty ? "" : "Seen in \(rhythm.filter(\.seen).count) of the last 12 months"
    }

    /// The timeline header's "3 of 8" for the card at `index`.
    static func position(index: Int, count: Int) -> String {
        "\(min(index + 1, count)) of \(count)"
    }

    /// "Father: Bo Test" as a role and a value, when the text before the first ": " is a short
    /// (28 characters or fewer) non-empty role and a value follows; else nil. The role's bold
    /// marks are dropped ("**Wife**" reads "Wife").
    static func roleSplit(_ item: String) -> (role: String, value: String)? {
        guard let colon = item.range(of: ": ") else { return nil }
        let role = BrainPersonLayout.unboldRole(item[..<colon.lowerBound].trimmingCharacters(in: .whitespaces))
        let value = item[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty, role.count <= 28, !value.isEmpty else { return nil }
        return (role, value)
    }

    /// True when an item opens with a bold lead-in ("**Education**: …") whose text ends before
    /// the first ": ": a bold label. Outside the Family section only such items take the label
    /// layout, so plain sentences with a colon ("Philosophy: Doesn't accept…") stay whole.
    static func isBoldLeadIn(_ item: String) -> Bool {
        guard item.hasPrefix("**"), let end = item.range(of: "**:") else { return false }
        return item[..<end.lowerBound].range(of: ": ") == nil
    }

    /// An About item with its broken wiki-link noise removed, before Markdown parsing. A link
    /// whose target holds a space or ends in `.md` is a vault page name that could never resolve:
    /// a trailing ` - See <link>` (dash or em dash) to one is dropped as redundant (the row
    /// already names the person), and any other is flattened to its text without `.md`. Valid
    /// links such as `[profile]` with a real URL target are kept.
    static func aboutItem(_ raw: String) -> String {
        var text = raw
        if let see = text.firstMatch(of: seeLink), isVaultTarget(see.output.1) {
            text.removeSubrange(see.range)
        }
        return text.replacing(link) { match -> String in
            let (whole, label, target) = match.output
            guard isVaultTarget(target) else { return String(whole) }
            let name = label.hasSuffix(".md") ? label.dropLast(3) : label
            return name.trimmingCharacters(in: .whitespaces)
        }
    }

    /// `[label](target)`.
    private static let link = try! Regex(#"\[([^\]]+)\]\(([^)]*)\)"#, as: (Substring, Substring, Substring).self)
    /// A trailing ` - See [label](target)` (dash or em dash); the capture is the target.
    private static let seeLink = try! Regex(#"\s+[-—]\s+See\s+\[[^\]]+\]\(([^)]*)\)\s*$"#, as: (Substring, Substring).self)

    /// A link target that names a vault page (it holds a space or ends in `.md`), so it can never resolve.
    private static func isVaultTarget(_ target: Substring) -> Bool {
        target.contains(" ") || target.hasSuffix(".md")
    }

    /// "**Wife**" as "Wife": a role wrapped in bold (or `__`) marks loses them.
    private static func unboldRole(_ role: String) -> String {
        for mark in ["**", "__"] where role.hasPrefix(mark) && role.hasSuffix(mark) && role.count > 2 * mark.count {
            return String(role.dropFirst(mark.count).dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        return role
    }

    /// A mention section's refs without the journal days the timeline already shows, and its
    /// total less the refs dropped here.
    func remainingMentions(_ refs: [BrainRef], total: Int) -> (refs: [BrainRef], total: Int) {
        let shown = refs.filter { !hiddenMentionIDs.contains($0.id) }
        return (shown, max(shown.count, total - (refs.count - shown.count)))
    }

    /// "today", "yesterday", "N days ago" (under 14), weeks (under 60 days), months (under 730), then years.
    static func relative(daysAgo: Int) -> String {
        let days = max(0, daysAgo)
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<14: return "\(days) days ago"
        case ..<60: return ago(days / 7, "week")
        case ..<730: return ago(days / 30, "month")
        default: return ago(days / 365, "year")
        }
    }

    private static func ago(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s") ago"
    }

    // MARK: Subtitle, catch up and rhythm

    private static func subtitle(page: BrainPage, person: BrainPerson, days: DayMath) -> String {
        var parts = [page.item.subtitle, fact("Location", in: page) ?? ""]
        if let lastSeen = person.lastSeen, let ago = days.daysAgo(lastSeen) {
            parts.append("seen " + relative(daysAgo: ago))
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private static func catchUp(person: BrainPerson, days: DayMath) -> CatchUp? {
        let summary = person.catchup?.trimmingCharacters(in: .whitespacesAndNewlines)
        let threads = person.threads.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let lines = birthdayLine(person: person, days: days).map { [$0] + threads } ?? threads
        let recap = summary?.isEmpty == false ? summary : nil
        return recap == nil && lines.isEmpty ? nil : CatchUp(summary: recap, lines: lines)
    }

    /// "Birthday Oct 26, in 12 days" when the next birthday is within 30 days.
    private static func birthdayLine(person: BrainPerson, days: DayMath) -> String? {
        guard let iso = person.nextBirthday, let away = days.daysAhead(iso), (0...30).contains(away) else { return nil }
        switch away {
        case 0: return "Birthday today"
        case 1: return "Birthday \(monthDay(iso) ?? iso), in 1 day"
        default: return "Birthday \(monthDay(iso) ?? iso), in \(away) days"
        }
    }

    private static func rhythm(_ counts: [Int], today: Date, calendar: Calendar) -> [RhythmMonth] {
        guard counts.count == 12 else { return [] }
        let month = calendar.component(.month, from: today)
        return counts.enumerated().map { offset, count in
            // Eleven months back is `offset` 0; months are 1...12.
            let label = monthSymbols[((month - 1 + offset - 11) % 12 + 12) % 12]
            return RhythmMonth(id: offset, label: label, seen: count > 0)
        }
    }

    private static let monthSymbols: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.shortMonthSymbols
    }()

    // MARK: Chips and About

    private static let chipLimit = 32
    /// About's leading sections, in order; any other title follows in server order, Questions last.
    private static let sectionOrder = ["Family", "Work", "School", "Likes"]
    private static let sectionTitles: [String: String] = [
        "family": "Family",
        "company": "Work", "linkedin": "Work", "work": "Work", "job": "Work", "career": "Work", "industry": "Work",
        "school": "School", "education": "School",
        "likes": "Likes", "interests": "Likes", "hobbies": "Likes",
        "misc. notes": "Notes", "misc notes": "Notes", "misc": "Notes", "notes": "Notes", "": "Notes",
        "questions": "Questions",
    ]

    private static func chipsAndAbout(page: BrainPage, person: BrainPerson) -> ([String], [AboutSection]) {
        // Each section's non-blank items, trimmed, with their index in the section.
        let profile = person.profile.map { section in
            section.items.enumerated().compactMap { index, item -> (index: Int, text: String)? in
                let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : (index, text)
            }
        }
        func firstItem(labelled label: String) -> (key: String, text: String)? {
            for (section, items) in profile.enumerated()
            where key(person.profile[section].label) == label {
                if let item = items.first { return ("\(section):\(item.index)", item.text) }
            }
            return nil
        }

        var chips: [String] = []
        var usedItems: Set<String> = []
        func addChip(_ text: String?, item: String? = nil) {
            guard let text, !text.isEmpty, text.count <= chipLimit else { return }
            chips.append(text)
            if let item { usedItems.insert(item) }
        }
        if let birthday = fact("Birthday", in: page) { addChip("Birthday " + (monthDay(birthday) ?? birthday)) }
        let industry = fact("Industry", in: page)
        var industryShown = false
        if let company = firstItem(labelled: "company"), company.text.count <= chipLimit {
            addChip(company.text, item: company.key)
        } else if let industry, industry.count <= chipLimit {
            addChip(industry)
            industryShown = true
        }
        if let school = firstItem(labelled: "school") { addChip(school.text, item: school.key) }

        // Keyed by the lowercased title, so "Pets" and "pets" share one section (the first spelling wins).
        var sections: [AboutSection] = []
        func append(_ title: String, _ items: [String]) {
            let id = title.lowercased()
            if let index = sections.firstIndex(where: { $0.id == id }) {
                sections[index] = AboutSection(id: id, title: sections[index].title, items: sections[index].items + items)
            } else {
                sections.append(AboutSection(id: id, title: title, items: items))
            }
        }
        for (section, items) in profile.enumerated() {
            let label = person.profile[section].label.trimmingCharacters(in: .whitespaces)
            append(sectionTitles[key(label)] ?? sentenceCase(label),
                   items.filter { !usedItems.contains("\(section):\($0.index)") }.map(\.text))
        }
        // Industry that isn't a chip goes under Work, unless Work already says it.
        if let industry, !industryShown,
           !sections.contains(where: { $0.id == "work" && $0.items.contains { $0.caseInsensitiveCompare(industry) == .orderedSame } }) {
            append("Work", [industry])
        }
        append("Questions", person.questions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })

        func rank(_ section: AboutSection) -> Int {
            if section.id == "questions" { return sectionOrder.count + 1 }
            return sectionOrder.firstIndex(of: section.title) ?? sectionOrder.count
        }
        let ordered = sections.enumerated().sorted { lhs, rhs in
            let l = rank(lhs.element), r = rank(rhs.element)
            return l == r ? lhs.offset < rhs.offset : l < r
        }
        return (chips, ordered.map(\.element).filter { !$0.items.isEmpty })
    }

    /// "favorite foods" as "Favorite foods": the first letter capitalized, the rest kept.
    private static func sentenceCase(_ label: String) -> String {
        guard let first = label.first else { return label }
        return first.uppercased() + label.dropFirst()
    }

    private static func key(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func fact(_ label: String, in page: BrainPage) -> String? {
        page.facts
            .first { $0.label.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(label) == .orderedSame
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Timeline

    private static func timeline(encounters: [BrainEncounter], journal: [BrainJournalMention], days: DayMath) -> [Entry] {
        let encounters = timelineOrder(encounters, date: \.date, id: \.id)
        let journal = timelineOrder(journal, date: \.date, id: \.id)
        var firstEncounterOfDay: [String: String] = [:]
        for encounter in encounters {
            if let day = encounter.date.isoDay, firstEncounterOfDay[day] == nil { firstEncounterOfDay[day] = encounter.id }
        }
        var folded: [String: BrainJournalMention] = [:]
        var separate: [BrainJournalMention] = []
        for mention in journal {
            if let day = mention.date.isoDay, let encounterID = firstEncounterOfDay[day], folded[encounterID] == nil {
                folded[encounterID] = BrainJournalMention(id: mention.id, date: mention.date,
                                                          snippet: stripMarker(mention.snippet), mention: mention.mention)
            } else {
                separate.append(mention)
            }
        }
        let rows: [(sortDate: String, order: Int, entry: Entry)] =
            encounters.enumerated().map { ($1.date.isoDay ?? "", $0, encounterEntry($1, journal: folded[$1.id], days: days)) }
            + separate.enumerated().map { ($1.date.isoDay ?? "", encounters.count + $0, journalEntry($1, days: days)) }
        // An encounter id can still collide with a `journal:` id; the first in timeline order wins.
        var seen: Set<String> = []
        return rows
            .sorted { $0.sortDate == $1.sortDate ? $0.order < $1.order : $0.sortDate > $1.sortDate }
            .map(\.entry)
            .filter { seen.insert($0.id).inserted }
    }

    /// Newest first, server order within a date, a repeated id kept only the first time.
    private static func timelineOrder<Item>(_ items: [Item], date: (Item) -> String, id: (Item) -> String) -> [Item] {
        var seen: Set<String> = []
        return items.enumerated()
            .sorted { lhs, rhs in
                let l = date(lhs.element).isoDay ?? "", r = date(rhs.element).isoDay ?? ""
                return l == r ? lhs.offset < rhs.offset : l > r
            }
            .map(\.element)
            .filter { seen.insert(id($0)).inserted }
    }

    private static func encounterEntry(_ encounter: BrainEncounter, journal: BrainJournalMention?, days: DayMath) -> Entry {
        let bullets = encounter.bullets.map(stripMarker).filter { !$0.isEmpty }
        let title = encounter.title.map(stripMarker).flatMap { $0.isEmpty ? nil : $0 }
        let headline: String
        let items: [String]
        if let title {
            headline = title
            items = bullets
        } else {
            headline = bullets.first ?? ""
            items = Array(bullets.dropFirst())
        }
        return Entry(id: encounter.id, kind: .encounter(encounter),
                     kicker: kicker("Encounter", date: encounter.date, days: days), headline: headline,
                     bullets: items,
                     extra: extraLines(encounter.body, shown: Set(bullets + [headline])), journal: journal)
    }

    /// The body's non-blank lines that are not bullets (a column-0 `-` or `*` and the indented
    /// lines after it), thematic breaks, or text already `shown` (the headline, or prose lines the
    /// server made the items), trimmed and joined by newlines.
    private static func extraLines(_ body: String, shown: Set<String>) -> String {
        var inBullet = false
        var lines: [String] = []
        for line in body.split(whereSeparator: \.isNewline).map(String.init) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let indented = line.first == " " || line.first == "\t"
            if text.isEmpty { continue }
            if text.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                inBullet = false
            } else if line.range(of: #"^[-*]\s"#, options: .regularExpression) != nil {
                inBullet = true
            } else if inBullet && indented {
                continue
            } else {
                inBullet = false
                if !shown.contains(text) { lines.append(text) }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func journalEntry(_ mention: BrainJournalMention, days: DayMath) -> Entry {
        Entry(id: "journal:" + mention.id, kind: .journal(mention),
              kicker: kicker("Journal", date: mention.date, days: days),
              headline: stripMarker(mention.snippet), bullets: [], extra: "", journal: nil)
    }

    /// "Encounter · Oct 8 · 6 days ago"; a date that is not an ISO day shows as sent, without
    /// the relative part.
    private static func kicker(_ kind: String, date: String, days: DayMath) -> String {
        let raw = date.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = [kind, monthDay(raw) ?? raw]
        if let ago = days.daysAgo(raw) { parts.append(relative(daysAgo: ago)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Drops one leading "- " or "* " list marker; nested lines after the first newline are kept.
    private static func stripMarker(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["- ", "* "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    // MARK: Dates

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// "Jan 20" for an ISO day, or a birthday with no year (`MM-DD`, `--MM-DD`), else nil. An impossible
    /// date ("2026-02-30") is nil rather than rolled over into March.
    static func monthDay(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts: (year: Int, month: Int, day: Int)
        if let iso = trimmed.isoDayParts {
            parts = iso
        } else if let match = trimmed.wholeMatch(of: #/(?:--)?(\d{2})-(\d{2})/#), let month = Int(match.1), let day = Int(match.2) {
            parts = (2000, month, day)  // a leap year, so Feb 29 is a real birthday
        } else {
            return nil
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) else { return nil }
        let check = utc.dateComponents([.year, .month, .day], from: date)
        guard check.year == parts.year, check.month == parts.month, check.day == parts.day else { return nil }
        return monthDayFormatter.string(from: date)
    }

    /// Whole calendar days between an ISO day (read in `calendar`'s time zone) and today's day.
    struct DayMath {
        let today: Date
        let calendar: Calendar

        /// Days since the date; future dates clamp to 0. Nil when the string is not an ISO day.
        func daysAgo(_ iso: String) -> Int? { offset(iso).map { max(0, -$0) } }

        /// Days until the date; negative when it has passed. Nil when the string is not an ISO day.
        func daysAhead(_ iso: String) -> Int? { offset(iso) }

        private func offset(_ iso: String) -> Int? {
            guard let parts = iso.isoDayParts,
                  let day = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
            else { return nil }
            // `date(from:)` rolls impossible dates over (Feb 30 becomes Mar 2); reject them instead.
            let check = calendar.dateComponents([.year, .month, .day], from: day)
            guard check.year == parts.year, check.month == parts.month, check.day == parts.day else { return nil }
            return calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: today)).day.map { -$0 }
        }
    }
}

private extension String {
    /// The leading `yyyy-MM-dd` as numbers, when the string starts with one.
    var isoDayParts: (year: Int, month: Int, day: Int)? {
        guard let isoDay else { return nil }
        let numbers = isoDay.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return (numbers[0], numbers[1], numbers[2])
    }

    /// The leading `yyyy-MM-dd` text when the string (trimmed) starts with one.
    var isoDay: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10 else { return nil }
        let head = String(trimmed.prefix(10))
        return head.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? head : nil
    }
}
