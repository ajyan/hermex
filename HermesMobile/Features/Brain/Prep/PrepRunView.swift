import SwiftUI

/// Today's run, one rep per screen. Pushed as `.brainRoute(.prep(.run))`; owns no
/// `NavigationStack`. Closing pops: the server records every answer, so closing is
/// save and quit. The drills themselves live in `PrepDrillViews.swift`.
struct PrepRunView: View {
    @State private var viewModel: PrepRunViewModel
    @State private var didLoad = false
    /// The option tapped on a choice rep, kept to mark it once graded.
    @State private var chosen: ChosenOption?
    @Environment(\.dismiss) private var dismiss

    private struct ChosenOption: Equatable {
        let rep: Int
        let id: String
    }

    init(server: URL) {
        _viewModel = State(initialValue: PrepRunViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server))))
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
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
            }
            .background(Color.hxCanvas.ignoresSafeArea())
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
            scaffold(rep) { repContent(rep) }
                // Fresh view state (timer start, example toggle) for every rep.
                .id(rep.index)
        case .result(let rep, let result, _):
            scaffold(rep) {
                PrepResultView(
                    rep: rep,
                    result: result,
                    chosenID: chosen?.rep == rep.index ? chosen?.id : nil,
                    placedLines: viewModel.board?.placed ?? [],
                    onContinue: { Task { await viewModel.continue() } }
                )
            }
            .id(rep.index)
        case .finished(let streak, let moved):
            PrepRunCompleteView(streak: streak, moved: moved) { dismiss() }
        }
    }

    /// A rep's screen: the progress bar and problem card pinned over the drill's scroll view.
    private func scaffold<Content: View>(_ rep: PrepRep, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
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
                PrepProblemCard(rep: rep)
            }
            .padding(.horizontal, BrainStyle.l)
            .padding(.bottom, BrainStyle.s)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            .background(Color.hxCanvas)
        }
    }

    @ViewBuilder
    private func repContent(_ rep: PrepRep) -> some View {
        switch rep.drill {
        case .patternID, .complexity:
            PrepChoiceView(
                rep: rep,
                grading: nil,
                isSubmitting: viewModel.isSubmitting,
                submitError: viewModel.submitError
            ) { option in
                chosen = ChosenOption(rep: rep.index, id: option.id)
                Task { await viewModel.choose(.choice(option.id)) }
            }
        case .parsons:
            if let board = viewModel.board {
                PrepParsonsView(
                    hints: rep.item.hints,
                    board: board,
                    hintsShown: viewModel.hintsShown,
                    isSubmitting: viewModel.isSubmitting,
                    submitError: viewModel.submitError,
                    place: { viewModel.place(poolIndex: $0) },
                    unplace: { viewModel.unplace(at: $0) },
                    showHint: { viewModel.showHint() },
                    check: { Task { await viewModel.checkParsons() } }
                )
            }
        case .primer:
            PrepPrimerView(
                item: rep.item,
                isSubmitting: viewModel.isSubmitting,
                submitError: viewModel.submitError
            ) {
                Task { await viewModel.acknowledgePrimer() }
            }
        case .unknown:
            EmptyView()
        }
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
                    BrainRow(title: PrepCopy.streak(days: streak.days), subtitle: PrepCopy.freezes(streak.freezes))
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
