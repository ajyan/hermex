import SwiftUI

/// A goal on its Daily Brief paper: days left, serif title, identity, and this week as a
/// strip of seven days. Goals home shows it compact; goal detail adds the why and lets the
/// strip pick which day (today or yesterday) the check-ins below write to.
struct GoalHeroCard: View {
    let goal: GoalSummary
    var why: String = ""
    var isCompact = false
    /// The server's today, so the strip can dash the days still ahead.
    var today: String?
    /// The day the detail screen checks in for; nil leaves the strip read-only.
    var selection: (today: String, yesterday: String, selected: GoalDay)?
    var onSelect: (GoalDay) -> Void = { _ in }

    var body: some View {
        let palette = GoalPaper.palette(for: goal)
        HXCard(.glow(palette.colors), title: goal.title, titleStyle: isCompact ? .title3 : .title,
               spacing: BrainStyle.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: GoalHeroCopy.countdown(goal))
                    .font(BrainStyle.meta)

                Spacer(minLength: 0)
                Image(systemName: GoalPaper.symbol(goal.icon))
                    .font(BrainStyle.rowSubtitle)

                    .accessibilityHidden(true)
            }
        } content: {
            if !goal.identity.isEmpty {
                Text(verbatim: GoalHeroCopy.sentenceCase(goal.identity))
                    .font(AppFont.display(style: .subheadline, weight: .medium))

            }
            if !isCompact, !why.isEmpty {
                Text(verbatim: why)
                    .font(BrainStyle.rowSubtitle)

                    .fixedSize(horizontal: false, vertical: true)
            }
            if !goal.week.days.isEmpty {
                GoalWeekStrip(days: goal.week.days, ink: palette.ink, onInk: palette.onInk, today: today ?? selection?.today,
                              selection: selection, onSelect: onSelect)
                    .padding(.top, BrainStyle.xs)
            }
        } footer: {
            if !goal.week.commitments.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    ForEach(goal.week.commitments) { row in
                        GoalCommitmentWeek(row: row, atRisk: goal.flags.missTwice.contains(row.id), paper: palette.colors)
                    }
                }
            }
        }
        .foregroundStyle(palette.ink)
    }
}

/// A commitment's week on the hero, laid out like a row of the Brief's week grid (`DeckWeekGrid`):
/// its name with a small count in the flexible column, then its pips in the seven fixed day columns,
/// and a "Don't miss twice" chip under it when the server flags it.
struct GoalCommitmentWeek: View {
    let row: GoalCommitmentProgress
    let atRisk: Bool
    let paper: HermexPaper

    var body: some View {
        let pips = GoalPips(row, name: GoalsCopy.shortName(row.action))
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: GoalsCopy.shortName(row.action))
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineLimit(2)
                    Text(verbatim: pips.count)
                        .font(AppFont.caption())
                        .foregroundStyle(paper.glow)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
                GoalPipRow(pips: pips, ink: paper.glow)
            }
            .frame(minHeight: 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: pips.spoken))
            if atRisk {
                GoalAtRiskChip(row: row, paper: paper)
            }
        }
    }
}

/// The Brief's never-miss-twice cue on a commitment: a chip in the goal's paper, never amber.
struct GoalAtRiskChip: View {
    let row: GoalCommitmentProgress
    let paper: HermexPaper

    var body: some View {
        HXChip(paper: paper, symbol: "exclamationmark.circle", label: GoalPips.atRiskLabel(row))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: GoalPips.atRiskSpoken(row)))
    }
}

/// A commitment's week as the Brief's pips (`DeckDot`): one per day of its target, filled once
/// done (the 2-minute version too), then its skip budget, half-filled for a skip taken and
/// dashed for one still left. An item commitment has a pip per item of its target.
struct GoalPips: Equatable {
    /// `DeckDot` states, left to right.
    let states: [String]
    /// The small count beside the pips: "3 of 6".
    let count: String
    /// "Stretch: 3 of 6 days, 1 skip left".
    let spoken: String

    init(_ row: GoalCommitmentProgress, name: String) {
        if row.isItem {
            let done = row.done
            states = (0..<max(row.target, done)).map { $0 < done ? "done" : "missed" }
            count = row.target > 0 ? "\(done) of \(row.target)" : "\(done)"
            spoken = row.target > 0 ? "\(name): \(done) of \(row.target) this week" : "\(name): \(done) this week"
        } else {
            let shown = row.done + row.min
            let used = min(row.skipped, row.skips)
            let left = max(0, row.skips - row.skipped)
            states = (0..<max(row.target, shown)).map { $0 < shown ? "done" : "missed" }
                + Array(repeating: "skip", count: used) + Array(repeating: "ahead", count: left)
            count = "\(shown) of \(row.target)"
            let skips = row.skips == 0 ? "" : left == 1 ? ", 1 skip left" : ", \(left) skips left"
            spoken = "\(name): \(shown) of \(row.target) day\(row.target == 1 ? "" : "s")\(skips)"
        }
    }

    /// The chip's words: a day commitment missed yesterday, or an item one short two weeks running.
    static func atRiskLabel(_ row: GoalCommitmentProgress) -> String {
        row.isItem ? "Short 2 weeks running" : "Don't miss twice"
    }

    static func atRiskSpoken(_ row: GoalCommitmentProgress) -> String {
        let name = GoalsCopy.shortName(row.action)
        return row.isItem ? "\(name) was short two weeks running" : "\(name) missed yesterday. Don't miss twice"
    }
}

/// The pips in the seven fixed day columns of the Brief's week grid, sharing them when there are more.
struct GoalPipRow: View {
    let pips: GoalPips
    let ink: Color

    var body: some View {
        let column = DeckWeekGridLayout.pipColumn(pips: pips.states.count, addsOne: false)
        HStack(spacing: 0) {
            ForEach(Array(pips.states.enumerated()), id: \.offset) { _, state in
                DeckDot(state: state, ink: ink, column: column)
            }
        }
        .frame(width: DeckWeekGridLayout.trailingWidth, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// Monday to Sunday as seven cells filled by each day's best check-in. With a selection,
/// today and yesterday are buttons and the selected one is outlined.
private struct GoalWeekStrip: View {
    let days: [GoalHeatDay]
    let ink: Color
    let onInk: Color
    let today: String?
    let selection: (today: String, yesterday: String, selected: GoalDay)?
    let onSelect: (GoalDay) -> Void
    @ScaledMetric(relativeTo: .caption) private var cellHeight: CGFloat = 22

    var body: some View {
        HStack(spacing: BrainStyle.xs) {
            ForEach(days, id: \.date) { day in
                cell(day)
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: GoalHeatDay) -> some View {
        let choice = selection.flatMap { GoalCalendar.selectableDay(day.date, today: $0.today, yesterday: $0.yesterday) }
        let isSelected = choice != nil && choice == selection?.selected
        let isFuture = today.map { day.date > $0 } ?? false
        let shape = RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous)
        let content = VStack(spacing: 3) {
            shape
                .fill(isFuture ? Color.clear : GoalPaper.fill(day.status, ink: ink))
                .overlay {
                    if isFuture {
                        shape.strokeBorder(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    } else if let glyph = GoalHeroCopy.glyph(day.status) {
                        // The status as a mark too, so skip, miss and an empty day never differ by color alone.
                        Image(systemName: glyph)
                            .font(AppFont.caption2(weight: .bold))
                            .foregroundStyle(day.status.isShown ? onInk : Color.hxTextPrimary)
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
                            .strokeBorder(ink, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .frame(height: cellHeight)
            Text(verbatim: GoalHeroCopy.weekdayLetter(day.date))
                .font(AppFont.caption2(weight: isSelected ? .semibold : .regular))
        }
        .frame(maxWidth: .infinity)

        if let choice {
            Button { onSelect(choice) } label: {
                content.frame(minHeight: BrainStyle.minTapTarget).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: GoalHeroCopy.dayLabel(day, choice: choice)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(Text(verbatim: "Check in for this day"))
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: GoalHeroCopy.dayLabel(day, choice: nil)))
        }
    }
}

enum GoalHeroCopy {
    private static let deadlineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d"
        return f
    }()

    static func countdown(_ goal: GoalSummary) -> String {
        guard let days = goal.daysLeft, let deadline = goal.deadline, let date = GoalCalendar.date(deadline) else {
            return goal.status.capitalized
        }
        let left = days == 1 ? "1 day" : "\(days) days"
        return "\(left) · \(deadlineFormatter.string(from: date))"
    }

    static func sentenceCase(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    static func weekdayLetter(_ iso: String) -> String {
        GoalCalendar.weekdayIndex(iso).map { DeckDots.weekdays[$0] } ?? ""
    }

    /// A checked-in day's mark in the strip and calendar (`GoalDetailCopy.symbol`); nil for an empty day.
    static func glyph(_ status: GoalStatus) -> String? {
        switch status {
        case .done, .min, .skip, .miss: GoalDetailCopy.symbol(status)
        case .none, .clear, .unknown: nil
        }
    }

    static func dayLabel(_ day: GoalHeatDay, choice: GoalDay?) -> String {
        let name = choice == .today ? "Today" : choice == .yesterday ? "Yesterday" : day.date
        let state: String = switch day.status {
        case .done: "done"
        case .min: "2-minute version"
        case .skip: "skipped"
        case .miss: "missed"
        case .none, .clear, .unknown: "not checked in"
        }
        return "\(name), \(state)"
    }
}
