import SwiftUI

/// A goal's paper: one of the Daily Brief's palettes, named in the goal file (`color:`) or
/// picked from its slug so a goal keeps the same colour everywhere.
enum GoalPaper {
    /// The papers a goal can take, in a fixed order the slug fallback indexes into.
    static let choices: [DeckPalette] = [.wiki, .quote, .book, .reading, .notes, .video, .past, .opener]

    static func palette(named name: String, slug: String) -> DeckPalette {
        switch name {
        case "wiki": return .wiki
        case "quote": return .quote
        case "book": return .book
        case "reading": return .reading
        case "notes": return .notes
        case "video": return .video
        case "past": return .past
        case "opener": return .opener
        default:
            // A stable hash (Swift's `hashValue` changes per launch).
            let sum = slug.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
            return choices[sum % choices.count]
        }
    }

    static func palette(for goal: GoalSummary) -> DeckPalette {
        palette(named: goal.color, slug: goal.slug)
    }

    static func symbol(_ icon: String) -> String {
        icon.isEmpty ? "flag" : icon
    }

    /// Fill for a day square or strip cell, in the goal's ink.
    static func fill(_ status: GoalStatus, ink: Color) -> Color {
        switch status {
        case .done: ink
        case .min: ink.opacity(0.45)
        case .skip: Color.hxTextSecondary.opacity(0.25)
        case .miss: Color.hxWarning.opacity(0.55)
        case .none, .unknown: Color.hxSeparator.opacity(0.6)
        }
    }
}

/// One square of the consistency calendar.
struct GoalCalendarDay: Equatable, Hashable {
    let date: String
    let dayOfMonth: Int
    let status: GoalStatus
    let isToday: Bool
    let isFuture: Bool
    let isDeadline: Bool
}

/// Day maths for the week strip and the consistency calendar, on the server's ISO days.
enum GoalCalendar {
    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2
        return cal
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ iso: String) -> Date? { formatter.date(from: String(iso.prefix(10))) }
    static func iso(_ date: Date) -> String { formatter.string(from: date) }

    private static func monday(of date: Date) -> Date {
        let weekday = calendar.component(.weekday, from: date)  // Sunday = 1
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: date)!
    }

    /// Which check-in day tapping `date` in the week strip selects; only today and yesterday.
    static func selectableDay(_ date: String, today: String, yesterday: String) -> GoalDay? {
        date == today ? .today : date == yesterday ? .yesterday : nil
    }

    /// Week rows (Monday first) from the goal's first day to its deadline, or through this
    /// Sunday without one, showing at most the last four weeks before today's.
    static func weeks(heatmap: [GoalHeatDay], today: String, deadline: String?) -> [[GoalCalendarDay?]] {
        guard let todayDate = date(today) else { return [] }
        let first = heatmap.first.flatMap { date($0.date) } ?? todayDate
        let earliest = monday(of: calendar.date(byAdding: .day, value: -21, to: todayDate)!)
        let start = max(first, deadline == nil ? earliest : first)
        let thisSunday = calendar.date(byAdding: .day, value: 6, to: monday(of: todayDate))!
        let end = deadline.flatMap(date).map { max($0, todayDate) } ?? thisSunday
        let statuses = Dictionary(heatmap.map { ($0.date, $0.status) }, uniquingKeysWith: { _, last in last })

        var rows: [[GoalCalendarDay?]] = []
        var cursor = monday(of: start)
        let lastDay = calendar.date(byAdding: .day, value: 6, to: monday(of: end))!
        while cursor <= lastDay {
            var row: [GoalCalendarDay?] = []
            for _ in 0..<7 {
                if cursor < start || cursor > end {
                    row.append(nil)
                } else {
                    let key = iso(cursor)
                    row.append(GoalCalendarDay(
                        date: key,
                        dayOfMonth: calendar.component(.day, from: cursor),
                        status: statuses[key] ?? .none,
                        isToday: key == today,
                        isFuture: cursor > todayDate,
                        isDeadline: key == deadline
                    ))
                }
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            }
            rows.append(row)
        }
        return rows
    }

    /// Days shown up (done or 2-min) out of the days so far; today counts only once it's shown.
    static func shownUp(heatmap: [GoalHeatDay], today: String) -> (shown: Int, total: Int) {
        let counted = heatmap.filter { $0.date != today || $0.status.isShown }
        return (counted.filter { $0.status.isShown }.count, counted.count)
    }
}

/// A goal's accent on the app's own surfaces (rows, calendar, choices): its ink in light
/// appearance and its paper in dark, so it stays legible on dark glass; `on` is the text on it.
struct GoalTint {
    let fill: Color
    let on: Color

    init(_ palette: DeckPalette, scheme: ColorScheme) {
        fill = scheme == .dark ? palette.paper : palette.ink
        on = scheme == .dark ? palette.ink : .white
    }
}
