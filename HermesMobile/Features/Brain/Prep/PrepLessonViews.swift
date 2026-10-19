import SwiftUI

// The learn-first course's screens inside a run: a lesson (its example-first cards, or the idea, and one
// check), its graded check, a boss result without critique, and the end-of-day summary.
// Prep wears the `.knowledge` paper; reward marks (flame, crown, stars) use the opener glow as a
// symbol color only (DESIGN.md, "Reward gold").

/// The reward mark color: the opener glow, for symbols only.
private var prepRewardGold: Color { HermexPaper.opener.glow }

/// A section label inside a lesson, in the Prep paper's glow.
private struct PrepLessonLabel: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(AppFont.display(style: .subheadline, weight: .semibold))
            .foregroundStyle(HermexPaper.knowledge.glow)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A lesson's teaching: its example-first cards when it has them, else the idea in Markdown (a coach re-teach),
/// and where it comes from. Never a script to say back.
struct PrepLessonBody: View {
    let lesson: PrepLesson

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.l) {
            Text(verbatim: lesson.title)
                .font(AppFont.display(style: .title3))
                .foregroundStyle(Color.hxTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if lesson.isReteach {
                HXChip(paper: .knowledge, symbol: "arrow.triangle.2.circlepath", label: "Another way to see it") {
                    EmptyView()
                }
            }
            if let cards = lesson.cards {
                PrepLessonCardsView(title: lesson.title, cards: cards)
            } else {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    PrepLessonLabel(title: "The idea")
                    MarkdownRenderer(content: lesson.ideaMD)
                }
            }
            if let line = PrepCopy.sourceLine(lesson.sources) {
                Label {
                    Text(verbatim: line)
                } icon: {
                    Image(systemName: "quote.opening")
                }
                .brainText(.meta)
                .accessibilityLabel(Text(verbatim: "Source: \(line)"))
            }
        }
    }
}

/// The check's question, under its "Quick check" label.
struct PrepCheckPrompt: View {
    let check: PrepCheck

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            PrepLessonLabel(title: "Quick check")
            Text(verbatim: check.prompt)
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The XP an answer earned, faded in once (shown at once under Reduce Motion).
struct PrepXPTick: View {
    let xp: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Text(verbatim: PrepCopy.xpLabel(xp))
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(HermexPaper.knowledge.glow)
            .monospacedDigit()
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { shown = true }
                }
            }
            .accessibilityLabel(Text(verbatim: PrepCopy.xpSpoken(xp)))
    }
}

/// A lesson's check once graded: the right answer marked, why a wrong pick is wrong, and the
/// explanation. Never a critique of the user.
struct PrepCheckResult: View {
    let check: PrepCheck
    let result: PrepAttemptResult
    let chosenID: String?
    let typedAnswer: String
    let xp: Int?

    private var correct: String? {
        if case let .choice(text)? = result.correct { return text }
        return nil
    }

    var body: some View {
        PrepCheckPrompt(check: check)
        if check.isCloze {
            PrepNoteCard {
                PrepLeadText(lead: result.verdict == "pass" ? "Right." : "Not quite.",
                             rest: "You wrote \u{201C}\(typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}. "
                                 + "The answer is \(correct ?? "").")
            }
        } else {
            PrepChoiceView(title: "Your answer", options: check.options.map { PrepOption(id: $0, title: $0) },
                           grading: .init(chosenID: chosenID, correctID: correct)) { _ in }
        }
        if result.why != nil || !result.feedback.isEmpty {
            PrepNoteCard {
                if let why = result.why {
                    PrepLeadText(lead: "Why not that one:", rest: why)
                }
                if !result.feedback.isEmpty {
                    Text(verbatim: result.feedback)
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let xp {
            PrepXPTick(xp: xp)
        }
    }
}

/// One to three stars in reward gold.
struct PrepStars: View {
    let stars: Int

    var body: some View {
        HStack(spacing: BrainStyle.xs) {
            ForEach(0..<3, id: \.self) { index in
                Image(systemName: index < stars ? "star.fill" : "star")
                    .foregroundStyle(index < stars ? prepRewardGold : Color.hxSeparator)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PrepCopy.starsLabel(stars)))
    }
}

/// A boss answer's result: the sitting (once complete), each key point hit or missed with
/// "I had that" on the misses, the sample answer, and the lessons that teach the misses.
struct PrepBossResultView: View {
    let result: PrepAttemptResult
    let xp: Int?
    var isTestOut = false
    /// The point whose claim is saving; every "I had that" waits until it lands.
    var overridingPoint: String?
    let overrideMissed: (String) -> Void

    private var hits: [String] { result.judgment?.pointsHit.map(\.pointID) ?? [] }
    private var misses: [String] { result.judgment?.pointsMissed.map(\.pointID) ?? [] }

    var body: some View {
        if let sitting = result.sitting {
            VStack(spacing: BrainStyle.s) {
                Image(systemName: "crown")
                    .font(AppFont.display(style: .title2))
                    .foregroundStyle(prepRewardGold)
                    .accessibilityLabel(Text(verbatim: "Boss quiz"))
                Text(verbatim: PrepCopy.sittingHeadline(sitting))
                    .font(AppFont.display(style: .title3))
                    .foregroundStyle(HermexPaper.knowledge.glow)
                if let score = sitting.score {
                    HStack(spacing: BrainStyle.s) {
                        PrepStars(stars: sitting.stars)
                        Text(verbatim: PrepCopy.percent(score))
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(HermexPaper.knowledge.glow)
                            .monospacedDigit()
                    }
                }
                Text(verbatim: PrepCopy.unlockLine(sitting, xp: xp, testOut: isTestOut))
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(Color.hxTextPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(BrainStyle.l)
            .glowSurface(.knowledge, cornerRadius: HXRadius.xl)
        } else if result.isUngraded {
            PrepNoteCard {
                Text(verbatim: "Saved — Atlas will grade this tonight.")
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
        if !hits.isEmpty || !misses.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: PrepCopy.keyPointsLine(hit: hits.count, total: hits.count + misses.count))
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array((hits.map { ($0, true) } + misses.map { ($0, false) }).enumerated()),
                                id: \.element.0) { offset, row in
                            if offset > 0 { PrepRowDivider() }
                            PrepKeyPointRow(result: result, id: row.0, hit: row.1,
                                            overridingPoint: overridingPoint, overrideMissed: overrideMissed)
                                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                        }
                    }
                }
            }
        }
        if !result.strongAnswer.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Sample answer")
                Text(verbatim: result.strongAnswer)
                    .brainText(.quote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                    .padding(.vertical, BrainStyle.cardVerticalPadding)
                    .hxCard()
            }
        }
        if !result.revisit.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Where these are taught")
                FlowRow(spacing: BrainStyle.s) {
                    ForEach(result.revisit) { lesson in
                        NavigationLink(value: ShellPushDestination.brainRoute(.prep(.lesson(lesson.lessonID)))) {
                            HXChip(paper: .knowledge, symbol: "book", label: lesson.title) { EmptyView() }
                                .frame(minHeight: BrainStyle.minTapTarget)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "Revisit \(lesson.title)"))
                    }
                }
            }
        }
    }
}

/// The end of a course run: the day's ring, XP, streak, what was learned, and what comes next.
struct PrepDayCompleteView: View {
    let summary: PrepDaySummary
    var offersBonus = true
    let done: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closed = false
    @ScaledMetric(relativeTo: .largeTitle) private var ring: CGFloat = 132

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                if summary.welcomeBack {
                    Text(verbatim: "Welcome back. Picking up right where you left off.")
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.hxTextSecondary)
                }
                hero
                ForEach(Array(summary.milestones.enumerated()), id: \.offset) { _, milestone in
                    Label {
                        Text(verbatim: PrepCopy.milestoneTitle(milestone))
                            .font(AppFont.display(style: .headline))
                            .foregroundStyle(Color.hxTextPrimary)
                    } icon: {
                        Image(systemName: Self.symbol(milestone)).foregroundStyle(prepRewardGold)
                    }
                    .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                    .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                    .hxCard()
                }
                Label {
                    Text(verbatim: PrepCopy.streakTitle(days: summary.streak.days))
                } icon: {
                    Image(systemName: "flame").foregroundStyle(prepRewardGold)
                }
                .font(BrainStyle.rowTitle)
                .foregroundStyle(Color.hxTextPrimary)
                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                .hxCard()
                if !summary.learned.isEmpty || summary.reviews > 0 {
                    VStack(alignment: .leading, spacing: BrainStyle.s) {
                        BrainSectionHeader(title: "Today")
                        SectionCard {
                            VStack(spacing: 0) {
                                ForEach(Array(summary.learned.enumerated()), id: \.offset) { offset, title in
                                    if offset > 0 { PrepRowDivider() }
                                    Label {
                                        Text(verbatim: title).font(BrainStyle.rowTitle).foregroundStyle(Color.hxTextPrimary)
                                    } icon: {
                                        Image(systemName: "book").foregroundStyle(HermexPaper.knowledge.glow)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                                }
                                if summary.reviews > 0 || summary.missedChecks > 0 {
                                    if !summary.learned.isEmpty { PrepRowDivider() }
                                    BrainRow(title: PrepCopy.reviewLine(reviews: summary.reviews, missed: summary.missedChecks))
                                }
                            }
                        }
                    }
                }
                if let next = summary.nextUp {
                    VStack(alignment: .leading, spacing: BrainStyle.s) {
                        BrainSectionHeader(title: "Tomorrow")
                        SectionCard { BrainRow(title: next) }
                    }
                }
                VStack(spacing: BrainStyle.s) {
                    PrepPrimaryButton(title: "Done", action: done)
                    if offersBonus {
                        NavigationLink(value: ShellPushDestination.brainRoute(.prep(.bonus))) {
                            Text(verbatim: "One more round")
                                .font(AppFont.body(weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(verbatim: "Up to five more recalls"))
                    }
                }
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .sensoryFeedback(.success, trigger: closed)
        .onAppear {
            if reduceMotion {
                closed = true
            } else {
                withAnimation(.easeOut(duration: 0.7)) { closed = true }
            }
        }
    }

    /// The day's ring closing once, the ready count inside, and what became interview-ready.
    private var hero: some View {
        PrepRunCard {
            VStack(spacing: BrainStyle.s) {
                ZStack {
                    Circle().stroke(HermexPaper.knowledge.wash, lineWidth: ring * 0.09)
                    Circle()
                        .trim(from: 0, to: closed ? 1 : 0)
                        .stroke(HermexPaper.knowledge.glow, style: StrokeStyle(lineWidth: ring * 0.09, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(verbatim: "\(summary.readyCount)")
                            .font(AppFont.display(style: .largeTitle))
                            .foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: "ready")
                            .font(BrainStyle.meta)
                            .foregroundStyle(HermexPaper.knowledge.glow)
                    }
                }
                .frame(width: ring, height: ring)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: PrepCopy.readyLine(ready: summary.readyCount, total: summary.lessonTotal)))
                Text(verbatim: summary.readyGained.isEmpty ? "Day complete"
                     : "+\(summary.readyGained.count) interview-ready")
                    .font(AppFont.display(style: .title2))
                    .foregroundStyle(HermexPaper.knowledge.glow)
                if !summary.readyGained.isEmpty {
                    Text(verbatim: summary.readyGained.joined(separator: " · "))
                        .font(BrainStyle.rowSubtitle)
                        .foregroundStyle(Color.hxTextPrimary)
                        .multilineTextAlignment(.center)
                }
                if summary.xpGained > 0 {
                    Text(verbatim: PrepCopy.xpLabel(summary.xpGained))
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextSecondary)
                        .accessibilityLabel(Text(verbatim: PrepCopy.xpSpoken(summary.xpGained)))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static func symbol(_ m: PrepMilestone) -> String {
        switch m {
        case .bossPassed: "crown"
        case .ready: "star"
        case .streak: "flame"
        }
    }
}

/// One lesson to re-read, pushed from a learned node or a revisit chip: the teaching and its
/// check with the answer shown.
struct PrepLessonView: View {
    @State private var viewModel: PrepLessonViewModel
    @State private var didLoad = false

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        _viewModel = State(initialValue: PrepLessonViewModel(
            id: id, client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle(title)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                guard !didLoad else { return }
                didLoad = true
                await viewModel.load()
            }
    }

    private var title: String {
        if case let .loaded(lesson) = viewModel.state { return lesson.title }
        return "Lesson"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this lesson", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let lesson):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    PrepLessonBody(lesson: lesson)
                    if !lesson.check.prompt.isEmpty {
                        PrepNoteCard {
                            PrepCheckPrompt(check: lesson.check)
                            if let answer = lesson.check.answer {
                                PrepLeadText(lead: "Answer:", rest: answer)
                            }
                            if let explain = lesson.check.explain {
                                Text(verbatim: explain)
                                    .font(BrainStyle.rowTitle)
                                    .foregroundStyle(Color.hxTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
        }
    }
}
