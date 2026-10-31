import SwiftUI

/// The streak and the calendar of every day, drawn from the view model's prepared calendar.
struct GoalConsistencySection: View {
    let streakDays: Int
    let calendar: GoalCalendarModel
    let tint: GoalTint

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Consistency")
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: GoalsCopy.streakTitle(streakDays)).brainText(.rowTitle)
                        Spacer(minLength: BrainStyle.s)
                        Text(verbatim: GoalDetailCopy.shownUpLine((calendar.shown, calendar.total)))
                            .brainText(.meta).monospacedDigit()
                    }
                    GoalCalendarGrid(calendar: calendar, tint: tint)
                }
                .padding(.vertical, BrainStyle.xs)
            }
        }
    }
}

/// Every day from the goal's start to its deadline, Monday first, in the goal's tint.
struct GoalCalendarGrid: View {
    let calendar: GoalCalendarModel
    let tint: GoalTint

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(Array(DeckDots.weekdays.enumerated()), id: \.offset) { _, letter in
                Text(verbatim: letter).font(AppFont.caption2()).foregroundStyle(Color.hxTextSecondary)
            }
            ForEach(calendar.slots) { slot in
                if let day = slot.day {
                    GoalCalendarCell(day: day, tint: tint)
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: calendar.summary))
    }
}

private struct GoalCalendarCell: View {
    let day: GoalCalendarDay
    let tint: GoalTint

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous)
        let filled = !day.isFuture && (day.status != .none || day.isToday)
        ZStack {
            if day.isFuture {
                shape.strokeBorder(Color.hxSeparator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                shape.fill(GoalPaper.fill(day.status, ink: tint.fill))
            }
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
                    .font(AppFont.caption2().monospacedDigit())
                    .foregroundStyle(filled && day.status.isShown ? tint.on : Color.hxTextSecondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
