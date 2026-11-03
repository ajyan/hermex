import SwiftUI

/// This goal's own consistency: how many of its days he showed up and the calendar of the days so
/// far. The hero's kicker counts down to the deadline; the all-goals streak lives on Goals home.
struct GoalConsistencySection: View {
    let calendar: GoalCalendarModel
    let tint: GoalTint

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Consistency")
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    Text(verbatim: GoalDetailCopy.shownUpLine((calendar.shown, calendar.total)))
                        .brainText(.rowTitle)
                        .monospacedDigit()
                    GoalCalendarGrid(calendar: calendar, tint: tint)
                }
                .padding(.vertical, BrainStyle.xs)
            }
        }
    }
}

/// The calendar's days, Monday first, in the goal's tint, with the month named beside the row
/// it starts in (and beside the first row).
struct GoalCalendarGrid: View {
    let calendar: GoalCalendarModel
    let tint: GoalTint
    @ScaledMetric(relativeTo: .caption2) private var monthWidth: CGFloat = 26

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Color.clear.frame(width: monthWidth, height: 1)
                ForEach(Array(DeckDots.weekdays.enumerated()), id: \.offset) { _, letter in
                    Text(verbatim: letter)
                        .font(AppFont.caption2())
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(GoalCalendarRows.rows(calendar.slots)) { row in
                HStack(spacing: 5) {
                    Text(verbatim: row.month ?? "")
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: monthWidth, alignment: .leading)
                    ForEach(row.slots) { slot in
                        Group {
                            if let day = slot.day {
                                GoalCalendarCell(day: day, tint: tint)
                            } else {
                                Color.clear.aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: calendar.summary))
    }
}

/// One week of the calendar and the month it names, if any.
struct GoalCalendarRow: Identifiable, Equatable {
    let id: String
    /// "Nov" beside the row holding the 1st of a month, and beside the first row; else nil.
    let month: String?
    let slots: [GoalCalendarModel.Slot]
}

enum GoalCalendarRows {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The calendar's cells cut into weeks of seven, each naming the month it starts.
    static func rows(_ slots: [GoalCalendarModel.Slot]) -> [GoalCalendarRow] {
        stride(from: 0, to: slots.count, by: 7).map { start in
            let week = Array(slots[start..<min(start + 7, slots.count)])
            let days = week.compactMap(\.day)
            let labelled = start == 0 ? days.first : days.first { $0.dayOfMonth == 1 }
            return GoalCalendarRow(id: week.first?.id ?? "row-\(start)", month: labelled.flatMap { month($0.date) }, slots: week)
        }
    }

    /// "2026-11-01" → "Nov".
    static func month(_ iso: String) -> String? {
        guard let number = Int(iso.dropFirst(5).prefix(2)), (1...12).contains(number) else { return nil }
        return months[number - 1]
    }
}

extension GoalCalendarModel {
    /// The detail screen's calendar: the goal's days so far and the rest of this week, never the
    /// weeks still ahead (the hero's kicker says how many days are left). A goal without a deadline
    /// keeps the calendar's cap of the last four weeks.
    static func throughThisWeek(heatmap: [GoalHeatDay], today: String, deadline: String?) -> GoalCalendarModel {
        let full = GoalCalendarModel(heatmap: heatmap, today: today, deadline: deadline)
        let summary = GoalDetailCopy.shownUpLine((full.shown, full.total))
        guard let index = full.slots.firstIndex(where: { $0.day?.isToday == true }) else {
            return GoalCalendarModel(slots: full.slots, shown: full.shown, total: full.total, summary: summary)
        }
        let slots = Array(full.slots.prefix((index / 7 + 1) * 7))
        return GoalCalendarModel(slots: slots, shown: full.shown, total: full.total, summary: summary)
    }
}

private struct GoalCalendarCell: View {
    let day: GoalCalendarDay
    let tint: GoalTint

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous)
        let isEmpty = GoalHeroCopy.glyph(day.status) == nil
        ZStack {
            if day.isFuture {
                shape.strokeBorder(Color.hxSeparator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else if !(day.isToday && isEmpty) {
                // A missed day keeps the empty day's neutral fill and says so with its mark, never amber.
                shape.fill(GoalPaper.fill(day.status == .miss ? .none : day.status, ink: tint.fill))
            }
            // Today is a ring: filled once checked in, never the gray of a day gone by.
            if day.isToday { shape.strokeBorder(tint.fill, lineWidth: 2) }
            if day.isDeadline {
                Image(systemName: "flag.checkered")
                    .font(AppFont.caption2(weight: .semibold))
                    .foregroundStyle(!day.isFuture && day.status.isShown ? tint.on : tint.fill)
            } else if !day.isFuture, day.status == .skip || day.status == .miss {
                // A skip or a miss shows its mark, so it never differs from an empty day by color alone.
                Image(systemName: GoalDetailCopy.symbol(day.status))
                    .font(AppFont.caption2(weight: .bold))
                    .foregroundStyle(Color.hxTextPrimary)
            } else {
                Text(verbatim: "\(day.dayOfMonth)")
                    .font(AppFont.caption2(weight: day.isToday ? .semibold : .regular).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(day.status.isShown ? tint.on : day.isToday ? tint.fill : Color.hxTextSecondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
