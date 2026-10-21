import SwiftUI

/// One feedback entry, laid out around the decision it waits on. A stage track shows where it
/// is (You said → Plan → Build → Merge); then what changes as Now → After, the plan's
/// questions or the build's checks, and what it touches. The full plan and build report open
/// in a sheet. The decisions sit in a bar at the bottom, each naming what it starts (Drop on
/// a note still waiting for tonight, Undo on a shipped fix, Redo plan on an undone one). Reads
/// the entry from the inbox, so a decision updates both screens.
struct FeedbackDetailView: View {
    let entryID: String
    let viewModel: FeedbackInboxViewModel
    @State private var plan: BrainLoadState<FeedbackPlan> = .loading
    @State private var answers = FeedbackAnswers()
    @State private var replyTarget: FeedbackEntry?
    @State private var isConfirmingReject = false
    @State private var isConfirmingUndo = false
    @State private var sheet: Sheet?
    @State private var showsWholeQuote = false

    private enum Sheet: String, Identifiable {
        case plan, report
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let entry = viewModel.entry(id: entryID) {
                content(entry)
                    .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(entry) }
                    .task(id: entry.status) { await loadPlan(entry) }
                    .confirmationDialog(
                        Text(verbatim: entry.status.rejectConfirmation.title),
                        isPresented: $isConfirmingReject,
                        titleVisibility: .visible
                    ) {
                        Button(role: .destructive) { decide(entry, .reject) } label: { Text(verbatim: "Drop") }
                    } message: {
                        Text(verbatim: entry.status.rejectConfirmation.message)
                    }
                    .confirmationDialog(
                        Text(verbatim: "Undo this fix?"),
                        isPresented: $isConfirmingUndo,
                        titleVisibility: .visible
                    ) {
                        Button(role: .destructive) { decide(entry, .undo) } label: { Text(verbatim: "Undo") }
                    } message: {
                        Text(verbatim: "Reverts this change on the vault's main branch.")
                    }
                    .sheet(item: $sheet) { sheet in sheetContent(sheet, entry) }
                    .hxNavigationTitle(entry.status.screenTitle)
                    .feedbackReplyPrompt(for: $replyTarget, viewModel: viewModel,
                                         prefix: steerable.flatMap { answers.note(for: $0.questions) })
            } else {
                ContentUnavailableView {
                    Label { Text(verbatim: "This feedback is gone") } icon: { Image(systemName: "tray") }
                }
                .hxNavigationTitle("Feedback")
            }
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .onDisappear { viewModel.clearError() }
    }

    /// The loaded plan when it has the steering parts.
    private var steerable: FeedbackPlan? {
        if case .loaded(let plan) = plan, plan.isSteerable { return plan }
        return nil
    }

    private var loadedPlan: FeedbackPlan? {
        if case .loaded(let plan) = plan { return plan }
        return nil
    }

    private func content(_ entry: FeedbackEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Above everything: a 409 reload can move the entry past its action bar.
                if let error = viewModel.error {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(AppFont.footnote(weight: .medium))
                        .foregroundStyle(Color.hxDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let stage = FeedbackStage(entry: entry) {
                    FeedbackStageTrack(stage: stage)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: entry.headline)
                        .font(AppFont.display(style: .title2))
                        .foregroundStyle(Color.hxTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    let meta = entry.isMerged ? viewModel.metaLine(for: entry) : metaLine(entry)
                    if !meta.isEmpty {
                        Text(verbatim: meta)
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }

                if let recurred = entry.recurred, recurred > 0 {
                    recurrence(recurred, evidence: entry.evidence)
                }

                youSaid(entry)

                let hasNowAfter = entry.now != nil || entry.after != nil
                // A plan without Now → After leads with its questions, ahead of the longer prose.
                if !hasNowAfter { questions(entry) }

                if hasNowAfter {
                    FeedbackNowAfterCard(entry: entry)
                } else if let changes = steerable?.changes ?? entry.summary {
                    block("What changes") {
                        Text(verbatim: changes)
                            .font(AppFont.body())
                            .foregroundStyle(Color.hxTextPrimary)
                            .textSelection(.enabled)
                    }
                } else if entry.status == .new || entry.status == .planning {
                    Text(verbatim: FeedbackStatus.new.noPlanText)
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextSecondary)
                }

                if hasNowAfter { questions(entry) }

                if entry.status == .failed {
                    block("What went wrong") {
                        Text(verbatim: entry.error?.isEmpty == false ? entry.error! : entry.status.noPlanText)
                            .font(AppFont.mono(style: .footnote))
                            .foregroundStyle(Color.hxDanger)
                            .lineLimit(8)
                            .textSelection(.enabled)
                    }
                }

                if entry.status == .ready || entry.status == .merged {
                    FeedbackChecksCard(entry: entry)
                } else if entry.status != .failed {
                    touches(entry)
                }

                let merged = viewModel.mergedNotes(into: entry.id)
                if !merged.isEmpty {
                    block("Also covers") {
                        ForEach(merged) { note in mergedNote(note) }
                    }
                }

                readMore(entry)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
    }

    @ViewBuilder
    private func questions(_ entry: FeedbackEntry) -> some View {
        if let steerable, entry.status == .planned, !steerable.questions.isEmpty {
            FeedbackQuestionsCard(questions: steerable.questions, answers: $answers)
        }
    }

    /// The line under the title: where it came from, or what the build made.
    private func metaLine(_ entry: FeedbackEntry) -> String {
        if entry.status == .ready || entry.status == .merged, !entry.commits.isEmpty {
            let commits = entry.commits.count == 1 ? "1 commit" : "\(entry.commits.count) commits"
            return [entry.feature, [commits, entry.repo].compactMap { $0 }.joined(separator: " on ")]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        return entry.detailMetaLine
    }

    /// What the user sent, in their words. Long text folds to four lines; a tap shows it whole.
    private func youSaid(_ entry: FeedbackEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: entry.text)
                .font(AppFont.serif(style: .callout))
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(showsWholeQuote ? nil : 4)
                .textSelection(.enabled)
            ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                Text(verbatim: note.text)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .lineLimit(showsWholeQuote ? nil : 2)
            }
            Text(verbatim: "You said")
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { showsWholeQuote.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: showsWholeQuote ? "Folds it." : "Shows it whole."))
    }

    /// Where the change lands: the repo, the files the plan names, and its size.
    @ViewBuilder
    private func touches(_ entry: FeedbackEntry) -> some View {
        let repo = entry.planRepo ?? entry.repo
        if repo != nil || !entry.files.isEmpty || entry.sizeWord != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "Touches")
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
                FlowRow(spacing: 6) {
                    if let repo { HXChip(paper: .tool, label: repo) }
                    ForEach(entry.files, id: \.self) { file in
                        HXChip(paper: .file, symbol: "doc", label: (file as NSString).lastPathComponent)
                            .accessibilityLabel(Text(verbatim: file))
                    }
                    if let size = entry.sizeWord { HXChip(paper: .tool, label: size) }
                }
            }
        }
    }

    /// Rows opening the full plan and the build report.
    @ViewBuilder
    private func readMore(_ entry: FeedbackEntry) -> some View {
        let hasPlan = loadedPlan != nil
        let hasReport = entry.tests?.isEmpty == false
        if hasPlan || hasReport {
            VStack(spacing: 0) {
                if hasPlan {
                    sheetRow("Read the full plan") { sheet = .plan }
                }
                if hasPlan, hasReport {
                    Divider().overlay(Color.hxSeparator).padding(.leading, 14)
                }
                if hasReport {
                    sheetRow("Read the build report") { sheet = .report }
                }
            }
            .hxCard()
        }
    }

    private func sheetRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(verbatim: title)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet, _ entry: FeedbackEntry) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch sheet {
                    case .plan:
                        if let loadedPlan { MarkdownRenderer(content: loadedPlan.body) }
                    case .report:
                        if let branch = entry.branch, !branch.isEmpty {
                            Text(verbatim: [entry.repo, branch].compactMap { $0 }.joined(separator: " · "))
                                .font(AppFont.mono(style: .footnote))
                                .foregroundStyle(Color.hxTextSecondary)
                                .textSelection(.enabled)
                        }
                        Text(verbatim: entry.tests ?? "")
                            .font(AppFont.mono(style: .footnote))
                            .foregroundStyle(Color.hxTextPrimary)
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.hxCanvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: sheet == .plan ? "Plan" : "Build report"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { self.sheet = nil } label: { Text(verbatim: "Done") }
                }
            }
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

    /// A reopened fix: how many times the recurrence watch saw the problem again, and what it saw.
    private func recurrence(_ count: Int, evidence: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: "Recurred ×\(count)")
            } icon: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(Color.hxWarning)
            if let evidence, !evidence.isEmpty {
                Text(verbatim: evidence)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// A note the nightly job folded into this entry's plan, with Unmerge to plan it on its own again.
    private func mergedNote(_ note: FeedbackEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: note.text)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(3)
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

    @ViewBuilder
    private func actionBar(_ entry: FeedbackEntry) -> some View {
        if entry.status.hasActions {
            VStack(spacing: 8) {
                if viewModel.pendingID == entry.id {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(verbatim: "Saving…")
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                actions(entry)
                    .disabled(viewModel.pendingID != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.hxCanvas)
            .overlay(alignment: .top) { Divider().overlay(Color.hxSeparator) }
            .environment(\.hxPaper, .request)
        }
    }

    @ViewBuilder
    private func actions(_ entry: FeedbackEntry) -> some View {
        switch entry.status {
        case .planned:
            let note = steerable.flatMap { answers.note(for: $0.questions) }
            primary("Build tonight", caption: "Branch ready by morning") {
                decide(entry, note.map(FeedbackDecision.approveAnswering) ?? .approve)
            }
            .accessibilityHint(Text(verbatim: note == nil
                                    ? "Builds it tonight. Unanswered questions take the recommended answer."
                                    : "Builds it tonight with your answers."))
            secondaryRow(("Change plan…", "Tell the planner what to change. It replans tonight.", { replyTarget = entry }),
                         drop: "Drop it")
        case .ready:
            let merge = entry.mergeAction
            primary(merge.title, caption: merge.caption) { decide(entry, .merged) }
                .accessibilityHint(Text(verbatim: merge.caption))
            secondaryRow(("Send back…", "Replans it tonight with your note.", { replyTarget = entry }),
                         drop: "Drop branch")
        case .failed:
            primary("Retry", caption: "Tries again tonight") { decide(entry, .retry) }
            secondaryRow(nil, drop: "Drop it")
        case .new:
            secondaryRow(nil, drop: "Drop it")
        case .shipped:
            Button { isConfirmingUndo = true } label: { Text(verbatim: "Undo") }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: .destructive))
                .accessibilityLabel(Text(verbatim: "Undo this fix"))
                .accessibilityHint(Text(verbatim: "Reverts this change on the vault's main branch."))
        case .reverted:
            Button { replyTarget = entry } label: { Text(verbatim: "Redo plan") }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                .accessibilityHint(Text(verbatim: "Tell the planner what to change. It replans tonight."))
        default:
            EmptyView()
        }
    }

    private func primary(_ title: String, caption: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(verbatim: title)
                    .font(AppFont.body(weight: .semibold))
                Text(verbatim: caption)
                    .font(AppFont.caption2(weight: .medium))
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
    }

    private func secondaryRow(_ other: (title: String, hint: String, action: () -> Void)?, drop: String) -> some View {
        HStack(spacing: 8) {
            if let other {
                Button(action: other.action) { Text(verbatim: other.title) }
                    .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                    .accessibilityHint(Text(verbatim: other.hint))
            }
            Button { isConfirmingReject = true } label: { Text(verbatim: drop) }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: .destructive))
                .accessibilityHint(Text(verbatim: "Moves it to Done."))
        }
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

extension FeedbackStatus {
    /// The detail screen's title.
    var screenTitle: String {
        switch self {
        case .planned: "Plan"
        case .ready: "Branch"
        case .failed: "Failed"
        default: "Feedback"
        }
    }
}
