import SwiftUI

/// Settings › Feedback: the active server's feedback, grouped for review. A planned row
/// can be approved or answered in place; tapping a row opens its plan. English-only copy
/// (personal fork).
struct FeedbackInboxView: View {
    @State private var viewModel: FeedbackInboxViewModel
    @State private var openedID: String?
    @State private var replyTarget: FeedbackEntry?

    init(client: any FeedbackDataClient) {
        _viewModel = State(initialValue: FeedbackInboxViewModel(client: client))
    }

    var body: some View {
        content
            .background(Color.hxCanvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "Feedback"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.load() }
            .navigationDestination(item: $openedID) { id in
                FeedbackDetailView(entryID: id, viewModel: viewModel)
            }
            .feedbackReplyPrompt(for: $replyTarget, viewModel: viewModel)
            // The detail screen shows its own errors inline while it is open.
            .alert(
                Text(verbatim: "Feedback"),
                isPresented: Binding(
                    get: { openedID == nil && viewModel.error != nil },
                    set: { if !$0 { viewModel.clearError() } }
                )
            ) {
                Button(role: .cancel) { viewModel.clearError() } label: { Text(verbatim: "OK") }
            } message: {
                Text(verbatim: viewModel.error ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No feedback inbox on this server") } icon: { Image(systemName: "message") }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load feedback") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
            }
        case .loaded:
            let sections = viewModel.sections
            if sections.isEmpty {
                ContentUnavailableView {
                    Label { Text(verbatim: "No feedback yet") } icon: { Image(systemName: "message") }
                } description: {
                    Text(verbatim: "Send feedback from a screen's More menu.")
                }
            } else {
                List {
                    ForEach(sections, id: \.group) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                FeedbackInboxRow(
                                    entry: entry,
                                    isBusy: viewModel.pendingID != nil,
                                    open: { openedID = entry.id },
                                    approve: { Task { await viewModel.decide(entry, .approve) } },
                                    reply: { replyTarget = entry }
                                )
                                .listRowBackground(Color.hxSurface)
                            }
                        } header: {
                            Text(verbatim: section.group.title)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable { await viewModel.load() }
            }
        }
    }
}

/// One entry: its headline and "Feature · status · size". A planned entry adds its
/// summary with Approve (the screen's only accent button) and Reply.
private struct FeedbackInboxRow: View {
    let entry: FeedbackEntry
    let isBusy: Bool
    let open: () -> Void
    let approve: () -> Void
    let reply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Every button in the row has an explicit style, so each keeps its own hit area.
            Button(action: open) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: entry.headline)
                            .font(AppFont.body(weight: .medium))
                            .foregroundStyle(Color.hxTextPrimary)
                            .lineLimit(3)
                        Text(verbatim: entry.metaLine)
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                        if entry.status == .planned, let summary = entry.summary, !summary.isEmpty {
                            Text(verbatim: summary)
                                .font(AppFont.subheadline())
                                .foregroundStyle(Color.hxTextPrimary)
                                .padding(.top, 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.forward")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: "Opens the plan."))

            if entry.status == .planned {
                HStack(spacing: 8) {
                    Button(action: approve) { Text(verbatim: "Approve") }
                        .buttonStyle(.borderedProminent)
                    Button(action: reply) { Text(verbatim: "Reply") }
                        .buttonStyle(.bordered)
                        .tint(Color.hxTextPrimary)
                }
                .font(AppFont.subheadline(weight: .semibold))
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 4)
    }
}

extension View {
    /// The Reply prompt: a note for the planner, sent as a `reply` decision while `target` is set.
    func feedbackReplyPrompt(for target: Binding<FeedbackEntry?>, viewModel: FeedbackInboxViewModel) -> some View {
        modifier(FeedbackReplyPrompt(target: target, viewModel: viewModel))
    }
}

private struct FeedbackReplyPrompt: ViewModifier {
    @Binding var target: FeedbackEntry?
    let viewModel: FeedbackInboxViewModel
    @State private var note = ""

    func body(content: Content) -> some View {
        content.alert(
            Text(verbatim: "Reply to the plan"),
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            presenting: target
        ) { entry in
            TextField(text: $note) { Text(verbatim: "What should change?") }
            Button {
                let text = note
                note = ""
                Task { await viewModel.decide(entry, .reply(text)) }
            } label: {
                Text(verbatim: "Send")
            }
            Button(role: .cancel) { note = "" } label: { Text(verbatim: "Cancel") }
        } message: { _ in
            Text(verbatim: "The plan goes back for another pass tonight.")
        }
    }
}
