import SwiftUI

/// One feedback entry, laid out for steering from the phone: the plan's questions first, then
/// what changes, what was sent, and the technical details folded away. A plan written before
/// the steering format shows its Markdown whole. The decisions its status allows sit in a bar
/// at the bottom; Reject is in the header menu. Reads the entry from the inbox, so a decision
/// updates both screens.
struct FeedbackDetailView: View {
    let entryID: String
    let viewModel: FeedbackInboxViewModel
    @State private var plan: BrainLoadState<FeedbackPlan> = .loading
    @State private var answers = FeedbackAnswers()
    @State private var replyTarget: FeedbackEntry?
    @State private var isConfirmingReject = false

    var body: some View {
        Group {
            if let entry = viewModel.entry(id: entryID) {
                content(entry)
                    .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(entry) }
                    .task(id: entry.status) { await loadPlan(entry) }
                    .toolbar { menu(entry) }
                    .confirmationDialog(
                        Text(verbatim: entry.status == .ready ? "Reject this branch?" : "Reject this plan?"),
                        isPresented: $isConfirmingReject,
                        titleVisibility: .visible
                    ) {
                        Button(role: .destructive) { decide(entry, .reject) } label: { Text(verbatim: "Reject") }
                    } message: {
                        Text(verbatim: entry.status == .ready
                             ? "It moves to Done. The branch stays on your Mac until you delete it."
                             : "It moves to Done and won't be built.")
                    }
            } else {
                ContentUnavailableView {
                    Label { Text(verbatim: "This feedback is gone") } icon: { Image(systemName: "tray") }
                }
            }
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle("Plan")
        .feedbackReplyPrompt(for: $replyTarget, viewModel: viewModel)
        .onDisappear { viewModel.clearError() }
    }

    /// The loaded plan when it has the steering parts.
    private var steerable: FeedbackPlan? {
        if case .loaded(let plan) = plan, plan.isSteerable { return plan }
        return nil
    }

    private func content(_ entry: FeedbackEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Above everything: a 409 reload can move the entry past its action bar.
                if let error = viewModel.error {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(AppFont.footnote(weight: .medium))
                        .foregroundStyle(Color.hxDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.headline)
                        .font(AppFont.display(style: .title3))
                        .foregroundStyle(Color.hxTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    let meta = entry.isMerged ? viewModel.metaLine(for: entry) : entry.detailMetaLine
                    if !meta.isEmpty {
                        Text(verbatim: meta)
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }

                if let steerable, entry.status == .planned, !steerable.questions.isEmpty {
                    FeedbackQuestionsCard(questions: steerable.questions, answers: $answers)
                }

                if let error = entry.status == .failed ? entry.error : nil, !error.isEmpty {
                    block("Error") {
                        Text(verbatim: error)
                            .font(AppFont.mono(style: .footnote))
                            .foregroundStyle(Color.hxDanger)
                            .textSelection(.enabled)
                    }
                }

                if entry.status == .ready {
                    if let branch = entry.branch, !branch.isEmpty {
                        block("Branch") {
                            Text(verbatim: [entry.repo, branch].compactMap { $0 }.joined(separator: " · "))
                                .font(AppFont.mono(style: .footnote))
                                .foregroundStyle(Color.hxTextPrimary)
                                .textSelection(.enabled)
                        }
                    }
                    if let tests = entry.tests, !tests.isEmpty {
                        block("Tests") { monospaced(tests) }
                    }
                }

                if let changes = steerable?.changes {
                    block("What changes") {
                        Text(verbatim: changes)
                            .font(AppFont.body())
                            .foregroundStyle(Color.hxTextPrimary)
                            .textSelection(.enabled)
                    }
                }

                block("You said") {
                    Text(verbatim: entry.text)
                        .font(BrainStyle.quote)
                        .foregroundStyle(Color.hxTextPrimary)
                        .textSelection(.enabled)
                    ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                        Text(verbatim: note.text)
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextSecondary)
                            .textSelection(.enabled)
                    }
                }

                let merged = viewModel.mergedNotes(into: entry.id)
                if !merged.isEmpty {
                    block("Also covers") {
                        ForEach(merged) { note in mergedNote(note) }
                    }
                }

                if let steerable {
                    if let details = steerable.details {
                        FeedbackDetailsDisclosure(markdown: details)
                    }
                } else {
                    block("Plan") { planContent }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
    }

    /// The whole plan, for an entry without one yet or a plan written before the steering format.
    @ViewBuilder
    private var planContent: some View {
        switch plan {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        case .unavailable:
            Text(verbatim: viewModel.entry(id: entryID)?.status.noPlanText ?? FeedbackStatus.new.noPlanText)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextSecondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                Button {
                    guard let entry = viewModel.entry(id: entryID) else { return }
                    Task { await loadPlan(entry) }
                } label: {
                    Text(verbatim: "Try again")
                }
            }
        case .loaded(let plan):
            MarkdownRenderer(content: plan.body)
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func monospaced(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(verbatim: text)
                .font(AppFont.mono(style: .caption))
                .foregroundStyle(Color.hxTextPrimary)
                .textSelection(.enabled)
                .padding(10)
        }
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
    }

    /// A note the nightly job folded into this entry's plan, with Unmerge to plan it on its own again.
    private func mergedNote(_ note: FeedbackEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: note.text)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if viewModel.pendingID == note.id {
                ProgressView().accessibilityLabel(Text(verbatim: "Saving"))
            }
            Button { decide(note, .unmerge) } label: { Text(verbatim: "Unmerge") }
                .buttonStyle(.bordered)
                .tint(Color.hxTextPrimary)
                .font(AppFont.subheadline(weight: .semibold))
                .disabled(viewModel.pendingID != nil)
                .accessibilityHint(Text(verbatim: "Gets its own plan tonight."))
        }
    }

    // MARK: - Decisions

    @ToolbarContentBuilder
    private func menu(_ entry: FeedbackEntry) -> some ToolbarContent {
        if entry.status.canReject {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { isConfirmingReject = true } label: {
                        Label { Text(verbatim: "Reject…") } icon: { Image(systemName: "xmark") }
                    }
                } label: {
                    Label { Text(verbatim: "More") } icon: { Image(systemName: "ellipsis") }
                }
                .disabled(viewModel.pendingID != nil)
            }
        }
    }

    @ViewBuilder
    private func actionBar(_ entry: FeedbackEntry) -> some View {
        if entry.status.hasDecisions {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.pendingID == entry.id {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(verbatim: "Saving…")
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack(spacing: 8) { actions(entry) }
                    .font(AppFont.body(weight: .semibold))
                    .controlSize(.large)
                    .disabled(viewModel.pendingID != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.hxCanvas)
            .overlay(alignment: .top) { Divider().overlay(Color.hxSeparator) }
        }
    }

    @ViewBuilder
    private func actions(_ entry: FeedbackEntry) -> some View {
        switch entry.status {
        case .planned:
            let note = steerable.flatMap { answers.note(for: $0.questions) }
            Button {
                if let note { decide(entry, .reply(note)) } else { replyTarget = entry }
            } label: {
                wide(note == nil ? "Redo plan" : "Send answers")
            }
            .buttonStyle(.bordered)
            .tint(Color.hxTextPrimary)
            .accessibilityHint(Text(verbatim: note == nil
                                    ? "Tell the planner what to change. It replans tonight."
                                    : "The planner replans tonight with your answers."))
            Button {
                decide(entry, note.map(FeedbackDecision.approveAnswering) ?? .approve)
            } label: {
                wide("Approve")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(Text(verbatim: note == nil
                                    ? "Builds it tonight. Unanswered questions take the recommended answer."
                                    : "Builds it tonight with your answers."))
        case .ready:
            Button { decide(entry, .merged) } label: { wide("Mark merged") }
                .buttonStyle(.borderedProminent)
        case .failed:
            Button { decide(entry, .retry) } label: { wide("Retry") }
                .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }

    private func wide(_ title: String) -> some View {
        Text(verbatim: title).frame(maxWidth: .infinity)
    }

    private func decide(_ entry: FeedbackEntry, _ decision: FeedbackDecision) {
        Task { await viewModel.decide(entry, decision) }
    }

    /// Entries still waiting for a plan have none to fetch.
    private func loadPlan(_ entry: FeedbackEntry) async {
        guard entry.status != .new, entry.status != .planning else {
            plan = .unavailable
            return
        }
        plan = .loading
        let result = await viewModel.plan(for: entry)
        guard !Task.isCancelled else { return }
        plan = result
    }
}

/// The plan's questions as a request card: each question with its answers as choice buttons
/// and "Other…" for a typed answer. Nothing is preselected; the recommended answer is labeled.
private struct FeedbackQuestionsCard: View {
    let questions: [FeedbackQuestion]
    @Binding var answers: FeedbackAnswers
    @State private var otherTarget: Int?
    @State private var otherText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(verbatim: questions.count == 1 ? "1 question" : "\(questions.count) questions")
            } icon: {
                Image(systemName: "questionmark.circle")
            }
            .font(AppFont.display(style: .subheadline))
            .foregroundStyle(HermexPaper.request.glow)
            .accessibilityAddTraits(.isHeader)

            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\(index + 1). \(question.text)")
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(Color.hxTextPrimary)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { option, answer in
                        choice(answer.text,
                               note: answer.recommended ? "recommended" : nil,
                               isPicked: answers.pick(for: index) == .option(option)) {
                            answers.toggle(option, for: index)
                        }
                    }
                    let typed: String? = if case .other(let text)? = answers.pick(for: index) { text } else { nil }
                    choice(typed ?? "Other…", note: nil, isPicked: typed != nil, dashed: typed == nil) {
                        otherText = typed ?? ""
                        otherTarget = index
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowSurface(.request, cornerRadius: HXRadius.lg)
        .alert(
            Text(verbatim: "Your answer"),
            isPresented: Binding(get: { otherTarget != nil }, set: { if !$0 { otherTarget = nil } })
        ) {
            TextField(text: $otherText) { Text(verbatim: "Answer in your words") }
            Button {
                if let otherTarget { answers.setOther(otherText, for: otherTarget) }
            } label: {
                Text(verbatim: "Done")
            }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        }
    }

    private func choice(_ title: String, note: String?, isPicked: Bool, dashed: Bool = false,
                        action: @escaping () -> Void) -> some View {
        let paper = HermexPaper.request
        let shape = RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous)
        return Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title)
                    .font(AppFont.subheadline(weight: .medium))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note {
                    Text(verbatim: note)
                        .font(AppFont.caption())
                }
                if isPicked {
                    Image(systemName: "checkmark")
                        .font(AppFont.caption(weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isPicked ? paper.onGlow : paper.glow)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(isPicked ? paper.glow : paper.wash, in: shape)
            .overlay(shape.strokeBorder(isPicked ? paper.glow : paper.edge,
                                        style: StrokeStyle(lineWidth: 0.5, dash: dashed ? [4, 3] : [])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: [title, note].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}

/// The plan's Details section, folded away in a neutral card.
private struct FeedbackDetailsDisclosure: View {
    let markdown: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownRenderer(content: markdown)
                .padding(.top, 8)
        } label: {
            Text(verbatim: "Technical details")
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(Color.hxTextPrimary)
        }
        .tint(Color.hxTextSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .hxCard()
    }
}
