import SwiftUI

/// The finish check and Baki's note (board 7), pushed from the workout's Finish button. He answers
/// three questions and saves; the screen then waits for Baki's note, which the server writes a
/// little later, and shows any proposals the rules raised. Done leaves for Body home.
struct WorkoutFinishView: View {
    @State private var viewModel: WorkoutFinishViewModel
    private let onDone: () -> Void
    @Environment(\.openDraftChat) private var openDraftChat

    init(workout: WorkoutViewModel, client: BodyDataClient, onAPIError: @escaping (Error) -> Void = { _ in },
         onDone: @escaping () -> Void) {
        self.onDone = onDone
        _viewModel = State(initialValue: WorkoutFinishViewModel(workout: workout, client: client, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                if viewModel.phase == .saved {
                    saved
                } else {
                    checkCard
                }
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await viewModel.refreshNote() }
        .hxNavigationTitle(WorkoutFinishCopy.title(day: viewModel.day), subtitle: viewModel.summary)
        .background(Color.hxCanvas.ignoresSafeArea())
        // Once he saves, the workout is closed and Done is the only way on; while it saves, Back would
        // leave a request in flight.
        .navigationBarBackButtonHidden(viewModel.phase != .asking)
        // Once saved, waits for Baki's note; leaving the screen cancels the wait.
        .task(id: viewModel.phase) { await viewModel.awaitNote() }
    }

    // MARK: The check

    private var checkCard: some View {
        HXCard(.neutral, spacing: 18) {
            question("How hard was it?") {
                choices($viewModel.effort, [(.easy, "Easy"), (.solid, "Solid"), (.grinder, "Grinder")])
            }
            question("Lower back") {
                choices($viewModel.back, Self.conditions)
            }
            question("Shoulder blades") {
                choices($viewModel.shoulders, Self.conditions)
            }
            if viewModel.asksPain { painDetails }
            noteField
            if let error = viewModel.saveError {
                Text(verbatim: error)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            saveButton
        }
        .disabled(viewModel.phase == .saving)
    }

    private static let conditions: [(BodyCondition, String)] = [(.fine, "Fine"), (.tight, "Tight"), (.pain, "Pain")]

    private func question<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// Capsules in a row; the chosen one fills with the training hue.
    private func choices<Value: Hashable>(_ selection: Binding<Value>, _ options: [(Value, String)]) -> some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { value, title in
                let isSelected = selection.wrappedValue == value
                Button { selection.wrappedValue = value } label: { Text(verbatim: title).bodyTapHeight() }
                    .buttonStyle(ChatDecisionButtonStyle(emphasis: isSelected ? .primary : .secondary))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .environment(\.hxPaper, paper)
    }

    /// Pain asks how bad it was (0 to 10) and on which lift.
    private var painDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            question("How bad? 0 is none, 10 is the worst") {
                HStack(spacing: 14) {
                    stepButton(symbol: "minus", label: "Less pain", delta: -1)
                    Text(verbatim: viewModel.painScore.map(String.init) ?? "—")
                        .font(AppFont.display(style: .title2, weight: .bold))
                        .foregroundStyle(paper.glow)
                        .monospacedDigit()
                        .frame(minWidth: 44)
                        .accessibilityLabel(Text(verbatim: viewModel.painScore.map { "Pain \($0) out of 10" } ?? "No score yet"))
                    stepButton(symbol: "plus", label: "More pain", delta: 1)
                }
            }
            question("Which lift?") {
                Menu {
                    ForEach(viewModel.painLifts) { lift in
                        Button(lift.name) { viewModel.painLift = lift.id }
                    }
                } label: {
                    HStack {
                        Text(verbatim: viewModel.painLifts.first { $0.id == viewModel.painLift }?.name ?? "Choose a lift")
                            .font(AppFont.body())
                            .foregroundStyle(viewModel.painLift == nil ? Color.hxTextSecondary : Color.hxTextPrimary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(AppFont.caption())
                            .foregroundStyle(Color.hxTextSecondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .modifier(FinishFieldBackground())
                }
            }
        }
    }

    private func stepButton(symbol: String, label: String, delta: Int) -> some View {
        Button { viewModel.stepPain(delta) } label: {
            Image(systemName: symbol)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(paper.glow)
                .frame(width: 44, height: 44)
                .background(paper.wash, in: Circle())
                .overlay(Circle().strokeBorder(paper.edge, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text(verbatim: "Anything else? ").font(AppFont.subheadline(weight: .semibold)).foregroundStyle(Color.hxTextPrimary)
                + Text(verbatim: "optional").font(AppFont.subheadline()).foregroundStyle(Color.hxTextSecondary))
                .accessibilityAddTraits(.isHeader)
            TextField(text: $viewModel.note, axis: .vertical) { Text(verbatim: "How it felt, what to watch") }
                .lineLimit(1...4)
                .font(AppFont.body())
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44, alignment: .topLeading)
                .modifier(FinishFieldBackground())
        }
    }

    private var saveButton: some View {
        Button { Task { await viewModel.save() } } label: {
            Group {
                if viewModel.phase == .saving {
                    ProgressView()
                } else {
                    Text(verbatim: "Save workout")
                }
            }
            .font(AppFont.display(style: .headline, weight: .semibold))
            // A disabled prominent button dims its fill, so the label drops the on-glow color to stay readable.
            .foregroundStyle(viewModel.canSave ? paper.onGlow : Color.hxTextSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(paper.glow)
        .disabled(!viewModel.canSave)
    }

    // MARK: After saving

    @ViewBuilder
    private var saved: some View {
        if let note = viewModel.coachNote {
            coachCard(note)
        } else {
            Text(verbatim: "The coach's note will be here shortly.")
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HXCard<EmptyView, EmptyView, EmptyView>.padding)
                .hxCard()
        }
        // What the rules raised from this workout; undecided ones wait on Body home.
        BodyProposalCards(proposals: viewModel.proposals, deciding: viewModel.deciding, error: viewModel.decideError) { proposal, accept in
            Task { await viewModel.decide(proposal, accept: accept) }
        }
        if viewModel.coachNote == nil { doneButton }
    }

    private func coachCard(_ note: BodyCoachNote) -> some View {
        HXCard(.glow(paper), title: note.headline, titleStyle: .title3, spacing: 10) {
            BodyCoachKicker(text: WorkoutFinishCopy.kicker(day: viewModel.day))
        } content: {
            ForEach(Array(note.body.enumerated()), id: \.offset) { _, paragraph in
                Text(verbatim: paragraph)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack(spacing: 8) {
                if openDraftChat.isAvailable {
                    Button { openDraftChat(BodyAskBaki.draft) } label: { Text(verbatim: "Ask Baki") }
                        .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                }
                Button(action: onDone) { Text(verbatim: "Done") }
                    .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
            }
            .environment(\.hxPaper, paper)
            .padding(.top, 4)
        }
    }

    private var doneButton: some View {
        Button(action: onDone) { Text(verbatim: "Done") }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
            .environment(\.hxPaper, paper)
    }
}

/// An input's fill on a neutral card: the canvas with a hairline, like the board's text fields.
private struct FinishFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
        content
            .background(Color.hxCanvas, in: shape)
            .overlay(shape.strokeBorder(Color.hxSeparator, lineWidth: 0.5))
    }
}

/// The small label above Baki's words on a glow card: a person symbol and who is speaking
/// ("Baki suggests", "Baki · after Push").
struct BodyCoachKicker: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.fill")
                .font(AppFont.caption2(weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(AppFont.caption(weight: .semibold))
        }
        .foregroundStyle(HermexPaper.training.glow)
    }
}
