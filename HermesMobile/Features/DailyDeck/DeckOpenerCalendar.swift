import SwiftUI

/// The opener's calendar (wire `calendar` on the headline, vault `daily_deck.calendar_view`): each day of
/// today's Mon–Sun week with how many events touch it, and today's events.
struct DeckDayCalendar: Decodable, Equatable {
    struct Day: Decodable, Equatable {
        /// "2026-11-11"
        let date: String
        let count: Int

        init(date: String, count: Int) {
            self.date = date
            self.count = count
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(String.self, forKey: .date)
            count = max(0, (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0)
        }

        private enum CodingKeys: String, CodingKey { case date, count }
    }

    struct Event: Decodable, Equatable {
        let title: String
        let allDay: Bool
        /// Minutes after midnight, clipped to today; nil on an all-day event.
        let start: Int?
        let end: Int?

        init(title: String, allDay: Bool, start: Int?, end: Int?) {
            self.title = title
            self.allDay = allDay
            self.start = start
            self.end = end
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            allDay = (try? c.decodeIfPresent(Bool.self, forKey: .allDay)) ?? false
            start = try? c.decodeIfPresent(Int.self, forKey: .start)
            end = try? c.decodeIfPresent(Int.self, forKey: .end)
        }

        private enum CodingKeys: String, CodingKey { case title, allDay, start, end }

        /// A timed event that can be placed: both times, ending after it starts.
        var isPlaceable: Bool {
            guard !allDay, let start, let end else { return false }
            return end > start
        }
    }

    let week: [Day]
    let allDay: [Event]
    /// Today's timed events, each with a start before its end.
    let timed: [Event]

    var isEmpty: Bool { week.isEmpty && allDay.isEmpty && timed.isEmpty }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = ((try? c.decodeIfPresent([Lossy<Day>].self, forKey: .week)) ?? []).compactMap(\.value)
        let today = ((try? c.decodeIfPresent([Lossy<Event>].self, forKey: .today)) ?? []).compactMap(\.value)
        allDay = today.filter(\.allDay)
        timed = today.filter(\.isPlaceable)
    }

    private enum CodingKeys: String, CodingKey { case week, today }
}

/// How today's timed events stack on the opener: runs of nearby events as stretches of the hour rail, and the
/// free time between them as a line, so a 9am meeting and a 7pm dinner don't stretch the card ten hours tall.
enum DeckTimelineLayout {
    /// Events further apart than this start a new stretch.
    static let gap = 90
    /// A day that ends before this says when it's free after.
    static let lateEnd = 21 * 60

    struct Block: Equatable {
        let title: String
        let start: Int
        let end: Int
        /// Which side-by-side column, for events that overlap.
        let lane: Int
    }

    struct Stretch: Equatable {
        let startHour: Int
        let endHour: Int
        let lanes: Int
        let blocks: [Block]
    }

    enum Piece: Equatable {
        case stretch(Stretch)
        case free(String)
    }

    static func pieces(_ events: [DeckDayCalendar.Event]) -> [Piece] {
        let sorted = events.compactMap { e in e.start.flatMap { s in e.end.map { (e.title, s, $0) } } }
            .filter { $0.1 < $0.2 }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        var groups: [[(String, Int, Int)]] = []
        for event in sorted {
            if let last = groups.last, let end = last.map(\.2).max(), event.1 - end <= gap {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }
        var pieces: [Piece] = []
        for (index, group) in groups.enumerated() {
            let end = group.map(\.2).max() ?? 0
            if index > 0, let previous = groups[index - 1].map(\.2).max() {
                pieces.append(.free("Free \(clock(previous))–\(clock(group[0].1))"))
            }
            pieces.append(.stretch(stretch(group, end: end)))
            if index == groups.count - 1, end < lateEnd {
                pieces.append(.free("Free after \(clock(end))"))
            }
        }
        return pieces
    }

    /// One run of events on the rail, each in the first lane free when it starts.
    private static func stretch(_ events: [(String, Int, Int)], end: Int) -> Stretch {
        var laneEnds: [Int] = []
        var blocks: [Block] = []
        for (title, start, finish) in events {
            let lane = laneEnds.firstIndex { $0 <= start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(finish) } else { laneEnds[lane] = finish }
            blocks.append(Block(title: title, start: start, end: finish, lane: lane))
        }
        return Stretch(startHour: events[0].1 / 60, endHour: (end + 59) / 60, lanes: max(1, laneEnds.count), blocks: blocks)
    }

    /// "1:00", "6:30": the deck's times, twelve-hour without am or pm.
    static func clock(_ minutes: Int) -> String {
        let hour = (minutes / 60) % 12
        return String(format: "%d:%02d", hour == 0 ? 12 : hour, minutes % 60)
    }
}

extension DeckCard {
    /// The opener's tag lines; its calendar lines leave when the calendar draws them.
    var openerTags: [DeckTag] {
        self.calendar == nil ? self.headlineTags : self.headlineTags.filter { $0.icon != "calendar" }
    }
}

/// The opener's week as day circles, today filled, a dot under each day per event; then today's all-day events
/// and its timed ones on an hour rail (Andrew, 2026-11-13: option C of the opener calendar canvas). Everything
/// wears the opener's own paper.
struct DeckOpenerCalendar: View {
    let calendar: DeckDayCalendar
    /// The deck's day, "2026-11-11": its column in the week is filled.
    let today: String
    let paper: HermexPaper

    @ScaledMetric(relativeTo: .footnote) private var hourHeight: CGFloat = 52
    @ScaledMetric(relativeTo: .caption) private var gutter: CGFloat = 42
    @ScaledMetric(relativeTo: .subheadline) private var dayCircle: CGFloat = 32

    private static let letters = ["M", "T", "W", "T", "F", "S", "S"]
    private static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if calendar.week.count == 7 { week }
            VStack(alignment: .leading, spacing: 8) {
                if calendar.allDay.isEmpty && calendar.timed.isEmpty {
                    Text(verbatim: "Nothing on the calendar today")
                        .font(AppFont.footnote())
                        .foregroundStyle(paper.secondaryInk)
                }
                ForEach(Array(calendar.allDay.enumerated()), id: \.offset) { _, event in
                    HStack(spacing: 10) {
                        Text(verbatim: "all day").font(AppFont.caption()).foregroundStyle(Color.hxTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: gutter, alignment: .trailing)
                        block(event.title, time: nil)
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(Array(DeckTimelineLayout.pieces(calendar.timed).enumerated()), id: \.offset) { _, piece in
                    switch piece {
                    case .stretch(let stretch): rail(stretch)
                    case .free(let text):
                        Text(verbatim: text)
                            .font(AppFont.footnote())
                            .foregroundStyle(paper.secondaryInk)
                            .padding(.leading, gutter + 10)
                    }
                }
            }
            .padding(.top, calendar.week.count == 7 ? 18 : 0)
        }
    }

    private var week: some View {
        HStack(spacing: 0) {
            ForEach(Array(calendar.week.enumerated()), id: \.offset) { index, day in
                let isToday = day.date == today
                let isPast = day.date < today
                VStack(spacing: 4) {
                    Text(verbatim: Self.letters[index]).font(AppFont.caption()).foregroundStyle(Color.hxTextSecondary)
                    Text(verbatim: String(Int(day.date.suffix(2)) ?? 0))
                        .font(AppFont.display(style: .subheadline, weight: isPast ? .regular : .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? paper.onGlow : isPast ? Color.hxTextSecondary : Color.hxTextPrimary)
                        .frame(width: dayCircle, height: dayCircle)
                        .background { if isToday { Circle().fill(paper.glow) } }
                    HStack(spacing: 3) {
                        ForEach(0..<min(day.count, 4), id: \.self) { _ in
                            Circle()
                                .fill(isPast ? Color.hxTextSecondary.opacity(0.5) : paper.glow)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .frame(height: 5)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "This week. " + calendar.week.enumerated().map { index, day in
            let events = day.count == 0 ? "nothing" : day.count == 1 ? "1 event" : "\(day.count) events"
            return "\(day.date == today ? "Today" : Self.dayNames[index]), \(events)"
        }.joined(separator: ". ")))
    }

    private func rail(_ stretch: DeckTimelineLayout.Stretch) -> some View {
        let hours = stretch.endHour - stretch.startHour
        let top = stretch.startHour * 60
        return ZStack(alignment: .topLeading) {
            ForEach(stretch.startHour...stretch.endHour, id: \.self) { hour in
                HStack(spacing: 8) {
                    Text(verbatim: String(hour % 12 == 0 ? 12 : hour % 12))
                        .font(AppFont.caption())
                        .monospacedDigit()
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(width: gutter, alignment: .trailing)
                    Rectangle().fill(Color.hxSeparator).frame(height: 0.5)
                }
                .frame(height: 16)
                .offset(y: CGFloat(hour - stretch.startHour) * hourHeight - 8)
                .accessibilityHidden(true)
            }
            GeometryReader { proxy in
                let lead = gutter + 10
                let lane = (proxy.size.width - lead) / CGFloat(stretch.lanes)
                ForEach(Array(stretch.blocks.enumerated()), id: \.offset) { _, b in
                    let height = max(22, CGFloat(b.end - b.start) / 60 * hourHeight - 2)
                    block(b.title, time: "\(DeckTimelineLayout.clock(b.start))–\(DeckTimelineLayout.clock(b.end))",
                          stacked: height >= 44)
                        .frame(width: lane - 2, height: height, alignment: .topLeading)
                        .offset(x: lead + CGFloat(b.lane) * lane, y: CGFloat(b.start - top) / 60 * hourHeight + 1)
                }
            }
        }
        .frame(height: CGFloat(hours) * hourHeight)
        .padding(.vertical, 8)
    }

    private func block(_ title: String, time: String?, stacked: Bool = false) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        return layout {
            Text(verbatim: title)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
            if let time {
                Text(verbatim: time)
                    .font(AppFont.caption())
                    .foregroundStyle(paper.secondaryInk)
                    .lineLimit(1)
                    .fixedSize()
            }
            if !stacked { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowSurface(paper, cornerRadius: HXRadius.sm, opaque: true)  // the hour lines stop at a block
        .accessibilityElement(children: .combine)
    }
}
