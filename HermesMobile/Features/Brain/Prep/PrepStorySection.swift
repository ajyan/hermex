import SwiftUI

/// The behavioral stories on Prep home: each active story with its three readiness marks (told
/// in time, scored 4 or better, probes held), tapping a row to open that story's page, then
/// the bench stories under a Bench label, drillable the same way (spec §3.1), and last a
/// Dismissed (N) row that reveals the candidates set aside with Not now, each with Add to bench.
/// Hidden by the home when the server has no stories or candidates.
struct PrepStorySection: View {
    let list: PrepStoryList
    /// Candidate ids with a verdict in flight, and why the last verdict on one failed.
    var inFlight: Set<String> = []
    var errors: [String: String] = [:]
    var onAct: (PrepStoryCandidate, PrepStoryCandidateAction) -> Void = { _, _ in }

    @State private var showsDismissed = false
    @State private var showsAll = false
    private static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(
                title: "Stories",
                trailing: PrepCopy.storiesSubtitle(ready: list.readyCount, total: list.activeTotal))
            ForEach(list.candidates) { candidate in
                PrepStoryCandidateCard(
                    candidate: candidate, isActing: inFlight.contains(candidate.id), failure: errors[candidate.id],
                    onAct: { onAct(candidate, $0) })
            }
            if !list.stories.isEmpty {
                SectionCard {
                    VStack(spacing: 0) {
                        rows(Array(list.activeStories.prefix(showsAll ? list.activeStories.count : Self.shown)))
                        if list.activeStories.count > Self.shown || !list.benchStories.isEmpty {
                            PrepRowDivider()
                            PrepShowAllButton(showsAll: $showsAll, count: list.activeStories.count + list.benchStories.count)
                        }
                        if showsAll && !list.benchStories.isEmpty {
                            if !list.activeStories.isEmpty { PrepRowDivider() }
                            HStack {
                                Text(verbatim: "Bench")
                                    .font(BrainStyle.meta.weight(.semibold))
                                    .foregroundStyle(Color.hxTextSecondary)
                                Spacer(minLength: BrainStyle.s)
                                Text(verbatim: "\(list.benchStories.count)")
                                    .font(BrainStyle.meta)
                                    .foregroundStyle(Color.hxTextSecondary)
                                    .monospacedDigit()
                            }
                            .padding(.top, BrainStyle.s)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            rows(list.benchStories)
                        }
                    }
                }
            }
            if !list.dismissed.isEmpty {
                dismissedCard
            }
        }
    }
}

private extension PrepStorySection {
    /// "Dismissed (N)", tapping to show or hide the set-aside candidates.
    var dismissedCard: some View {
        SectionCard {
            VStack(spacing: 0) {
                Button {
                    showsDismissed.toggle()
                } label: {
                    HStack {
                        Text(verbatim: "Dismissed (\(list.dismissed.count))")
                            .font(BrainStyle.meta.weight(.semibold))
                            .foregroundStyle(Color.hxTextSecondary)
                        Spacer(minLength: BrainStyle.s)
                        Image(systemName: showsDismissed ? "chevron.up" : "chevron.down")
                            .font(BrainStyle.meta)
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    .frame(minHeight: BrainStyle.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Dismissed stories, \(list.dismissed.count)"))
                .accessibilityValue(Text(verbatim: showsDismissed ? "Shown" : "Hidden"))
                if showsDismissed {
                    ForEach(list.dismissed) { candidate in
                        PrepRowDivider()
                        PrepDismissedCandidateRow(
                            candidate: candidate, isActing: inFlight.contains(candidate.id),
                            failure: errors[candidate.id], onAdd: { onAct(candidate, .add) })
                    }
                }
            }
        }
    }

    /// One row per story, each opening that story's page.
    func rows(_ stories: [PrepStorySummary]) -> some View {
        ForEach(Array(stories.enumerated()), id: \.element.id) { offset, story in
            if offset > 0 { PrepRowDivider() }
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.storyPage(story.id)))) {
                PrepStoryRow(story: story)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A story the Tuesday scout found, waiting for a verdict: why it might be one, the prompt it
/// would answer, and Add to bench or Not now. A drafting candidate (the server is writing it up)
/// reads "Drafting\u{2026}" with both buttons off; so does one with a verdict on its way.
struct PrepStoryCandidateCard: View {
    let candidate: PrepStoryCandidate
    let isActing: Bool
    /// Why the last verdict failed, when it did.
    let failure: String?
    let onAct: (PrepStoryCandidateAction) -> Void

    private var isDrafting: Bool { candidate.status == "drafting" }

    @ViewBuilder
    private var buttons: some View {
        PrepCandidateButton(
            title: isDrafting ? "Drafting\u{2026}" : "Add to bench", prominent: true,
            accessibility: isDrafting ? "Drafting \(candidate.title)" : "Add \(candidate.title) to bench",
            enabled: !isDrafting && !isActing) { onAct(.add) }
        PrepCandidateButton(
            title: "Not now", prominent: false, accessibility: "Not now for \(candidate.title)",
            enabled: !isDrafting && !isActing) { onAct(.dismiss) }
    }

    var body: some View {
        let paper = HermexPaper.knowledge
        HXCard(.wash(paper), title: candidate.title, spacing: BrainStyle.s, kicker: {
            HXChip(paper: paper, label: "That's a story") { EmptyView() }
        }, content: {
            if let prompt = candidate.forPrompt, !prompt.isEmpty {
                Text(verbatim: "For: \(prompt)")
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = candidate.why, !why.isEmpty {
                Text(verbatim: why)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = failure ?? candidate.error, !message.isEmpty {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }, footer: {
            // Side by side when they fit; stacked at accessibility text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BrainStyle.s) { buttons }
                VStack(alignment: .leading, spacing: BrainStyle.s) { buttons }
            }
        })
        .accessibilityElement(children: .contain)
    }
}

/// A candidate set aside with Not now: its title, the prompt it would answer, and Add to bench.
private struct PrepDismissedCandidateRow: View {
    let candidate: PrepStoryCandidate
    let isActing: Bool
    let failure: String?
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BrainStyle.m) {
                    BrainRow(title: candidate.title, subtitle: subtitle)
                    button
                }
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    BrainRow(title: candidate.title, subtitle: subtitle)
                    button
                }
            }
            if let failure, !failure.isEmpty {
                Text(verbatim: failure)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, BrainStyle.xs)
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String? { candidate.forPrompt.flatMap { $0.isEmpty ? nil : "For: \($0)" } }

    private var button: some View {
        PrepCandidateButton(
            title: "Add to bench", prominent: true, accessibility: "Add \(candidate.title) to bench",
            enabled: !isActing) { onAdd() }
    }
}

/// A capsule button on the candidate card: accent when prominent, quiet otherwise, dimmed when off.
private struct PrepCandidateButton: View {
    let title: String
    let prominent: Bool
    let accessibility: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(BrainStyle.rowSubtitle.weight(.semibold))
                .foregroundStyle(prominent && enabled ? Color.hxOnAccent : Color.hxTextSecondary)
                .lineLimit(1)
                .padding(.horizontal, BrainStyle.l)
                .padding(.vertical, BrainStyle.s)
                .background(
                    prominent && enabled ? Color.accentColor : Color.hxSeparator.opacity(0.6), in: Capsule())
                .frame(minHeight: BrainStyle.minTapTarget)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: accessibility))
    }
}

/// One story: its title, when it was last told, and the three marks.
private struct PrepStoryRow: View {
    let story: PrepStorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            BrainRow(
                title: story.title,
                subtitle: story.last.map { "Last told \(BrainStyle.displayDate($0))" },
                badge: story.ready ? "Ready" : nil)
            // One line when it fits; stacked at accessibility text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BrainStyle.m) { marks }
                VStack(alignment: .leading, spacing: BrainStyle.xs) { marks }
            }
        }
        .padding(.vertical, BrainStyle.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var marks: some View {
        PrepStoryMark(kind: .time, value: story.marks.time)
        PrepStoryMark(kind: .score, value: story.marks.score)
        PrepStoryMark(kind: .probes, value: story.marks.probes)
    }
}

/// A readiness mark: its word and a glyph (a check when earned, a hollow dot when not yet, a
/// quiet dash with no rep). The glyph is in the Prep paper's glow only once earned.
private struct PrepStoryMark: View {
    let kind: PrepStoryMarkKind
    let value: Bool?

    var body: some View {
        HStack(spacing: BrainStyle.xs) {
            Text(verbatim: kind.rawValue.capitalized)
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextSecondary)
            Text(verbatim: PrepCopy.storyMarkSymbol(value))
                .font(BrainStyle.meta.weight(.semibold))
                .foregroundStyle(value == true ? HermexPaper.knowledge.glow : Color.hxTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PrepCopy.storyMarkLabel(kind, value)))
    }
}

// MARK: - A story's page

/// One story to review and practice, opened from its row on Prep home: practice actions first (drill it, a voice
/// mock interview on just this story, or work on it with Atlas, who can update the story file), then its
/// readiness, the questions it answers, its beats as cues, the full telling behind a tap so the user tells it
/// first, and the follow-ups to expect with what a strong answer covers.
struct PrepStoryPageView: View {
    @State private var viewModel: PrepStoryPageViewModel
    @State private var showsTelling = false
    @State private var openProbes: Set<Int> = []
    @Environment(\.openMockCall) private var openMockCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ask: (String) -> Void

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void, ask: @escaping (String) -> Void) {
        _viewModel = State(initialValue: PrepStoryPageViewModel(
            id: id, client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
        self.ask = ask
    }

    var body: some View {
        content
            .hxNavigationTitle("Story")
            .feedbackContext(FeedbackContext(feature: "Prep", screen: "Story"))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            // A server without the story page can still drill the story.
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load this story") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
                NavigationLink(value: ShellPushDestination.brainRoute(.prep(.story(viewModel.id)))) {
                    Text(verbatim: "Drill it")
                }
            }
        case .loaded(let page):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    header(page)
                    practice(page)
                    if !page.prompts.isEmpty { prompts(page) }
                    if !page.cues.isEmpty { beats(page) }
                    if !page.sayItMD.isEmpty { telling(page) }
                    if !page.probes.isEmpty { probes(page) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func header(_ page: PrepStoryPage) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Text(verbatim: page.title)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let signal = page.primarySignal {
                HXChip(paper: .knowledge, symbol: "person.wave.2", label: page.status == "bench" ? "\(signal) · Bench" : signal)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BrainStyle.m) { marks(page) }
                VStack(alignment: .leading, spacing: BrainStyle.xs) { marks(page) }
            }
            Text(verbatim: page.last.map { "Last told \(BrainStyle.displayDate($0))" } ?? "Not told yet")
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextSecondary)
        }
    }

    @ViewBuilder
    private func marks(_ page: PrepStoryPage) -> some View {
        PrepStoryMark(kind: .time, value: page.marks.time)
        PrepStoryMark(kind: .score, value: page.marks.score)
        PrepStoryMark(kind: .probes, value: page.marks.probes)
    }

    private func practice(_ page: PrepStoryPage) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Practice")
            SectionCard {
                VStack(spacing: 0) {
                    NavigationLink(value: ShellPushDestination.brainRoute(.prep(.story(page.id)))) {
                        actionRow(symbol: "timer", title: "Drill it",
                                  subtitle: "Tell it against the clock, then answer two follow-ups")
                    }
                    .buttonStyle(.plain)
                    if openMockCall.isAvailable {
                        PrepRowDivider()
                        Button {
                            Task { await viewModel.startMock(open: openMockCall) }
                        } label: {
                            actionRow(symbol: "phone.fill",
                                      title: viewModel.mock.isStarting ? "Starting the call…" : "Mock interview",
                                      subtitle: "A voice interviewer asks for this story and presses on it")
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.mock.isStarting)
                    }
                    PrepRowDivider()
                    Button {
                        ask(PrepCopy.storyAtlasPrompt(page))
                    } label: {
                        actionRow(symbol: "bubble.left.and.text.bubble.right", title: "Work on it with Atlas",
                                  subtitle: "Talk it through, sharpen it, and update the story")
                    }
                    .buttonStyle(.plain)
                }
            }
            if let message = viewModel.mock.errorMessage {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actionRow(symbol: String, title: String, subtitle: String) -> some View {
        BrainRow(leading: {
            Image(systemName: symbol)
                .font(AppFont.body())
                .foregroundStyle(HermexPaper.knowledge.glow)
                .frame(width: 28)
                .accessibilityHidden(true)
        }, title: title, subtitle: subtitle)
        .padding(.vertical, BrainStyle.xs)
        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func prompts(_ page: PrepStoryPage) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Questions it answers")
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(page.prompts.enumerated()), id: \.offset) { offset, prompt in
                        if offset > 0 { PrepRowDivider() }
                        // The signal only when it says something the question doesn't already.
                        BrainRow(title: prompt.text, subtitle: PrepCopy.promptSignal(prompt.signal, question: prompt.text),
                                 titleLineLimit: nil)
                            .padding(.vertical, BrainStyle.xs)
                    }
                }
            }
        }
    }

    private func beats(_ page: PrepStoryPage) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "The beats")
            PrepRunCard {
                ForEach(page.cues) { cue in
                    HStack(alignment: .firstTextBaseline, spacing: BrainStyle.m) {
                        Text(verbatim: cue.label)
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(HermexPaper.knowledge.glow)
                            .frame(minWidth: 72, alignment: .leading)
                        Text(verbatim: cue.cue)
                            .font(AppFont.body())
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func telling(_ page: PrepStoryPage) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "The full telling")
            PrepRunCard {
                if showsTelling {
                    MarkdownRenderer(content: page.sayItMD)
                        .transition(.opacity)
                } else {
                    Text(verbatim: "Tell it out loud from the beats first, then compare.")
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.hxTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsTelling = true }
                    } label: {
                        Text(verbatim: "Show the full telling")
                            .font(BrainStyle.rowTitle)
                            .frame(minHeight: BrainStyle.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func probes(_ page: PrepStoryPage) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Follow-ups to expect")
            PrepRunCard {
                ForEach(Array(page.probes.enumerated()), id: \.offset) { index, probe in
                    VStack(alignment: .leading, spacing: BrainStyle.xs) {
                        Text(verbatim: probe.attack)
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if openProbes.contains(index) {
                            ForEach(probe.points, id: \.self) { point in
                                Label {
                                    Text(verbatim: point)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "checkmark").foregroundStyle(HermexPaper.knowledge.glow)
                                }
                                .font(BrainStyle.rowTitle)
                                .foregroundStyle(Color.hxTextPrimary)
                            }
                            .transition(.opacity)
                        } else if !probe.points.isEmpty {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { _ = openProbes.insert(index) }
                            } label: {
                                Text(verbatim: "What a strong answer covers")
                                    .font(BrainStyle.rowTitle)
                                    .frame(minHeight: BrainStyle.minTapTarget)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
    }
}
