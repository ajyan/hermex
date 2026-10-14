import Foundation

/// A decoded person page turned into display-ready strings and one merged timeline.
/// Built once per page (not in a view body), so all date math and string building lives here.
struct BrainPersonLayout: Equatable {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case encounter(BrainEncounter), journal(BrainJournalMention) }
        /// The encounter id, or `"journal:" + journal id`.
        let id: String
        let kind: Kind
        /// "Oct 8, 2026 · 6 days ago" for an encounter, "Journal · Sep 25, 2026" for a journal day.
        let meta: String
        /// An encounter's title (else its first bullet); a journal day's snippet.
        let headline: String
        /// Up to two bullets after the headline (encounters only).
        let preview: [String]
        /// Bullets beyond the headline and preview.
        let moreCount: Int
        /// The encounter holds more than the headline and preview show: hidden bullets, or body
        /// lines that are not bullets (prose, `_Source:` lines, `####` subheads).
        let canExpand: Bool
    }

    /// Relationship, location, and "seen <relative>", non-empty parts joined by " · ".
    let subtitle: String
    /// Birthday, Industry, then profile items by section (Family, Company, School, Likes, the rest); items of 40 characters or fewer.
    let chips: [String]
    /// Profile items longer than 40 characters, in chip order.
    let longItems: [String]
    /// Open questions, then a birthday line when the next birthday is within 30 days.
    let nextTime: [String]
    /// Encounters and journal days, newest first; on one date, encounters before journal. Ids are unique.
    let timeline: [Entry]
    /// Journal ids already shown in the timeline, to drop from "Mentioned in" and "Unlinked".
    let hiddenMentionIDs: Set<String>

    init(page: BrainPage, person: BrainPerson, today: Date, calendar: Calendar = .current) {
        let days = DayMath(today: today, calendar: calendar)
        subtitle = Self.subtitle(page: page, person: person, days: days)
        (chips, longItems) = Self.chipsAndLongItems(page: page, person: person)
        nextTime = Self.nextTime(person: person, days: days)
        let journal = person.journal.filter { !$0.id.isEmpty }
        timeline = Self.timeline(encounters: person.encounters.filter { !$0.id.isEmpty }, journal: journal, days: days)
        hiddenMentionIDs = Set(journal.map(\.id))
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

    // MARK: Subtitle and next time

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

    private static func nextTime(person: BrainPerson, days: DayMath) -> [String] {
        var lines = person.questions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let iso = person.nextBirthday, let away = days.daysAhead(iso), (0...30).contains(away) {
            switch away {
            case 0: lines.append("Birthday today")
            case 1: lines.append("Birthday \(monthDay(iso) ?? iso), in 1 day")
            default: lines.append("Birthday \(monthDay(iso) ?? iso), in \(away) days")
            }
        }
        return lines
    }

    // MARK: Chips

    private static let chipLimit = 40
    private static let sectionOrder = ["family", "company", "school", "likes"]

    private static func chipsAndLongItems(page: BrainPage, person: BrainPerson) -> ([String], [String]) {
        var chips: [String] = []
        if let birthday = fact("Birthday", in: page) {
            chips.append("Birthday " + (monthDay(birthday) ?? birthday))
        }
        if let industry = fact("Industry", in: page) { chips.append(industry) }
        var long: [String] = []
        let ranked = person.profile.enumerated().sorted { lhs, rhs in
            let l = rank(lhs.element.label), r = rank(rhs.element.label)
            return l == r ? lhs.offset < rhs.offset : l < r
        }
        for (_, section) in ranked {
            for item in section.items where !item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if item.count > chipLimit { long.append(item) } else { chips.append(item) }
            }
        }
        return (chips, long)
    }

    private static func rank(_ label: String) -> Int {
        let key = label.trimmingCharacters(in: .whitespaces).lowercased()
        return sectionOrder.firstIndex(of: key) ?? sectionOrder.count
    }

    private static func fact(_ label: String, in page: BrainPage) -> String? {
        page.facts
            .first { $0.label.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(label) == .orderedSame
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Timeline

    private static func timeline(encounters: [BrainEncounter], journal: [BrainJournalMention], days: DayMath) -> [Entry] {
        let rows: [(sortDate: String, order: Int, entry: Entry)] =
            encounters.enumerated().map { ($1.date.isoDay ?? "", $0, encounterEntry($1, days: days)) }
            + journal.enumerated().map { ($1.date.isoDay ?? "", encounters.count + $0, journalEntry($1)) }
        // A repeated id would collide in the timeline's `ForEach`; the first in timeline order wins.
        var seen: Set<String> = []
        return rows
            .sorted { $0.sortDate == $1.sortDate ? $0.order < $1.order : $0.sortDate > $1.sortDate }
            .map(\.entry)
            .filter { seen.insert($0.id).inserted }
    }

    private static func encounterEntry(_ encounter: BrainEncounter, days: DayMath) -> Entry {
        let bullets = encounter.bullets.map(stripMarker).filter { !$0.isEmpty }
        let title = encounter.title.map(stripMarker).flatMap { $0.isEmpty ? nil : $0 }
        let headline: String
        let rest: [String]
        if let title {
            headline = title
            rest = bullets
        } else {
            headline = bullets.first ?? ""
            rest = Array(bullets.dropFirst())
        }
        var meta = BrainStyle.displayDate(encounter.date)
        if let ago = days.daysAgo(encounter.date) { meta += " · " + relative(daysAgo: ago) }
        let preview = Array(rest.prefix(2))
        let moreCount = max(0, rest.count - 2)
        return Entry(id: encounter.id, kind: .encounter(encounter), meta: meta, headline: headline,
                     preview: preview, moreCount: moreCount,
                     canExpand: moreCount > 0 || hasUnshownLines(encounter.body, shown: [headline] + preview))
    }

    /// Whether `body` has a non-blank line, list marker aside, that none of `shown` contains.
    private static func hasUnshownLines(_ body: String, shown: [String]) -> Bool {
        let visible = Set(shown.flatMap { $0.split(whereSeparator: \.isNewline) }.map { stripMarker(String($0)) })
        return body.split(whereSeparator: \.isNewline).contains { line in
            let text = stripMarker(String(line))
            return !text.isEmpty && !visible.contains(text)
        }
    }

    private static func journalEntry(_ mention: BrainJournalMention) -> Entry {
        Entry(id: "journal:" + mention.id, kind: .journal(mention),
              meta: "Journal · " + BrainStyle.displayDate(mention.date),
              headline: stripMarker(mention.snippet), preview: [], moreCount: 0, canExpand: false)
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

    /// "Jan 20" for an ISO day, else nil.
    private static func monthDay(_ iso: String) -> String? {
        guard let parts = iso.isoDayParts else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) else { return nil }
        return monthDayFormatter.string(from: date)
    }

    /// Whole calendar days between an ISO day (read in `calendar`'s time zone) and today's day.
    private struct DayMath {
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
