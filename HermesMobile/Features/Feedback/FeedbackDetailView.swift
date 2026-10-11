import SwiftUI

/// One feedback entry: what was sent, any replies, the branch and tests or the error,
/// and the plan in the shared Markdown renderer. The decisions its status allows sit in
/// a bar at the bottom. Reads the entry from the inbox, so a decision updates both screens.
struct FeedbackDetailView: View {
    let entryID: String
    let viewModel: FeedbackInboxViewModel
    @State private var plan: BrainLoadState<String> = .loading
    @State private var replyTarget: FeedbackEntry?
    @State private var isConfirmingReject = false

    var body: some View {
        Group {
            if let entry = viewModel.entry(id: entryID) {
                content(entry)
                    .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(entry) }
                    .task(id: entry.status) { await loadPlan(entry) }
            } else {
                ContentUnavailableView {
                    Label { Text(verbatim: "This feedback is gone") } icon: { Image(systemName: "tray") }
                }
            }
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .navigationTitle(Text(verbatim: "Feedback"))
        .navigationBarTitleDisplayMode(.inline)
        .feedbackReplyPrompt(for: $replyTarget, viewModel: viewModel)
        .onDisappear { viewModel.clearError() }
    }

    private func content(_ entry: FeedbackEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Above everything: a 409 reload can move the entry past its action bar.
                if let error = viewModel.error {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(AppFont.footnote(weight: .medium))
                        .foregroundStyle(Color.hxDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.headline)
                        .font(AppFont.title3(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: entry.metaLine)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }

                block("You said") {
                    Text(verbatim: entry.text)
                        .font(BrainStyle.quote)
                        .foregroundStyle(Color.hxTextPrimary)
                        .textSelection(.enabled)
                }

                if !entry.notes.isEmpty {
                    block("Your replies") {
                        ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                            Text(verbatim: note.text)
                                .font(AppFont.body())
                                .foregroundStyle(Color.hxTextPrimary)
                        }
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

                if entry.status == .failed, let error = entry.error, !error.isEmpty {
                    block("Error") {
                        Text(verbatim: error)
                            .font(AppFont.mono(style: .footnote))
                            .foregroundStyle(Color.hxDanger)
                            .textSelection(.enabled)
                    }
                }

                block("Plan") { planContent }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
    }

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
        case .loaded(let markdown):
            MarkdownRenderer(content: markdown)
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

    // MARK: - Decisions

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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions(entry) }
                    VStack(spacing: 8) { actions(entry) }
                }
                .font(AppFont.body(weight: .semibold))
                .controlSize(.large)
                .disabled(viewModel.pendingID != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.hxCanvas)
            .overlay(alignment: .top) { Divider().overlay(Color.hxSeparator) }
            .confirmationDialog(
                Text(verbatim: entry.status == .ready ? "Reject this branch?" : "Reject this plan?"),
                isPresented: $isConfirmingReject,
                titleVisibility: .visible
            ) {
                Button(role: .destructive) {
                    decide(entry, .reject)
                } label: {
                    Text(verbatim: "Reject")
                }
            } message: {
                Text(verbatim: entry.status == .ready
                     ? "It moves to Done. The branch stays on your Mac until you delete it."
                     : "It moves to Done and won't be built.")
            }
        }
    }

    @ViewBuilder
    private func actions(_ entry: FeedbackEntry) -> some View {
        switch entry.status {
        case .planned:
            Button { decide(entry, .approve) } label: { wide("Approve") }
                .buttonStyle(.borderedProminent)
            Button { replyTarget = entry } label: { wide("Reply") }
                .buttonStyle(.bordered)
                .tint(Color.hxTextPrimary)
        case .ready:
            Button { decide(entry, .merged) } label: { wide("Mark merged") }
                .buttonStyle(.bordered)
                .tint(Color.hxTextPrimary)
        case .failed:
            Button { decide(entry, .retry) } label: { wide("Retry") }
                .buttonStyle(.bordered)
                .tint(Color.hxTextPrimary)
        default:
            EmptyView()
        }
        if entry.status.canReject {
            Button(role: .destructive) { isConfirmingReject = true } label: { wide("Reject") }
                .buttonStyle(.bordered)
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
