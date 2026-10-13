import Charts
import SwiftUI

/// One card of the Daily Deck stack, a glow card in its kind's paper (`DeckPalette`). A card
/// leads with its takeaway in large rounded type (serif when it quotes your saved words) and
/// scrolls into the rest: context, the question, and your reflection. Writing happens in `ReflectionSheet`, so a card never holds a text
/// field and long text never fights the swipe.
struct DeckPageView: View {
    let page: DeckPage
    let viewModel: DailyDeckViewModel
    let file: () -> Void
    /// Cards under the top one show only their paper; their words fade in as they rise.
    var contentOpacity: Double = 1

    static let shape = RoundedRectangle(cornerRadius: HXRadius.xl, style: .continuous)

    var body: some View {
        let palette = DeckPalette.of(page)
        Group {
            switch page {
            case .card(let card):
                DeckCardView(card: card, palette: palette, viewModel: viewModel, file: file)
            case .followUps(let cards):
                FollowUpsPage(cards: cards, viewModel: viewModel)
            }
        }
        .opacity(contentOpacity)
        .background(palette.paper, in: Self.shape)
        .overlay(Self.shape.strokeBorder(palette.edge, lineWidth: 0.5))
        .clipShape(Self.shape)
        .hxShadow(.paper)
        .padding(.vertical, 12)
    }
}

/// A single card: lead, attribution, detail, question, reflection.
private struct DeckCardView: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel
    let file: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by the Daily Deck when the server takes labels.
    @Environment(LabelsViewModel.self) private var labels: LabelsViewModel?
    @State private var isWriting = false
    @State private var overflows = false
    /// The sleep card's numbers, shown before rating when asked for.
    @State private var showsNumbers = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch card.type {
                case .headline: opener
                case .close: close
                case .sleep: sleep
                default: reading
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.contentOffset.y > geometry.containerSize.height + 8
        } action: { _, more in
            overflows = more
        }
        .overlay(alignment: .bottom) { moreHint }
        .overlay(alignment: .topTrailing) {
            Image(systemName: palette.symbol)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(palette.ink.opacity(0.35))
                .padding(18)
                .accessibilityHidden(true)
        }
        .foregroundStyle(palette.ink)
        .tint(palette.ink)
        .sheet(isPresented: $isWriting) {
            ReflectionSheet(card: card, palette: palette, viewModel: viewModel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: palette.name))
    }

    // MARK: Reading cards

    @ViewBuilder
    private var reading: some View {
        let text = DeckCardText(card)
        if card.itemKind == "quote" {
            Image(systemName: "quote.opening")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.22))
                .padding(.bottom, 10)
                .accessibilityHidden(true)
        }
        if let lead = text.lead {
            Text(inlineMarkdown(lead))
                .font(DeckCardText.leadFont(for: card, lead: lead))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 30)
                .textSelection(.enabled)
        }
        if let attribution = text.attribution {
            Text(verbatim: attribution)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(palette.ink)
                .padding(.top, 12)
        }
        if let detail = text.detail {
            Text(inlineMarkdown(detail))
                .font(AppFont.body())
                .lineSpacing(4)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .textSelection(.enabled)
        }
        if !card.points.isEmpty {
            MoodChart(points: card.points, palette: palette).padding(.top, 22)
        }
        if !card.meters.isEmpty {
            GoalMeters(meters: card.meters, palette: palette).padding(.top, 22)
        }
        if !card.entries.isEmpty {
            RecapList(entries: card.entries, palette: palette).padding(.top, 22)
        }
        if !text.leadIsQuestion, let question = viewModel.question(for: card) {
            Text(verbatim: question)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
                .id(question)
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        }
        if card.takesText { reflection().padding(.top, 16) }
        if let reason = card.reason {
            Text(verbatim: reason)
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
        }
        if card.type == .reflect, let labels {
            DeckRateRows(card: card, date: viewModel.date, kind: viewModel.kind,
                         showsQuestion: viewModel.question(for: card) == card.question,
                         labels: labels, palette: palette)
                .padding(.top, 24)
        }
    }

    /// Your words once written; until then, the way in.
    @ViewBuilder
    private func reflection(_ invitation: String = "Write a reflection") -> some View {
        if let text = viewModel.answer(for: card)?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button { isWriting = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: text)
                        .font(AppFont.body())
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Label { Text(verbatim: "Edit") } icon: { Image(systemName: "pencil") }
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Your reflection: \(text). Edit"))
        } else {
            Button { isWriting = true } label: {
                Label { Text(verbatim: invitation) } icon: { Image(systemName: "square.and.pencil") }
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(palette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Sleep

    /// Rate the night first, then last night's numbers: shown once rated (or when asked for) so
    /// they don't decide the rating. A note is optional.
    @ViewBuilder
    private var sleep: some View {
        let rating = viewModel.answer(for: card)?.rating
        Text(verbatim: card.question ?? "How did you sleep?")
            .font(AppFont.display(style: .title2, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 30)
        FlowRow(spacing: 8) {
            ForEach(Array(card.scale.enumerated()), id: \.offset) { index, label in
                ChoiceButton(title: label, isSelected: rating == index + 1) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { viewModel.rate(index + 1, for: card) }
                }
            }
        }
        .padding(.top, 18)
        if let numbers = card.sleep {
            if rating != nil || showsNumbers {
                SleepNumbers(sleep: numbers, palette: palette)
                    .padding(.top, 26)
                    .transition(.opacity)
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsNumbers = true }
                } label: {
                    Label { Text(verbatim: "Show last night") } icon: { Image(systemName: "chart.bar") }
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
                .buttonStyle(.plain)
                .padding(.top, 22)
            }
        }
        reflection("Add a note").padding(.top, 24)
        if let reason = card.reason {
            Text(verbatim: reason)
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
        }
    }

    /// A soft fade and arrow while there is more card below.
    @ViewBuilder
    private var moreHint: some View {
        if overflows {
            LinearGradient(colors: [palette.paper.opacity(0), palette.paper], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .overlay(alignment: .bottom) {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.45))
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    // MARK: Opener and close

    /// The day's title, a line about yesterday, and the cards ahead, so you know what you're
    /// about to get.
    @ViewBuilder
    private var opener: some View {
        if card.stats.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.lines, id: \.self) { line in
                    Text(verbatim: line).font(AppFont.footnote())
                }
            }
            .foregroundStyle(palette.ink)
            .padding(.trailing, 24)
        }
        Text(verbatim: card.title ?? "Today")
            .font(AppFont.display(style: .largeTitle, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, card.stats.isEmpty ? 10 : 0)
            .padding(.trailing, card.stats.isEmpty ? 0 : 24)
        if let recap = card.recap {
            (Text("Yesterday").font(AppFont.display(style: .subheadline, weight: .semibold))
                + Text(verbatim: " · \(recap)").font(AppFont.subheadline()).foregroundStyle(Color.hxTextPrimary.opacity(0.85)))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        if !card.stats.isEmpty {
            StatGrid(stats: card.stats, palette: palette).padding(.top, 22)
        }
        let ahead = viewModel.visiblePages.dropFirst().filter {
            if case .card(let c) = $0, c.type == .close { return false }
            return true
        }
        Text("Today · \(ahead.count) cards")
            .font(AppFont.display(style: .subheadline, weight: .semibold))
            .padding(.top, 26)
            .padding(.bottom, 6)
        VStack(spacing: 0) {
            ForEach(Array(ahead.enumerated()), id: \.element.id) { _, page in
                DeckAheadRow(page: page)
            }
        }
        Text(verbatim: "Swipe to begin")
            .font(AppFont.footnote())
            .foregroundStyle(palette.ink)
            .padding(.top, 16)
    }

    @ViewBuilder
    private var close: some View {
        let count = viewModel.answeredCount
        let filed = viewModel.isFiled && !viewModel.hasChanges
        Text(verbatim: filed ? "Filed" : count == 1 ? "1 reflection" : "\(count) reflections")
            .font(AppFont.display(style: .largeTitle, weight: .semibold))
        Text(verbatim: filed
             ? "In your journal. Edit any card and file again to update it."
             : viewModel.isFiled
             ? "Filing again updates the journal: changed answers replace what was filed, new ones are added, nothing is deleted."
             : count == 0
             ? "Nothing written yet. Swipe back to any card, or file the follow-ups you chose."
             : "Atlas writes them into today's journal and runs the follow-ups you chose.")
            .font(AppFont.body())
            .foregroundStyle(Color.hxTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        if case .failed(let message) = viewModel.filing {
            Text(verbatim: message).font(AppFont.footnote()).foregroundStyle(Color.hxDanger).padding(.top, 12)
        }
        Button(action: file) {
            HStack {
                if viewModel.filing == .filing { ProgressView().tint(palette.onInk) }
                Text(verbatim: viewModel.isFiled ? "File Changes" : "File It")
            }
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(palette.onInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(palette.ink.opacity(filed ? 0.35 : 1), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.filing == .filing || !viewModel.hasChanges)
        .padding(.top, 28)
    }
}

/// Last night in words (hours against need, then timing and recovery) over the week's strip.
private struct SleepNumbers: View {
    let sleep: DeckSleep
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let headline = sleep.headline {
                Text(verbatim: headline)
                    .font(AppFont.display(style: .title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(sleep.lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            if sleep.nights.contains(where: { $0.hours != nil }) {
                SleepStrip(nights: sleep.nights, palette: palette).padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The last seven nights as bars, last night full strength, each with a tick at that night's need.
private struct SleepStrip: View {
    let nights: [DeckNight]
    let palette: DeckPalette

    private static let height: CGFloat = 64

    var body: some View {
        let top = max(nights.compactMap { max($0.hours ?? 0, $0.need ?? 0) }.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(nights.enumerated()), id: \.offset) { index, night in
                let last = index == nights.count - 1
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        Color.clear
                        RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous)
                            .fill(palette.ink.opacity(night.hours == nil ? 0.12 : last ? 1 : 0.35))
                            .frame(height: night.hours.map { max(Self.height * $0 / top, 3) } ?? 3)
                        if let need = night.need {
                            Rectangle()
                                .fill(palette.ink.opacity(0.7))
                                .frame(height: 1.5)
                                .padding(.bottom, Self.height * need / top)
                        }
                    }
                    .frame(height: Self.height)
                    Text(verbatim: night.day)
                        .font(AppFont.caption(weight: last ? .semibold : .regular))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Last \(nights.count) nights"))
        .accessibilityValue(Text(verbatim: nights.map { night in
            "\(night.day): " + (night.hours.map { "\($0.formatted()) hours" } ?? "no data")
        }.joined(separator: ", ")))
    }
}

/// A recap's entries: each label set small and bold above its text, shown once for a run of
/// entries that share it (the items under "Career Priorities"), with hairlines between groups.
private struct RecapList: View {
    let entries: [DeckEntry]
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                let newGroup = index == 0 || entry.label != entries[index - 1].label
                if newGroup && index > 0 {
                    Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5).padding(.vertical, 14)
                }
                if newGroup, let label = entry.label {
                    Text(verbatim: label)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
                Text(Self.titled(entry.text))
                    .font(AppFont.serif(style: .body))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, newGroup ? 0 : 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Volume Increase: target 8+ applications" with its short title in bold, so a plan scans.
    static func titled(_ text: String) -> AttributedString {
        var out = inlineMarkdown(text)
        guard let colon = text.range(of: ": "),
              text.distance(from: text.startIndex, to: colon.lowerBound) <= 48,
              !text[..<colon.lowerBound].contains(where: { ".!?,".contains($0) }),
              let range = out.range(of: String(text[..<colon.lowerBound]))
        else { return out }
        out[range].inlinePresentationIntent = .stronglyEmphasized
        return out
    }
}

/// A weekly review's headline numbers, two to a row: the number large, its label under it.
private struct StatGrid: View {
    let stats: [DeckStat]
    let palette: DeckPalette

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 18) {
            ForEach(stats, id: \.self) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: stat.value)
                        .font(AppFont.serif(style: .largeTitle))
                        .monospacedDigit()
                    Text(verbatim: stat.label)
                        .font(AppFont.footnote(weight: .medium))
                        .foregroundStyle(palette.ink.opacity(0.7))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The week on one 0–10 scale: sleep hours as bars, energy (Garmin Body Battery) as a solid line,
/// mood (read from your writing) dashed. A missing reading leaves a gap. Under the chart, each
/// day's mood with the words it was read from.
private struct MoodChart: View {
    let points: [DeckPoint]
    let palette: DeckPalette

    private var hasSleep: Bool { points.contains { $0.sleep != nil } }
    private var hasEnergy: Bool { points.contains { $0.energy != nil } }
    private var hasMood: Bool { points.contains { $0.mood != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Chart {
                ForEach(points, id: \.label) { point in
                    if let hours = point.sleep {
                        BarMark(x: .value("Day", point.label), y: .value("Value", min(hours, 10)), width: .ratio(0.5))
                            .foregroundStyle(palette.ink.opacity(0.13))
                            .cornerRadius(4)
                            .accessibilityLabel(Text(verbatim: "\(point.label), sleep"))
                            .accessibilityValue(Text(verbatim: "\(hours.formatted(.number.precision(.fractionLength(0...1)))) hours"))
                    }
                }
                ForEach(points.filter { $0.energy != nil }, id: \.label) { point in
                    LineMark(x: .value("Day", point.label), y: .value("Value", point.energy ?? 0), series: .value("Kind", "Energy"))
                        .foregroundStyle(palette.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    PointMark(x: .value("Day", point.label), y: .value("Value", point.energy ?? 0))
                        .foregroundStyle(palette.ink)
                        .accessibilityLabel(Text(verbatim: "\(point.label), energy"))
                        .accessibilityValue(Text(verbatim: "\(point.energy ?? 0) of 10"))
                }
                ForEach(points.filter { $0.mood != nil }, id: \.label) { point in
                    LineMark(x: .value("Day", point.label), y: .value("Value", point.mood ?? 0), series: .value("Kind", "Mood"))
                        .foregroundStyle(palette.ink.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))
                    PointMark(x: .value("Day", point.label), y: .value("Value", point.mood ?? 0))
                        .foregroundStyle(palette.ink.opacity(0.55))
                        .symbolSize(30)
                        .accessibilityLabel(Text(verbatim: "\(point.label), mood"))
                        .accessibilityValue(Text(verbatim: "\(point.mood ?? 0) of 10"))
                }
            }
            .chartXScale(domain: points.map(\.label))
            .chartYScale(domain: 0...10)
            .chartYAxis {
                AxisMarks(values: [0, 5, 10]) { _ in
                    AxisGridLine().foregroundStyle(palette.ink.opacity(0.12))
                    AxisValueLabel().foregroundStyle(palette.ink.opacity(0.6))
                }
            }
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().foregroundStyle(palette.ink.opacity(0.7)) }
            }
            .frame(height: 180)
            HStack(spacing: 14) {
                if hasEnergy { legend("Energy", line: []) }
                if hasMood { legend("Mood", line: [4, 4]) }
                if hasSleep {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(palette.ink.opacity(0.13)).frame(width: 10, height: 12)
                        Text(verbatim: "Sleep (h)")
                    }
                }
            }
            .font(AppFont.footnote(weight: .medium))
            .foregroundStyle(palette.ink.opacity(0.7))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(points.filter { $0.mood != nil && !($0.quote ?? "").isEmpty }, id: \.label) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: point.label)
                            .font(AppFont.footnote(weight: .semibold))
                            .foregroundStyle(palette.ink.opacity(0.7))
                            .frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: [point.mood.map { "Mood \($0)" }, point.note].compactMap { $0 }
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(AppFont.subheadline(weight: .medium))
                            Text(verbatim: "“\(point.quote ?? "")”")
                                .font(AppFont.serif(style: .subheadline))
                                .foregroundStyle(palette.ink.opacity(0.75))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func legend(_ name: String, line dash: [CGFloat]) -> some View {
        HStack(spacing: 6) {
            Path { $0.move(to: CGPoint(x: 0, y: 4)); $0.addLine(to: CGPoint(x: 18, y: 4)) }
                .stroke(palette.ink.opacity(dash.isEmpty ? 1 : 0.55), style: StrokeStyle(lineWidth: 2, dash: dash))
                .frame(width: 18, height: 8)
            Text(verbatim: name)
        }
    }
}

/// A goals card's week: each commitment under its goal, with how many of its target you hit.
private struct GoalMeters: View {
    let meters: [DeckMeter]
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(meters.enumerated()), id: \.offset) { index, meter in
                if let group = meter.group, index == 0 || meters[index - 1].group != group {
                    Text(verbatim: group)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.7))
                        .padding(.top, index == 0 ? 0 : 6)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: meter.label).font(AppFont.body())
                        Spacer(minLength: 8)
                        Text(verbatim: "\(meter.done) of \(meter.target)")
                            .font(AppFont.subheadline(weight: .semibold))
                            .monospacedDigit()
                    }
                    Capsule()
                        .fill(palette.ink.opacity(0.12))
                        .frame(height: 8)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule().fill(palette.ink).frame(width: proxy.size.width * meter.fraction)
                            }
                        }
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Writing a reflection: the card's question pinned on its own paper, the whole sheet for words.
/// Text saves as you type, so closing the sheet any way keeps it.
private struct ReflectionSheet: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: viewModel.question(for: card) ?? DeckCardText(card).lead ?? "Your thoughts")
                    .font(AppFont.display(style: .title3, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(verbatim: "Write as much or as little as you like")
                                .font(AppFont.body())
                                .foregroundStyle(Color.hxTextSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(palette.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .toolbarBackground(palette.paper, for: .navigationBar)
        }
        .tint(palette.ink)
        .onAppear {
            text = viewModel.answer(for: card)?.text ?? ""
            isFocused = true
        }
        .onChange(of: text) { _, new in viewModel.setText(new, for: card) }
        .presentationDragIndicator(.visible)
    }
}

/// Every follow-up on one page: each row shows what's open and its choices; choosing
/// Answer, Edit, or Draft opens a box for the words.
private struct FollowUpsPage: View {
    let cards: [DeckCard]
    let viewModel: DailyDeckViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: cards.count == 1 ? "1 follow-up" : "\(cards.count) follow-ups")
                    .font(AppFont.display(style: .title, weight: .semibold))
                    .padding(.bottom, 20)
                ForEach(Array(cards.enumerated()), id: \.element.id) { offset, card in
                    if offset > 0 { Divider().padding(.vertical, 16) }
                    FollowUpRow(card: card, viewModel: viewModel)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(DeckPalette.followUps.ink)
    }
}

private struct FollowUpRow: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel

    var body: some View {
        let chosen = viewModel.answer(for: card)?.action
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: card.title ?? "Follow-up").font(AppFont.headline())
            if let body = card.body, body != card.title {
                Text(verbatim: body).font(AppFont.subheadline()).foregroundStyle(.secondary)
            }
            if let draft = card.draft, let text = draft.text {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Draft to \(draft.to ?? "them")\(draft.channel.map { " · \($0)" } ?? "")")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: text).font(AppFont.body())
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            // Side by side when they fit; stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons(chosen) }
                VStack(alignment: .leading, spacing: 8) { buttons(chosen) }
            }
            if let chosen, card.actions.first(where: { $0.id == chosen })?.takesText == true {
                AnswerBox(card: card, viewModel: viewModel, prompt: chosen == "edit" ? "Your version" : "Your answer", minHeight: 88)
            } else if chosen == "draft" {
                AnswerBox(card: card, viewModel: viewModel, prompt: "Anything to mention? (optional)", minHeight: 88)
            }
        }
    }

    private func buttons(_ chosen: String?) -> some View {
        ForEach(card.actions) { action in
            ChoiceButton(title: action.label, isSelected: chosen == action.id) {
                viewModel.choose(action, for: card)
            }
        }
    }
}

/// A writing area that takes the space it is offered (at least `minHeight`); tapping
/// anywhere in it puts the cursor in the text.
private struct AnswerBox: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel
    let prompt: String
    var minHeight: CGFloat = 180
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(text: textBinding, axis: .vertical) {
            Text(verbatim: prompt)
        }
        .focused($isFocused)
        .font(AppFont.body())
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { isFocused = true }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { viewModel.answer(for: card)?.text ?? "" },
            set: { viewModel.setText($0, for: card) }
        )
    }
}

/// Saved notes carry *emphasis* and **bold**; show it rather than the asterisks.
private func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

/// A capsule toggle for follow-up choices.
private struct ChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .lineLimit(1)
                .font(AppFont.subheadline(weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .foregroundStyle(isSelected ? Color.hxOnAccent : Color.primary)
                .background(isSelected ? Color.accentColor : Color.hxSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One card ahead on the opener: its kind's icon on a glow tile, its title, and its kind.
private struct DeckAheadRow: View {
    let page: DeckPage

    var body: some View {
        let palette = DeckPalette.of(page)
        HStack(spacing: 10) {
            Image(systemName: palette.symbol)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(width: 26, height: 26)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.xs + 2, style: .continuous))
                .accessibilityHidden(true)
            Text(verbatim: Self.title(page))
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: palette.shortName)
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
                .lineLimit(1)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    /// The card's own title, else its question, else what kind of card it is.
    static func title(_ page: DeckPage) -> String {
        switch page {
        case .followUps(let cards):
            return cards.count == 1 ? "1 follow-up" : "\(cards.count) follow-ups"
        case .card(let card):
            return [card.title, card.question].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? DeckPalette.of(card).name
        }
    }
}

extension DeckCardText {
    /// A card's lead font, wherever the card is drawn. Saved words (a quote, a book highlight,
    /// a past journal entry) keep the serif; every other lead is the rounded display voice,
    /// smaller as the lead grows.
    static func leadFont(for card: DeckCard, lead: String) -> Font {
        let style: Font.TextStyle = card.itemKind == "quote" ? .title
            : lead.count > 480 ? .body : lead.count > 220 ? .title3 : .title2
        let quotesSavedWords = ["quote", "book", "on_this_day"].contains(card.itemKind ?? "")
        return quotesSavedWords ? AppFont.serif(style: style) : AppFont.display(style: style, weight: .semibold)
    }
}
