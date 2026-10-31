import SwiftUI

/// The live workout (board 2C), pushed as `.bodyWorkout(day)`: the rough-night and morning-hinge
/// offers, then every lift in order. The open lift is a glow card with its sets; done lifts fold
/// to their reps and upcoming ones to their prescription. Ticking a lift's last set opens the
/// next. Changes save as he goes; leaving the screen or the app sends anything still waiting.
struct WorkoutView: View {
    @State private var viewModel: WorkoutViewModel
    @State private var showsFinish = false
    private let client: BodyDataClient
    private let onAPIError: (Error) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(day: String?, server: URL, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientBodyAdapter(apiClient: APIClient(baseURL: server))
        self.client = client
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: WorkoutViewModel(client: client, day: day, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        content
            .hxNavigationTitle(title, subtitle: subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
            .onDisappear { viewModel.saveNow() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    saveInBackground()
                } else if phase != .active {
                    viewModel.saveNow()
                }
            }
            .navigationDestination(isPresented: $showsFinish) {
                // Done leaves the workout too: it is closed, and Body home is where he lands.
                WorkoutFinishView(workout: viewModel, client: client, onAPIError: onAPIError) { dismiss() }
            }
    }

    /// Sends what's waiting while iOS gives the app a little time in the background.
    private func saveInBackground() {
        let background = WorkoutBackgroundSave()
        background.begin()
        viewModel.saveNow()
        Task { [viewModel] in
            await viewModel.idle()
            background.end()
        }
    }

    private var title: String {
        (viewModel.session?.day ?? viewModel.day)?.capitalized ?? "Workout"
    }

    private var subtitle: String? {
        if viewModel.saveStatus == .failed { return "Not saved" }
        if viewModel.saveStatus == .finished { return "Already finished" }
        guard let session = viewModel.session else { return nil }
        return WorkoutCopy.phaseLabel(session.phase, deload: session.deload)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No Body on this server") } icon: {
                    Image(systemName: "figure.strengthtraining.traditional")
                }
            } description: {
                Text(verbatim: "This server doesn't serve Body. It needs the Body API from your hermes-webui fork.")
            }
        case .failed(let message):
            PrepFailedView(title: "Couldn't load the workout", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let session):
            if session.exercises.isEmpty {
                ContentUnavailableView {
                    Label { Text(verbatim: "Nothing to lift today") } icon: {
                        Image(systemName: "figure.walk")
                    }
                } description: {
                    Text(verbatim: session.phase == "recover"
                        ? "Recover week: no lifting yet. Walk, stretch, and sleep."
                        : "Lifting starts with Re-entry.")
                }
            } else {
                workout(session)
            }
        }
    }

    private func workout(_ session: BodySession) -> some View {
        ScrollViewReader { proxy in
            List {
                if viewModel.saveStatus == .failed { notSavedRow.workoutPlainRow() }
                if viewModel.saveStatus == .finished { finishedRow.workoutPlainRow() }
                if viewModel.sleepBanner != .hidden { sleepBanner.workoutPlainRow() }
                if viewModel.hingeBanner != .hidden { hingeBanner.workoutPlainRow() }
                ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, lift in
                    let startsSection = index == 0 || session.exercises[index - 1].section != lift.section
                    liftRows(lift, index: index, startsSection: startsSection)
                }
                finishButton.workoutPlainRow()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            // A resumed workout opens on its first unfinished lift, which may be far down.
            // A fresh one starts at the top, where the offers are.
            .onAppear { if viewModel.current > 0 { scrollToOpenLift(proxy, animated: false) } }
            .onChange(of: viewModel.current) { scrollToOpenLift(proxy, animated: !reduceMotion) }
        }
    }

    private func scrollToOpenLift(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let exercises = viewModel.session?.exercises, exercises.indices.contains(viewModel.current) else { return }
        let id = exercises[viewModel.current].id
        if animated {
            withAnimation(HXMotion.scroll(reduceMotion: reduceMotion)) { proxy.scrollTo(id, anchor: .top) }
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    @ViewBuilder
    private func liftRows(_ lift: BodyExercise, index: Int, startsSection: Bool) -> some View {
        if startsSection {
            HXSectionHeader(title: WorkoutCopy.sectionTitle(lift.section))
                .padding(.top, 8)
                .workoutPlainRow()
        }
        if index == viewModel.current {
            WorkoutCardHeader(lift: lift)
                .equatable()
                .workoutCardRow(.top)
                .id(lift.id)
            ForEach(Array(lift.sets.enumerated()), id: \.element.uid) { setIndex, _ in
                WorkoutSetRow(lift: lift, exercise: index, index: setIndex, viewModel: viewModel)
                    .equatable()
                    .workoutCardRow(.middle)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if WorkoutViewModel.canDelete(set: setIndex, of: lift) {
                            Button(role: .destructive) {
                                viewModel.deleteSet(exercise: index, set: setIndex)
                            } label: {
                                Label { Text(verbatim: "Delete") } icon: { Image(systemName: "trash") }
                            }
                        }
                    }
            }
            if viewModel.effortPrompt == index {
                WorkoutEffortRow(answer: lift.repsLeft, viewModel: viewModel)
                    .equatable()
                    .workoutCardRow(.middle)
            }
            WorkoutCardFooter(exercise: index, canRemove: lift.workSets.count > 1, viewModel: viewModel)
                .equatable()
                .workoutCardRow(.bottom)
        } else {
            WorkoutFoldedRow(lift: lift, index: index, viewModel: viewModel)
                .equatable()
                .workoutPlainRow()
                .id(lift.id)
        }
    }

    // MARK: Banners

    private var notSavedRow: some View {
        HStack(spacing: 10) {
            Text(verbatim: "Not saved yet. Your sets are kept on this phone.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
            Spacer(minLength: 8)
            Button { viewModel.saveNow() } label: {
                Text(verbatim: "Retry").font(AppFont.subheadline(weight: .semibold))
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        }
    }

    private var finishedRow: some View {
        Text(verbatim: "This workout was already finished. Changes here aren't saved.")
            .font(AppFont.footnote())
            .foregroundStyle(Color.hxTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder
    private var sleepBanner: some View {
        let notes = HermexPaper.notes
        if viewModel.sleepBanner == .asking {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "moon.fill")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(notes.glow)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: viewModel.sleepOffer.map(WorkoutCopy.sleepTitle) ?? "Rough night")
                            .font(AppFont.display(style: .headline, weight: .semibold))
                            .foregroundStyle(notes.glow)
                        Text(verbatim: "Drop one set from each lift? The warm-up and finisher stay.")
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { viewModel.acceptSleepOffer() } label: { Text(verbatim: "Drop a set") }
                        .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
                    Button { viewModel.keepAllSets() } label: { Text(verbatim: "Keep them all") }
                        .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                }
            }
            .padding(14)
            .glowSurface(notes, cornerRadius: HXRadius.lg, opaque: true)
        } else {
            undoBanner("One set dropped from each lift.", paper: notes) { viewModel.undoSleepOffer() }
        }
    }

    @ViewBuilder
    private var hingeBanner: some View {
        let notes = HermexPaper.notes
        if viewModel.hingeBanner == .asking {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sunrise.fill")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(notes.glow)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: WorkoutCopy.hingeTitle(minutes: viewModel.hingeMinutes))
                            .font(AppFont.display(style: .headline, weight: .semibold))
                            .foregroundStyle(notes.glow)
                        Text(verbatim: WorkoutCopy.hingeQuestion(viewModel.hingeNames))
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { viewModel.moveHinge() } label: { Text(verbatim: "Move to the end") }
                        .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
                    Button { viewModel.keepHingeOrder() } label: { Text(verbatim: "Keep the order") }
                        .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                }
            }
            .padding(14)
            .glowSurface(notes, cornerRadius: HXRadius.lg, opaque: true)
        } else {
            undoBanner("Moved to the end of the main lifts.", paper: notes) { viewModel.undoMoveHinge() }
        }
    }

    private func undoBanner(_ text: String, paper: HermexPaper, undo: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: text)
                .font(AppFont.subheadline())
                .foregroundStyle(paper.glow)
            Spacer(minLength: 8)
            Button(action: undo) {
                Text(verbatim: "Undo").font(AppFont.subheadline(weight: .semibold))
            }
            .buttonStyle(.borderless)
            .tint(.accentColor)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .glowSurface(paper, cornerRadius: HXRadius.md)
    }

    // MARK: Finish

    private var finishButton: some View {
        Button {
            viewModel.saveNow()
            showsFinish = true
        } label: {
            Text(verbatim: "Finish workout")
                .font(AppFont.display(style: .headline, weight: .semibold))
                .foregroundStyle(paper.onGlow)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(paper.glow)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}

// MARK: - Card slices

/// One slice of the open lift's glow card, drawn behind a List row.
struct WorkoutCardPiece: View {
    enum Position { case top, middle, bottom }
    let position: Position

    var body: some View {
        let top = position == .top ? HXRadius.xl : 0
        let bottom = position == .bottom ? HXRadius.xl : 0
        UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                               bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
            .fill(HermexPaper.training.card)
            .padding(.horizontal, WorkoutLayout.gutter)
            .padding(.top, position == .top ? WorkoutLayout.rowGap : 0)
            .padding(.bottom, position == .bottom ? WorkoutLayout.rowGap : 0)
    }
}

enum WorkoutLayout {
    /// The screen's side margin.
    static let gutter: CGFloat = 16
    /// Half the gap between folded rows.
    static let rowGap: CGFloat = 4
    /// The open card's inner side padding.
    static let cardInset: CGFloat = 14
    static let tagWidth: CGFloat = 30
    static let weightWidth: CGFloat = 72
    static let countWidth: CGFloat = 60
    static let checkSize: CGFloat = 44
    static let columnSpacing: CGFloat = 8
}

extension View {
    /// A row on the screen's canvas: banners, section labels, folded lifts, Finish.
    func workoutPlainRow() -> some View {
        listRowInsets(EdgeInsets(top: WorkoutLayout.rowGap, leading: WorkoutLayout.gutter,
                                 bottom: WorkoutLayout.rowGap, trailing: WorkoutLayout.gutter))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// A row inside the open lift's card.
    func workoutCardRow(_ position: WorkoutCardPiece.Position) -> some View {
        let side = WorkoutLayout.gutter + WorkoutLayout.cardInset
        return listRowInsets(EdgeInsets(
            top: position == .top ? WorkoutLayout.rowGap + 16 : 0, leading: side,
            bottom: position == .bottom ? WorkoutLayout.rowGap + 14 : 0, trailing: side))
            .listRowBackground(WorkoutCardPiece(position: position))
            .listRowSeparator(.hidden)
            .environment(\.hxPaper, .training)
    }
}

// MARK: - Open card rows

/// Board 6: after a big lift's last set, "How many more could you have done?" 0 / 1 / 2 / 3+.
struct WorkoutEffortRow: View, Equatable {
    let answer: Int?
    let viewModel: WorkoutViewModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.answer == rhs.answer }

    private static let choices: [(value: Int, label: String, spoken: String)] = [
        (0, "0", "None left"), (1, "1", "One left"), (2, "2", "Two left"), (3, "3+", "Three or more left"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "How many more could you have done?")
                .font(AppFont.display(style: .headline, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Self.choices, id: \.value) { choice in
                    Button { viewModel.setRepsLeft(choice.value) } label: {
                        Text(verbatim: choice.label).monospacedDigit()
                    }
                    .buttonStyle(ChatDecisionButtonStyle(emphasis: answer == choice.value ? .primary : .secondary))
                    .accessibilityLabel(Text(verbatim: choice.spoken))
                    .accessibilityAddTraits(answer == choice.value ? .isSelected : [])
                }
            }
            Text(verbatim: "Only on the last set of big lifts. Tap and the next lift opens.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.hxCanvas, in: RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous)
            .strokeBorder(HermexPaper.training.edge, lineWidth: 0.5))
        .padding(.vertical, 6)
    }
}

/// The open card's foot: + Add set and − Remove set, and how to change a set.
struct WorkoutCardFooter: View, Equatable {
    let exercise: Int
    let canRemove: Bool
    let viewModel: WorkoutViewModel

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.exercise == rhs.exercise && lhs.canRemove == rhs.canRemove
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { viewModel.addSet(exercise: exercise) } label: { Text(verbatim: "+ Add set") }
                    .accessibilityLabel(Text(verbatim: "Add a set"))
                Button { viewModel.removeSet(exercise: exercise) } label: { Text(verbatim: "− Remove set") }
                    .disabled(!canRemove)
                    .accessibilityLabel(Text(verbatim: "Remove the last set"))
            }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
            Text(verbatim: "Tap a number to change it · swipe a set to delete it")
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 6)
    }
}

/// A background task held while the last changes save, ended when they have or when iOS
/// runs out of time.
@MainActor
private final class WorkoutBackgroundSave {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Save workout") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
