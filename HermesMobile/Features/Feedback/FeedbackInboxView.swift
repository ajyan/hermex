import SwiftUI

/// Drawer › Feedback: the active server's feedback, grouped for review. Entries waiting on
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
        case .toApprove, .toMerge, .toRetry:
            HXSectionHeader(title: section.group.title, trailing: "\(section.entries.count)")
                .padding(.top, 4)
            ForEach(section.entries) { entry in
                FeedbackRequestCard(
                    entry: entry,
                    isSaving: viewModel.pendingID == entry.id,
                    isBusy: viewModel.pendingID != nil,
                    open: { openedID = viewModel.openedID(for: entry) },
                    decide: { decision in Task { await viewModel.decide(entry, decision) } }
                )
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

/// An entry waiting on a decision: its title in the glow, the one-line outcome, chips for what
/// it needs, and the decision's button. Tapping the card opens the entry; the button acts
/// in place (Build, Retry) or opens it to answer questions or review a branch.
private struct FeedbackRequestCard: View {
    let entry: FeedbackEntry
    let isSaving: Bool
    let isBusy: Bool
    let open: () -> Void
    let decide: (FeedbackDecision) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.headline)
                        .font(AppFont.display(style: .headline))
                        .foregroundStyle(HermexPaper.request.glow)
                        .multilineTextAlignment(.leading)
                    if let line = entry.status == .failed ? entry.errorLine : entry.outcome {
                        Text(verbatim: line)
                            .font(AppFont.subheadline())
                            .foregroundStyle(entry.status == .failed ? Color.hxDanger : Color.hxTextPrimary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                    FlowRow(spacing: 6) { chips }
                        .padding(.top, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(verbatim: "Opens it."))

            action
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .glowSurface(.request, cornerRadius: HXRadius.lg)
    }

    @ViewBuilder
    private var chips: some View {
        switch entry.status {
        case .ready:
            if entry.checks.isEmpty {
                HXChip(paper: .tool, symbol: "arrow.triangle.branch", label: entry.repo ?? "Branch ready")
            }
            ForEach([FeedbackCheck.State.ok, .warn, .fail], id: \.self) { state in
                let count = entry.checkCount(state)
                if count > 0 {
                    FeedbackCheckChip(state: state, count: count)
                }
            }
        default:
            if entry.questionCount > 0 {
                HXChip(paper: .request, symbol: "questionmark.circle",
                       label: entry.questionCount == 1 ? "1 question" : "\(entry.questionCount) questions")
            }
            if let place = entry.placeLine {
                HXChip(paper: .tool, label: place)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if isSaving {
            ProgressView()
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text(verbatim: "Saving"))
        } else if let quick = entry.quickAction {
            let (title, primary): (String, Bool) = switch quick {
            case .build: ("Build", true)
            case .answer: ("Answer", false)
            case .review: ("Review", false)
            case .retry: ("Retry", true)
            }
            Button {
                switch quick {
                case .build: decide(.approve)
                case .retry: decide(.retry)
                case .answer, .review: open()
                }
            } label: {
                Text(verbatim: title)
            }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: primary ? .primary : .secondary))
            .fixedSize()
            .disabled(isBusy)
            .accessibilityHint(Text(verbatim: quick.hint))
        }
    }
}

/// A count of build checks in one state, as a chip: green passed, amber unchecked, red failed.
struct FeedbackCheckChip: View {
    let state: FeedbackCheck.State
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .font(AppFont.caption2(weight: .bold))
                .accessibilityHidden(true)
            Text(verbatim: state.countLabel(count))
                .font(AppFont.caption(weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(state.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(state.color.opacity(0.14), in: Capsule())
    }
}

extension FeedbackCheck.State {
    var symbol: String {
        switch self {
        case .ok: "checkmark"
        case .warn: "exclamationmark"
        case .fail: "xmark"
        case .unknown: "circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: .hxSuccess
        case .warn: .hxWarning
        case .fail: .hxDanger
        case .unknown: .hxTextSecondary
        }
    }

    func countLabel(_ count: Int) -> String {
        switch self {
        case .ok: count == 1 ? "1 check passed" : "\(count) checks passed"
        case .warn: "\(count) unchecked"
        case .fail: "\(count) failed"
        case .unknown: "\(count) other"
        }
    }
}

private extension FeedbackEntry.QuickAction {
    var hint: String {
        switch self {
        case .build: "Approves the plan. It builds tonight."
        case .answer: "Opens the plan to answer its questions."
        case .review: "Opens the branch's checks."
        case .retry: "Tries the failed step again tonight."
        }
    }
}

extension View {
    /// The free-text Reply prompt: a note for the planner, sent as a `reply` decision while
    /// `target` is set. `prefix` (the plan's answers) leads the note when there is one. A plan
    /// goes back for another pass; a built branch is set aside and replanned.
    func feedbackReplyPrompt(for target: Binding<FeedbackEntry?>, viewModel: FeedbackInboxViewModel,
                             prefix: String? = nil) -> some View {
        modifier(FeedbackReplyPrompt(target: target, viewModel: viewModel, prefix: prefix))
    }
}

private struct FeedbackReplyPrompt: ViewModifier {
    @Binding var target: FeedbackEntry?
    let viewModel: FeedbackInboxViewModel
    let prefix: String?
    @State private var note = ""

    func body(content: Content) -> some View {
        content.alert(
            Text(verbatim: target?.status == .ready ? "Send it back" : "Change the plan"),
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
            presenting: target
        ) { entry in
            TextField(text: $note) { Text(verbatim: "What should change?") }
            Button {
                let text = [prefix, note].compactMap { $0 }.joined(separator: "\n")
                note = ""
                Task { await viewModel.decide(entry, .reply(text)) }
            } label: {
                Text(verbatim: "Send")
            }
            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(role: .cancel) { note = "" } label: { Text(verbatim: "Cancel") }
        } message: { entry in
            Text(verbatim: entry.status == .ready
                 ? "It gets a new plan tonight with your note. This branch is set aside."
                 : "The plan goes back for another pass tonight.")
        }
    }
}
