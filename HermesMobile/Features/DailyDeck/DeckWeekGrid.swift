import SwiftUI

/// The close's week in a deck by job, laid out as one grid: a flexible label column and seven fixed day
/// columns under the weekday letters. Every
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

/// The close's habit tracker: the weekday letters over one row per habit, every dot in its day's column, then
/// the counted habits as pips in a section of their own. Each row's dots wear the habit's paper
/// (`DeckFrontRow.habitPaper`); the labels stay neutral. Today's and yesterday's dots log a goal commitment in
/// place (`DeckRowCheckIn`), and + adds one to a count. Numbers are dots and pips, never a bar or a bare count.
struct DeckWeekGrid: View {
    let rows: [DeckFrontRow]
    let deckDate: String

    var body: some View {
        let days = DeckWeekGridLayout.groups(rows, kind: .days).flatMap(\.rows)
        let counts = DeckWeekGridLayout.groups(rows, kind: .pips).flatMap(\.rows)
        VStack(alignment: .leading, spacing: 0) {
            if !days.isEmpty {
                weekdays.padding(.bottom, 2)
                ForEach(days) { row in
                    DeckWeekGridRow(row: row, deckDate: deckDate)
                }
            }
            if !counts.isEmpty {
                Rectangle().fill(Color.hxSeparator).frame(height: 0.5)
                    .padding(.top, days.isEmpty ? 0 : 10)
                    .padding(.bottom, 4)
                ForEach(counts) { row in
                    DeckWeekGridRow(row: row, deckDate: deckDate)
                }
            }
        }
    }

    /// The weekday letters over the day columns, today's heavy.
    private var weekdays: some View {
        let today = DeckWeekGridLayout.weekdayIndex(of: deckDate)
        return HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(Array(DeckDots.weekdays.enumerated()), id: \.offset) { index, letter in
                Text(verbatim: letter)
                    .font(AppFont.caption2(weight: index == today ? .heavy : .regular))
                    .foregroundStyle(index == today ? Color.hxTextPrimary : Color.hxTextSecondary)
                    .frame(width: DeckWeekGridLayout.dayColumn)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One habit of the close's tracker: its label in the flexible column, then its dots in the fixed day columns,
/// or its pips (and +) packed against the trailing edge.
private struct DeckWeekGridRow: View {
    let row: DeckFrontRow
    let deckDate: String

    @Environment(GoalsHomeViewModel.self) private var model: GoalsHomeViewModel?
    /// A row is as tall as a comfortable tap, so today's dot is easy to hit.
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 36

    var body: some View {
        let checkIn = DeckRowCheckIn(row: row, ink: row.habitPaper.glow, deckDate: deckDate, model: model, hitHeight: rowHeight)
        HStack(spacing: 0) {
            Text(verbatim: row.label)
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
                .accessibilityHidden(true)
            switch row.kind {
            case .days: days(checkIn)
            case .pips: pips(checkIn)
            }
        }
        .frame(minHeight: rowHeight)
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
        .frame(width: DeckWeekGridLayout.trailingWidth, alignment: .leading)
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
                DeckDot(state: index < done ? "done" : "missed", ink: row.habitPaper.glow, column: column)
            }
            checkIn.addButton(column: column)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: checkIn.spokenCount))
    }
}
