import SwiftUI

// The monthly review's sleep, question, and close cards, and the pieces its cards share: his own
// words behind a card, his advisors' read, and the month's highlights as tiles.

// MARK: Shared pieces

/// "In your words": the journal lines and answers behind a card, in the saved-words serif, each with
/// its day and what it answered. They rise in one after another when the card is revealed.
struct MonthSnippets: View {
    var title = "In your words"
    let snippets: [DeckMonth.Snippet]
    let palette: DeckPalette
    let revealed: Bool
    var delay: Double = 0.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)
            ForEach(Array(snippets.enumerated()), id: \.offset) { index, snippet in
                VStack(alignment: .leading, spacing: 5) {
                    if index > 0 { WeekHairline(palette: palette).padding(.bottom, 10) }
                    Text(verbatim: "\u{201C}\(snippet.text)\u{201D}")
                        .font(AppFont.serif(style: .body))
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = Self.source(snippet) {
                        Text(verbatim: line)
                            .font(AppFont.caption(weight: .medium))
                            .foregroundStyle(Color.hxTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, index > 0 ? 0 : 10)
                .padding(.bottom, 10)
                .accessibilityElement(children: .combine)
                .opacity(revealed ? 1 : 0.35)
                .offset(y: revealed ? 0 : 10)
                .animation(HXMotion.reveal(reduceMotion: reduceMotion, delay: min(delay, 0.25) + Double(index) * HXMotion.rowStagger), value: revealed)
            }
        }
    }

    /// "Oct 22 · asked: What is one thing…", or just the day.
    static func source(_ snippet: DeckMonth.Snippet) -> String? {
        let asked = snippet.asked.flatMap { WeekLastIntentionCard.nonBlank($0) }.map { "on \u{201C}\($0)\u{201D}" }
        let parts = [snippet.day, asked].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// "From your advisors": each advisor's read in a line, under their monogram and lens.
struct MonthAdvisors: View {
    var title = "From your advisors"
    let notes: [DeckMonth.AdvisorNote]
    let palette: DeckPalette

    @ScaledMetric(relativeTo: .body) private var monogram: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: Self.initials(note.name))
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(palette.ink)
                        .frame(width: monogram, height: monogram)
                        .background(palette.colors.wash, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: note.name)
                            .font(AppFont.footnote(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: note.text)
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// The month's highlights as tiles, two to a row: a number that rolls up (or a few words), what it
/// was, and when. They pop in one after another.
struct MonthHighlights: View {
    let tiles: [DeckMonth.Tile]
    let palette: DeckPalette
    let revealed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .topLeading),
                            GridItem(.flexible(), spacing: 10, alignment: .topLeading)], alignment: .leading, spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                tileView(tile, delay: 0.1 + Double(index) * HXMotion.rowStagger)
                    .scaleEffect(revealed ? 1 : 0.9)
                    .opacity(revealed ? 1 : 0.35)
                    .animation(HXMotion.pop(reduceMotion: reduceMotion, delay: 0.1 + Double(index) * HXMotion.rowStagger),
                               value: revealed)
            }
        }
    }

    private func tileView(_ tile: DeckMonth.Tile, delay: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let value = tile.value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    MonthCountUp(value: value, revealed: revealed, delay: delay)
                    if let unit = tile.unit { Text(verbatim: unit).font(AppFont.headline()) }
                }
                .font(AppFont.display(style: .title, weight: .bold))
                .foregroundStyle(palette.ink)
            } else if let text = tile.text {
                Text(verbatim: text)
                    .font(AppFont.display(style: .title3, weight: .bold))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: tile.label)
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let day = tile.day {
                Text(verbatim: day)
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "From your second brain": quotes and highlights he saved that speak to the card, each in the
/// saved-words serif with where it's from.
struct MonthLibrary: View {
    let quotes: [DeckMonth.LibraryQuote]
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(verbatim: "From your second brain")
            } icon: {
                Image(systemName: "books.vertical")
            }
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(palette.ink)
            .accessibilityAddTraits(.isHeader)
            ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\u{201C}\(quote.text)\u{201D}")
                        .font(AppFont.serif(style: .body).italic())
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let source = quote.source {
                        Text(verbatim: source)
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(palette.ink)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// "What kept coming up": the month's themes from his entries, each a few words in the card's ink
/// over a line on where it showed, rising in one after another.
struct MonthThemes: View {
    var title = "What kept coming up"
    let themes: [DeckMonth.Theme]
    let palette: DeckPalette
    let revealed: Bool
    var delay: Double = 0.15

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(themes.enumerated()), id: \.offset) { index, theme in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: theme.title)
                        .font(AppFont.display(style: .title3, weight: .bold))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = theme.line {
                        Text(verbatim: line)
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                .accessibilityElement(children: .combine)
                .opacity(revealed ? 1 : 0.35)
                .offset(y: revealed ? 0 : 10)
                .animation(HXMotion.reveal(reduceMotion: reduceMotion, delay: min(delay, 0.2) + Double(index) * HXMotion.rowStagger), value: revealed)
            }
        }
    }
}

// MARK: Value

/// A value's month, read only: the value as the title, the themes his entries kept returning to,
/// one advisor's read of them, the weekly scores, and his own words.
struct MonthValueCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var revealed = false

    var body: some View {
        let month = card.month
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.name ?? WeekValues.shortName(card.valueID ?? "") ?? "")
                .font(AppFont.display(style: .largeTitle, weight: .bold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, clearance)
                .accessibilityAddTraits(.isHeader)
            if month?.scored == true, month?.inputFirst == true { scoreRow.padding(.top, 16) }
            if let stat = month?.stat {
                // Becoming a dad carries the letters: how many, and the days written.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MonthCountUp(value: stat.value, revealed: revealed, delay: 0.1)
                        .font(AppFont.display(style: .largeTitle, weight: .heavy))
                        .foregroundStyle(palette.ink)
                    Text(verbatim: stat.label)
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, 14)
                if let month, !month.days.isEmpty {
                    MonthDayStrip(days: Set(month.days), marked: [], count: month.daysInMonth ?? 31,
                                  revealed: revealed, paper: palette.colors)
                        .padding(.top, 10)
                }
            }
            if let themes = month?.themes, !themes.isEmpty {
                MonthThemes(themes: themes, palette: palette, revealed: revealed).padding(.top, 20)
            }
            if let advisors = month?.advisors, !advisors.isEmpty {
                MonthAdvisors(title: advisors.count == 1 ? "Your advisor's read" : "From your advisors",
                              notes: advisors, palette: palette)
                    .padding(.top, 22)
            }
            if let scores = month?.weekScores, scores.contains(where: { $0 != nil }) {
                MonthWeekScores(scores: scores, palette: palette).padding(.top, 22)
            }
            if let snippets = month?.snippets, !snippets.isEmpty {
                MonthSnippets(snippets: snippets, palette: palette, revealed: revealed, delay: 0.7).padding(.top, 22)
            }
            if let library = month?.library, !library.isEmpty {
                MonthLibrary(quotes: library, palette: palette).padding(.top, 22)
            }
            if month?.scored == true, month?.inputFirst != true { scoreRow.padding(.top, 24) }
        }
        .monthReveal(card, viewModel, $revealed)
    }

    /// The weekly review's 1–10 for the value; the monthly's value cards are read only.
    private var scoreRow: some View {
        let valueID = card.valueID ?? card.id
        return WeekScoreRow(title: "How you lived it this week", score: viewModel.answer(for: card)?.scores?[valueID],
                            palette: palette) { viewModel.setScore(valueID, $0, for: card) }
    }
}

// MARK: Sleep

/// The month's sleep, read like a monthly check-up: the average score against last month, every
/// night as a dot by how it scored, HRV status night by night, the month's numbers as tiles, the
/// sleep coach's read, and his own words about being tired.
struct MonthSleepCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 20
    @State private var revealed = false

    var body: some View {
        let month = card.month
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "Your sleep")
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
            if let month, !month.rows.isEmpty, month.daysInMonth == 7 {
                MonthWeekDots(rows: month.rows, labels: month.labels, revealed: revealed, paper: palette.colors)
                    .padding(.top, 20)
                ForEach(month.pips) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: row.label)
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        Spacer()
                        MonthCountUp(value: row.count, revealed: revealed, delay: 0.3)
                            .font(AppFont.subheadline(weight: .bold))
                            .foregroundStyle(palette.ink)
                    }
                    .padding(.top, 12)
                    .accessibilityElement(children: .combine)
                }
                Text(verbatim: "Sleep")
                    .font(AppFont.title3(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, 26)
            }
            if let sleep = month?.sleep {
                score(sleep).padding(.top, 14)
                nights(sleep, firstWeekday: month?.firstWeekday ?? 0, count: month?.daysInMonth ?? 31).padding(.top, 18)
                hrv(sleep, count: month?.daysInMonth ?? 31).padding(.top, 20)
                tiles(sleep.tiles).padding(.top, 20)
                if let coach = sleep.coach {
                    MonthAdvisors(title: "Your sleep coach", notes: [coach], palette: palette).padding(.top, 22)
                }
            }
            if let snippets = month?.snippets, !snippets.isEmpty {
                MonthSnippets(snippets: snippets, palette: palette, revealed: revealed, delay: 0.2).padding(.top, 22)
            }
            if let library = month?.library, !library.isEmpty {
                MonthLibrary(quotes: library, palette: palette).padding(.top, 22)
            }
        }
        .monthReveal(card, viewModel, $revealed)
    }

    private func score(_ sleep: DeckMonth.Sleep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            MonthCountUp(value: sleep.score, revealed: revealed, delay: 0.1)
                .font(AppFont.display(style: .largeTitle, weight: .heavy))
                .foregroundStyle(palette.ink)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "average sleep score")
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(Color.hxTextPrimary)
                if let delta = sleep.delta {
                    Text(verbatim: delta == 0 ? "same as last \(span)" : "\(delta > 0 ? "+" : "−")\(abs(delta)) on last \(span)")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// A week's calendar runs Monday to Sunday (the deck's `labels`); a month's Sunday to Saturday.
    private var isWeek: Bool { card.month?.labels.count == 7 }
    private var span: String { isWeek ? "week" : "month" }
    private var columnLetters: [String] { isWeek ? card.month?.labels ?? [] : ["S", "M", "T", "W", "T", "F", "S"] }

    /// The HRV strip's ends: "Mon" and "Sun" for a week, the month's first and last day for a month.
    private var stripEnds: (String, String) {
        if isWeek { return ("Mon", "Sun") }
        let month = DailyDeckPaths.date(day: viewModel.date)?.formatted(.dateTime.month(.abbreviated)) ?? ""
        return ("\(month) 1", "\(month) \(card.month?.daysInMonth ?? 31)")
    }

    /// The month as a calendar of nights: full for 80+, half for the 70s, a ring under 70.
    private func nights(_ sleep: DeckMonth.Sleep, firstWeekday: Int, count: Int) -> some View {
        let tiers = Dictionary(sleep.nights.map { ($0.day, $0.tier) }, uniquingKeysWith: { a, _ in a })
        let cells: [Int?] = Array(repeating: nil, count: max(0, min(6, firstWeekday))) + (1...max(1, count)).map { $0 }
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(columnLetters.enumerated()), id: \.offset) { _, letter in
                    Text(verbatim: letter)
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
            VStack(spacing: dot * 0.6) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { column in
                            Group {
                                if column < week.count, let day = week[column] {
                                    TierDot(tier: tiers[day], revealed: revealed, delay: 0.3 + Double(day) * 0.025,
                                            paper: palette.colors, size: dot)
                                } else {
                                    Color.clear.frame(width: dot, height: dot)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                legend("good", "80+")
                legend("fair", "70s")
                legend("rough", "under 70")
            }
            .font(AppFont.caption(weight: .medium))
            .foregroundStyle(Color.hxTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Nights: \(sleep.nights.filter { $0.tier == "good" }.count) scored 80 or more, "
            + "\(sleep.nights.filter { $0.tier == "fair" }.count) in the 70s, \(sleep.nights.filter { $0.tier == "rough" }.count) under 70"))
    }

    private func legend(_ tier: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            TierDot(tier: tier, revealed: true, delay: 0, paper: palette.colors, size: 9)
            Text(verbatim: label)
        }
    }

    /// HRV night by night: full when balanced, half when unbalanced, a ring when low.
    private func hrv(_ sleep: DeckMonth.Sleep, count: Int) -> some View {
        let status = Dictionary(sleep.hrv.map { ($0.day, $0.tier) }, uniquingKeysWith: { a, _ in a })
        let tier: (Int) -> String? = { day in
            switch status[day] {
            case "balanced": "good"
            case "unbalanced": "fair"
            case "low": "rough"
            default: nil
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "HRV, night by night")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            HStack(spacing: 0) {
                ForEach(1...max(1, count), id: \.self) { day in
                    TierDot(tier: tier(day), revealed: revealed, delay: 0.9 + Double(day) * 0.02, paper: palette.colors, size: 7)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text(verbatim: stripEnds.0)
                Spacer()
                Text(verbatim: stripEnds.1)
            }
            .font(AppFont.caption2(weight: .medium))
            .foregroundStyle(Color.hxTextSecondary)
            HStack(spacing: 14) {
                legend("good", "balanced")
                legend("fair", "unbalanced")
                legend("rough", "low")
            }
            .font(AppFont.caption(weight: .medium))
            .foregroundStyle(Color.hxTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "HRV: \(sleep.hrv.filter { $0.tier == "balanced" }.count) balanced nights"))
    }

    private func tiles(_ tiles: [DeckMonth.Sleep.NumberTile]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .topLeading),
                            GridItem(.flexible(), spacing: 10, alignment: .topLeading)], alignment: .leading, spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tile.label)
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Text(verbatim: tile.value)
                        .font(AppFont.display(style: .title3, weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    if let note = tile.note {
                        Text(verbatim: note)
                            .font(AppFont.caption())
                            .foregroundStyle(Color.hxTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A night or a day by tier: `good` full, `fair` half-strength, `rough` a ring, none a faint dot.
private struct TierDot: View {
    let tier: String?
    let revealed: Bool
    let delay: Double
    let paper: HermexPaper
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = revealed ? tier : nil
        Circle()
            .fill(shown == "good" ? paper.glow : shown == "fair" ? paper.glow.opacity(0.45) : Color.clear)
            .overlay(Circle().strokeBorder(paper.glow.opacity(shown == "rough" ? 0.9 : shown == nil ? 0.25 : 0),
                                           lineWidth: shown == "rough" ? 1.5 : 1))
            .frame(width: size, height: size)
            .scaleEffect(tier == nil ? 0.5 : shown == nil ? 0.72 : 1)
            .animation(HXMotion.pop(reduceMotion: reduceMotion, delay: delay), value: revealed)
    }
}

// MARK: Question

/// A reflection question with what led to it: the month's highlights, his own words, and his
/// advisors' read first, then the question and his answer.
struct MonthQuestionCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var revealed = false
    @State private var isEditing = false

    var body: some View {
        let month = card.month
        let answer = viewModel.answer(for: card)?.text ?? ""
        VStack(alignment: .leading, spacing: 0) {
            if let title = card.title {
                // The same header as the month's insight and sleep cards.
                Text(verbatim: title)
                    .font(AppFont.display(style: .largeTitle, weight: .bold))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, clearance)
                    .padding(.bottom, 18)
                    .accessibilityAddTraits(.isHeader)
            }
            if month?.inputFirst == true {
                answerBlock(answer).padding(.bottom, 24)
            }
            if let tiles = month?.tiles, !tiles.isEmpty {
                MonthHighlights(tiles: tiles, palette: palette, revealed: revealed).padding(.bottom, 20)
            }
            if let themes = month?.themes, !themes.isEmpty {
                MonthThemes(themes: themes, palette: palette, revealed: revealed,
                            delay: month?.tiles.isEmpty == false ? 0.6 : 0.15)
                    .padding(.bottom, 22)
            }
            if let advisors = month?.advisors, !advisors.isEmpty {
                MonthAdvisors(notes: advisors, palette: palette).padding(.bottom, 22)
            }
            if let snippets = month?.snippets, !snippets.isEmpty {
                MonthSnippets(snippets: snippets, palette: palette, revealed: revealed, delay: 0.9)
                    .padding(.bottom, 18)
            }
            if let library = month?.library, !library.isEmpty {
                MonthLibrary(quotes: library, palette: palette).padding(.bottom, 22)
            }
            if month?.inputFirst != true { answerBlock(answer) }
        }
        .monthReveal(card, viewModel, $revealed)
        .sheet(isPresented: $isEditing) {
            WeekEditorSheet(title: card.title ?? "Reflect", subtitle: card.question, placeholder: "In your words", serif: true,
                            palette: palette, initial: answer) { viewModel.setText($0, for: card) }
        }
    }

    private func answerBlock(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            WeekCardHeading(title: card.question ?? "", palette: palette)
            WeekWordsBox(text: answer, placeholder: "In your words", palette: palette) { isEditing = true }
        }
    }
}

// MARK: Close

/// The month's close: the year as a ring of twelve months, drawn round to this one, which lights up
/// with its title in the middle; then how many answers wait to be filed.
struct MonthCloseHero: View {
    let month: DeckMonth
    let title: String?
    let palette: DeckPalette
    let answered: Int
    let filed: Bool
    /// Whether the close is the card on top; the ring draws only once he reaches it.
    let isOnTop: Bool
    /// Moments he starred this week (the weekly cover's `lists["stars"]`).
    var stars = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var ring: CGFloat = 250
    @State private var drawn = false

    private var current: Int? { month.months.lastIndex { $0.title != nil } }

    /// "3 moments starred · 7 answers to keep", leaving out what's zero.
    private var summary: String {
        let answers = max(0, answered - (stars > 0 ? 1 : 0))
        let parts = [stars > 0 ? "\(stars) \(stars == 1 ? "moment" : "moments") starred" : nil,
                     answers > 0 ? "\(answers) \(answers == 1 ? "answer" : "answers") to keep" : nil].compactMap { $0 }
        return parts.isEmpty ? "Nothing written yet." : parts.joined(separator: " · ")
    }

    var body: some View {
        let count = max(1, month.months.count)
        let reach = Double((current ?? -1) + 1) / Double(count)
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .stroke(palette.colors.wash, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: drawn ? reach : 0)
                    .stroke(palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                ForEach(Array(month.months.enumerated()), id: \.element.id) { index, item in
                    let angle = Angle.degrees(Double(index) / Double(count) * 360 - 90)
                    let isCurrent = index == current
                    let r = ring / 2
                    ZStack {
                        if isCurrent {
                            Circle().fill(palette.colors.wash).frame(width: 40, height: 40)
                                .scaleEffect(drawn ? 1 : 0.2)
                        }
                        Circle()
                            .fill(item.title != nil ? palette.ink : palette.paper)
                            .overlay(Circle().strokeBorder(palette.ink.opacity(item.title != nil ? 0 : 0.35), lineWidth: 1))
                            .frame(width: isCurrent ? 16 : (count > 12 ? 6 : 9), height: isCurrent ? 16 : (count > 12 ? 6 : 9))
                            .scaleEffect(isCurrent && !drawn ? 0.2 : 1)
                    }
                    .offset(x: cos(angle.radians) * r, y: sin(angle.radians) * r)
                    // A ring of weeks labels only the first week of each month.
                    Text(verbatim: String(item.month.prefix(month.months.count > 12 ? 3 : 1)))
                        .font(AppFont.caption2(weight: isCurrent ? .bold : .medium))
                        .foregroundStyle(isCurrent ? palette.ink : Color.hxTextSecondary)
                        .offset(x: cos(angle.radians) * (r + 22), y: sin(angle.radians) * (r + 22))
                }
                VStack(spacing: 6) {
                    Text(verbatim: month.name ?? current.map { month.months[$0].month } ?? "")
                        .font(AppFont.display(style: .largeTitle, weight: .bold))
                        .foregroundStyle(palette.ink)
                    if let title {
                        Text(verbatim: title)
                            .font(AppFont.serif(style: .title3).italic())
                            .foregroundStyle(Color.hxTextPrimary)
                            .multilineTextAlignment(.center)
                    }
                    if let year = month.year {
                        Text(verbatim: String(year))
                            .font(AppFont.footnote(weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
                .frame(width: ring * 0.7)
                .opacity(drawn ? 1 : 0)
            }
            .frame(width: ring, height: ring)
            .padding(.vertical, 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(month.name ?? "This month"), \(title ?? ""), in your year"))
            Text(verbatim: filed ? "Sealed. \(month.name ?? "This month") is part of your year now." : summary)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(Color.hxTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !drawn else { return }
            withAnimation(HXMotion.draw(reduceMotion: reduceMotion, delay: 0.25)) { drawn = true }
        }
    }
}
