import SwiftUI

// The monthly review's own cards, drawn inside `DeckCardView`: the cover, the weeks arc, the month
// in dots, and an insight. Its value, sleep, question, and close cards, and the pieces they share,
// are in `MonthlyReviewParts.swift`; every card wears its month paper (`DeckPalette.month`).
// Each card plays one entrance the first time it reaches the top of the stack (`MonthReveal`); with
// Reduce Motion it starts in its final state.

// MARK: Shared

/// The values' papers on a monthly card: each value wears the paper of the kind of thing it's about.
enum MonthValues {
    static func paper(_ value: String) -> HermexPaper {
        switch value {
        case "present": .past
        case "people": .quote
        case "dad": .advisor
        case "potential": .notes
        case "body": .training
        default: .dusk
        }
    }
}

/// Flips `revealed` once the card is on top of the stack (or at once with Reduce Motion), so a
/// card's entrance plays when he reaches it, not while it waits underneath.
private struct MonthReveal: ViewModifier {
    let cardID: String
    let viewModel: DailyDeckViewModel
    @Binding var revealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear { if reduceMotion { revealed = true } }
            .task(id: viewModel.currentCardID == cardID) {
                guard viewModel.currentCardID == cardID, !revealed else { return }
                // A beat for the card to settle on top before its entrance starts.
                try? await Task.sleep(for: .milliseconds(180))
                revealed = true
            }
    }
}

extension View {
    func monthReveal(_ card: DeckCard, _ viewModel: DailyDeckViewModel, _ revealed: Binding<Bool>) -> some View {
        modifier(MonthReveal(cardID: card.id, viewModel: viewModel, revealed: revealed))
    }
}

/// A number that rolls up from zero when its card is revealed.
struct MonthCountUp: View {
    let value: Int
    let revealed: Bool
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = revealed ? value : 0
        Text(shown, format: .number)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(shown)))
            .animation(reduceMotion ? nil : .smooth(duration: 1.1).delay(delay), value: revealed)
            .accessibilityLabel(Text(value, format: .number))
    }
}

// MARK: Cover

/// The month's cover: its name and range, Atlas's title, the month's big numbers rolling up, the
/// moments rising one at a time, and how the month ended.
struct MonthCoverCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var revealed = false
    @State private var isEditingTitle = false

    private var editedTitle: String? {
        viewModel.answer(for: card)?.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private var title: String { editedTitle ?? card.title ?? card.month?.name ?? "Your month" }

    var body: some View {
        let totals = card.month?.totals ?? []
        VStack(alignment: .leading, spacing: 0) {
            HXChip(paper: palette.colors, label: [card.month?.name, card.range].compactMap { $0 }.joined(separator: " · "))
                .padding(.trailing, clearance)
            Button { isEditingTitle = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: title)
                        .font(AppFont.display(style: .largeTitle, weight: .bold))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Label {
                        Text(verbatim: editedTitle == nil ? "Atlas's title, tap to change" : "Your title, tap to change")
                    } icon: { Image(systemName: "pencil") }
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .accessibilityLabel(Text(verbatim: "Title: \(title)"))
            .accessibilityHint(Text(verbatim: "Changes the month's title"))
            if !totals.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                    ForEach(Array(stride(from: 0, to: totals.count, by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(start..<min(start + 2, totals.count), id: \.self) { index in
                                total(totals[index], delay: Double(index) * 0.12)
                            }
                        }
                    }
                }
                .padding(.top, 22)
            }
            if let note = card.noteFromPast {
                MonthLetterFromPast(note: note, palette: palette).padding(.top, 20)
            }
            if let days = card.month?.dayLines, !days.isEmpty {
                MonthDayRows(card: card, days: days, palette: palette, viewModel: viewModel, revealed: revealed)
                    .padding(.top, 22)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.moments.enumerated()), id: \.element.id) { index, moment in
                    if index > 0 { WeekHairline(palette: palette) }
                    momentRow(moment)
                        .opacity(revealed ? 1 : 0.35)
                        .offset(y: revealed ? 0 : 14)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.45).delay(0.7 + Double(index) * 0.32),
                                   value: revealed)
                }
            }
            .padding(.top, 22)
            if let ended = WeekLastIntentionCard.nonBlank(card.ended) {
                Text(verbatim: ended)
                    .font(AppFont.serif(style: .title3))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .opacity(revealed ? 1 : 0.35)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5).delay(0.8 + Double(card.moments.count) * 0.32),
                               value: revealed)
            }
        }
        .monthReveal(card, viewModel, $revealed)
        .sensoryFeedback(.impact(weight: .light), trigger: revealed) { _, now in now }
        .sheet(isPresented: $isEditingTitle) {
            WeekEditorSheet(title: "The month's title", placeholder: card.title ?? "A few words for the month",
                            palette: palette, initial: title) { viewModel.setText($0, for: card) }
        }
    }

    private func total(_ total: DeckMonth.Total, delay: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MonthCountUp(value: total.value, revealed: revealed, delay: delay)
                .font(AppFont.display(style: .title, weight: .bold))
                .foregroundStyle(palette.ink)
            Text(verbatim: total.label)
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(Color.hxTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func momentRow(_ moment: DeckMoment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: moment.day)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .frame(minWidth: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: moment.line)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let value = WeekValues.shortName(moment.value) {
                    HXChip(paper: MonthValues.paper(moment.value), label: value)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WeekValues.spokenMoment(day: moment.day, line: moment.line, value: moment.value)))
    }
}

// MARK: Weeks

/// The month's weeks as one arc: a numbered stop per week on a line, its title and what marked it,
/// sliding in one after another. The month's last week, still open, is a dashed stop.
struct MonthWeeksCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var stop: CGFloat = 40
    @State private var revealed = false

    var body: some View {
        let weeks = card.month?.weeks ?? []
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Your weeks", palette: palette)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                    row(week, isLast: index == weeks.count - 1, index: index)
                        .opacity(revealed ? 1 : 0.35)
                        .offset(x: revealed ? 0 : -40)
                        .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.72)
                            .delay(0.1 + Double(index) * 0.14), value: revealed)
                }
            }
            .padding(.top, 16)
            DeckFootnote(card: card, palette: palette)
        }
        .monthReveal(card, viewModel, $revealed)
    }

    /// A week's stop: its number in a circle, joined to the next stop by a line that runs between the
    /// circles (never through them), then its title and what marked it.
    private func row(_ week: DeckMonth.Week, isLast: Bool, index: Int) -> some View {
        let isOpen = week.open == true
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
            ZStack {
                Circle().fill(isOpen ? palette.paper : palette.colors.wash)
                Circle().strokeBorder(palette.ink.opacity(isOpen ? 0.6 : 0.25),
                                      style: StrokeStyle(lineWidth: 1, dash: isOpen ? [3, 3] : []))
                Text(verbatim: "\(week.number)")
                    .font(AppFont.footnote(weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
            }
            .frame(width: stop, height: stop)
                if !isLast {
                    Rectangle()
                        .fill(palette.ink.opacity(0.25))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                        .scaleEffect(y: revealed ? 1 : 0, anchor: .top)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.3 + Double(index) * 0.14),
                                   value: revealed)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: week.title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let range = week.range {
                    Text(verbatim: range)
                        .font(AppFont.footnote(weight: .medium))
                        .foregroundStyle(Color.hxTextSecondary)
                }
                if let line = week.line {
                    Text(verbatim: line)
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if week.drafted == true {
                    Text(verbatim: "Atlas's title")
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(palette.ink)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, isLast ? 0 : 18)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Week \(week.number), \(week.title)\(isOpen ? ", still open" : "")"))
    }
}

// MARK: Dots

/// The month in dots: a calendar per habit in its own paper, its done days filling in day by day,
/// then the counted rows as pips.
struct MonthDotsCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var revealed = false

    var body: some View {
        let month = card.month
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Your month in dots", palette: palette)
            if let month, month.daysInMonth == 7 {
                MonthWeekDots(rows: month.rows, labels: month.labels, revealed: revealed, paper: palette.colors)
                    .padding(.top, 18)
            } else {
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 20) {
                let rows = month?.rows ?? []
                ForEach(Array(stride(from: 0, to: rows.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + 2, rows.count), id: \.self) { index in
                            MonthCalendar(row: rows[index], firstWeekday: month?.firstWeekday ?? 0,
                                          daysInMonth: month?.daysInMonth ?? 31, revealed: revealed,
                                          delay: Double(index) * 0.1, paper: palette.colors)
                        }
                    }
                }
            }
            .padding(.top, 18)
            }
            ForEach(Array((month?.pips ?? []).enumerated()), id: \.element.id) { index, row in
                pips(row, delay: 0.9 + Double(index) * 0.2).padding(.top, index == 0 ? 22 : 12)
            }
            DeckFootnote(card: card, palette: palette)
        }
        .monthReveal(card, viewModel, $revealed)
    }

    private func pips(_ row: DeckMonth.PipRow, delay: Double) -> some View {
        let paper = palette.colors
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.label)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Spacer()
                MonthCountUp(value: row.count, revealed: revealed, delay: delay)
                    .font(AppFont.subheadline(weight: .bold))
                    .foregroundStyle(paper.glow)
            }
            FlowRow(spacing: 5) {
                ForEach(0..<row.count, id: \.self) { index in
                    MonthDot(filled: true, revealed: revealed, delay: delay + Double(index) * 0.05, paper: paper)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One habit's month as a calendar: its label and count, then its done days filled in its paper.
private struct MonthCalendar: View {
    let row: DeckMonth.DotRow
    let firstWeekday: Int
    let daysInMonth: Int
    let revealed: Bool
    let delay: Double
    /// Every calendar on the card wears the card's paper, so the month reads as one piece.
    let paper: HermexPaper

    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 11

    var body: some View {
        let done = Set(row.days)
        let cells: [Int?] = Array(repeating: nil, count: max(0, min(6, firstWeekday))) + (1...max(1, daysInMonth)).map { $0 }
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: row.label)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                MonthCountUp(value: done.count, revealed: revealed, delay: delay + 0.3)
                    .font(AppFont.subheadline(weight: .bold))
                    .foregroundStyle(paper.glow)
            }
            VStack(alignment: .leading, spacing: dot * 0.4) {
                HStack(spacing: dot * 0.4) {
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, letter in
                        Text(verbatim: letter)
                            .font(AppFont.caption2(weight: .semibold))
                            .foregroundStyle(Color.hxTextSecondary)
                            .frame(width: dot)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: dot * 0.4) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            if let day {
                                MonthDot(filled: done.contains(day), revealed: revealed,
                                         delay: delay + Double(day) * 0.028, paper: paper, size: dot)
                            } else {
                                Color.clear.frame(width: dot, height: dot)
                            }
                        }
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(row.label), \(done.count) of \(daysInMonth) days"))
    }
}

/// A day: a ring until revealed, then filled in its paper's glow when done; a missed day stays a ring.
private struct MonthDot: View {
    let filled: Bool
    let revealed: Bool
    let delay: Double
    let paper: HermexPaper
    var size: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let on = filled && revealed
        // Every day starts as the same small ring; a done day grows and fills, a missed one stays small.
        Circle()
            .fill(on ? paper.glow : Color.clear)
            .overlay(Circle().strokeBorder(paper.glow.opacity(on ? 0 : 0.3), lineWidth: 1))
            .frame(width: size, height: size)
            .scaleEffect(on ? 1 : 0.72)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6).delay(delay), value: revealed)
    }
}

// MARK: Insight

/// One thing Atlas noticed across the month's weeks, days, and cards, on the paper of what it's
/// about: a headline, a sentence, then its proof (a number rolling up, the days it touched, or his
/// own words, quoted).
struct MonthInsightCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var revealed = false

    var body: some View {
        let month = card.month
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "")
                .font(AppFont.display(style: .largeTitle, weight: .bold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, clearance)
                .accessibilityAddTraits(.isHeader)
            if let body = WeekLastIntentionCard.nonBlank(card.body) {
                Text(verbatim: body)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            if let stat = month?.stat {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        MonthCountUp(value: stat.value, revealed: revealed, delay: 0.15)
                            .font(AppFont.display(style: .largeTitle, weight: .heavy))
                            .foregroundStyle(palette.ink)
                        if let of = stat.of {
                            Text(verbatim: "of \(of)")
                                .font(AppFont.display(style: .title2, weight: .semibold))
                                .foregroundStyle(palette.ink)
                        }
                    }
                    Text(verbatim: stat.label)
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, 24)
            }
            if let month, !month.days.isEmpty {
                MonthDayStrip(days: Set(month.days), marked: Set(month.marked), count: month.daysInMonth ?? 31,
                              revealed: revealed, paper: palette.colors)
                    .padding(.top, 16)
            }
            if let tiles = month?.tiles, !tiles.isEmpty {
                MonthHighlights(tiles: tiles, palette: palette, revealed: revealed).padding(.top, 22)
            }
            if let snippets = month?.snippets, !snippets.isEmpty {
                MonthSnippets(snippets: snippets, palette: palette, revealed: revealed, delay: 0.5).padding(.top, 24)
            }
            if let advisors = month?.advisors, !advisors.isEmpty {
                MonthAdvisors(notes: advisors, palette: palette).padding(.top, 22)
            }
            if let library = month?.library, !library.isEmpty {
                MonthLibrary(quotes: library, palette: palette).padding(.top, 22)
            }
            DeckFootnote(card: card, palette: palette)
        }
        .monthReveal(card, viewModel, $revealed)
    }
}

/// The month's days in one line: a day the insight touched fills in, a marked day keeps a ring.
struct MonthDayStrip: View {
    let days: Set<Int>
    let marked: Set<Int>
    let count: Int
    let revealed: Bool
    let paper: HermexPaper

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(1...max(1, count), id: \.self) { day in
                    let on = days.contains(day) && revealed
                    Circle()
                        .fill(on ? paper.glow : Color.clear)
                        .overlay(Circle().strokeBorder(paper.glow.opacity(marked.contains(day) ? 0.9 : on ? 0 : 0.28),
                                                       lineWidth: marked.contains(day) ? 1.5 : 1))
                        .frame(width: 7, height: 7)
                        .frame(maxWidth: .infinity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2).delay(0.3 + Double(day) * 0.025),
                                   value: revealed)
                }
            }
            HStack {
                Text(verbatim: "1")
                Spacer()
                Text(verbatim: "\(count)")
            }
            .font(AppFont.caption2(weight: .medium))
            .foregroundStyle(Color.hxTextSecondary)
        }
        .accessibilityHidden(true)
    }
}

// MARK: Value scores

/// A monthly value card's weekly scores, one stop per week: the score where the week has one.
struct MonthWeekScores: View {
    let scores: [Int?]
    let palette: DeckPalette

    @ScaledMetric(relativeTo: .body) private var stop: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Your weekly scores")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
            HStack(spacing: 8) {
                ForEach(Array(scores.enumerated()), id: \.offset) { _, score in
                    ZStack {
                        Circle().fill(score == nil ? Color.clear : palette.colors.wash)
                        Circle().strokeBorder(palette.ink.opacity(score == nil ? 0.3 : 0),
                                              style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        Text(verbatim: score.map(String.init) ?? "–")
                            .font(AppFont.footnote(weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(score == nil ? Color.hxTextSecondary : palette.ink)
                    }
                    .frame(width: stop, height: stop)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Weekly scores: " + scores.map { $0.map(String.init) ?? "none" }.joined(separator: ", ")))
    }
}

// MARK: The week

/// A weekly cover's days, one row each: the day, its line, and its value in that value's paper. A star
/// marks a real moment of the week (filed as `lists["stars"]`); the month's cover draws from the stars.
struct MonthDayRows: View {
    let card: DeckCard
    let days: [DeckMonth.DayLine]
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel
    let revealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let stars = viewModel.answer(for: card)?.lists?["stars"] ?? []
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "Star the moments that mattered")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.bottom, 6)
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                if index > 0 { WeekHairline(palette: palette) }
                row(day, starred: stars.contains(day.day), stars: stars)
                    .opacity(revealed ? 1 : 0.35)
                    .offset(y: revealed ? 0 : 12)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3).delay(0.15 + Double(index) * 0.06), value: revealed)
            }
        }
    }

    private func row(_ day: DeckMonth.DayLine, starred: Bool, stars: [String]) -> some View {
        Button {
            let next = starred ? stars.filter { $0 != day.day } : stars + [day.day]
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6)) {
                viewModel.setList("stars", next, for: card)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: day.day)
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .frame(minWidth: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: day.line)
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let value = day.value, let name = WeekValues.shortName(value) {
                        HXChip(paper: MonthValues.paper(value), label: name)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: starred ? "star.fill" : "star")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(starred ? palette.ink : palette.ink.opacity(0.45))
                    .scaleEffect(starred ? 1.15 : 1)
                    .frame(minWidth: 32, minHeight: 32)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(day.day), \(day.line)"))
        .accessibilityValue(Text(verbatim: starred ? "Starred" : "Not starred"))
        .accessibilityHint(Text(verbatim: starred ? "Removes the star" : "Stars this moment"))
    }
}

/// The week in dots: one row per habit, a dot per day under the weekday letters, and its count.
struct MonthWeekDots: View {
    let rows: [DeckMonth.DotRow]
    let labels: [String]
    let revealed: Bool
    let paper: HermexPaper

    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 16

    var body: some View {
        let letters = labels.count == 7 ? labels : ["M", "T", "W", "T", "F", "S", "S"]
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 96, height: 1)
                ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                    Text(verbatim: letter)
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(maxWidth: .infinity)
                }
                Color.clear.frame(width: 26, height: 1)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let done = Set(row.days)
                HStack(spacing: 0) {
                    Text(verbatim: row.label)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 96, alignment: .leading)
                    ForEach(1...7, id: \.self) { day in
                        MonthDot(filled: done.contains(day), revealed: revealed,
                                 delay: Double(index) * 0.08 + Double(day) * 0.06, paper: paper, size: dot)
                            .frame(maxWidth: .infinity)
                    }
                    MonthCountUp(value: done.count, revealed: revealed, delay: 0.3 + Double(index) * 0.08)
                        .font(AppFont.subheadline(weight: .bold))
                        .foregroundStyle(paper.glow)
                        .frame(width: 26, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(row.label), \(done.count) of 7 days"))
            }
        }
    }
}


/// The letter he sealed this week a year ago: a sealed envelope until tapped, then his words.
struct MonthLetterFromPast: View {
    let note: DeckPastNote
    let palette: DeckPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen = false

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8)) { isOpen.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: isOpen ? "envelope.open" : "envelope.fill")
                        .font(AppFont.title3(weight: .semibold))
                        .foregroundStyle(palette.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "A letter from a year ago")
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: isOpen ? (note.title ?? "You wrote this a year ago") : "Sealed a year ago · tap to open")
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    Spacer(minLength: 0)
                }
                if isOpen {
                    Text(verbatim: note.text)
                        .font(AppFont.serif(style: .body))
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowSurface(palette.colors, cornerRadius: HXRadius.md, opaque: true)
            .contentShape(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: isOpen ? "A letter from a year ago: \(note.text)" : "A sealed letter from a year ago"))
        .accessibilityHint(Text(verbatim: isOpen ? "Closes the letter" : "Opens the letter"))
    }
}
