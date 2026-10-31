import SwiftUI

/// A run, one rep per screen: today's (`.brainRoute(.prep(.run))`), a test out (`.prep(.testout(unit))`),
/// one more round (`.prep(.bonus)`) or one story (`.prep(.story(id))`). Owns no
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
    /// "Save and quit" with an unsent answer asks before dropping it.
    @State private var confirmingQuit = false
    /// A mic still working on the answer (`PrepMicBusyKey`); Submit and Send wait for it.
    @State private var micBusy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Starts a new Atlas chat with these words in the composer ("Go deeper in Atlas").
    private let ask: (String) -> Void

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
        /// A choice rep's picked option, sent by the pinned Submit.
        var choice: String?
    }

    init(server: URL, run: PrepRunKind = .daily, unit: String? = nil, onAPIError: @escaping (Error) -> Void,
         ask: @escaping (String) -> Void = { _ in }) {
        self.init(viewModel: PrepRunViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), run: run, unit: unit,
            onAPIError: onAPIError), ask: ask)
    }

    init(viewModel: PrepRunViewModel, ask: @escaping (String) -> Void = { _ in }) {
        _viewModel = State(initialValue: viewModel)
        self.ask = ask
    }

    var body: some View {
        content
            .onPreferenceChange(PrepMicBusyKey.self) { micBusy = $0 }
            .environment(\.prepUndoOverride, PrepUndoOverrideAction { Task { await viewModel.undoOverride() } })
            .environment(\.prepDiagramLoader, viewModel.diagramLoader)
            .hxNavigationTitle(title)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if hasUnsentAnswer { confirmingQuit = true } else { quit() }
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
            .confirmationDialog(Text(verbatim: "Discard your answer?"), isPresented: $confirmingQuit,
                                titleVisibility: .visible) {
                Button(role: .destructive, action: quit) { Text(verbatim: "Discard and quit") }
                Button(role: .cancel) {} label: { Text(verbatim: "Keep writing") }
            } message: {
                Text(verbatim: "Your answered reps are saved. The one you're writing hasn't been sent.")
            }
            .feedbackContext(feedbackContext)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                guard !didLoad else { return }
                didLoad = true
                await viewModel.load()
            }
            .sensoryFeedback(.success, trigger: passCount)
            .sensoryFeedback(.impact(weight: .light), trigger: warmupCount)
    }

    /// Changes when a recall passes, for the success haptic; misses get none.
    private var passCount: String {
        if case let .result(rep, result, _) = viewModel.phase, Self.usesRecall(rep), result.verdict == "pass" {
            return "\(rep.index)-\(result.verdict)"
        }
        return ""
    }

    /// Changes when a warm-up is answered right, for a light tap.
    private var warmupCount: String {
        if case let .result(rep, result, _) = viewModel.phase, rep.drill == .warmup, result.verdict == "pass" {
            return "\(rep.index)"
        }
        return ""
    }

    private static func usesRecall(_ rep: PrepRep) -> Bool {
        (rep.drill == .lesson || rep.drill == .recall) && rep.item.lesson?.hasRecall == true
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
        // A boss rep carries no lesson object; its item's title is the lesson the question tests.
        return currentRep.map { rep in
            PrepCopy.runTitle(block: rep.block, lessonTitle: rep.item.lesson?.title ?? (rep.drill == .boss ? rep.item.title : nil))
        } ?? ""
    }

    private var feedbackContext: FeedbackContext {
        var result: PrepAttemptResult?
        if case .result(_, let graded, _) = viewModel.phase { result = graded }
        return .prepRun(rep: currentRep, answer: currentRep.flatMap(answer(for:)), result: result)
    }

    /// The answer on screen for a rep: the option tapped, the typed answer, or the recall draft.
    private func answer(for rep: PrepRep) -> PrepAnswer? {
        switch rep.drill {
        case .judgment, .boss:
            return .choice(draft(for: rep).text)
        case .lesson where Self.usesRecall(rep), .recall where Self.usesRecall(rep):
            return .choice(viewModel.recallDraft)
        case .lesson, .warmup, .recall:
            if Self.isCloze(rep) { return .choice(draft(for: rep).text) }
            return chosen?.rep == rep.index ? chosen.map { .choice($0.id) } : nil
        case .story:
            switch viewModel.storyStage {
            case .telling, .probing: return .choice(viewModel.recallDraft)
            case .told, .probed: return nil
            }
        // Skipped: the retired DSA drills and unknown ones. A probe only comes inside a story rep.
        case .approach, .complexity, .spotBug, .trace, .primer, .fact, .unknown, .probe:
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
        case .fact: "Fact"
        case .judgment: "Judgment"
        case .lesson: "Lesson"
        case .recall: "Recall"
        case .warmup: "Warm-up"
        case .boss: "Boss quiz"
        case .story: "Story"
        case .probe: "Probe"
        case .unknown: "Run"
        }
    }

    /// A lesson check answered by typing rather than tapping an option.
    fileprivate static func isCloze(_ rep: PrepRep) -> Bool {
        rep.item.lesson?.check.isCloze == true
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
        case .result(let rep, let result, _) where Self.usesRecall(rep) && viewModel.inDialogue:
            scaffold(rep, hasAction: true, followsLatest: true) {
                PrepTutorDialogueView(
                    prompt: rep.item.lesson?.recall?.prompt ?? "",
                    kicker: PrepCopy.questionKicker(rep.item.lesson?.recall?.type ?? ""),
                    followup: PrepCopy.followupLine(result.dialogue),
                    firstAnswer: viewModel.firstAnswer, state: result.dialogue,
                    streaming: viewModel.tutorStreaming, pendingReply: viewModel.pendingReply,
                    error: viewModel.tutorError) { Task { await viewModel.retryTutor() } }
            } bottom: {
                PrepTutorReplyBar(
                    draft: Binding(get: { viewModel.tutorDraft }, set: { viewModel.tutorDraft = $0 }),
                    canReply: result.dialogue?.awaitingReply == true && viewModel.pendingReply == nil,
                    canSend: viewModel.canSendTutorReply && !micBusy, isBusy: viewModel.tutorBusy,
                    send: { Task { await viewModel.sendTutorReply() } },
                    showMe: { Task { await viewModel.showMe() } })
            }
            .id(rep.index)
        case .result(let rep, let result, _) where Self.usesRecall(rep):
            scaffold(rep, hasAction: true) {
                PrepRecallResultView(result: result, xp: viewModel.lastXP, goDeeper: ask,
                                     canOverride: viewModel.canOverride,
                                     overridingPoint: viewModel.overridingPoint) { point in
                    Task { await viewModel.overridePoint(point) }
                }
                if let cards = rep.item.lesson?.cards, !result.isUngraded {
                    PrepTakeaway(idea: cards.idea)
                }
                if let error = viewModel.submitError { PrepSubmitError(message: error) }
                if rep.item.lesson?.isReteach == true {
                    PrepFlagCardButton(
                        isFlagged: viewModel.isFlagged(rep.item.id),
                        error: viewModel.flagError
                    ) { Task { await viewModel.flagCurrent() } }
                }
            } bottom: {
                PrepPrimaryButton(title: "Next") { Task { await viewModel.continue() } }
            }
            .id(rep.index)
        case .result(let rep, let result, _) where rep.drill == .warmup:
            scaffold(rep, hasAction: true) {
                if let lesson = rep.item.lesson {
                    PrepRunCard {
                        Text(verbatim: "Warm-up · \(lesson.title)").font(BrainStyle.meta)
                            .foregroundStyle(HermexPaper.prep.glow)
                        PrepCheckResult(check: lesson.check, result: result,
                                        chosenID: chosen?.rep == rep.index ? chosen?.id : nil,
                                        typedAnswer: draft(for: rep).text, xp: viewModel.lastXP)
                    }
                }
            } bottom: {
                PrepPrimaryButton(title: "Next") { Task { await viewModel.continue() } }
            }
            .id(rep.index)
        case .result(let rep, let result, _) where rep.drill == .lesson:
            scaffold(rep, hasAction: true) {
                if let lesson = rep.item.lesson {
                    if !viewModel.isReview(rep) || viewModel.revealedLesson || result.verdict == "miss" {
                        PrepLessonBody(lesson: lesson)
                    }
                    PrepCheckResult(check: lesson.check, result: result,
                                    chosenID: chosen?.rep == rep.index ? chosen?.id : nil,
                                    typedAnswer: draft(for: rep).text, xp: viewModel.lastXP)
                    if lesson.isReteach {
                        PrepFlagCardButton(
                            isFlagged: viewModel.isFlagged(rep.item.id),
                            error: viewModel.flagError
                        ) { Task { await viewModel.flagCurrent() } }
                    }
                }
            } bottom: {
                PrepPrimaryButton(title: "Continue") { Task { await viewModel.continue() } }
            }
            .id(rep.index)
        case .result(let rep, let result, _) where rep.drill == .boss:
            scaffold(rep, hasAction: true) {
                PrepBossResultView(result: result, xp: viewModel.lastXP, isTestOut: viewModel.runKind == .testout,
                                   overridingPoint: viewModel.overridingPoint) { point in
                    Task { await viewModel.overridePoint(point) }
                }
                if let error = viewModel.submitError { PrepSubmitError(message: error) }
            } bottom: {
                PrepPrimaryButton(title: "Continue") { Task { await viewModel.continue() } }
            }
            .id(rep.index)
        case .result(let rep, let result, _):
            scaffold(rep, hasAction: true) {
                PrepResultView(rep: rep, result: result)
                if rep.item.isCoachWritten {
                    PrepFlagCardButton(
                        isFlagged: viewModel.isFlagged(rep.item.id),
                        error: viewModel.flagError
                    ) { Task { await viewModel.flagCurrent() } }
                }
            } bottom: {
                PrepPrimaryButton(title: "Continue") { Task { await viewModel.continue() } }
            }
            .id(rep.index)
        case .finished(let summary) where summary.isCourse:
            PrepDayCompleteView(summary: summary, offersBonus: viewModel.runKind != .bonus) { dismiss() }
        case .finished(let summary):
            PrepRunCompleteView(streak: summary.streak) { dismiss() }
        }
    }

    /// A rep's screen: the progress bar and problem card pinned over the drill's scroll view.
    /// The primary action is pinned in a bottom bar so it never scrolls out of reach.
    private func scaffold<Content: View, Bottom: View>(
        _ rep: PrepRep, hasAction: Bool, followsLatest: Bool = false,
        @ViewBuilder content: () -> Content, @ViewBuilder bottom: () -> Bottom
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                content()
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        // The tutor dialogue keeps its newest turn in view: your reply, the Thinking
        // bubble, streamed text, and the reply field growing all stay at the bottom.
        .defaultScrollAnchor(followsLatest ? .bottom : nil, for: .initialOffset)
        .defaultScrollAnchor(followsLatest ? .bottom : nil, for: .sizeChanges)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: BrainStyle.m) {
                if let progress {
                    PrepSegmentBar(position: progress.position, count: progress.count)
                }
                if ![.lesson, .recall, .warmup, .story].contains(rep.drill) {  // these cards carry their own content
                    PrepProblemCard(rep: rep)
                }
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
        case .judgment, .boss, .story: true
        case .lesson where Self.usesRecall(rep), .recall where Self.usesRecall(rep): true
        case .lesson, .warmup, .recall: true  // cloze text, or the picked option
        case .approach, .complexity, .spotBug, .trace, .primer, .fact, .unknown, .probe: true  // Skip
        }
    }

    /// The pinned action for a rep awaiting its answer; a choice rep's tap only picks, Submit sends it.
    @ViewBuilder
    private func repAction(_ rep: PrepRep) -> some View {
        switch rep.drill {
        case .judgment, .boss:
            let text = draft(for: rep).text
            let floor = PrepWordFloor(text, floor: rep.minWords)
            PrepPrimaryButton(
                title: floor.submitTitle,
                enabled: PrepCopy.canSubmitJudgment(text) && floor.isMet && !viewModel.isSubmitting,
                isGrading: viewModel.isSubmitting
            ) { Task { await viewModel.submitJudgment(text) } }
        case .lesson where Self.usesRecall(rep) && viewModel.lessonStage == .reading:
            PrepPrimaryButton(title: rep.item.lesson?.recall?.isQuestion == true ? "Try a question" : "I'm ready") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { viewModel.beginRecall() }
            }
        case .lesson where Self.usesRecall(rep), .recall where Self.usesRecall(rep):
            PrepPrimaryButton(
                title: viewModel.answerFloor.submitTitle,
                enabled: viewModel.canSubmitRecall && !micBusy,
                isGrading: viewModel.isSubmitting
            ) { Task { await viewModel.submitRecall() } }
        case .lesson, .warmup, .recall:
            if Self.isCloze(rep) {
                let text = draft(for: rep).text
                PrepPrimaryButton(
                    title: "Submit",
                    enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isSubmitting
                ) { Task { await viewModel.submitCloze(text) } }
            } else {
                let picked = draft(for: rep).choice
                PrepPrimaryButton(title: "Submit", enabled: picked != nil && !viewModel.isSubmitting,
                                  isGrading: viewModel.isSubmitting) {
                    guard let picked else { return }
                    choose(PrepOption(id: picked, title: picked), in: rep)
                }
            }
        case .story:
            storyAction
        // The retired DSA drills (an old plan entry) and drills this build doesn't know; a probe only
        // comes inside a story rep.
        case .approach, .complexity, .spotBug, .trace, .primer, .fact, .unknown, .probe:
            PrepPrimaryButton(title: "Skip") { Task { await viewModel.skip() } }
        }
    }

    @ViewBuilder
    private func repContent(_ rep: PrepRep) -> some View {
        switch rep.drill {
        case .lesson where Self.usesRecall(rep), .recall where Self.usesRecall(rep):
            if let lesson = rep.item.lesson, let recall = lesson.recall {
                if let label = rep.label {
                    HXChip(paper: .prep, symbol: "arrow.uturn.backward", label: label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if viewModel.lessonStage == .reading {
                    Group {
                        if lesson.cards != nil {
                            PrepLessonBody(lesson: lesson)
                        } else {
                            PrepRunCard { PrepLessonBody(lesson: lesson) }
                        }
                    }
                    .transition(.opacity)
                } else {
                    PrepRecallCard(
                        prompt: recall.prompt,
                        label: PrepCopy.recallKicker(recall, lessonTitle: lesson.title, isReview: rep.drill == .recall),
                        draft: Binding(get: { viewModel.recallDraft }, set: { viewModel.recallDraft = $0 }),
                        isSubmitting: viewModel.isSubmitting,
                        dontKnow: { Task { await viewModel.dontKnow() } }
                    )
                    .transition(.opacity)
                }
            }
        case .warmup:
            if let lesson = rep.item.lesson {
                PrepRunCard {
                    Text(verbatim: "Warm-up · \(lesson.title)").font(BrainStyle.meta)
                        .foregroundStyle(HermexPaper.prep.glow)
                    PrepCheckPrompt(check: lesson.check)
                    if Self.isCloze(rep) {
                        PrepClozeView(
                            text: Binding(get: { draft(for: rep).text }, set: { text in updateDraft(rep) { $0.text = text } }),
                            isSubmitting: viewModel.isSubmitting
                        ) { Task { await viewModel.submitCloze(draft(for: rep).text) } }
                    } else {
                        PrepChoiceView(
                            title: "Your answer",
                            options: lesson.check.options.map { PrepOption(id: $0, title: $0) },
                            grading: nil,
                            isSubmitting: viewModel.isSubmitting,
                            submitError: viewModel.submitError,
                            selectedID: draft(for: rep).choice
                        ) { option in updateDraft(rep) { $0.choice = option.id } }
                    }
                }
            }
        case .lesson, .recall:
            if let lesson = rep.item.lesson {
                let review = viewModel.isReview(rep)
                if !review || viewModel.revealedLesson {
                    PrepLessonBody(lesson: lesson)
                }
                PrepCheckPrompt(check: lesson.check)
                if Self.isCloze(rep) {
                    PrepClozeView(
                        text: Binding(get: { draft(for: rep).text }, set: { text in updateDraft(rep) { $0.text = text } }),
                        isSubmitting: viewModel.isSubmitting
                    ) { Task { await viewModel.submitCloze(draft(for: rep).text) } }
                } else {
                    PrepChoiceView(
                        title: "Your answer",
                        options: lesson.check.options.map { PrepOption(id: $0, title: $0) },
                        grading: nil,
                        isSubmitting: viewModel.isSubmitting,
                        submitError: viewModel.submitError,
                        selectedID: draft(for: rep).choice
                    ) { option in updateDraft(rep) { $0.choice = option.id } }
                }
                if review && !viewModel.revealedLesson {
                    Button {
                        viewModel.showIdea()
                    } label: {
                        Label { Text(verbatim: "Show the idea") } icon: { Image(systemName: "lightbulb") }
                            .font(BrainStyle.rowTitle)
                            .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        case .judgment, .boss:
            PrepAnswerEditor(
                text: Binding(
                    get: { draft(for: rep).text },
                    set: { text in updateDraft(rep) { $0.text = PrepCopy.cappedApproach(text) } }),
                isSubmitting: viewModel.isSubmitting
            )
        case .story:
            storyContent(rep)
        case .approach, .complexity, .spotBug, .trace, .primer, .fact, .unknown, .probe:
            PrepNoteCard {
                Text(verbatim: "Update Atlas to do this rep")
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
    }

    // MARK: Story reps

    /// The story rep's screen for its stage: the telling, its result, a probe, or a probe's result.
    @ViewBuilder
    private func storyContent(_ rep: PrepRep) -> some View {
        let draft = Binding(get: { viewModel.recallDraft }, set: { viewModel.editStory($0) })
        switch viewModel.storyStage {
        case .telling:
            PrepStoryTellCard(
                prompt: rep.item.prompt,
                title: rep.item.title,
                signal: rep.item.signal,
                cues: rep.item.cues,
                script: rep.item.scriptMD,
                startedAt: viewModel.storyStartedAt,
                elapsedMS: { viewModel.storyElapsedMS },
                draft: draft,
                isSubmitting: viewModel.isSubmitting,
                startClock: { viewModel.markStoryStarted() },
                cuesHidden: rep.cuesHidden,
                peeked: viewModel.storyCuesPeeked,
                peek: { viewModel.peekStoryCues() })
        case .told(let result):
            PrepStoryResultView(result: result, titles: viewModel.storyTitles,
                                overridingPoint: viewModel.overridingPoint) { point in
                Task { await viewModel.overridePoint(point) }
            }
        case .probing(let probe, let number):
            PrepProbeCard(prompt: rep.item.prompt, probe: probe, number: number, draft: draft,
                          isSubmitting: viewModel.isSubmitting)
        case .probed(let result, let number):
            PrepProbeResultView(result: result, number: number, overridingPoint: viewModel.overridingPoint) { point in
                Task { await viewModel.overridePoint(point) }
            }
        }
    }

    /// Submit while telling or answering a probe; then the next probe, or Next once the rep is done.
    @ViewBuilder
    private var storyAction: some View {
        switch viewModel.storyStage {
        case .telling:
            PrepPrimaryButton(title: viewModel.answerFloor.submitTitle, enabled: viewModel.canSubmitStoryAnswer && !micBusy,
                              isGrading: viewModel.isSubmitting) { Task { await viewModel.submitStory() } }
        case .probing:
            PrepPrimaryButton(title: viewModel.answerFloor.submitTitle, enabled: viewModel.canSubmitStoryAnswer && !micBusy,
                              isGrading: viewModel.isSubmitting) { Task { await viewModel.submitProbe() } }
        case .told, .probed:
            if let next = viewModel.nextProbe {
                PrepPrimaryButton(title: PrepCopy.probeLabel(next.number)) { viewModel.beginProbe() }
            } else {
                PrepPrimaryButton(title: "Next") { Task { await viewModel.continue() } }
            }
        }
    }

    private func choose(_ option: PrepOption, in rep: PrepRep) {
        chosen = ChosenOption(rep: rep.index, id: option.id)
        Task { await viewModel.choose(.choice(option.id)) }
    }

    private func quit() {
        viewModel.leave()
        dismiss()
    }

    /// Typed, dictated or still-transcribing words the server hasn't seen.
    private var hasUnsentAnswer: Bool {
        if viewModel.hasUnsentText || micBusy { return true }
        guard case let .rep(rep, _) = viewModel.phase else { return false }
        let local = draft(for: rep)
        return !local.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || local.line != nil
            || local.choice != nil
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

/// The end of a run outside the course: the streak and Done.
struct PrepRunCompleteView: View {
    let streak: PrepStreak
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                SectionCard {
                    BrainRow(
                        title: PrepCopy.streakTitle(days: streak.days),
                        subtitle: PrepCopy.streakSubtitle(days: streak.days, freezes: streak.freezes))
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
