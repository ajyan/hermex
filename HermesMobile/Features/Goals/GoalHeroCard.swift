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

    private static let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        let palette = GoalPaper.palette(for: goal)
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: GoalHeroCopy.countdown(goal))
                    .font(BrainStyle.meta)
                    .opacity(0.75)
                Spacer(minLength: 0)
                Image(systemName: GoalPaper.symbol(goal.icon))
                    .font(BrainStyle.rowSubtitle)
                    .opacity(0.7)
                    .accessibilityHidden(true)
            }
            Text(verbatim: goal.title)
                .font(AppFont.serif(style: isCompact ? .title3 : .title))
                .fixedSize(horizontal: false, vertical: true)
            if !goal.identity.isEmpty {
                Text(verbatim: GoalHeroCopy.sentenceCase(goal.identity))
                    .font(AppFont.serif(style: .subheadline))
                    .italic()
                    .opacity(0.85)
            }
            if !isCompact, !why.isEmpty {
                Text(verbatim: why)
                    .font(BrainStyle.rowSubtitle)
                    .opacity(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !goal.week.days.isEmpty {
                GoalWeekStrip(days: goal.week.days, ink: palette.ink, today: today ?? selection?.today,
                              selection: selection, onSelect: onSelect)
                    .padding(.top, BrainStyle.xs)
            }
            Text(verbatim: GoalHeroCopy.weekSummary(goal.week.commitments))
                .font(BrainStyle.meta)
                .monospacedDigit()
        }
        .foregroundStyle(palette.ink)
        .padding(BrainStyle.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.paper, in: Self.shape)
        .environment(\.colorScheme, .light)  // bright paper in every appearance, like the Brief
    }
}

/// Monday to Sunday as seven cells filled by each day's best check-in. With a selection,
/// today and yesterday are buttons and the selected one is outlined.
private struct GoalWeekStrip: View {
    let days: [GoalHeatDay]
    let ink: Color
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
        let content = VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isFuture ? Color.clear : GoalPaper.fill(day.status, ink: ink))
                .overlay {
                    if isFuture {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(ink, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .frame(height: cellHeight)
            Text(verbatim: GoalHeroCopy.weekdayLetter(day.date))
                .font(.caption2.weight(isSelected ? .semibold : .regular))
                .opacity(0.75)
        }
        .frame(maxWidth: .infinity)

        if let choice {
            Button { onSelect(choice) } label: { content.contentShape(Rectangle()) }
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
    static func countdown(_ goal: GoalSummary) -> String {
        guard let days = goal.daysLeft, let deadline = goal.deadline, let date = GoalCalendar.date(deadline) else {
            return goal.status.capitalized
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d"
        let left = days == 1 ? "1 day" : "\(days) days"
        return "\(left) · \(f.string(from: date))"
    }

    static func sentenceCase(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// "Stretch 3/6 · Run 0/1 · 1 skip left": the week's counts in one line.
    static func weekSummary(_ commitments: [GoalCommitmentProgress]) -> String {
        var parts = commitments.map { "\(GoalsCopy.shortName($0.action)) \($0.done + $0.min)/\($0.target)" }
        let skipsLeft = commitments.reduce(0) { $0 + max(0, $1.skips - $1.skipped) }
        if skipsLeft > 0 { parts.append(skipsLeft == 1 ? "1 skip left" : "\(skipsLeft) skips left") }
        return parts.joined(separator: " · ")
    }

    static func weekdayLetter(_ iso: String) -> String {
        guard let date = GoalCalendar.date(iso) else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return ["S", "M", "T", "W", "T", "F", "S"][cal.component(.weekday, from: date) - 1]
    }

    static func dayLabel(_ day: GoalHeatDay, choice: GoalDay?) -> String {
        let name = choice == .today ? "Today" : choice == .yesterday ? "Yesterday" : day.date
        let state: String = switch day.status {
        case .done: "done"
        case .min: "2-minute version"
        case .skip: "skipped"
        case .miss: "missed"
        case .none, .unknown: "not checked in"
        }
        return "\(name), \(state)"
    }
}
