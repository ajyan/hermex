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
        let palette = DeckPalette.of(page, inV2Weekly: viewModel.isSealedWeekly)
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
                        .onAppear { viewModel.screenAppeared() }
                        .onDisappear { viewModel.screenDisappeared() }
                }
                .padding(.vertical, 12)
        }
    }

    /// "Open the page" on an open card whose source is a Brain page.
    private var sourceAction: HXCardAction? {
        guard case .card(let card) = page, let route = card.sourceRoute, openBrainRoute.isAvailable else { return nil }
        let (open, deck) = (openBrainRoute, viewModel)
        return HXCardAction(title: DeckCard.openTitle(for: route)) {
            deck.opened("source", on: card.id)
            open(route)
        }
    }
}

/// A single card: lead, attribution, detail, question, reflection.
struct DeckCardView: View {
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
    /// The week's divider: his intention shown in full.
    @State private var showsFullIntention = false
    /// The week's divider: a new question was asked on this screen, so the "Why?" note shows.
    @State private var hasAskedNewQuestion = false
    @State private var endInView = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch card.type {
                case .headline: opener
                case .section: section
                case .front: frontDivider
                case .close: close
                case .sleep: sleep
                case .goal: goal
                case .changes: DeckChangesCard(card: card, palette: palette, viewModel: viewModel)
                case .ask: ask
                case .dinner: dinner
                case .meals: DeckMealsCard(card: card, palette: palette, viewModel: viewModel)
                case .decision:
                    FollowUpRow(card: card, viewModel: viewModel, palette: palette, isPage: true)
                    // The week's question closes the Reflect chapter; other follow-ups carry no chapter.
                    if card.chapter != nil { DeckFootnote(card: card, palette: palette) }
                case .cover: WeekCoverCard(card: card, palette: palette, viewModel: viewModel)
                case .lastIntention: WeekLastIntentionCard(card: card, palette: palette, viewModel: viewModel)
                case .value: WeekValueCard(card: card, palette: palette, viewModel: viewModel)
                case .intention: WeekIntentionCard(card: card, palette: palette, viewModel: viewModel)
                case .keepsakes: WeekKeepsakesCard(card: card, palette: palette, viewModel: viewModel)
                case .training: WeekTrainingCard(card: card, palette: palette, model: viewModel.training)
                default: if isJobCard { jobReading } else { reading }
                }
                // Reaching the end of the card counts toward the style learner's usage (`DeckSignals`). A short card's
                // end is in view while it is still the next card under the stack, so it's checked again on arrival.
                Color.clear.frame(height: 1)
                    .onScrollVisibilityChange(threshold: 0.9) { visible in
                        endInView = visible
                        if visible { viewModel.reachedEnd(card.id) }
                    }
                    .onChange(of: viewModel.currentCardID) { _, id in
                        if endInView, id == card.id { viewModel.reachedEnd(card.id) }
                    }
                    .accessibilityHidden(true)
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
            // A card that names its kind in its first line doesn't wear the corner mark too.
            if !showsKindLabel {
                Image(systemName: palette.symbol)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(palette.ink.opacity(0.35))
                    .padding(18)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(palette.ink)
        .tint(palette.ink)
        .sheet(isPresented: $isWriting, onDismiss: sendMandarinAnswer) {
            ReflectionSheet(card: card, palette: palette, viewModel: viewModel)
        }
        .sheet(isPresented: $showsSleepHistory) {
            let deck = viewModel
            SleepView(viewModel: SleepViewModel(today: SleepNight.dayFormatter.date(from: deck.date) ?? .now) {
                try await deck.sleepHistory()
            })
        }
        .sheet(item: $openDiagram) { entry in
            DiagramSheet(title: entry.title ?? "Diagram") { [viewModel] in try await viewModel.diagramFragment(entry) }
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
            DeckMandarinCard(card: card, palette: palette, asked: viewModel.question(for: card),
                             practice: viewModel.mandarinPractice(for: card)) {
                reflection(DeckCopy.invitation(for: card))
            }
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
        diagramButtons
        if !card.isMandarin, let detail = text.detail {
            Text(inlineMarkdown(detail))
                .font(AppFont.body())
                .lineSpacing(4)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .textSelection(.enabled)
        }
        if let piece = card.piece {
            PieceArgument(piece: piece, palette: palette).padding(.top, 22)
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
        if let traits = card.selfRatings {
            selfRatings(traits).padding(.top, 18)
        } else if card.takesText, !card.isMandarin {
            reflection(DeckCopy.invitation(for: card))
                .padding(.top, 16)
        }
        DeckFootnote(card: card, palette: palette)
    }

    /// Secondary buttons in the card's paper, so "Write a reflection" stays the one filled button: a Piece
    /// card's map first, then a diagram of its topic when there is one.
    private var diagramButtons: some View {
        ForEach(Array(viewModel.diagrams(for: card).enumerated()), id: \.element.id) { index, diagram in
            Button {
                viewModel.opened(diagram.isMap ? "map" : "diagram", on: card.id)
                openDiagram = diagram
            } label: { OpenDiagramLabel(paper: palette.colors, isMap: diagram.isMap) }
            .buttonStyle(.plain)
            .padding(.top, index == 0 ? 18 : 10)
            .accessibilityLabel(Text(verbatim: diagram.isMap ? "Open the map" : "Open the diagram: \(diagram.title ?? "interactive")"))
            .accessibilityHint(Text(verbatim: diagram.isMap ? "Opens the piece's parts and argument, step by step"
                                    : "Opens an interactive diagram"))
        }
    }

    // MARK: Deck by job

    /// A deck by job's card drawn by the card anatomy (`jobReading`): every act card but the Mandarin card,
    /// whose own view stays. Sleep, goals, meals, the Ask and follow-ups keep their views by type.
    private var isJobCard: Bool { card.act != nil && !card.isMandarin }

    /// Whether the card names its kind in its first line rather than in the corner.
    private var showsKindLabel: Bool {
        switch card.type {
        case .close: DeckAct.isByJob(viewModel.visiblePages) && !card.weekRows.isEmpty
        case .prompt, .reflect, .item, .unknown: isJobCard
        case .training: true
        default: false
        }
    }

    /// An act card, top to bottom: its kind label, its title, its body, and the one ask. No reason
    /// footnote and no `lines` subtitles; a letter's countdown sits in its kind label.
    @ViewBuilder
    private var jobReading: some View {
        let idea = DeckAct.ideaPosition(of: card, in: viewModel.visiblePages)
        DeckKindLabel(symbol: palette.symbol, text: card.kindLabel(palette, idea: idea, advisor: viewModel.deck?.advisor),
                      ink: palette.ink)
        if idea != nil, let week = card.weekQuestion {
            Text(verbatim: "This week: \(week)")
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        let text = DeckCardText(card)
        let isYearAgo = card.itemKind == "on_this_day"
        let title = card.asksInTitle ? (viewModel.question(for: card) ?? text.lead)
            : card.act == "ideas" || isYearAgo ? (card.title ?? text.lead) : text.lead
        if let title {
            Text(inlineMarkdown(title))
                .font(isYearAgo ? AppFont.serif(style: .title2) : AppFont.display(style: .title2, weight: .bold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .textSelection(.enabled)
                .id(title)
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                .accessibilityAddTraits(.isHeader)
        }
        jobBody(text, isYearAgo: isYearAgo)
        diagramButtons
        if let piece = card.piece {
            PieceArgument(piece: piece, palette: palette).padding(.top, 22)
        }
        let question = card.asksInTitle ? nil : viewModel.question(for: card).flatMap { $0 == title ? nil : $0 }
        if question != nil || card.selfRatings != nil || card.takesText {
            jobAsk(question)
        }
    }

    /// An act card's one ask under a hairline: its question (when the title isn't it), then the answer.
    private func jobAsk(_ question: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let question {
                Text(verbatim: question)
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .id(question)
                    .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
            }
            if let traits = card.selfRatings {
                selfRatings(traits)
            } else if card.takesText {
                reflection(DeckCopy.invitation(for: card))
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.15)).frame(height: 0.5) }
        .padding(.top, 24)
    }

    /// An act card's body: an idea's source, gist, quotes and parts; a check-in's or letter's thread
    /// (else the check-in's message); a year-ago entry's later words; anything else its attribution and detail.
    @ViewBuilder
    private func jobBody(_ text: DeckCardText, isYearAgo: Bool) -> some View {
        if card.act == "ideas" {
            DeckIdeaBody(card: card, palette: palette)
        } else if let thread = card.thread {
            DeckThreadView(thread: thread, palette: palette).padding(.top, 18)
        } else if card.type == .prompt {
            if let context = card.context, context != viewModel.question(for: card) {
                Text(inlineMarkdown(context))
                    .font(AppFont.body())
                    .lineSpacing(3)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .textSelection(.enabled)
            }
        } else if isYearAgo {
            if let later = card.body, later != card.title {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Later that day")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.75))
                    Text(inlineMarkdown(later))
                        .font(AppFont.serif(style: .body))
                        .lineSpacing(3)
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.top, 18)
            }
        } else {
            if let attribution = text.attribution {
                Text(verbatim: attribution)
                    .font(AppFont.subheadline())
                    .foregroundStyle(palette.ink.opacity(0.75))
                    .padding(.top, 6)
            }
            if let detail = text.detail {
                Text(inlineMarkdown(detail))
                    .font(AppFont.body())
                    .lineSpacing(3)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .textSelection(.enabled)
            }
        }
    }

    /// The Mandarin card's answer goes for feedback as soon as its sheet closes; an unchanged answer
    /// that already has feedback isn't sent again.
    private func sendMandarinAnswer() {
        guard card.isMandarin, let text = viewModel.answer(for: card)?.text else { return }
        let practice = viewModel.mandarinPractice(for: card)
        let asked = viewModel.question(for: card)
        Task { await practice.submit(text, question: asked == card.question ? nil : asked) }
    }

    /// Your words once written; until then, the way in.
    @ViewBuilder
    private func reflection(_ invitation: String = "Write a reflection") -> some View {
        if let text = viewModel.answer(for: card)?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button { isWriting = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: text)
                        // A weekly review's answers are words he keeps (proud, the lesson).
                        .font(card.chapter == nil ? AppFont.body() : AppFont.serif(style: .body))
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

    /// Each trait over a 1–10 row of the sleep card's chips; tapping the chosen score clears it.
    private func selfRatings(_ traits: [String]) -> some View {
        let scores = viewModel.traitScores(for: card)
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(traits, id: \.self) { trait in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: trait)
                        .font(AppFont.subheadline(weight: .semibold))
                    FlowRow(spacing: 4) {
                        ForEach(1...10, id: \.self) { score in
                            ChoiceButton(title: "\(score)", isSelected: scores[trait] == score, compact: true) {
                                viewModel.rateTrait(trait, score, for: card)
                            }
                            .accessibilityLabel(Text(verbatim: "\(trait) \(score) of 10"))
                        }
                    }
                }
            }
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
        DeckFootnote(card: card, palette: palette)
    }

    // MARK: Meals

    /// Last night's dinner: which of the week's dinners it was, how it went, and a cooking note.
    @ViewBuilder
    private var dinner: some View {
        let answer = viewModel.answer(for: card)
        Text(verbatim: card.question ?? "What was last night's dinner?")
            .font(AppFont.display(style: .title2, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 30)
        FlowRow(spacing: 8) {
            ForEach(card.options) { option in
                ChoiceButton(title: option.label, isSelected: answer?.action == option.id) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { viewModel.pick(option.id, for: card) }
                }
            }
        }
        .padding(.top, 18)
        if let pick = answer?.action, pick != "out" {
            Text(verbatim: "Make it again?")
                .font(AppFont.subheadline(weight: .semibold))
                .padding(.top, 20)
            HStack(spacing: 8) {
                ChoiceButton(title: "Yes", isSelected: answer?.rating == 2) { viewModel.rate(2, for: card) }
                ChoiceButton(title: "Not really", isSelected: answer?.rating == 1) { viewModel.rate(1, for: card) }
            }
            .padding(.top, 10)
        }
        reflection(answer?.action == "other" ? "What did you make?" : "Add a cooking note").padding(.top, 24)
        DeckFootnote(card: card, palette: palette)
    }

    /// The Daily Ask: today's three roles, live.
    @ViewBuilder
    private var ask: some View {
        DeckAskCard(card: card, deckDate: viewModel.date)
        DeckFootnote(card: card, palette: palette)
    }

    /// The goal card: live check-ins, then a note on how yesterday went.
    @ViewBuilder
    private var goal: some View {
        DeckGoalCard(card: card, palette: palette, deckDate: viewModel.date)
        reflection("Add a note").padding(.top, 24)
        DeckFootnote(card: card, palette: palette)
    }

    // MARK: Opener and close

    /// The day's title, a line about yesterday (on a weekly review, the week and its highlights),
    /// and the cards ahead, so you know what you're about to get.
    /// "Learned: …" with Undo, which files the rule's id so tomorrow's deck drops it ("Undone" takes it back).
    private func learnedRow(_ rule: DeckLearned) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: rule.line).font(AppFont.footnote())
            if rule.isLearned {
                let undone = viewModel.signals.undo.contains(rule.id)
                Button {
                    viewModel.undoLearned(rule.id)
                } label: {
                    Text(verbatim: undone ? "Undone" : "Undo").font(AppFont.footnote(weight: .semibold))
                }
                .buttonStyle(.borderless)
                .tint(Color.accentColor)
                .accessibilityLabel(Text(verbatim: undone ? "Undone. Tap to keep the rule" : "Undo this rule"))
            }
        }
    }

    @ViewBuilder
    private var opener: some View {
        let pages = viewModel.visiblePages
        if DeckAct.isByJob(pages) { jobOpener(pages) } else { frontOpener }
    }

    /// A deck by job's opener: the day's tag lines, the date, yesterday's one, today's one, then each
    /// act's cards ("Ideas · 2 cards"). No recap and no front rows; the close shows where you stand.
    @ViewBuilder
    private func jobOpener(_ pages: [DeckPage]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if card.headlineTags.isEmpty {
                ForEach(card.lines, id: \.self) { line in
                    Text(verbatim: line).font(AppFont.footnote())
                }
            } else {
                DeckTagLines(tags: card.headlineTags)
            }
            ForEach(card.learned) { rule in
                learnedRow(rule)
            }
        }
        .foregroundStyle(palette.ink)
        .padding(.trailing, 24)
        Text(verbatim: card.title ?? "Today")
            .font(AppFont.display(style: .largeTitle, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
            .accessibilityAddTraits(.isHeader)
        if let one = card.yesterdayOne {
            DeckYesterdayLine(card: card, one: one, palette: palette, viewModel: viewModel).padding(.top, 18)
        }
        if let one = card.todayOne {
            DeckTodayOnePanel(one: one, palette: palette).padding(.top, 18)
        }
        ForEach(Array(Self.acts(pages).enumerated()), id: \.offset) { index, group in
            act(group.name, group.pages).padding(.top, index == 0 ? 22 : 16)
        }
        Text(verbatim: "Swipe to begin")
            .font(AppFont.footnote())
            .foregroundStyle(palette.ink)
            .padding(.top, 16)
    }

    @ViewBuilder
    private var frontOpener: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(card.lines, id: \.self) { line in
                Text(verbatim: line).font(AppFont.footnote())
            }
            ForEach(card.learned) { rule in
                learnedRow(rule)
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
        if let one = card.yesterdayOne {
            DeckYesterdayLine(card: card, one: one, palette: palette, viewModel: viewModel).padding(.top, 18)
        }
        let acts = Self.acts(viewModel.visiblePages)
        ForEach(Array(acts.filter { $0.divider == nil }.enumerated()), id: \.offset) { _, group in
            act(group.name, group.pages).padding(.top, 26)
        }
        let fronts = acts.filter { $0.divider != nil }
        if !fronts.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(fronts.enumerated()), id: \.offset) { _, group in
                    frontAct(group)
                }
            }
            .padding(.top, 22)
        }
        Text(verbatim: "Swipe to begin")
            .font(AppFont.footnote())
            .foregroundStyle(palette.ink)
            .padding(.top, 16)
    }

    /// A front on the opener's list: its symbol, its name, and how many cards it holds; the week's lead says so.
    private func frontAct(_ group: DeckAct) -> some View {
        let divider = group.divider
        let symbol = divider.map { DeckPalette.of($0).symbol } ?? "tray"
        let leads = divider?.type == .section
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(AppFont.subheadline())
                .foregroundStyle(palette.ink)
                .frame(width: 28)
            Text(verbatim: group.name)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: leads ? "leads · \(group.pages.count)" : "\(group.pages.count)")
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextSecondary)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }

    /// One act of the opener's list: "Today · 3 cards" over a row per card.
    private func act(_ name: String, _ pages: [DeckPage]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(name) · \(pages.count) \(pages.count == 1 ? "card" : "cards")")
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(pages) { page in
                DeckAheadRow(page)
            }
        }
    }

    /// The cards ahead of the opener, grouped by the divider they follow: those before any divider
    /// are Today, the week's `section` opens its front's group (its kicker, "This week · Body"),
    /// and each `front` divider opens one under its title ("Becoming a dad", "Also"). The opener,
    /// the dividers and the close card are not listed, and a group with no cards is left out.
    /// A deck by job groups by act instead (`DeckAct.byJob`).
    static func acts(_ pages: [DeckPage]) -> [DeckAct] {
        if DeckAct.isByJob(pages) { return DeckAct.byJob(pages) }
        var groups = [DeckAct(name: "Today", divider: nil, pages: [])]
        for page in pages {
            if case .card(let card) = page {
                switch card.type {
                case .headline, .close: continue
                case .section:
                    groups.append(DeckAct(name: card.frontName ?? card.lines.first ?? "This week", divider: card, pages: []))
                    continue
                case .front:
                    groups.append(DeckAct(name: card.title ?? "Also", divider: card, pages: []))
                    continue
                default: break
                }
            }
            groups[groups.count - 1].pages.append(page)
        }
        return groups.filter { !$0.pages.isEmpty }
    }

    /// "Yesterday · …" on the opener: the label bold in the ink, the line in body text.
    private func recapLine(_ label: String?, _ text: String) -> some View {
        (Text(verbatim: label.map { "\($0) · " } ?? "").font(AppFont.display(style: .subheadline, weight: .semibold))
            + Text(verbatim: text).font(AppFont.subheadline()).foregroundStyle(Color.hxTextPrimary.opacity(0.85)))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The divider between Today and the week's question: its kicker and the question, the last
    /// time's answer, and (on the open card's foot) "Open the page" for the view it comes from.
    @ViewBuilder
    private var section: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(viewModel.sectionLines(for: card).enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(AppFont.footnote())
                }
            }
            .padding(.trailing, 24)
            Text(verbatim: shownQuestion)
                .font(AppFont.display(style: .title, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .id(shownQuestion)
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: card.sectionSpokenLabel(question: shownQuestion)))
        .accessibilityAddTraits(.isHeader)
        if let intention = card.intention { intentionLine(intention).padding(.top, 10) }
        DeckFrontWeek(card: card, palette: palette, deckDate: viewModel.date)
        if !card.altQuestions.isEmpty { newQuestion }
        if let recap = card.recap {
            recapLine("Last time", recap).padding(.top, 14)
        }
    }

    private var shownQuestion: String { viewModel.question(for: card) ?? card.title ?? "This week" }

    /// The week's intention as its short line, with his full words one tap away ("More").
    private func intentionLine(_ intention: DeckIntentionLine) -> some View {
        let short = intention.short ?? intention.text
        let more = short != intention.text || !(intention.ifThen ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            (Text(verbatim: "Intention · ").font(AppFont.subheadline(weight: .semibold)).foregroundStyle(Color.hxTextPrimary)
                + Text(verbatim: short).font(AppFont.subheadline()).foregroundStyle(Color.hxTextSecondary))
                .fixedSize(horizontal: false, vertical: true)
            if showsFullIntention {
                Text(verbatim: intention.line.replacingOccurrences(of: "Your intention: ", with: ""))
                    .font(AppFont.serif(style: .subheadline))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if more {
                Button(showsFullIntention ? "Less" : "More") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsFullIntention.toggle() }
                }
                .font(AppFont.subheadline(weight: .semibold))
                .buttonStyle(.borderless)
                .tint(Color.accentColor)
                .accessibilityHint(Text(verbatim: showsFullIntention ? "Shows the short line" : "Shows your intention in full"))
            }
        }
    }

    /// A season front's divider: where the front stands today over its name, its week as dots, and its one thing today.
    @ViewBuilder
    private var frontDivider: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(AppFont.footnote())
                }
            }
            .padding(.trailing, 24)
            Text(verbatim: card.title ?? palette.name)
                .font(AppFont.display(style: .title, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([card.title ?? palette.name] + card.lines).joined(separator: ", ")))
        .accessibilityAddTraits(.isHeader)
        DeckFrontWeek(card: card, palette: palette, deckDate: viewModel.date)
    }

    /// "New question" steps to the week's next drafted question (its sources replace the last's
    /// in act 2); once asked, an optional one-line note on why goes with it.
    @ViewBuilder
    private var newQuestion: some View {
        Button {
            hasAskedNewQuestion = true
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { viewModel.regenerateQuestion(for: card) }
            AccessibilityNotification.Announcement("New question: \(shownQuestion)").post()
        } label: {
            Label { Text(verbatim: "New question") } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(palette.colors.wash, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.colors.edge, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 18)
        .accessibilityLabel(Text(verbatim: "New question"))
        .accessibilityHint(Text(verbatim: "Shows another question for this week"))
        let note = viewModel.answer(for: card)?.text ?? ""
        if hasAskedNewQuestion || viewModel.answer(for: card)?.question != nil || !note.isEmpty {
            TextField(text: Binding(get: { note }, set: { viewModel.setNote($0, for: card) })) {
                Text(verbatim: "Why? (optional)")
            }
            .font(AppFont.body())
            .submitLabel(.done)
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var close: some View {
        if showsKindLabel { jobClose } else { plainClose }
    }

    /// A deck by job's close: where you stand this week as one grid, today's one thing, then filing.
    @ViewBuilder
    private var jobClose: some View {
        let day = DailyDeckPaths.date(day: viewModel.date)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        DeckKindLabel(symbol: palette.symbol, text: day.map { "Close · \($0)" } ?? "Close", ink: palette.ink)
        Text(verbatim: "Where you stand this week")
            .font(AppFont.display(style: .title2, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 14)
            .accessibilityAddTraits(.isHeader)
        DeckWeekGrid(rows: card.weekRows, palette: palette, deckDate: viewModel.date).padding(.top, 18)
        Text(verbatim: "Tap a ringed + to log yesterday or add one.")
            .font(AppFont.footnote())
            .foregroundStyle(palette.ink.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        if !card.options.isEmpty {
            DeckTodaysOne(card: card, palette: palette, viewModel: viewModel).padding(.top, 24)
        }
        if let variantCard = viewModel.variantCard {
            DeckVariantPick(card: variantCard, viewModel: viewModel, palette: palette)
                .padding(.top, 24)
        }
        closeStatus(seal: false)
        fileButton(seal: false)
    }

    @ViewBuilder
    private var plainClose: some View {
        let count = viewModel.answeredCount
        let filed = viewModel.isFiled && !viewModel.hasChanges
        let seal = viewModel.isSealedWeekly
        Text(verbatim: DeckCopy.closeHeading(seal: seal, filed: filed, count: count))
            .font(AppFont.display(style: .largeTitle, weight: .semibold))
        if seal {
            Text(verbatim: DeckCopy.answered(count))
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.top, 4)
        }
        closeStatus(seal: seal)
        if !card.options.isEmpty, !seal {
            DeckTodaysOne(card: card, palette: palette, viewModel: viewModel).padding(.top, 24)
        }
        if let variantCard = viewModel.variantCard, !seal {
            DeckVariantPick(card: variantCard, viewModel: viewModel, palette: palette)
                .padding(.top, 24)
        }
        fileButton(seal: seal)
    }

    /// What filing does (or did), and anything that failed.
    @ViewBuilder
    private func closeStatus(seal: Bool) -> some View {
        let count = viewModel.answeredCount
        let filed = viewModel.isFiled && !viewModel.hasChanges
        Text(verbatim: filed
             ? DeckCopy.filedLine(seal: seal)
             : viewModel.isFiled
             ? (seal ? "Sealing again replaces this week's page with these answers."
                     : "Filing again updates the journal: changed answers replace what was filed, new ones are added, nothing is deleted.")
             : seal
             ? "Sealing writes this week's page from your answers."
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
    }

    /// File It (Seal the week on a weekly review), then Rate earlier cards on today's morning deck.
    @ViewBuilder
    private func fileButton(seal: Bool) -> some View {
        let filed = viewModel.isFiled && !viewModel.hasChanges
        Button(action: file) {
            HStack {
                if viewModel.filing == .filing { ProgressView().tint(seal ? Color.hxOnAccent : palette.onInk) }
                Text(verbatim: seal ? (viewModel.isFiled ? "Seal your edits" : "Seal the week")
                     : viewModel.isFiled ? "File Changes" : "File It")
            }
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(seal ? Color.hxOnAccent : palette.onInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(seal ? Color.accentColor.opacity(filed ? 0.35 : 1) : palette.ink.opacity(filed ? 0.35 : 1), in: Capsule())
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
/// A Piece card's argument: "The argument · N steps", each a numbered claim with where it sits in the piece,
/// then "In its own words", a few of its quotes in the saved-words serif with where each comes from.
private struct PieceArgument: View {
    let piece: DeckPiece
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !piece.steps.isEmpty {  // the variant's gist face shows the quotes alone
                Text(verbatim: "The argument · \(piece.steps.count) \(piece.steps.count == 1 ? "step" : "steps")")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 10)
            }
            ForEach(Array(piece.steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5).padding(.vertical, 12)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "\(index + 1)")
                        .font(AppFont.display(style: .subheadline, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(minWidth: 16, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: step.claim)
                            .font(AppFont.body())
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let span = step.span {
                            Text(verbatim: span)
                                .font(AppFont.footnote(weight: .medium))
                                .foregroundStyle(palette.ink)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "Step \(index + 1): \(step.claim)\(step.span.map { ". \($0)" } ?? "")"))
            }
            if !piece.quotes.isEmpty {
                Text(verbatim: "In its own words")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 26)
                    .padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(piece.quotes, id: \.self) { quote in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "quote.opening")
                                .font(AppFont.footnote(weight: .semibold))
                                .foregroundStyle(palette.ink)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: quote.text)
                                    .font(AppFont.serif(style: .body))
                                    .lineSpacing(3)
                                    .foregroundStyle(Color.hxTextPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let at = quote.at {
                                    Text(verbatim: at)
                                        .font(AppFont.footnote(weight: .medium))
                                        .foregroundStyle(palette.ink)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
                if card.isMandarin, !card.phrases.isEmpty {
                    MandarinCueList(phrases: card.phrases, used: [], palette: palette, speaker: nil)
                }
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
    var palette: DeckPalette = .followUps
    /// The card has a page to itself (the week's question): its title leads in the display voice.
    var isPage = false
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
            // The Sunday view-take card: its kicker, the week's answers, and what you said last time.
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line).font(AppFont.footnote()).foregroundStyle(isPage ? palette.ink : .secondary)
            }
            Text(verbatim: card.title ?? (isPage ? palette.name : "Follow-up"))
                .font(isPage ? AppFont.display(style: .title2, weight: .semibold) : AppFont.headline())
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, isPage ? 24 : 0)
                .padding(.bottom, isPage ? 6 : 0)
                .accessibilityAddTraits(isPage ? .isHeader : [])
            if let body = card.decisionBody {
                Text(verbatim: body).font(AppFont.subheadline()).foregroundStyle(.secondary)
            }
            if !card.entries.isEmpty {
                RecapList(entries: card.entries, palette: palette).padding(.vertical, 6)
            }
            if let context = card.context {
                Text(verbatim: context).font(AppFont.subheadline()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                AnswerBox(card: card, viewModel: viewModel, prompt: card.answerPrompt(chosen: chosen), minHeight: 88)
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

/// A capsule toggle for follow-up choices.
/// A pill choice: the decision card's buttons, also the Daily Ask's.
struct ChoiceButton: View {
    let title: String
    let isSelected: Bool
    /// A narrow chip for a row of numbers, so ten fit on one line.
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .lineLimit(1)
                .font(AppFont.subheadline(weight: .medium))
                .monospacedDigit()
                .padding(.horizontal, compact ? 4 : 12)
                .frame(minWidth: compact ? 30 : nil, minHeight: 36)
                .foregroundStyle(isSelected ? Color.hxOnAccent : Color.primary)
                .background(isSelected ? Color.accentColor : Color.hxSurface, in: Capsule())
                // A hairline so the chip reads on a neutral card, whose fill is the same surface.
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.hxSeparator, lineWidth: 1))
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

    /// The card's own title (a year-ago card's day), else its question, else what kind of card it is.
    static func title(_ page: DeckPage) -> String {
        switch page {
        case .followUps(let cards):
            return cards.count == 1 ? "1 follow-up" : "\(cards.count) follow-ups"
        case .card(let card):
            // A year-ago card's title is his own opening words; its row names the day instead.
            if let day = card.dateLabel { return day }
            // A letter's title is only "To her"; its row names today's prompt.
            let first = card.isLetter && card.act != nil ? [card.question, card.title] : [card.title, card.question]
            return first.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? DeckPalette.of(card).name
        }
    }
}

extension DeckCardText {
    /// A card's lead font, wherever the card is drawn. Saved words (a quote, a book highlight,
    /// a past journal entry, a journal entry picked for the week) keep the serif; every other lead is the rounded display voice,
    /// smaller as the lead grows.
    static func leadFont(for card: DeckCard, lead: String) -> Font {
        let style = leadStyle(length: lead.count, isQuote: card.itemKind == "quote")
        let quotesSavedWords = ["quote", "book", "on_this_day", "journal"].contains(card.itemKind ?? "")
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
