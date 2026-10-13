import SwiftUI

/// Settings › Feedback: the active server's feedback, grouped for review. Entries waiting on
/// the user are request cards; tapping any entry opens it, where every decision lives.
/// English-only copy (personal fork).
struct FeedbackInboxView: View {
    @State private var viewModel: FeedbackInboxViewModel
    @State private var openedID: String?
    @State private var showsDone = false
    /// Label recent cards; nil when the server has no labels.
    @State private var labelQueue: LabelQueueViewModel?

    init(client: any FeedbackDataClient, labelQueue: LabelQueueViewModel? = nil) {
        _viewModel = State(initialValue: FeedbackInboxViewModel(client: client))
        _labelQueue = State(initialValue: labelQueue)
    }

    var body: some View {
        content
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle("Feedback")
            .task { await viewModel.load() }
            // Not a `.task`: opening the queue would cancel it mid-build. The queue owns its build.
            .onAppear { labelQueue?.start() }
            .navigationDestination(item: $openedID) { id in
                FeedbackDetailView(entryID: id, viewModel: viewModel)
            }
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
            if sections.isEmpty, labelQueue == nil {
                ContentUnavailableView {
                    Label { Text(verbatim: "No feedback yet") } icon: { Image(systemName: "message") }
                } description: {
                    Text(verbatim: "Send feedback from a screen's More menu.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let labelQueue {
                            LabelQueueRow(queue: labelQueue)
                        }
                        if sections.isEmpty {
                            Text(verbatim: "No feedback yet. Send feedback from a screen's More menu.")
                                .font(AppFont.footnote())
                                .foregroundStyle(Color.hxTextSecondary)
                                .padding(.top, 12)
                        }
                        ForEach(sections, id: \.group) { section in
                            sectionView(section)
                        }
                    }
                    .padding(16)
                    .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
                }
                .refreshable { await viewModel.load() }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: FeedbackInboxViewModel.InboxSection) -> some View {
        switch section.group {
        case .needsReview:
            HXSectionHeader(title: section.group.title)
                .padding(.top, 4)
            ForEach(section.entries) { entry in
                FeedbackRequestCard(entry: entry) { openedID = viewModel.openedID(for: entry) }
            }
        case .inProgress:
            HXSectionHeader(title: section.group.title)
                .padding(.top, 12)
            rows(section.entries) { $0.progressWord }
        case .done:
            Button {
                showsDone.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    HXSectionHeader(title: section.group.title, trailing: "\(section.entries.count)")
                    Image(systemName: showsDone ? "chevron.up" : "chevron.down")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityValue(Text(verbatim: showsDone ? "Shown" : "Hidden"))
            if showsDone {
                rows(section.entries) { viewModel.metaLine(for: $0) }
            }
        }
    }

    /// Neutral rows in one card, each opening its entry.
    private func rows(_ entries: [FeedbackEntry], status: @escaping (FeedbackEntry) -> String) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Divider().overlay(Color.hxSeparator).padding(.leading, 14)
                }
                Button { openedID = viewModel.openedID(for: entry) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: entry.headline)
                            .font(AppFont.body())
                            .foregroundStyle(Color.hxTextPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: status(entry))
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .hxCard()
    }
}

/// A Needs you entry: a request card with its title in the glow, the plan's one-line summary,
/// and a chip naming what it needs.
private struct FeedbackRequestCard: View {
    let entry: FeedbackEntry
    let open: () -> Void

    var body: some View {
        let chip = entry.needsYouChip
        Button(action: open) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.headline)
                    .font(AppFont.display(style: .headline))
                    .foregroundStyle(HermexPaper.request.glow)
                    .multilineTextAlignment(.leading)
                if let summary = entry.summary, !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextPrimary)
                        .multilineTextAlignment(.leading)
                }
                HXChip(paper: .request, symbol: chip.symbol, label: chip.label)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glowSurface(.request, cornerRadius: HXRadius.lg)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: "Opens the plan."))
    }
}

extension View {
    /// The free-text Reply prompt: a note for the planner, sent as a `reply` decision while
    /// `target` is set.
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
            Text(verbatim: "Redo the plan"),
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
            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(role: .cancel) { note = "" } label: { Text(verbatim: "Cancel") }
        } message: { _ in
            Text(verbatim: "The plan goes back for another pass tonight.")
        }
    }
}
