import SwiftUI

struct TasksView: View {
    let server: URL
    let onAPIError: (Error) -> Void

    @State private var viewModel: TasksViewModel
    @State private var isPresentingCreateTask = false
    @State private var jobPendingDeletion: CronJob?
    /// "Ran Recently" shows a few rows until the user asks for the rest. View
    /// state only: every fresh visit starts compact.
    @State private var isShowingAllRecentRuns = false
    /// False until the first load settles, so the frame before `.task` starts
    /// shows the placeholder rather than flashing "No Tasks".
    @State private var hasLoadedOnce = false

    /// Rows "Ran Recently" shows before it needs a "Show all" row.
    private static let compactRecentRunCount = 3

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: TasksViewModel(server: server))
    }

    var body: some View {
        content
            .hxNavigationTitle(String(localized: "Tasks"))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.clearActionError()
                        isPresentingCreateTask = true
                    } label: {
                        Label("New Task", systemImage: "plus")
                    }
                    .disabled(viewModel.isMutating)

                    Button {
                        Task { await loadTasks() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .sheet(isPresented: $isPresentingCreateTask, onDismiss: {
                // A failed create leaves its message behind; without this the
                // list's own alert would fire the moment the sheet closes.
                viewModel.clearActionError()
            }) {
                CronJobEditorSheet(
                    title: String(localized: "New Task"),
                    server: server,
                    draft: CronJobEditorDraft(),
                    saveTitle: String(localized: "Create"),
                    isSaving: viewModel.isMutating,
                    errorMessage: viewModel.actionErrorMessage,
                    deliveryOptions: viewModel.deliveryOptions
                ) { draft in
                    let didCreate = await viewModel.create(from: draft)
                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                    return didCreate
                }
            }
            .alert("Delete task?", isPresented: deletionConfirmationBinding, presenting: jobPendingDeletion) { job in
                Button("Delete", role: .destructive) {
                    Task { await performAction { await viewModel.delete(job) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { job in
                Text("“\(job.displayName)” will be removed from the Hermes server.")
            }
            .alert("Couldn't update task", isPresented: actionErrorBinding) {
                Button("OK", role: .cancel) { viewModel.clearActionError() }
            } message: {
                Text(viewModel.actionErrorMessage ?? "")
            }
            .task {
                await loadTasks()
                hasLoadedOnce = true
            }
    }

    /// Which of the screen's states is up. `.hxLoadSwap` crossfades on this,
    /// never on the jobs, so a refresh with new rows doesn't fade the list.
    private enum Phase: Hashable {
        case loading, failed, empty, loaded
    }

    private var phase: Phase {
        if !viewModel.jobs.isEmpty { return .loaded }
        if viewModel.isLoading || !hasLoadedOnce { return .loading }
        if viewModel.errorMessage != nil { return .failed }
        return .empty
    }

    private var content: some View {
        Group {
            switch phase {
            case .loading:
                TasksLoadingPlaceholder()
            case .failed:
                HXFailedView(title: String(localized: "Couldn't load tasks"), message: viewModel.errorMessage) {
                    Task { await loadTasks() }
                }
            case .empty:
                ContentUnavailableView {
                    Label("No Tasks", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Scheduled jobs from the Hermes server will appear here.")
                }
            case .loaded:
                agenda
            }
        }
        .hxLoadSwap(phase)
    }

    private var sections: [TaskAgendaSection] {
        viewModel.sections()
    }

    @ViewBuilder
    private var agenda: some View {
        Group {
            if sections.isEmpty && viewModel.recentRuns.isEmpty {
                noMatchingTasks
            } else {
                // The list stays mounted while the feed has rows, so switching
                // to a filter with no tasks does not take "Ran Recently" away.
                List {
                    recentRunsSection

                    if sections.isEmpty {
                        Section {
                            noMatchingTasks
                                .listRowBackground(Color.clear)
                        }
                    }

                    ForEach(sections) { section in
                        Section {
                            ForEach(section.jobs) { job in
                                row(for: job, in: section.group)
                                    .listRowBackground(Color.hxSurface)
                            }
                        } header: {
                            HXSectionHeader(title: section.group.title)
                                .textCase(nil)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable {
                    await loadTasks()
                }
            }
        }
        .background(Color.hxCanvas)
        .safeAreaInset(edge: .top, spacing: 0) {
            filterPicker
        }
    }

    private var noMatchingTasks: some View {
        ContentUnavailableView {
            Label("No Matching Tasks", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("No tasks match this filter.")
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $viewModel.filter) {
            ForEach(TaskFilter.allCases) { filter in
                Text(filter.title(count: viewModel.count(for: filter))).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Matches the navigation bar and list above and below it, so no seam shows.
        .background(Color.hxCanvas)
    }

    /// Cross-task recent completions, above the agenda and outside the filter.
    /// Absent until the feed answers and whenever it is empty or failed.
    @ViewBuilder
    private var recentRunsSection: some View {
        let recentRuns = viewModel.recentRuns
        if !recentRuns.isEmpty {
            let isTruncated = recentRuns.count > Self.compactRecentRunCount && !isShowingAllRecentRuns
            let visibleRuns = isTruncated ? Array(recentRuns.prefix(Self.compactRecentRunCount)) : recentRuns

            Section {
                ForEach(visibleRuns) { completion in
                    if let job = viewModel.job(for: completion) {
                        NavigationLink {
                            detail(for: job)
                        } label: {
                            TaskRecentRunRowView(completion: completion)
                        }
                    } else {
                        // The feed named a job the list does not have: no link,
                        // no chevron, and nothing that reads as a button.
                        TaskRecentRunRowView(completion: completion)
                    }
                }
                .listRowBackground(Color.hxSurface)

                if recentRuns.count > Self.compactRecentRunCount {
                    Button {
                        isShowingAllRecentRuns.toggle()
                    } label: {
                        Text(isTruncated ? "Show All (\(recentRuns.count))" : "Show Less")
                            .font(AppFont.subheadline())
                    }
                    .listRowBackground(Color.hxSurface)
                }
            } header: {
                HXSectionHeader(title: String(localized: "Ran Recently"))
                    .textCase(nil)
            }
        }
    }

    private func detail(for job: CronJob) -> some View {
        TaskDetailView(
            job: job,
            runningElapsed: viewModel.runningElapsed(for: job),
            server: server,
            onAPIError: onAPIError,
            onMutation: { mutation in
                viewModel.apply(mutation)
            }
        )
    }

    private func row(for job: CronJob, in group: TaskAgendaGroup) -> some View {
        NavigationLink {
            detail(for: job)
        } label: {
            CronJobRowView(
                job: job,
                group: group,
                runningElapsed: viewModel.runningElapsed(for: job)
            )
        }
        .swipeActions(edge: .trailing) {
            pauseResumeButton(for: job)
            runNowButton(for: job)
        }
        .contextMenu {
            runNowButton(for: job)
            pauseResumeButton(for: job)

            Divider()

            Button(role: .destructive) {
                jobPendingDeletion = job
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(job.jobId == nil)
        }
    }

    @ViewBuilder
    private func runNowButton(for job: CronJob) -> some View {
        Button {
            Task { await performAction { await viewModel.runNow(job) } }
        } label: {
            Label("Run Now", systemImage: "play.fill")
        }
        .tint(Color.accentColor)
        .disabled(job.jobId == nil || viewModel.isPendingAction(job))
    }

    @ViewBuilder
    private func pauseResumeButton(for job: CronJob) -> some View {
        if job.isLive {
            Button {
                Task { await performAction { await viewModel.pause(job) } }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .tint(.hxWarning)
            .disabled(job.jobId == nil || viewModel.isPendingAction(job))
        } else {
            Button {
                Task { await performAction { await viewModel.resume(job) } }
            } label: {
                Label("Resume", systemImage: "play.circle")
            }
            .tint(.hxSuccess)
            .disabled(job.jobId == nil || viewModel.isPendingAction(job))
        }
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { jobPendingDeletion != nil },
            set: { if !$0 { jobPendingDeletion = nil } }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.actionErrorMessage != nil && !isPresentingCreateTask },
            set: { if !$0 { viewModel.clearActionError() } }
        )
    }

    private func performAction(_ action: () async -> Void) async {
        await action()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }

    private func loadTasks() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

/// The agenda's first frame while the jobs load: a section of rows shaped like
/// `CronJobRowView` (status dot, name, schedule line), redacted. Static, so it
/// costs nothing on screen, and VoiceOver hears one "Loading tasks".
private struct TasksLoadingPlaceholder: View {
    private static let rows: [(name: String, meta: String)] = [
        ("Morning briefing", "7:00 AM · Every day"),
        ("Inbox sweep", "9:30 AM · Weekdays"),
        ("Weekly review draft", "Sunday 6:00 PM · Every week"),
        ("Backup check", "11:00 PM · Every day"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.rows.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: Self.rows[index].name)
                                .font(AppFont.subheadline(weight: .semibold))
                            Text(verbatim: Self.rows[index].meta)
                                .font(AppFont.caption())
                                .foregroundStyle(.hxSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.hxSurface)
                }
            } header: {
                HXSectionHeader(title: "Later today")
                    .textCase(nil)
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .background(Color.hxCanvas)
        // The agenda's filter bar, so the rows don't drop by its height when the jobs land.
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker(selection: .constant(TaskFilter.all)) {
                ForEach(TaskFilter.allCases) { filter in
                    Text(filter.title(count: 0)).tag(filter)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.hxCanvas)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        // List rows are their own accessibility cells, so hide them all and speak one label instead.
        .accessibilityHidden(true)
        .overlay { Color.clear.accessibilityElement().accessibilityLabel(Text("Loading tasks")) }
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(AppFont.caption2())
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }
}
