import SwiftUI

/// A goal on its Daily Brief paper: days left, title, identity, then each commitment's week as the
/// Brief's dots under one row of weekday letters (`DeckWeekGrid`'s columns, today's letter heavy). With
/// `checkIn`, today's and yesterday's dots check in and an item row ends on a + (Goals home and goal
/// detail alike). On Monday a commitment with a last week shows it first under "Last week", so Sunday
/// can still be logged as yesterday.
struct GoalHeroCard: View {
    let goal: GoalSummary
    var why: String = ""
    var isCompact = false
    /// The server's today, for the live today and yesterday dots and Monday's last week.
    var today: String?
    /// One-tap check-ins on the dots; nil leaves them read-only.
    var checkIn: GoalHeroCheckIn?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var scaledDot: CGFloat = DeckDots.dot

    var body: some View {
        let palette = GoalPaper.palette(for: goal)
        let stacked = GoalHeroLayout.stacks(dynamicTypeSize)
        let metrics = stacked ? GoalDotMetrics.scaled(scaledDot) : .standard
        let today = today ?? checkIn?.today
        let lastWeek = goal.week.commitments.filter { GoalHeroLayout.showsLastWeek($0, today: today) }
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
            if !goal.identity.isEmpty, GoalHeroLayout.showsIdentity(isCompact: isCompact, stacked: stacked) {
                Text(verbatim: GoalHeroCopy.sentenceCase(goal.identity))
                    .font(AppFont.display(style: .subheadline, weight: .medium))

            }
            if !isCompact, !why.isEmpty {
                Text(verbatim: why)
                    .font(BrainStyle.rowSubtitle)

                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if !goal.week.commitments.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    GoalWeekLetters(label: lastWeek.isEmpty ? nil : "Last week", today: today, ink: palette.ink,
                                    metrics: metrics, stacked: stacked)
                    ForEach(lastWeek) { row in
                        GoalCommitmentWeek(row: row, atRisk: false, paper: palette.colors, today: today,
                                           checkIn: checkIn, isLastWeek: true, metrics: metrics, stacked: stacked)
                    }
                    if !lastWeek.isEmpty {
                        GoalWeekLabel(text: "This week", ink: palette.ink)
                            .padding(.top, BrainStyle.xs)
                    }
                    ForEach(goal.week.commitments) { row in
                        GoalCommitmentWeek(row: row, atRisk: goal.flags.missTwice.contains(row.id), paper: palette.colors,
                                           today: today, checkIn: checkIn, metrics: metrics, stacked: stacked)
                    }
                }
            }
        }
        .foregroundStyle(palette.ink)
    }
}

/// How the hero lays a commitment out, by text size and day.
enum GoalHeroLayout {
    /// At accessibility sizes a commitment's name and count stack above its dots, which then get the
    /// card's width to grow in.
    static func stacks(_ size: DynamicTypeSize) -> Bool { size >= .accessibility1 }

    /// Goals home's compact cards drop the identity line at accessibility sizes, so the dots stay near.
    static func showsIdentity(isCompact: Bool, stacked: Bool) -> Bool { !(isCompact && stacked) }

    /// Monday (today opens the server's week) shows the commitment's last week, when it had one.
    static func showsLastWeek(_ row: GoalCommitmentProgress, today: String?) -> Bool {
        guard let today, row.lastWeek != nil else { return false }
        if let first = row.weekDays.first { return first.date == today }
        return GoalCalendar.weekdayIndex(today) == 0
    }
}

/// The dots' sizes: the Brief's 16 pt in a 26 pt column, or at accessibility sizes grown with the text
/// up to `maxDot`, each column keeping the same 10 pt of air so neighbors and the + never touch.
struct GoalDotMetrics: Equatable {
    var dot: CGFloat = DeckDots.dot
    var column: CGFloat = DeckDots.column

    static let standard = GoalDotMetrics()
    /// Seven columns at this size still fit an iPhone SE's card.
    static let maxDot: CGFloat = 26

    static func scaled(_ dot: CGFloat) -> GoalDotMetrics {
        let size = min(max(dot, DeckDots.dot), maxDot)
        return GoalDotMetrics(dot: size, column: size + DeckDots.column - DeckDots.dot)
    }

    /// The seven day columns together.
    var trailingWidth: CGFloat { column * CGFloat(DeckWeekGridLayout.dayCount) }

    /// A counted row's pip column: the day columns' width shared by its pips and its +, never wider than a day's.
    func pipColumn(pips: Int, addsOne: Bool) -> CGFloat {
        let slots = pips + (addsOne ? 1 : 0)
        guard slots > 0 else { return column }
        return min(column, trailingWidth / CGFloat(slots))
    }

    /// The dot in a `column` that may be narrower than a day's, with air on each side.
    func dot(in column: CGFloat) -> CGFloat { min(dot, column - 4) }
}

/// The small in-card label over a week's rows ("Last week", "This week").
struct GoalWeekLabel: View {
    let text: String
    let ink: Color

    var body: some View {
        Text(verbatim: text)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(ink)
            .accessibilityAddTraits(.isHeader)
    }
}

/// M T W T F S S over the seven day columns, once per card, today's letter heavy; with a label
/// ("Last week") in the name column.
private struct GoalWeekLetters: View {
    let label: String?
    let today: String?
    let ink: Color
    let metrics: GoalDotMetrics
    let stacked: Bool

    var body: some View {
        let todayIndex = today.flatMap(GoalCalendar.weekdayIndex)
        let letters = HStack(spacing: 0) {
            ForEach(Array(DeckDots.weekdays.enumerated()), id: \.offset) { index, letter in
                Text(verbatim: letter)
                    .font(AppFont.caption2(weight: index == todayIndex ? .bold : .regular))
                    .foregroundStyle(ink)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(width: metrics.column)
            }
        }
        .frame(width: metrics.trailingWidth, alignment: .leading)
        .accessibilityHidden(true)
        if stacked {
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                if let label { GoalWeekLabel(text: label, ink: ink) }
                letters
            }
        } else {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Group {
                    if let label { GoalWeekLabel(text: label, ink: ink) } else { Color.clear.frame(height: 0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
                letters
            }
        }
    }
}

/// A commitment's week on the hero, laid out like a row of the Brief's week grid (`DeckWeekGrid`):
/// its name with a small count in the flexible column, then its dots in the seven fixed day columns
/// (stacked above them at accessibility sizes), and a "Don't miss twice" chip under it when the server
/// flags it. With `checkIn`, today's and yesterday's dots check in and an item row ends on a +
/// (`GoalCheckInPipRow`). `isLastWeek` draws the row's last week instead, where only an unlogged
/// Sunday (yesterday, on Monday) checks in.
struct GoalCommitmentWeek: View {
    let row: GoalCommitmentProgress
    let atRisk: Bool
    let paper: HermexPaper
    /// The server's today, so today's and yesterday's dots follow a tap at once.
    var today: String?
    var checkIn: GoalHeroCheckIn?
    var isLastWeek = false
    var metrics: GoalDotMetrics = .standard
    var stacked = false

    var body: some View {
        let name = GoalsCopy.shortName(row.action)
        let pips = isLastWeek ? GoalPips(lastWeekOf: row, name: name, today: today) : GoalPips(row, name: name, today: today)
        let dates = isLastWeek ? (row.lastWeek?.days.map(\.date) ?? []) : row.weekDays.map(\.date)
        // A row with a dot to tap is a 44 pt row; last week's only when its Sunday can still be logged.
        let tall = checkIn.map { !isLastWeek || (dates.contains($0.yesterday) && $0.tappableDays(row).contains(.yesterday)) } ?? false
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: BrainStyle.xs) {
                        label(pips)
                        dots(pips, dates: dates)
                    }
                } else {
                    HStack(spacing: 0) {
                        label(pips)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 6)
                        dots(pips, dates: dates)
                    }
                    .frame(minHeight: tall ? BrainStyle.minTapTarget : 24)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: isLastWeek ? "Last week, \(pips.spoken)" : pips.spoken))
            if atRisk {
                GoalAtRiskChip(row: row, paper: paper)
            }
        }
    }

    private func label(_ pips: GoalPips) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: GoalsCopy.shortName(row.action))
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(2)
            Text(verbatim: pips.count)
                .font(AppFont.caption())
                .foregroundStyle(paper.glow)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func dots(_ pips: GoalPips, dates: [String]) -> some View {
        if let checkIn {
            GoalCheckInPipRow(row: row, pips: pips, dates: dates, ink: paper.glow, checkIn: checkIn,
                              addsOne: !isLastWeek, metrics: metrics)
        } else {
            GoalPipRow(pips: pips, ink: paper.glow, metrics: metrics)
        }
    }
}

/// The Brief's never-miss-twice cue on a commitment: a chip in the goal's paper, never amber.
struct GoalAtRiskChip: View {
    let row: GoalCommitmentProgress
    let paper: HermexPaper

    var body: some View {
        HXChip(paper: paper, symbol: "exclamationmark.circle", label: GoalPips.atRiskLabel(row), lines: 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: GoalPips.atRiskSpoken(row)))
    }
}

/// A commitment's week as the Brief's dots (`DeckDot`). A day commitment is the week as days,
/// Mon–Sun as the server sends it, with today and yesterday following the row's check-ins so a
/// tap shows at once; from a server without those days, a pip per day of its target, then its
/// skip budget, half-filled for a skip taken and dashed for one still left. An item commitment
/// has a pip per item of its target.
struct GoalPips: Equatable {
    /// `DeckDot` states, left to right.
    let states: [String]
    /// The small count beside the dots: "3 of 6", and the skips left: "3 of 6 · 1 skip".
    let count: String
    /// "Stretch: 3 of 6 days, 1 skip left".
    let spoken: String

    /// `today` is the server's today, for the live today and yesterday dots.
    init(_ row: GoalCommitmentProgress, name: String, today: String? = nil) {
        if row.isItem {
            let done = row.done
            states = (0..<max(row.target, done)).map { $0 < done ? "done" : "missed" }
            count = row.target > 0 ? "\(done) of \(row.target)" : "\(done)"
            spoken = row.target > 0 ? "\(name): \(done) of \(row.target) this week" : "\(name): \(done) this week"
        } else {
            let shown = row.done + row.min
            let used = min(row.skipped, row.skips)
            let left = max(0, row.skips - row.skipped)
            if row.weekDays.count == 7 {
                states = Self.weekStates(row, today: today)
                count = "\(shown) of \(row.target)" + (left == 0 ? "" : left == 1 ? " · 1 skip left" : " · \(left) skips left")
            } else {
                states = (0..<max(row.target, shown)).map { $0 < shown ? "done" : "missed" }
                    + Array(repeating: "skip", count: used) + Array(repeating: "ahead", count: left)
                count = "\(shown) of \(row.target)"
            }
            let skips = row.skips == 0 ? "" : left == 1 ? ", 1 skip left" : ", \(left) skips left"
            spoken = "\(name): \(shown) of \(row.target) day\(row.target == 1 ? "" : "s")\(skips)"
        }
    }

    /// A commitment's last week, for Monday's hero: its seven days (yesterday, last Sunday, following the
    /// row's check-in) or, for an item row, a pip per item of its target; the count beside follows Sunday.
    init(lastWeekOf row: GoalCommitmentProgress, name: String, today: String?) {
        let week = row.lastWeek
        let target = week?.target ?? 0
        var done = week?.done ?? 0
        if let week, !row.isItem, week.days.count == 7 {
            let sunday = week.days[6]
            let status = today.flatMap { row.effectiveStatus(sunday.date, today: $0, yesterday: sunday.date) }
            let live = status == nil && sunday.state == "off"
                ? "off" : DeckRowCheckIn.liveState(status, isToday: false, deckState: sunday.state)
            // A Sunday logged since the server counted the week moves the count with it.
            if sunday.state != "done", live == "done" { done += 1 }
            if sunday.state == "done", live != "done" { done = max(0, done - 1) }
            states = week.days.dropLast().map(\.state) + [live]
            spoken = "\(name): \(done) of \(target) day\(target == 1 ? "" : "s")" + (live == "ask" ? ", Sunday not logged yet" : "")
        } else {
            states = (0..<max(target, done)).map { $0 < done ? "done" : "missed" }
            spoken = "\(name): \(done) of \(target)"
        }
        count = "\(done) of \(target)"
    }

    /// The server's Mon–Sun, with today and yesterday read from the row's own check-ins (which an
    /// optimistic tap updates) the way the Brief's live rows read them.
    static func weekStates(_ row: GoalCommitmentProgress, today: String?) -> [String] {
        guard let today, let index = row.weekDays.firstIndex(where: { $0.date == today }) else {
            return row.weekDays.map(\.state)
        }
        let yesterday = index > 0 ? row.weekDays[index - 1].date : ""
        return row.weekDays.map { day in
            guard day.date == today || day.date == yesterday else { return day.state }
            let status = row.effectiveStatus(day.date, today: today, yesterday: yesterday)
            if status == nil, day.state == "off" { return "off" }
            return DeckRowCheckIn.liveState(status, isToday: day.date == today, deckState: day.state)
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
    var metrics: GoalDotMetrics = .standard

    var body: some View {
        let column = metrics.pipColumn(pips: pips.states.count, addsOne: false)
        HStack(spacing: 0) {
            ForEach(Array(pips.states.enumerated()), id: \.offset) { _, state in
                DeckDot(state: state, ink: ink, column: column, size: metrics.dot(in: column))
            }
        }
        .frame(width: metrics.trailingWidth, alignment: .leading)
        .accessibilityHidden(true)
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

    /// A checked-in day's mark in the calendar (`GoalDetailCopy.symbol`); nil for an empty day.
    static func glyph(_ status: GoalStatus) -> String? {
        switch status {
        case .done, .min, .skip, .miss: GoalDetailCopy.symbol(status)
        case .none, .clear, .unknown: nil
        }
    }
}
