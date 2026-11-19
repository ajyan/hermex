import SwiftUI

/// A lift's Form page, pushed as `.bodyLiftForm(id)` from the cue in the open lift's card and from
/// the lift's history: what Baki has him working on, the cues to choose from, the setup, what goes
/// wrong and its fix, where to feel it, what keeps him safe, and where it all came from.
struct LiftFormView: View {
    @State private var viewModel: LiftFormViewModel
    private let id: String

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        self.id = id
        let client = APIClientBodyAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: LiftFormViewModel(client: client, id: id, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        content
            .hxLoadSwap(viewModel.state.phase)
            .hxNavigationTitle(title, subtitle: "Form")
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    private var title: String {
        if let name = viewModel.lift?.name, !name.isEmpty { return name }
        return "Lift"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            HXModuleHomePlaceholder(name: "Form")
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "Lift not found") } icon: { Image(systemName: "figure.strengthtraining.traditional") }
            } description: {
                Text(verbatim: "This server doesn't have a lift with that name. It may have been removed from the plan.")
            }
        case .failed(let message):
            HXFailedView(title: "Couldn't load this lift's form", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let lift):
            if let form = lift.form {
                ScrollView {
                    VStack(alignment: .leading, spacing: BrainStyle.l) {
                        if let focus = form.focus { focusCard(focus) }
                        if !form.cues.isEmpty { cues(form) }
                        if !form.setup.isEmpty { setup(form.setup) }
                        if !form.faults.isEmpty { faults(form.faults) }
                        if !form.feel.isEmpty { feel(form.feel) }
                        if let safety = form.safety, !safety.isEmpty {
                            safetyNote(safety, loads: LiftFormCopy.loads(lift))
                        }
                        if !form.sources.isEmpty { sources(form.sources) }
                    }
                    .padding(BrainStyle.l)
                    .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
                }
                .refreshable { await viewModel.load() }
            } else {
                ContentUnavailableView {
                    Label { Text(verbatim: "No form notes yet") } icon: { Image(systemName: "figure.strengthtraining.traditional") }
                } description: {
                    Text(verbatim: "Baki hasn't written a cue card for this lift.")
                }
            }
        }
    }

    // MARK: Focus

    /// Baki's focus on a wash card in Body's paper: the lift's diagram (once it has one), the focus
    /// as the title, why, and a pip per day he has checked it.
    private func focusCard(_ focus: BodyFormFocus) -> some View {
        HXCard(.wash(paper), title: focus.title, spacing: 10) {
            BodyCoachKicker(text: "Baki · your focus")
            CueDiagramSlot(liftID: id, large: true)
        } content: {
            if !focus.body.isEmpty {
                Text(verbatim: focus.body)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(verbatim: "Days with this focus")
                    .font(AppFont.footnote())
                    .foregroundStyle(.hxSecondary)
                Spacer(minLength: 8)
                BodyFocusPips(checks: focus.checks, size: 10)
            }
            .accessibilityElement(children: .combine)
        } footer: {
            EmptyView()
        }
    }

    // MARK: Cues

    private func cues(_ form: BodyForm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Cue", trailing: "Tap one to use it")
            VStack(spacing: 0) {
                ForEach(Array(form.cues.enumerated()), id: \.offset) { index, cue in
                    if index > 0 { PrepRowDivider().padding(.leading, 14) }
                    cueRow(cue, index: index, picked: form.picked == index)
                }
            }
            .hxCard()
            .disabled(viewModel.picking != nil)
            if let error = viewModel.pickError {
                Text(verbatim: error)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cueRow(_ cue: String, index: Int, picked: Bool) -> some View {
        Button { Task { await viewModel.pick(index) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "\(index + 1)")
                    .font(AppFont.footnote())
                    .monospacedDigit()
                    .foregroundStyle(.hxSecondary)
                Text(verbatim: cue)
                    .font(AppFont.body(weight: picked ? .semibold : nil))
                    .foregroundStyle(Color.hxTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if picked {
                    Image(systemName: "checkmark")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(paper.glow)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.chatTactile(.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: LiftFormCopy.cueLabel(cue, index: index)))
        .accessibilityHint(Text(verbatim: picked ? "The cue Baki uses" : "Uses this cue"))
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Setup, faults, feel

    private func setup(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Setup")
            Text(verbatim: text)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func faults(_ faults: [BodyFormFault]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "If it goes wrong")
            VStack(spacing: 0) {
                ForEach(Array(faults.enumerated()), id: \.offset) { index, fault in
                    if index > 0 { PrepRowDivider().padding(.leading, 14) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: fault.fault)
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: fault.fix)
                            .font(AppFont.subheadline())
                            .foregroundStyle(.hxSecondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .hxCard()
        }
    }

    private func feel(_ muscles: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Feel it in")
            FlowRow(spacing: 6) {
                ForEach(Array(muscles.enumerated()), id: \.offset) { _, muscle in
                    HXChip(paper: paper, label: muscle)
                }
            }
        }
    }

    /// The card's safety line, under a header that names what the lift loads.
    private func safetyNote(_ text: String, loads: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: WorkoutCoach.safetyHeader(loads: loads))
            Text(verbatim: text)
                .font(AppFont.footnote())
                .foregroundStyle(.hxSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Sources

    private func sources(_ sources: [BodyFormSource]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HXSectionHeader(title: "Sources")
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                let title = source.title.isEmpty ? source.url : source.title
                if let url = URL(string: source.url), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) {
                        Text(verbatim: title)
                            .font(AppFont.footnote())
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint(Text(verbatim: "Opens in your browser"))
                } else if !title.isEmpty {
                    Text(verbatim: title)
                        .font(AppFont.footnote())
                        .foregroundStyle(.hxSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }
}
