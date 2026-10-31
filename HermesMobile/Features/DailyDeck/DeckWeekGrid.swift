import SwiftUI

/// The close's week in a deck by job, laid out as one grid: a flexible label column (the count sits under
/// the label, so the label keeps its room) and seven fixed day columns under the weekday letters. Every
/// width but the label's is fixed, so a long label wraps inside its column and can never move a dot out
/// from under its letter.
enum DeckWeekGridLayout {
    static let dayColumn: CGFloat = DeckDots.column
    static let dayCount = 7

    /// The day columns together: the same in every row, whatever its label.
    static var trailingWidth: CGFloat { dayColumn * CGFloat(dayCount) }

    /// Where day `index`'s dot is centered, from the leading edge of a row `rowWidth` wide. The label
    /// takes what's left of the row, so it never enters this.
    static func dotCenter(day index: Int, rowWidth: CGFloat) -> CGFloat {
        rowWidth - trailingWidth + dayColumn * (CGFloat(index) + 0.5)
    }

    /// A counted row's pip column: the day columns' width shared by its pips and its +, never wider than a day's.
    static func pipColumn(pips: Int, addsOne: Bool) -> CGFloat {
        let slots = pips + (addsOne ? 1 : 0)
        guard slots > 0 else { return dayColumn }
        return min(dayColumn, dayColumn * CGFloat(dayCount) / CGFloat(slots))
    }

    /// One front's rows under its name ("Landing the AI role"); nil when the rows name no front.
    struct Group: Identifiable, Equatable {
        let name: String?
        var rows: [DeckFrontRow]
        var id: String { name ?? "" }
    }

    /// `kind`'s rows grouped under their front name, in the order the fronts first appear.
    static func groups(_ rows: [DeckFrontRow], kind: DeckFrontRow.Kind) -> [Group] {
        var groups: [Group] = []
        for row in rows where row.kind == kind {
            if let index = groups.firstIndex(where: { $0.name == row.frontName }) {
                groups[index].rows.append(row)
            } else {
                groups.append(Group(name: row.frontName, rows: [row]))
            }
        }
        return groups
    }

    /// Monday 0 through Sunday 6 for a `yyyy-MM-dd` day; nil when it doesn't read as one.
    static func weekdayIndex(of day: String, calendar: Calendar = .current) -> Int? {
        guard let date = DailyDeckPaths.date(day: day, calendar: calendar) else { return nil }
        return (calendar.component(.weekday, from: date) + 5) % 7
    }
}

/// "Where you stand this week" on a deck by job's close: day rows under the weekday letters, grouped by
/// front, then the counted rows below a hairline. Dots and + check in live as on a front divider.
struct DeckWeekGrid: View {
    let rows: [DeckFrontRow]
    let palette: DeckPalette
    let deckDate: String

    var body: some View {
        let days = DeckWeekGridLayout.groups(rows, kind: .days)
        let counts = DeckWeekGridLayout.groups(rows, kind: .pips)
        VStack(alignment: .leading, spacing: 0) {
            if !days.isEmpty {
                weekdays
                ForEach(days) { group in
                    groupRows(group, header: group.name)
                }
            }
            if !counts.isEmpty {
                Rectangle().fill(palette.ink.opacity(0.15)).frame(height: 0.5)
                    .padding(.top, days.isEmpty ? 0 : 14)
                    .padding(.bottom, 4)
                ForEach(counts) { group in
                    groupRows(group, header: group.name.map { "\($0) · counts" } ?? "Counts")
                }
            }
        }
    }

    /// The weekday letters over the day columns, today's bold.
    private var weekdays: some View {
        let today = DeckWeekGridLayout.weekdayIndex(of: deckDate)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(Array(DeckDots.weekdays.enumerated()), id: \.offset) { index, letter in
                Text(verbatim: letter)
                    .font(AppFont.caption2(weight: index == today ? .heavy : .regular))
                    .foregroundStyle(palette.ink.opacity(index == today ? 1 : 0.75))
                    .frame(width: DeckWeekGridLayout.dayColumn)
            }
        }
        .accessibilityHidden(true)
    }

    private func groupRows(_ group: DeckWeekGridLayout.Group, header: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(verbatim: header)
                    .font(AppFont.caption2(weight: .heavy))
                    .textCase(.uppercase)
                    .foregroundStyle(palette.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(group.rows) { row in
                DeckWeekGridRow(row: row, palette: palette, deckDate: deckDate)
            }
        }
    }
}

/// One row of the close's grid: its label in the flexible column, its dots (or pips and +) in the fixed
/// day columns, its count in the count column.
private struct DeckWeekGridRow: View {
    let row: DeckFrontRow
    let palette: DeckPalette
    let deckDate: String

    @Environment(GoalsHomeViewModel.self) private var model: GoalsHomeViewModel?

    var body: some View {
        let checkIn = DeckRowCheckIn(row: row, ink: palette.ink, deckDate: deckDate, model: model)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.label)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(2)
                Text(verbatim: checkIn.shortCountText)
                    .font(AppFont.caption())
                    .foregroundStyle(palette.ink.opacity(0.75))
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            Group {
                switch row.kind {
                case .days: days(checkIn)
                case .pips: pips(checkIn)
                }
            }
            .frame(width: DeckWeekGridLayout.dayColumn * CGFloat(DeckWeekGridLayout.dayCount), alignment: .leading)
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .contain)
    }

    private func days(_ checkIn: DeckRowCheckIn) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<DeckWeekGridLayout.dayCount, id: \.self) { index in
                if index < row.days.count {
                    checkIn.dot(row.days[index])
                } else {
                    Color.clear.frame(width: DeckWeekGridLayout.dayColumn, height: DeckDots.dot)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: checkIn.spokenWeek))
        .accessibilityActions { checkIn.yesterdayActions }
    }

    private func pips(_ checkIn: DeckRowCheckIn) -> some View {
        let done = checkIn.pipsDone
        let count = max(row.target, done)
        let column = DeckWeekGridLayout.pipColumn(pips: count, addsOne: checkIn.live != nil)
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                DeckDot(state: index < done ? "done" : "missed", ink: palette.ink, column: column)
            }
            checkIn.addButton(column: column)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: checkIn.spokenCount))
    }
}
