import SwiftUI

/// Today's run, one rep per screen. Pushed as `.brainRoute(.prep(.run))`; owns no
/// `NavigationStack`. Closing pops: the server records every answer, so closing is
/// save and quit. The drills themselves live in `PrepDrillViews.swift`.
struct PrepRunView: View {
    @State private var viewModel: PrepRunViewModel
    @State private var didLoad = false
    /// The option tapped on a choice rep, kept to mark it once graded.
    @State private var chosen: ChosenOption?
    /// The unsent answer on an approach or spot-the-bug rep.
    @State private var draft = Draft(rep: -1)
    @Environment(\.dismiss) private var dismiss
    @State private var screenHeight: CGFloat = 800

    private struct ChosenOption: Equatable {
        let rep: Int
        let id: String
    }

    /// Belongs to one rep; any other rep reads a fresh one.
    private struct Draft: Equatable {
        let rep: Int
        var text = ""
        var line: Int?
        var fix: String?
    }

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.init(viewModel: PrepRunViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    init(viewModel: PrepRunViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        content
            .hxNavigationTitle(title)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.leave()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text(verbatim: "Save and quit"))
                }
                if let progress {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text(verbatim: "\(progress.position + 1) / \(progress.count)")
                            .brainText(.meta)
                            .monospacedDigit()
                            .accessibilityLabel(Text(verbatim: "Rep \(progress.position + 1) of \(progress.count)"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { FeedbackMoreMenu() }
            }
            .feedbackContext(feedbackContext)
            .background(Color.hxCanvas.ignoresSafeArea())
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { screenHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in screenHeight = height }
                }
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                await viewModel.load()
            }
    }

    // MARK: Chrome

    private var currentRep: PrepRep? {
        switch viewModel.phase {
        case .rep(let rep, _), .result(let rep, _, _): rep
        default: nil
        }
    }

    private var title: String {
        if case .finished = viewModel.phase { return "Run complete" }
        return currentRep.map { PrepCopy.blockTitle($0.block) } ?? ""
    }

    private var feedbackContext: FeedbackContext {
        var result: PrepAttemptResult?
        if case .result(_, let graded, _) = viewModel.phase { result = graded }
        return .prepRun(rep: currentRep, answer: currentRep.flatMap(answer(for:)), result: result)
    }

    /// The answer on screen for a rep: the option tapped, the approach draft, or the bug pick.
    private func answer(for rep: PrepRep) -> PrepAnswer? {
        switch rep.drill {
        case .complexity, .trace:
            return chosen?.rep == rep.index ? chosen.map { .choice($0.id) } : nil
        case .approach:
            return .choice(draft(for: rep).text)
        case .spotBug:
            let draft = draft(for: rep)
            return draft.line.map { .bugFix(line: $0, fix: draft.fix ?? "") }
        case .primer, .unknown:
            return nil
        }
    }

    fileprivate static func drillTitle(_ drill: PrepDrill) -> String {
        switch drill {
        case .approach: "Approach"
        case .complexity: "Complexity"
        case .spotBug: "Spot the bug"
        case .trace: "Trace"
        case .primer: "Primer"
        case .unknown: "Run"
        }
    }

    /// The rep's position among today's reps (not its stable index, which can skip).
    private var progress: (position: Int, count: Int)? {
        guard let rep = currentRep, let reps = viewModel.run?.reps,
              let position = reps.firstIndex(where: { $0.index == rep.index })
        else { return nil }
        return (position, reps.count)
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            PrepFailedView(title: "Couldn't load today's run", message: message) {
                Task { await viewModel.load() }
            }
        case .rep(let rep, _):
            scaffold(rep, hasAction: hasAction(rep)) { repContent(rep) } bottom: { repAction(rep) }
                // Fresh view state (timer start, example toggle) for every rep.
                .id(rep.index)
        case .result(let rep, let result, _):
            scaffold(rep, hasAction: true) {
                PrepResultView(
                    rep: rep,
                    result: result,
                    chosenID: chosen?.rep == rep.index ? chosen?.id : nil,
                    chosenLine: draft(for: rep).line
                )
            } bottom: {
                PrepPrimaryButton(title: "Continue") { Task { await viewModel.continue() } }
            }
            .id(rep.index)
        case .finished(let streak, let moved):
            PrepRunCompleteView(streak: streak, moved: moved) { dismiss() }
        }
    }

    /// A rep's screen: the progress bar and problem card pinned over the drill's scroll view.
    /// The primary action is pinned in a bottom bar so it never scrolls out of reach.
    private func scaffold<Content: View, Bottom: View>(
        _ rep: PrepRep, hasAction: Bool, @ViewBuilder content: () -> Content, @ViewBuilder bottom: () -> Bottom
    ) -> some View {
        // The expanded card is capped at 45% of the screen; its detail scrolls inside.
        let availableHeight = screenHeight
        return ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                content()
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: BrainStyle.m) {
                if let progress {
                    PrepSegmentBar(position: progress.position, count: progress.count)
                }
                PrepProblemCard(rep: rep, maxHeight: availableHeight * 0.45)
            }
            .padding(.horizontal, BrainStyle.l)
            .padding(.bottom, BrainStyle.s)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            .background(Color.hxCanvas)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasAction {
                VStack(spacing: BrainStyle.s) {
                    bottom()
                    if case .rep = viewModel.phase, let submitError = viewModel.submitError {
                        PrepSubmitError(message: submitError)
                    }
                }
                .padding(.horizontal, BrainStyle.l)
                .padding(.vertical, BrainStyle.s)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
                .background(Color.hxCanvas)
            }
        }
    }

    private func hasAction(_ rep: PrepRep) -> Bool {
        switch rep.drill {
        case .primer, .approach, .spotBug, .unknown: true
        case .complexity, .trace: false
        }
    }

    /// The pinned action for a rep awaiting its answer; choice reps answer by tapping an option.
    @ViewBuilder
    private func repAction(_ rep: PrepRep) -> some View {
        switch rep.drill {
        case .primer:
            PrepPrimaryButton(title: "Got it", enabled: !viewModel.isSubmitting) {
                Task { await viewModel.acknowledgePrimer() }
            }
        case .approach:
            let text = draft(for: rep).text.trimmingCharacters(in: .whitespacesAndNewlines)
            PrepPrimaryButton(
                title: viewModel.isSubmitting ? "Grading…" : "Submit",
                enabled: !text.isEmpty && !viewModel.isSubmitting
            ) { Task { await viewModel.submitApproach(text) } }
        case .spotBug:
            let answer = draft(for: rep)
            PrepPrimaryButton(
                title: "Submit",
                enabled: PrepCopy.canSubmitBugFix(line: answer.line, fix: answer.fix) && !viewModel.isSubmitting
            ) {
                guard let line = answer.line, let fix = answer.fix else { return }
                Task { await viewModel.submitBugFix(line: line, fix: fix) }
            }
        case .unknown:
            PrepPrimaryButton(title: "Skip") { Task { await viewModel.skip() } }
        case .complexity, .trace:
            EmptyView()
        }
    }

    @ViewBuilder
    private func repContent(_ rep: PrepRep) -> some View {
        switch rep.drill {
        case .complexity:
            PrepChoiceView(
                title: "Time complexity?",
                options: rep.item.options,
                grading: nil,
                isSubmitting: viewModel.isSubmitting,
                submitError: viewModel.submitError
            ) { option in choose(option, in: rep) }
        case .trace:
            PrepTraceView(
                item: rep.item,
                isSubmitting: viewModel.isSubmitting,
                submitError: viewModel.submitError
            ) { option in choose(option, in: rep) }
        case .approach:
            PrepApproachView(
                text: Binding(
                    get: { draft(for: rep).text },
                    set: { text in updateDraft(rep) { $0.text = PrepCopy.cappedApproach(text) } }),
                hints: rep.item.hints,
                hintsShown: viewModel.hintsShown,
                isSubmitting: viewModel.isSubmitting,
                showHint: { viewModel.showHint() },
                shownAt: viewModel.shownAt
            )
        case .spotBug:
            let answer = draft(for: rep)
            PrepSpotBugView(
                code: rep.item.code,
                fixes: rep.item.fixes,
                selectedLine: answer.line,
                selectedFix: answer.fix,
                isSubmitting: viewModel.isSubmitting,
                selectLine: { line in updateDraft(rep) { $0.line = line } },
                selectFix: { fix in updateDraft(rep) { $0.fix = fix } }
            )
        case .primer:
            PrepPrimerView(item: rep.item)
        case .unknown:
            PrepNoteCard {
                Text(verbatim: "Update Atlas to do this rep")
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
    }

    private func choose(_ option: PrepOption, in rep: PrepRep) {
        chosen = ChosenOption(rep: rep.index, id: option.id)
        Task { await viewModel.choose(.choice(option.id)) }
    }

    private func draft(for rep: PrepRep) -> Draft {
        draft.rep == rep.index ? draft : Draft(rep: rep.index)
    }

    private func updateDraft(_ rep: PrepRep, _ change: (inout Draft) -> Void) {
        var next = draft(for: rep)
        change(&next)
        draft = next
    }
}

/// A thin bar of one segment per rep: done reps in muted secondary text, the current
/// one stronger, the rest on the separator. Neutral chrome; static, never animated.
private struct PrepSegmentBar: View {
    let position: Int
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(color(index))
                    .frame(height: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Rep \(position + 1) of \(count)"))
    }

    private func color(_ index: Int) -> Color {
        if index < position { return Color.hxTextSecondary.opacity(0.55) }
        if index == position { return Color.hxTextSecondary.opacity(0.9) }
        return .hxSeparator
    }
}

/// The end of the run: the streak, the skills whose mastery moved, and Done.
struct PrepRunCompleteView: View {
    let streak: PrepStreak
    let moved: [PrepSkill]
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                SectionCard {
                    BrainRow(
                        title: PrepCopy.streakTitle(days: streak.days),
                        subtitle: PrepCopy.streakSubtitle(days: streak.days, freezes: streak.freezes))
                }
                if !moved.isEmpty {
                    VStack(alignment: .leading, spacing: BrainStyle.s) {
                        BrainSectionHeader(title: "Moved today")
                        SectionCard {
                            VStack(spacing: 0) {
                                ForEach(Array(moved.enumerated()), id: \.element.id) { offset, skill in
                                    if offset > 0 { PrepRowDivider() }
                                    BrainRow(
                                        leading: { PrepCoverThumbnail(id: PrepCopy.coverID(skill.id)) },
                                        title: skill.title,
                                        subtitle: PrepCopy.movedSubtitle(mastery: skill.mastery)
                                    )
                                }
                            }
                        }
                    }
                }
                PrepPrimaryButton(title: "Done", action: done)
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
    }
}

extension FeedbackContext {
    /// "Prep · Spot the bug · Longest Substring" on a rep; just the run around it. State
    /// carries the rep, the answer on screen and, once graded, the verdict and feedback.
    static func prepRun(rep: PrepRep?, answer: PrepAnswer?, result: PrepAttemptResult?) -> FeedbackContext {
        guard let rep else { return FeedbackContext(feature: "Prep", screen: "Run") }
        let answerText: String? = switch answer {
        case .choice(let text): text
        case .bugFix(let line, let fix): "line \(line + 1): \(fix)"
        case nil: nil
        }
        return FeedbackContext(
            feature: "Prep", screen: PrepRunView.drillTitle(rep.drill), item: rep.item.title,
            state: [
                "item_id": rep.item.id,
                "drill": rep.drill.rawValue,
                "rep_index": String(rep.index),
                "answer": answerText,
                "verdict": result?.verdict,
                "feedback": result?.feedback,
            ])
    }
}
