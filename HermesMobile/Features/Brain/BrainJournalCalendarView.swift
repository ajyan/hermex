import SwiftUI

/// The journal calendar's pure date work, kept out of the views so it can be tested.
/// Days are calendar dates as written in the vault ("2026-10-06"), so everything runs in
/// UTC and never shifts a day across time zones.
enum BrainJournalCalendarLayout {
    /// One month on the calendar.
    struct Month: Hashable, Identifiable {
        let year: Int
        let month: Int
        var id: String { String(format: "%04d-%02d", year, month) }
    }

    /// A Gregorian calendar in UTC that starts the week where the reader's locale does.
    static func calendar(firstWeekday: Int = Calendar.current.firstWeekday) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// "yyyy-MM-dd" for a journal item: its date, or its file name, when either is a real day.
    static func dayKey(of item: BrainItem) -> String? {
        let stem = (item.id as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        return [item.date, stem].lazy
            .map { String($0.prefix(10)) }
            .first { date(fromKey: $0) != nil }
    }

    static func key(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Journal items by day; the first item for a day wins.
    static func entries(_ items: [BrainItem]) -> [String: BrainItem] {
        var out: [String: BrainItem] = [:]
        for item in items {
            if let key = dayKey(of: item), out[key] == nil { out[key] = item }
        }
        return out
    }

    /// Every month from the latest of this month and the newest entry, back to the month of
    /// the oldest entry, newest first. Empty months in between stay, so the calendar reads
    /// continuously.
    static func months(for keys: some Collection<String>, today: Date = .now, calendar: Calendar = calendar()) -> [Month] {
        let dates = keys.compactMap { date(fromKey: $0) }
        guard let oldest = dates.min(), let newest = dates.max() else { return [] }
        let top = month(of: max(newest, today), calendar: calendar)
        let bottom = month(of: oldest, calendar: calendar)
        var out: [Month] = []
        var cursor = top
        while (cursor.year, cursor.month) >= (bottom.year, bottom.month) {
            out.append(cursor)
            cursor = cursor.month == 1 ? Month(year: cursor.year - 1, month: 12) : Month(year: cursor.year, month: cursor.month - 1)
        }
        return out
    }

    /// The month's grid, row by row: nil for the blanks before the 1st, then each day.
    static func cells(for month: Month, calendar: Calendar = calendar()) -> [Int?] {
        guard let first = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first)
        else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: blanks) + days.map { Optional($0) }
    }

    /// The weekday initials in column order ("M T W T F S S" for a Monday start).
    static func weekdaySymbols(calendar: Calendar = calendar(), locale: Locale = .current) -> [String] {
        var localized = calendar
        localized.locale = locale
        let symbols = localized.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    /// "October 2026".
    static func title(of month: Month, locale: Locale = .current) -> String {
        guard let date = calendar().date(from: DateComponents(year: month.year, month: month.month, day: 1)) else {
            return month.id
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted).month(.wide).year()
        style.locale = locale
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return date.formatted(style)
    }

    /// "12 days", how many days of the month have an entry; nil for none.
    static func entryCount(in month: Month, entries: [String: BrainItem]) -> String? {
        let prefix = month.id + "-"
        let count = entries.keys.filter { $0.hasPrefix(prefix) }.count
        guard count > 0 else { return nil }
        return count == 1 ? "1 day" : "\(count) days"
    }

    /// "Monday, October 6, 2026", for VoiceOver.
    static func spokenDate(_ key: String, locale: Locale = .current) -> String {
        guard let date = date(fromKey: key) else { return key }
        var style = Date.FormatStyle(date: .complete, time: .omitted)
        style.locale = locale
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return date.formatted(style)
    }

    static func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard key.count == 10, parts.count == 3 else { return nil }
        let calendar = calendar()
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    private static func month(of date: Date, calendar: Calendar) -> Month {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return Month(year: parts.year ?? 1970, month: parts.month ?? 1)
    }
}

/// The journal as a calendar: months newest first, each day with an entry filled in the
/// journal's paper and opening that day. Older pages of the list load in the background
/// so earlier months fill in.
struct BrainJournalCalendarView: View {
    let isLoadingOlder: Bool
    let loadOlderFailed: Bool
    let onRetry: () -> Void
    /// Built once per list, never in `body`.
    private let entries: [String: BrainItem]
    private let months: [BrainJournalCalendarLayout.Month]
    private let todayKey: String

    init(list: BrainList, isLoadingOlder: Bool, loadOlderFailed: Bool, onRetry: @escaping () -> Void, today: Date = .now) {
        self.isLoadingOlder = isLoadingOlder
        self.loadOlderFailed = loadOlderFailed
        self.onRetry = onRetry
        let entries = BrainJournalCalendarLayout.entries(list.items)
        self.entries = entries
        self.months = BrainJournalCalendarLayout.months(for: entries.keys, today: today)
        let parts = BrainJournalCalendarLayout.calendar().dateComponents([.year, .month, .day], from: today)
        self.todayKey = BrainJournalCalendarLayout.key(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BrainStyle.xl) {
                ForEach(months) { month in
                    BrainJournalMonthView(month: month, entries: entries, todayKey: todayKey)
                }
                footer
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if loadOlderFailed {
            Button(action: onRetry) {
                Text(verbatim: "Couldn't load older days. Try again")
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
            }
            .buttonStyle(.plain)
        } else if isLoadingOlder {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                .accessibilityLabel(Text(verbatim: "Loading older days"))
        }
    }
}

/// One month: its title and entry count, the weekday initials, and the day grid.
struct BrainJournalMonthView: View {
    let month: BrainJournalCalendarLayout.Month
    let entries: [String: BrainItem]
    let todayKey: String
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: BrainStyle.xs), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HXSectionHeader(title: BrainJournalCalendarLayout.title(of: month),
                            trailing: BrainJournalCalendarLayout.entryCount(in: month, entries: entries))
            LazyVGrid(columns: Self.columns, spacing: BrainStyle.xs) {
                ForEach(Array(BrainJournalCalendarLayout.weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                ForEach(Array(BrainJournalCalendarLayout.cells(for: month).enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(minHeight: BrainStyle.minTapTarget).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Int) -> some View {
        let key = BrainJournalCalendarLayout.key(year: month.year, month: month.month, day: day)
        if let item = entries[key] {
            NavigationLink(value: ShellPushDestination.brainRoute(.page(item.module, item.id))) {
                BrainJournalDay(day: day, hasEntry: true, isToday: key == todayKey)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(BrainJournalCalendarLayout.spokenDate(key)), journal entry"))
        } else {
            BrainJournalDay(day: day, hasEntry: false, isToday: key == todayKey)
                .accessibilityHidden(true)
        }
    }
}

/// One day's number: on a wash of the journal's paper when it has an entry, plain otherwise,
/// and underlined with a dot when it's today.
struct BrainJournalDay: View {
    let day: Int
    let hasEntry: Bool
    let isToday: Bool

    var body: some View {
        let paper = BrainModuleID.journal.paper
        let shape = RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
        VStack(spacing: 2) {
            Text(verbatim: "\(day)")
                .font(AppFont.subheadline(weight: hasEntry || isToday ? .semibold : .regular))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(hasEntry ? paper.glow : (isToday ? Color.hxTextPrimary : Color.hxTextSecondary))
            Circle()
                .fill(isToday ? (hasEntry ? paper.glow : Color.hxTextPrimary) : Color.clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
        .background(hasEntry ? paper.wash : Color.clear, in: shape)
        .overlay { if hasEntry { shape.strokeBorder(paper.edge, lineWidth: 0.5) } }
        .contentShape(shape)
    }
}

#if DEBUG
#Preview("Journal calendar") {
    let items = ["2026-10-01", "2026-10-06", "2026-10-07", "2026-10-12", "2026-09-20", "2026-08-03"].map {
        BrainItem(module: .journal, id: "journal/2026/\($0).md", title: $0, date: $0)
    }
    return NavigationStack {
        BrainJournalCalendarView(list: BrainList(items: items), isLoadingOlder: true, loadOlderFailed: false, onRetry: {})
            .background(Color.hxCanvas)
    }
}
#endif
