import Charts
import MessageUI
import SwiftUI

/// One card of the Daily Deck stack, a glow card in its kind's paper (`DeckPalette`). A card
/// leads with its takeaway in large rounded type (serif when it quotes your saved words) and
/// scrolls into the rest: context, the question, and your reflection. Writing happens in `ReflectionSheet`, so a card never holds a text
/// field and long text never fights the swipe. Pulling up past a card's end opens feedback on it.
struct DeckPageView: View {
    let page: DeckPage
    let viewModel: DailyDeckViewModel
    let file: () -> Void
    /// Opens Send feedback for this page; nil where the server takes no feedback.
    var feedback: (() -> Void)?
    /// Cards under the top one show only their paper; their words fade in as they rise.
    var contentOpacity: Double = 1
    /// The card opened to fill the screen: its words without the card's own surface.
    var isOpen = false

    @Environment(\.openBrainRoute) private var openBrainRoute

    var body: some View {
        let palette = DeckPalette.of(page)
        let words = Group {
            switch page {
            case .card(let card):
                DeckCardView(card: card, palette: palette, viewModel: viewModel, file: file, feedback: feedback)
            case .followUps(let cards):
                FollowUpsPage(cards: cards, viewModel: viewModel, feedback: feedback)
            }
        }
        .opacity(contentOpacity)
        if isOpen {
            words
        } else {
            words
                .hxCardSurface(palette.cardRole, clipsContent: true)
                .opensAsFullCard(palette.cardRole, title: palette.name, action: sourceAction) {
                    // No swipe-up feedback here: its sheet belongs to the deck under the open card.
                    DeckPageView(page: page, viewModel: viewModel, file: file, isOpen: true)
                }
                .padding(.vertical, 12)
        }
    }

    /// "Open the page" on an open card whose source is a Brain page.
    private var sourceAction: HXCardAction? {
        guard case .card(let card) = page, let route = card.sourceRoute, openBrainRoute.isAvailable else { return nil }
        let open = openBrainRoute
        return HXCardAction(title: DeckCard.openTitle(for: route)) { open(route) }
    }
}

/// A single card: lead, attribution, detail, question, reflection.
private struct DeckCardView: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel
    let file: () -> Void
    let feedback: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Today's morning deck only: earlier cards to rate, offered on the closing card.
    @Environment(LabelQueueViewModel.self) private var labelQueue: LabelQueueViewModel?
    @State private var isWriting = false
    /// The sleep card's numbers, shown before rating when asked for.
    @State private var showsNumbers = false
    /// The Sleep screen, opened from the sleep card's numbers.
    @State private var showsSleepHistory = false
    /// The card's diagram, while its sheet is open.
    @State private var openDiagram: BriefDiagramIndex.Entry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch card.type {
                case .headline: opener
                case .close: close
                case .sleep: sleep
                case .goal: goal
                case .weekAhead: DeckWeekAheadCard(card: card, palette: palette)
                case .changes: DeckChangesCard(card: card, palette: palette, viewModel: viewModel)
                case .ask: ask
                default: reading
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .moreBelowHint(fill: palette.paper, mark: palette.ink)
        .swipeUpForFeedback(mark: palette.ink, action: feedback)
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
        .sheet(isPresented: $showsSleepHistory) {
            let deck = viewModel
            SleepView(viewModel: SleepViewModel(today: SleepNight.dayFormatter.date(from: deck.date) ?? .now) {
                try await deck.sleepHistory()
            })
        }
        .sheet(item: $openDiagram) { entry in
            BriefDiagramSheet(entry: entry, viewModel: viewModel)
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
        if card.isLetter, let countdown = card.lines.first {
            // The countdown to her birth, then her age; the date it counts from underneath.
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: countdown)
                    .font(AppFont.display(style: .title3, weight: .semibold))
                ForEach(card.lines.dropFirst(), id: \.self) { line in
                    Text(verbatim: line).font(AppFont.footnote(weight: .medium))
                }
            }
            .padding(.trailing, 30)
            .padding(.bottom, 18)
            .accessibilityElement(children: .combine)
        }
        if card.isMandarin {
            DeckMandarinCard(card: card, palette: palette, asked: viewModel.question(for: card))
        }
        if !card.isMandarin, let lead = text.lead {
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
        if let diagram = viewModel.diagram(for: card) {
            // A secondary button in the card's paper, so "Write a reflection" stays the one filled button.
            Button { openDiagram = diagram } label: {
                Label { Text(verbatim: "Open the diagram") } icon: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(palette.colors.wash, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.colors.edge, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .accessibilityLabel(Text(verbatim: "Open the diagram: \(diagram.title ?? "interactive")"))
            .accessibilityHint(Text(verbatim: "Opens an interactive diagram"))
        }
        if !card.isMandarin, let detail = text.detail {
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
        if !card.isMandarin, !text.leadIsQuestion, let question = viewModel.question(for: card) {
            Text(verbatim: question)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
                .id(question)
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        }
        if card.takesText {
            reflection(card.isLetter ? "Write to her" : card.isMandarin ? "Answer in Mandarin" : "Write a reflection")
                .padding(.top, 16)
        }
        if let reason = card.reason {
            Text(verbatim: reason)
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
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
        if !card.tags.isEmpty {
            let tapped = viewModel.answer(for: card)?.tags ?? []
            Text(verbatim: "Anything that played a part?")
                .font(AppFont.subheadline(weight: .semibold))
                .padding(.top, 20)
            FlowRow(spacing: 8) {
                ForEach(card.tags) { tag in
                    ChoiceButton(title: tag.label, isSelected: tapped.contains(tag.id)) {
                        viewModel.toggleTag(tag.id, for: card)
                    }
                }
            }
            .padding(.top, 10)
        }
        if let numbers = card.sleep {
            if rating != nil || showsNumbers {
                SleepNumbers(sleep: numbers, palette: palette) { showsSleepHistory = true }
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

    /// The Daily Ask: today's three roles, live.
    @ViewBuilder
    private var ask: some View {
        DeckAskCard(card: card, deckDate: viewModel.date)
        if let reason = card.reason {
            Text(verbatim: reason)
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
        }
    }

    /// The goal card: live check-ins, then a note on how yesterday went.
    @ViewBuilder
    private var goal: some View {
        DeckGoalCard(card: card, palette: palette, deckDate: viewModel.date)
        reflection("Add a note").padding(.top, 24)
        if let reason = card.reason {
            Text(verbatim: reason)
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
        }
    }

    // MARK: Opener and close

    /// The day's title, a line about yesterday (on a weekly review, the week and its highlights),
    /// and the cards ahead, so you know what you're about to get.
    @ViewBuilder
    private var opener: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(card.lines, id: \.self) { line in
                Text(verbatim: line).font(AppFont.footnote())
            }
        }
        .foregroundStyle(palette.ink)
        .padding(.trailing, 24)
        Text(verbatim: card.title ?? "Today")
            .font(AppFont.display(style: .largeTitle, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        if let recap = card.recap {
            recapLine(viewModel.kind == "weekly" ? "This week" : "Yesterday", recap).padding(.top, 14)
        }
        ForEach(Array(card.entries.enumerated()), id: \.offset) { _, entry in
            recapLine(entry.label, entry.text).padding(.top, 10)
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
                DeckAheadRow(page)
            }
        }
        Text(verbatim: "Swipe to begin")
            .font(AppFont.footnote())
            .foregroundStyle(palette.ink)
            .padding(.top, 16)
    }

    /// "Yesterday · …" on the opener: the label bold in the ink, the line in body text.
    private func recapLine(_ label: String?, _ text: String) -> some View {
        (Text(verbatim: label.map { "\($0) · " } ?? "").font(AppFont.display(style: .subheadline, weight: .semibold))
            + Text(verbatim: text).font(AppFont.subheadline()).foregroundStyle(Color.hxTextPrimary.opacity(0.85)))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var close: some View {
        let count = viewModel.answeredCount
        let filed = viewModel.isFiled && !viewModel.hasChanges
        Text(verbatim: filed ? "Filed" : count == 1 ? "1 reflection" : "\(count) reflections")
            .font(AppFont.display(style: .largeTitle, weight: .semibold))
        Text(verbatim: filed
             ? viewModel.filedNote?.summary ?? "In your journal. Edit any card and file again to update it."
             : viewModel.isFiled
             ? "Filing again updates the journal: changed answers replace what was filed, new ones are added, nothing is deleted."
             : count == 0
             ? "Nothing written yet. Swipe back to any card, or file the follow-ups you chose."
             : "Atlas writes them into today's journal and runs the follow-ups you chose.")
            .font(AppFont.body())
            .foregroundStyle(Color.hxTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        if filed, let failures = viewModel.filedNote?.failures, !failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                    Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                }
            }
            .font(AppFont.footnote())
            .foregroundStyle(Color.hxWarning)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
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
        if let labelQueue {
            RateRecentCardsLink(queue: labelQueue, palette: palette)
                .padding(.top, 8)
        }
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
    /// The Mandarin card's mic: on-device zh-CN dictation into the answer.
    @State private var voiceInput = ComposerVoiceInputController(fixedLocale: MandarinDictation.locale)

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
                            Text(verbatim: card.isMandarin ? "Answer out loud in Mandarin, or type" : "Write as much or as little as you like")
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
            .safeAreaInset(edge: .bottom) {
                if card.isMandarin, let message = MandarinDictation.isAvailable
                    ? voiceInput.errorMessage
                    : "To answer by voice, add Chinese (Simplified) dictation in Settings › General › Keyboard." {
                    Text(verbatim: message)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar {
                if card.isMandarin && MandarinDictation.isAvailable {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            _ = voiceInput.scheduleToggle(currentDraft: text) { text = $0 }
                        } label: {
                            Image(systemName: voiceInput.state == .idle ? "mic" : "stop.circle.fill")
                        }
                        .accessibilityLabel(Text(verbatim: voiceInput.state == .idle ? "Speak in Mandarin" : "Stop dictation"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        voiceInput.stopKeepingTranscript()
                        dismiss()
                    } label: { Text(verbatim: "Done") }
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
        .onDisappear { voiceInput.stopKeepingTranscript() }
        .presentationDragIndicator(.visible)
    }
}

/// Every follow-up on one page: each row shows what's open and its choices; choosing
/// Answer, Edit, or Draft opens a box for the words.
private struct FollowUpsPage: View {
    let cards: [DeckCard]
    let viewModel: DailyDeckViewModel
    let feedback: (() -> Void)?

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
        .scrollDismissesKeyboard(.interactively)
        .swipeUpForFeedback(mark: DeckPalette.followUps.ink, action: feedback)
        .foregroundStyle(DeckPalette.followUps.ink)
    }
}

private struct FollowUpRow: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel
    /// The Messages sheet that is up: its Text action and the words it opened with.
    @State private var composing: Compose?
    /// The suggested text as edited here; nil until it is changed. Text sends these words.
    @State private var editedText: String?
    @FocusState private var isEditingText: Bool
    @Environment(\.openURL) private var openURL

    private struct Compose: Identifiable {
        let id = UUID()
        let action: DeckAction
        let message: DeckMessage
    }

    var body: some View {
        let chosen = viewModel.answer(for: card)?.action
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: card.title ?? "Follow-up").font(AppFont.headline())
            if let body = card.body, body != card.title {
                Text(verbatim: body).font(AppFont.subheadline()).foregroundStyle(.secondary)
            }
            if let preview = draftPreview {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(verbatim: preview.heading)
                        if preview.editable {
                            Spacer(minLength: 8)
                            Image(systemName: "pencil").accessibilityHidden(true)
                        }
                    }
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)
                    if preview.editable {
                        // The words Text sends: tap to change them before Messages opens.
                        TextField(text: Binding(get: { editedText ?? preview.text }, set: { editedText = $0 }),
                                  axis: .vertical) {
                            Text(verbatim: "Your message")
                        }
                        .font(AppFont.body())
                        .focused($isEditingText)
                        .accessibilityLabel(Text(verbatim: "Message to send"))
                    } else {
                        Text(verbatim: preview.text).font(AppFont.body())
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture { if preview.editable { isEditingText = true } }
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
        .sheet(item: $composing) { compose in
            MessageComposer(message: compose.message) { sent in
                composing = nil
                if sent { viewModel.markTexted(compose.action, body: compose.message.body, for: card) }
            }
            .ignoresSafeArea()
        }
    }

    private func buttons(_ chosen: String?) -> some View {
        ForEach(card.actions) { action in
            let texted = action.message != nil && chosen == action.id
            ChoiceButton(title: texted ? "Texted" : action.label, isSelected: chosen == action.id) {
                if let message = action.message {
                    text(message, with: action)
                } else {
                    viewModel.choose(action, for: card)
                }
            }
        }
    }

    /// The words to be sent, shown before sending: an agent's draft, else the Text action's
    /// suggestion. Editable when a Text action will send them from this phone.
    private var draftPreview: (heading: String, text: String, editable: Bool)? {
        let sendsHere = card.actions.contains { $0.message != nil }
        if let draft = card.draft, let text = draft.text {
            return ("Draft to \(draft.to ?? "them")\(draft.channel.map { " · \($0)" } ?? "")", text, sendsHere)
        }
        if let body = card.actions.lazy.compactMap({ $0.message?.body }).first(where: { !$0.isEmpty }) {
            return ("Suggested text", body, true)
        }
        return nil
    }

    /// Opens the Messages sheet with the edited words, if any. Where the device can't send texts
    /// (the simulator), it hands off to Messages instead, which can't report back, so the card
    /// stays unanswered.
    private func text(_ message: DeckMessage, with action: DeckAction) {
        isEditingText = false
        let message = DeckMessage(to: message.to, body: editedText ?? message.body)
        if MessageComposer.canSend {
            composing = Compose(action: action, message: message)
        } else if let url = MessageComposer.smsURL(message) {
            openURL(url)
        }
    }
}

/// The system Messages compose sheet, prefilled. Reports whether the text was actually sent:
/// `false` for a cancel or a failure.
private struct MessageComposer: UIViewControllerRepresentable {
    let message: DeckMessage
    let onFinish: (Bool) -> Void

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    /// `sms:` to the same recipient and words, for a device without the sheet.
    static func smsURL(_ message: DeckMessage) -> URL? {
        let body = message.body?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "sms:\(message.to)" + (body.isEmpty ? "" : "&body=\(body)"))
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = [message.to]
        controller.body = message.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            onFinish(result == .sent)
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
/// A pill choice: the decision card's buttons, also the Daily Ask's.
struct ChoiceButton: View {
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
struct DeckAheadRow: View {
    let symbol: String
    /// The symbol's color, on a tile in `wash`.
    let ink: Color
    let wash: Color
    let title: String
    /// The thing's kind in one word, at the row's end.
    let kind: String
    let kindColor: Color

    /// A Brief opener row: the card's kind on its paper, its title, its kind in secondary text.
    init(_ page: DeckPage) {
        let palette = DeckPalette.of(page)
        self.init(symbol: palette.symbol, ink: palette.ink, wash: palette.colors.wash,
                  title: Self.title(page), kind: palette.shortName, kindColor: Color.hxTextSecondary)
    }

    init(symbol: String, ink: Color, wash: Color, title: String, kind: String, kindColor: Color) {
        self.symbol = symbol
        self.ink = ink
        self.wash = wash
        self.title = title
        self.kind = kind
        self.kindColor = kindColor
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 26, height: 26)
                .background(wash, in: RoundedRectangle(cornerRadius: HXRadius.xs + 2, style: .continuous))
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: kind)
                .font(AppFont.caption())
                .foregroundStyle(kindColor)
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
        let style = leadStyle(length: lead.count, isQuote: card.itemKind == "quote")
        let quotesSavedWords = ["quote", "book", "on_this_day"].contains(card.itemKind ?? "")
        return quotesSavedWords ? AppFont.serif(style: style) : AppFont.display(style: style, weight: .semibold)
    }

    /// A lead's text style: a quote at title size, anything else smaller as it grows.
    static func leadStyle(length: Int, isQuote: Bool) -> Font.TextStyle {
        isQuote ? .title : length > 480 ? .body : length > 220 ? .title3 : .title2
    }
}

extension View {
    /// On a card's ScrollView: a soft fade into `fill` and a down arrow in `mark` while there is
    /// more card below. Daily Deck cards and Brain review bites share it.
    func moreBelowHint(fill: Color, mark: Color) -> some View {
        modifier(MoreBelowHint(fill: fill, mark: mark))
    }
}

private struct MoreBelowHint: ViewModifier {
    let fill: Color
    let mark: Color

    @State private var overflows = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y > geometry.containerSize.height + 8
            } action: { _, more in
                overflows = more
            }
            .overlay(alignment: .bottom) { hint }
    }

    @ViewBuilder
    private var hint: some View {
        if overflows {
            LinearGradient(colors: [fill.opacity(0), fill], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .overlay(alignment: .bottom) {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(mark.opacity(0.45))
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// On a card's scroll view: pulling up past the end and letting go runs `action` (Send
    /// feedback), with a cue that fades in as the card is pulled. Nil turns it off.
    func swipeUpForFeedback(mark: Color, action: (() -> Void)?) -> some View {
        modifier(SwipeUpForFeedback(mark: mark, action: action))
    }
}

private struct SwipeUpForFeedback: ViewModifier {
    let mark: Color
    let action: (() -> Void)?

    /// How far past the end a card is pulled before letting go opens feedback.
    private static let threshold: CGFloat = 72
    /// How far past the end the card is, clamped to the threshold.
    @State private var pull: CGFloat = 0
    @State private var isDragging = false
    /// Pulled far enough by a finger (not a fling's bounce); letting go now opens feedback.
    @State private var isArmed = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { old, new in
                isDragging = new == .interacting
                if old == .interacting, !isDragging, isArmed { action?() }
                if !isDragging { isArmed = false }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let end = max(geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height,
                              -geometry.contentInsets.top)
                return min(max(geometry.contentOffset.y - end, 0), Self.threshold).rounded()
            } action: { _, pull in
                guard action != nil else { return }
                self.pull = pull
                if isDragging { isArmed = pull >= Self.threshold }
            }
            .overlay(alignment: .bottom) { cue }
            .sensoryFeedback(.impact(weight: .light), trigger: isArmed) { _, armed in armed }
            .accessibilityActions {
                if let action {
                    Button(action: action) { Text(verbatim: "Send Feedback") }
                }
            }
    }

    @ViewBuilder
    private var cue: some View {
        // Only under a finger: a fling's bounce past the end never shows it.
        if action != nil, isDragging, pull > 0 {
            Label { Text(verbatim: isArmed ? "Release for feedback" : "Pull up for feedback") } icon: {
                Image(systemName: "message")
            }
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(mark)
            .opacity(Double(pull / Self.threshold))
            .padding(.bottom, 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
