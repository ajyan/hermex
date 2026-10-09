import SwiftUI
import SwiftData
import UIKit
import StoreKit

/// Refreshes the session list when the app returns from the background, so
/// sessions started or finished elsewhere show without a pull. A return that
/// lands while a load is running, or before the initial load has finished, is
/// remembered and refreshed once the list is idle: that load may have started
/// before backgrounding and would otherwise leave stale rows. Repeated returns
/// coalesce to one refresh.
struct SessionListForegroundRefresh: Equatable {
    private(set) var isPending = false

    /// Called on a real background-to-active return. Returns true when the
    /// list should refresh now; otherwise the return waits for `consumeIfReady`.
    mutating func appReturned(didCompleteInitialLoad: Bool, isLoading: Bool) -> Bool {
        isPending = true
        return consumeIfReady(didCompleteInitialLoad: didCompleteInitialLoad, isLoading: isLoading)
    }

    /// Called when loading stops or the initial load completes. Returns true
    /// once for a remembered return, as soon as the list is free to refresh.
    mutating func consumeIfReady(didCompleteInitialLoad: Bool, isLoading: Bool) -> Bool {
        guard isPending, didCompleteInitialLoad, !isLoading else { return false }
        isPending = false
        return true
    }
}

/// Decides whether an archive gets an Undo toast (#865). Each archive gets a
/// number from `archiveStarted` when it starts; once the server confirms it,
/// `archiveConfirmed` says whether to show the toast:
/// - Replies can land out of order, so an older archive never replaces a newer
///   one's toast. A newer archive that showed no toast blocks nothing.
/// - The toast lives in the drawer, so it shows only while the drawer is open.
///   Either way the session is in Archived.
struct SessionListArchiveToastRoute: Equatable {
    private var startedCount = 0
    private var newestShown = 0

    mutating func archiveStarted() -> Int {
        startedCount += 1
        return startedCount
    }

    mutating func archiveConfirmed(_ number: Int, isListShowing: Bool) -> Bool {
        guard number > newestShown, isListShowing else { return false }
        newestShown = number
        return true
    }
}

@MainActor
/// The logged-in root: one chat stack with a left drawer of chats over it.
/// Every launch opens a new chat; the drawer holds search, rows, and navigation.
struct ChatShellView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    private let draftStore: ChatDraftStore
    @Binding private var pendingSharedImport: SharedImportReservation?
    private let didRoutePendingSharedImport: (SharedImportReservation) -> Void
    private let hasWaitingSharedImport: Bool
    private let openNextSharedImport: () -> Void
    @Binding private var pendingDeepLinkedSessionID: String?
    @Binding private var requestedNewChat: NewChatRequest?
    @Binding private var requestedDailyBrief: Bool
    /// The bot a deep link named. Non-nil flips this screen to the Bots inbox, which
    /// resolves it against its live roster and clears it (#554).
    @Binding private var pendingBotDestination: BotDestination?
    @Binding private var pendingWebuiPush: WebuiPushDestination?

    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    /// Bumped by the top-bar call button; the chat on screen starts a call when it changes.
    @State private var callRequest = 0
    @State private var foregroundRefresh = SessionListForegroundRefresh()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: SessionListViewModel
    @State private var navigation = ShellNavigationState()
    /// The drawer is built on first open and kept alive, so it keeps its scroll position.
    @State private var hasOpenedDrawer = false
    /// False while ChatView pushes its own screens (Files, forks), which the typed path cannot see.
    @State private var isRootVisible = true
    @State private var sessionPendingRename: SessionSummary?
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingProjectCreation: SessionSummary?
    @State private var sessionOpenErrorMessage: String?
    @State private var sessionOpenTask: Task<Void, Never>?
    @State private var sessionExportShareItem: SessionExportShareItem?
    @State private var isPresentingProjectCreation = false
    @State private var isPresentingAddServer = false
    @State private var projectPendingDeletion: ProjectSummary?
    @State private var projectPendingRename: ProjectSummary?
    @State private var searchText = ""
    /// In memory only: every launch and server switch starts on Hermes chats.
    @State private var recentsFilter: RecentsFilter = .hermes
    @State private var didCompleteInitialLoad = false
    @State private var returnRefreshID: UUID?
    @State private var actionToast = ActionToastState()
    @State private var archiveToastRoute = SessionListArchiveToastRoute()
    /// The running auto-archive pass; owned here so it ends with the shell.
    @State private var autoArchiveTask: Task<Void, Never>?
    /// Chats the last pass archived, held until the drawer (the toast's host) is open.
    @State private var pendingAutoArchived: [SessionSummary] = []
    @State private var isPresentingArchiveReview = false
    @FocusState private var searchFieldIsFocused: Bool
    @AppStorage(SessionRowDisplaySettings.showMessageCountKey) private var showsSessionMessageCount = true
    @AppStorage(SessionRowDisplaySettings.showWorkspaceKey) private var showsSessionWorkspace = true
    @AppStorage(SessionRowDisplaySettings.showCronSessionsKey) private var showsCronSessions = true
    @AppStorage(SessionRowDisplaySettings.showSubagentSessionsKey)
    private var showsSubagentSessions = SessionRowDisplaySettings.defaultShowsSubagentSessions
    @AppStorage(SectionVisibilitySettings.tasksKey) private var showsTasksSection = true
    @AppStorage(SectionVisibilitySettings.kanbanKey) private var showsKanbanSection = true
    @AppStorage(SectionVisibilitySettings.skillsKey) private var showsSkillsSection = true
    @AppStorage(SectionVisibilitySettings.memoryKey) private var showsMemorySection = true
    @AppStorage(SectionVisibilitySettings.insightsKey) private var showsInsightsSection = true
    @AppStorage(SectionVisibilitySettings.activeProfileKey) private var showsActiveProfileSection = true
    @AppStorage(SectionVisibilitySettings.projectsKey) private var showsProjectsSection = true
    // Per-server key (#19): the CLI toggle mirrors the active server's
    // `show_cli_sessions`, so its cached value must not leak across servers.
    // Configured in `init`, where the server URL is known.
    @AppStorage private var showsCliSessions: Bool
    @AppStorage private var showsClaudeCodeSessions: Bool
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @AppStorage(BotModeGate.isEnabledKey) private var isBotModeEnabled = false
    @AppStorage(PrimaryActionTintSettings.isEnabledKey) private var tintsPrimaryActions = false
    @AppStorage(HeaderLogoColor.storageKey) private var themeHex = HeaderLogoColor.defaultHex

    init(
        authManager: AuthManager,
        server: URL,
        pendingSharedImport: Binding<SharedImportReservation?> = .constant(nil),
        didRoutePendingSharedImport: @escaping (SharedImportReservation) -> Void = { _ in },
        hasWaitingSharedImport: Bool = false,
        openNextSharedImport: @escaping () -> Void = {},
        pendingDeepLinkedSessionID: Binding<String?> = .constant(nil),
        requestedNewChat: Binding<NewChatRequest?> = .constant(nil),
        requestedDailyBrief: Binding<Bool> = .constant(false),
        pendingBotDestination: Binding<BotDestination?> = .constant(nil),
        pendingWebuiPush: Binding<WebuiPushDestination?> = .constant(nil),
        draftStore: ChatDraftStore? = nil
    ) {
        self.authManager = authManager
        self.server = server
        _pendingSharedImport = pendingSharedImport
        self.didRoutePendingSharedImport = didRoutePendingSharedImport
        self.hasWaitingSharedImport = hasWaitingSharedImport
        self.openNextSharedImport = openNextSharedImport
        self.draftStore = draftStore ?? .shared
        _pendingDeepLinkedSessionID = pendingDeepLinkedSessionID
        _requestedNewChat = requestedNewChat
        _requestedDailyBrief = requestedDailyBrief
        _pendingBotDestination = pendingBotDestination
        _pendingWebuiPush = pendingWebuiPush
        _viewModel = State(initialValue: SessionListViewModel(server: server))
        _showsCliSessions = AppStorage(
            wrappedValue: SessionRowDisplaySettings.showsCliSessions(for: server),
            SessionRowDisplaySettings.showCliSessionsKey(for: server)
        )
        _showsClaudeCodeSessions = AppStorage(
            wrappedValue: SessionRowDisplaySettings.showsClaudeCodeSessions(for: server),
            SessionRowDisplaySettings.showClaudeCodeSessionsKey(for: server)
        )
    }

    var body: some View {
        routedNavigationContainer
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    wasBackgrounded = true
                }
                if phase == .active, wasBackgrounded {
                    wasBackgrounded = false
                    viewModel.noteAppForegrounded()
                    if foregroundRefresh.appReturned(
                        didCompleteInitialLoad: didCompleteInitialLoad,
                        isLoading: viewModel.isLoading
                    ) {
                        refreshAfterReturningIfNeeded()
                    }
                }
            }
            .onChange(of: automatedSessionVisibility, initial: true) {
                viewModel.recentsVisibility = automatedSessionVisibility
            }
            .onChange(of: viewModel.availableRecentsFilters) {
                recentsFilter = RecentsFilter.resolved(recentsFilter, available: viewModel.availableRecentsFilters)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if hasWaitingSharedImport {
                    waitingSharedImportBanner
                }
            }
            .sheet(item: $sessionExportShareItem) { item in
                SessionExportShareSheet(fileURL: item.fileURL)
                    .presentationDetents([.medium, .large])
                    .adaptiveFormPresentation()
                    .ignoresSafeArea()
                    // The temp file lives in its own UUID directory (see
                    // SessionListViewModel.export); remove the directory once
                    // the share sheet is gone, shared and cancelled alike.
                    .onDisappear {
                        try? FileManager.default.removeItem(
                            at: item.fileURL.deletingLastPathComponent()
                        )
                    }
            }
            .sheet(item: $sessionPendingRename) { session in
                SessionRenameSheet(
                    initialTitle: SessionRowView.displayTitle(for: session),
                    isSaving: viewModel.isRenamingSession
                ) {
                    sessionPendingRename = nil
                } onSave: { title in
                    Task {
                        guard let session = sessionPendingRename else { return }

                        let didRename = await rename(session, to: title)
                        if didRename {
                            sessionPendingRename = nil
                        }
                    }
                }
                .presentationDetents([.height(180), .medium])
            }
            .alert("Session Action Failed", isPresented: sessionOpenErrorIsPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(sessionOpenErrorMessage ?? "")
            }
            .sheet(item: $sessionPendingProjectCreation) { session in
                ProjectCreationSheet(
                    existingProjectCount: viewModel.projects.count,
                    isSaving: viewModel.isCreatingProject || viewModel.isMovingSession
                ) {
                    sessionPendingProjectCreation = nil
                } onSave: { name, color in
                    Task {
                        let didMove = await viewModel.createProject(
                            named: name,
                            color: color,
                            moving: session,
                            modelContext: modelContext
                        )
                        handleLastError()

                        if didMove {
                            sessionPendingProjectCreation = nil
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingProjectCreation) {
                ProjectCreationSheet(
                    existingProjectCount: viewModel.projects.count,
                    isSaving: viewModel.isCreatingProject
                ) {
                    isPresentingProjectCreation = false
                } onSave: { name, color in
                    Task {
                        let didCreate = await viewModel.createEmptyProject(
                            named: name,
                            color: color,
                            modelContext: modelContext
                        )
                        handleLastError()

                        if didCreate {
                            isPresentingProjectCreation = false
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(item: $projectPendingRename) { project in
                ProjectRenameSheet(
                    project: project,
                    isSaving: viewModel.isRenamingProject
                ) {
                    projectPendingRename = nil
                } onSave: { name, color in
                    Task {
                        let didRename = await viewModel.rename(project, named: name, color: color)
                        handleLastError()

                        if didRename {
                            projectPendingRename = nil
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $isPresentingArchiveReview) {
                ArchiveReviewSheet(viewModel: viewModel) { session in
                    removeSessionFromNavigation(session)
                }
            }
            .sheet(isPresented: $isPresentingAddServer) {
                // Reuse #17's add-server flow directly as a power-user shortcut.
                // On success `addServer` switches the active server, which
                // rebuilds this stack via ContentView's `.id(server)` (#283).
                AddServerView(authManager: authManager)
            }
            .task {
                // Start the session rows immediately so a slow direct session
                // request cannot leave the sidebar empty. Deep-link resolution still
                // owns navigation precedence and is awaited before stored selection
                // restoration.
                await SessionListInitialLoad.run(
                    resolvePendingDeepLink: {
                        await openPendingDeepLinkedSessionIfNeeded()
                    },
                    loadSessions: {
                        await loadSessionRows()
                    },
                    sessionsDidLoad: {
                        didCompleteInitialLoad = true
                    },
                    loadProjects: {
                        await loadProjectsIfLive()
                    },
                    loadActiveProfile: {
                        await viewModel.loadActiveProfile()
                    }
                )
            }
            .task(id: pendingWebuiPush) {
                await openPendingWebuiPush()
            }
            .task(id: remoteSearchTaskID) {
                await viewModel.searchSessions(query: searchText, content: true, depth: 5)
            }
            .task(id: activeSessionMonitorTaskID) {
                await monitorActiveSessionRows()
            }
            .task(id: returnRefreshID) {
                guard returnRefreshID != nil else { return }
                await SessionListReturnRefresh.run(
                    refreshSessions: { await refreshSessionsAndActiveProfile() },
                    monitorTaskID: { activeSessionMonitorTaskID },
                    refreshActiveRows: { taskID in await refreshActiveSessionRows(taskID) }
                )
            }
            .onAppear {
                openPendingSharedImportIfNeeded()
                openRequestedNewChatIfNeeded()
                openRequestedDailyBriefIfNeeded()
                refreshAfterReturningIfNeeded()
            }
            .onDisappear {
                sessionOpenTask?.cancel()
                autoArchiveTask?.cancel()
                viewModel.invalidateSessionOpening()
                actionToast.dismiss()
            }
            .onChange(of: viewModel.isLoading) {
                refreshAfterForegroundReturnIfReady()
            }
            .onChange(of: didCompleteInitialLoad) {
                refreshAfterForegroundReturnIfReady()
            }
            .onChange(of: pendingSharedImport) {
                openPendingSharedImportIfNeeded()
            }
            .onChange(of: pendingDeepLinkedSessionID) {
                Task { await openPendingDeepLinkedSessionIfNeeded() }
            }
            .onChange(of: requestedNewChat) {
                openRequestedNewChatIfNeeded()
            }
            .onChange(of: requestedDailyBrief) {
                openRequestedDailyBriefIfNeeded()
            }
            .onChange(of: navigation.root) { oldValue, newValue in
                if case .session(let previous) = oldValue, previous.sessionId != navigation.selectedSessionID {
                    viewModel.noteReturn(from: previous)
                }
                if case .session(let current) = newValue {
                    viewModel.beginViewing(current)
                }
                SessionListDestinationReturn.run(
                    from: oldValue,
                    to: newValue,
                    suppressEmptyPlaceholders: viewModel.removeEmptySidebarPlaceholders,
                    refreshSessions: refreshAfterReturningIfNeeded
                )
            }
            .onChange(of: navigation.isDrawerOpen) { wasOpen, isOpen in
                // Closing by any path (scrim, Esc, picking a row) must not leave the
                // keyboard typing into the hidden search field.
                if !isOpen { searchFieldIsFocused = false }
                if isOpen { showPendingAutoArchiveToast() }
                guard ShellNavigationState.drawerOpenRequestsRefresh(wasOpen: wasOpen, isOpen: isOpen) else { return }
                refreshAfterReturningIfNeeded()
            }
            .modifier(
                SessionActionConfirmations(
                    viewModel: viewModel,
                    sessionPendingDeletion: $sessionPendingDeletion,
                    projectPendingDeletion: $projectPendingDeletion,
                    deleteSession: { session in
                        Task { await delete(session) }
                    },
                    deleteProject: { project in
                        Task { await delete(project) }
                    }
                )
            )
            .focusedSceneValue(\.hermexSceneActions, sceneActions)
    }

    private var waitingSharedImportBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Another shared item is waiting")
                    .font(.subheadline.weight(.semibold))
                Text("Open it when you are done with this draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Open Next", action: openNextSharedImport)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
    }

    /// The shell plus bot-link routing. Kept off `body`'s modifier chain, which is
    /// long enough that adding to it exceeds the type-checker's budget on the CI
    /// toolchain.
    private var routedNavigationContainer: some View {
        shellContainer
            // Cold launch delivers the link before this view appears; a warm one after.
            .task { showBotsForPendingDestination() }
            .onChange(of: pendingBotDestination) { showBotsForPendingDestination() }
            // Every chat below inherits this for its one-time notification offer (#863).
            .openNotificationSettings { showNotificationSettings() }
    }

    /// Opens Settings → Notifications for a chat's one-time offer (#863).
    private func showNotificationSettings() {
        navigation.showOnly(.settings(.notifications))
    }

    /// A bot deep link opens Settings, which pushes this server's Bots inbox to
    /// resolve it. Only this view's own server routes: a link for another server
    /// switches servers first, which rebuilds this view against it (#554). Settings
    /// already on screen pushes Bots itself, so it is not pushed a second time.
    private func showBotsForPendingDestination() {
        guard isBotModeEnabled, let destination = pendingBotDestination, destination.server == server,
              !navigation.path.contains(where: Self.isSettings) else {
            return
        }
        navigation.showOnly(.settings(nil))
    }

    private static func isSettings(_ destination: ShellPushDestination) -> Bool {
        if case .settings = destination { return true }
        return false
    }

    // MARK: - Shell

    private var shellContainer: some View {
        DrawerContainer(
            isOpen: navigation.isDrawerOpen,
            canEdgeOpen: navigation.path.isEmpty && isRootVisible,
            willOpen: { if !hasOpenedDrawer { hasOpenedDrawer = true } },
            setOpen: setDrawerOpen
        ) {
            mainStack
        } drawer: {
            if hasOpenedDrawer {
                sessionListSurface
            }
        }
        // The primary new-chat affordance; hidden on the empty new chat, where
        // another new chat would go nowhere (same rule as the top-bar button),
        // and while the drawer covers the screen (its New Chat row is there).
        .overlay(alignment: .bottomTrailing) {
            if !navigation.isOnEmptyNewChat, !navigation.isDrawerOpen {
                newChatFab
            }
        }
    }

    private var mainStack: some View {
        NavigationStack(path: $navigation.path) {
            rootView
                .toolbar { shellToolbar }
                .onAppear { isRootVisible = true }
                .onDisappear { isRootVisible = false }
                .navigationDestination(for: ShellPushDestination.self) { destination in
                    pushedView(destination)
                }
        }
        // A new root also drops screens ChatView pushed outside the typed path.
        .id(navigation.rootRevision)
        .background(Color.hxCanvas.ignoresSafeArea())
    }

    @ViewBuilder
    private var rootView: some View {
        switch navigation.root {
        case .session(let session):
            ChatView(
                session: session,
                server: server,
                onAPIError: authManager.handleAPIError,
                callRequest: callRequest,
                draftStore: draftStore,
                onSessionRenamed: { sessionID, title in
                    viewModel.applyConfirmedRename(sessionID: sessionID, title: title, modelContext: modelContext)
                }
            )
            .id(session.id)
        case .newChat(let route):
            PendingNewChatView(
                initialDraft: route.initialDraft,
                initialAttachments: route.initialAttachments,
                autoStartsVoiceInput: route.autoStartsVoiceInput,
                profileName: route.profileName,
                projectID: route.projectID,
                startsCall: route.startsCall,
                callRequest: callRequest,
                server: server,
                viewModel: viewModel,
                onAPIError: authManager.handleAPIError,
                onSessionCreated: rememberCreatedSession,
                onConversationStarted: { navigation.markNewChatStarted() },
                draftStore: draftStore,
                isStillRoot: { navigation.root == .newChat(route) }
            )
            .id(route.id)
        }
    }

    @ToolbarContentBuilder
    private var shellToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                setDrawerOpen(!navigation.isDrawerOpen)
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .accessibilityLabel(navigation.isDrawerOpen ? "Close chats" : "Open chats")
        }

        ToolbarItem(placement: .topBarTrailing) {
            // On a chat that's already new and empty, a new chat goes nowhere: offer the call instead.
            if navigation.isOnEmptyNewChat {
                Button(action: callFromEmptyNewChat) {
                    Image(systemName: "phone")
                }
                .disabled(viewModel.isViewingCachedData)
                .accessibilityLabel("Call Atlas")
            } else {
                // In a conversation, call on it; New Chat stays on the drawer's compose button and on long press.
                Button { callRequest += 1 } label: {
                    Image(systemName: "phone")
                }
                .disabled(viewModel.isViewingCachedData)
                .accessibilityLabel("Call Atlas")
                .contextMenu {
                    Button("Call Atlas", systemImage: "phone") { callRequest += 1 }
                    Button("New Chat", systemImage: "square.and.pencil", action: openNewChat)
                    Button("New Call", systemImage: "phone.badge.plus", action: openNewCall)
                }
            }
        }
    }

    @ViewBuilder
    private func pushedView(_ destination: ShellPushDestination) -> some View {
        switch destination {
        case .settings(let scrollTo):
            settingsDestination(scrollTo)
        case .tasks:
            TasksView(server: server, onAPIError: authManager.handleAPIError)
                .adaptiveSecondaryNavigationTitle()
        case .kanban:
            KanbanView(server: server, onAPIError: authManager.handleAPIError)
                .adaptiveSecondaryNavigationTitle()
        case .dailyDeck:
            DailyDeckView(server: server) { sessionID in
                Task { await openDeepLinkedSession(id: sessionID) }
            }
        case .brain:
            BrainHomeView(
                server: server,
                modelContext: modelContext,
                onAPIError: authManager.handleAPIError,
                push: { navigation.path.append(.brainRoute($0)) }
            )
            .adaptiveSecondaryNavigationTitle()
        case .brainRoute(let route):
            brainDestination(route)
        case .projects:
            ProjectsView(
                viewModel: viewModel,
                openProject: { navigation.push(.project($0)) },
                createProject: { isPresentingProjectCreation = true },
                renameProject: { projectPendingRename = $0 },
                deleteProject: { projectPendingDeletion = $0 }
            )
        case .project(let projectID):
            ProjectDetailView(
                viewModel: viewModel,
                projectID: projectID,
                automatedVisibility: automatedSessionVisibility,
                actions: sessionRowActions(),
                selectedSessionID: navigation.selectedSessionID,
                showsMessageCount: showsSessionMessageCount,
                showsWorkspace: showsSessionWorkspace,
                startChat: { selectDestination(PendingNewChatRoute(projectID: projectID)) }
            )
        }
    }

    @ViewBuilder
    private func brainDestination(_ route: BrainRoute) -> some View {
        switch route {
        case .module(.highlights):
            BrainHighlightsView(server: server, modelContext: modelContext, onAPIError: authManager.handleAPIError)
                .adaptiveSecondaryNavigationTitle()
        case .module(let module):
            BrainModuleListView(
                module: module,
                server: server,
                modelContext: modelContext,
                onAPIError: authManager.handleAPIError
            )
            .adaptiveSecondaryNavigationTitle()
        case .page(let module, let id) where BrainHighlightsBookView.isBook(module: module, id: id):
            BrainHighlightsBookView(id: id, server: server, modelContext: modelContext, onAPIError: authManager.handleAPIError)
        case .page(let module, let id):
            BrainReaderView(
                module: module,
                id: id,
                server: server,
                modelContext: modelContext,
                onAPIError: authManager.handleAPIError,
                push: { navigation.path.append(.brainRoute($0)) }
            )
        case .searchAll(let module, let query):
            BrainSearchView(module: module, query: query, server: server, onAPIError: authManager.handleAPIError)
                .adaptiveSecondaryNavigationTitle()
        }
    }

    private func setDrawerOpen(_ isOpen: Bool) {
        if isOpen {
            hasOpenedDrawer = true
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.3)) {
            navigation.isDrawerOpen = isOpen
        }
    }


    @ViewBuilder
    private func settingsDestination(_ scrollTo: SettingsScrollAnchor?) -> some View {
        SettingsView(
            authManager: authManager,
            server: server,
            initialScrollTarget: scrollTo,
            onDefaultProfileSelected: viewModel.adoptDefaultProfileSelection,
            profileViewModel: viewModel,
            switchActiveProfile: { profile in
                Task { await switchActiveProfile(profile) }
            },
            pendingBotDestination: $pendingBotDestination
        )
        .adaptiveSecondaryNavigationTitle()
    }

    /// The drawer's rows: search across every source while a query is typed,
    /// otherwise the recents filter. Computed once per drawer body.
    private var drawerSessions: [SessionSummary] {
        viewModel.visibleSessions(
            searchText: searchText,
            selectedProjectID: nil,
            automatedVisibility: automatedSessionVisibility,
            filter: recentsFilter
        )
    }

    private var sessionListSurface: some View {
        ChatDrawerView(
            viewModel: viewModel,
            searchText: $searchText,
            searchFocus: $searchFieldIsFocused,
            filter: $recentsFilter,
            sessions: drawerSessions,
            isSearching: isSearchingSessions,
            sectionVisibility: sidebarSectionVisibility,
            selectedSessionID: navigation.selectedSessionID,
            showsMessageCount: showsSessionMessageCount,
            showsWorkspace: showsSessionWorkspace,
            actions: sessionRowActions(),
            serverName: authManager.activeServer?.displayName ?? server.host() ?? server.absoluteString,
            canCreateNewChat: !viewModel.isViewingCachedData && !navigation.isCreatingNewChat,
            onNewChat: openNewChat,
            onOpen: { navigation.push($0) },
            onReviewArchiveCandidates: { isPresentingArchiveReview = true },
            refresh: { await refreshSessionsAndActiveProfile() }
        ) {
            AvatarServerSwitcherMenu(
                model: AvatarServerSwitcherModel(
                    servers: authManager.servers,
                    activeServerID: authManager.activeServerID
                ),
                switchToServer: { account in
                    authManager.switchActiveServer(to: account)
                },
                addServer: { isPresentingAddServer = true },
                manageServers: { navigation.push(.settings(.servers)) }
            )
        }
        .overlay(alignment: .bottom) {
            ActionToastView(state: actionToast)
                .padding(.horizontal, 16)
                .padding(.bottom, 64)
        }
    }

    private var automatedSessionVisibility: AutomatedSessionVisibility {
        AutomatedSessionVisibility(
            showsCron: showsCronSessions,
            showsCli: showsCliSessions,
            showsClaudeCode: showsClaudeCodeSessions,
            showsSubagents: showsSubagentSessions
        )
    }

    private var sidebarSectionVisibility: SidebarSectionVisibility {
        SidebarSectionVisibility(
            bots: isBotModeEnabled,
            tasks: showsTasksSection,
            kanban: showsKanbanSection,
            skills: showsSkillsSection,
            memory: showsMemorySection,
            insights: showsInsightsSection,
            activeProfile: showsActiveProfileSection,
            projects: showsProjectsSection,
            brain: true
        )
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearchingSessions: Bool {
        !normalizedSearchText.isEmpty
    }

    private var remoteSearchTaskID: SessionSearchTaskID {
        SessionSearchTaskID(query: normalizedSearchText, isViewingCachedData: viewModel.isViewingCachedData)
    }

    private var activeSessionMonitorTaskID: ActiveSessionMonitorTaskID {
        let activeSessions = viewModel.visibleActiveSessions(
            searchText: searchText,
            selectedProjectID: nil,
            automatedVisibility: automatedSessionVisibility
        )
        return ActiveSessionMonitorTaskID(
            streamIDs: SessionListViewModel.activeStreamIDs(in: activeSessions),
            hasActiveRows: !activeSessions.isEmpty,
            isViewingCachedData: viewModel.isViewingCachedData,
            isDrawerOpen: navigation.isDrawerOpen
        )
    }

    private func sessionRowActions() -> SessionListRowActions {
        SessionListRowActions(
            retryLoad: {
                Task { await refreshSessionsAndActiveProfile() }
            },
            open: { session in
                startOpeningSession(session)
            },
            toggleUnread: { session in
                viewModel.toggleUnread(session)
            },
            togglePinned: { session in
                Task { await togglePinned(session) }
            },
            archive: { session in
                Task { await archive(session) }
            },
            summarizeAndArchive: { session in
                Task { await summarizeAndArchive(session) }
            },
            delete: { session in
                sessionPendingDeletion = session
            },
            rename: { session in
                sessionPendingRename = session
            },
            duplicate: { session in
                Task { await duplicate(session) }
            },
            move: { session, projectID in
                Task { await move(session, to: projectID) }
            },
            createProject: { session in
                sessionPendingProjectCreation = session
            },
            refreshProjects: {
                Task { await viewModel.loadProjects() }
            },
            export: { session, format in
                Task { await export(session, format: format) }
            }
        )
    }

    private func refreshSessionsAndActiveProfile() async {
        await loadSessionRows()
        guard !Task.isCancelled else { return }
        await SessionListInitialLoad.loadProjectsAndActiveProfile(
            loadProjects: { await loadProjectsIfLive() },
            loadActiveProfile: { await viewModel.loadActiveProfile() }
        )
    }

    private var sceneActions: HermexSceneActions {
        HermexSceneActions(
            canCreateNewChat: !viewModel.isViewingCachedData && !navigation.isCreatingNewChat,
            createNewChat: openNewChatFromKeyboard,
            searchSessions: openSearchFromKeyboard,
            openChat: openChatFromKeyboard(atPosition:),
            openAdjacentChat: openAdjacentChatFromKeyboard(offset:)
        )
    }

    /// Chat shortcuts walk the drawer's rows as they appear, after search and
    /// the recents filter. Computed only on a key press, never in `body`.
    private var keyboardShortcutChats: [SessionSummary] {
        drawerSessions
    }

    private func openChatFromKeyboard(atPosition position: Int) {
        guard let chat = ChatShortcutNavigation.chat(atPosition: position, in: keyboardShortcutChats) else { return }
        startOpeningSession(chat)
    }

    /// Steps from the chat still opening, if any, so a second press during a
    /// slow external import moves on instead of reopening the same chat.
    private func openAdjacentChatFromKeyboard(offset: Int) {
        guard let chat = ChatShortcutNavigation.adjacentChat(
            offset: offset,
            from: viewModel.openingSessionID ?? navigation.selectedSessionID,
            in: keyboardShortcutChats
        ) else { return }
        startOpeningSession(chat)
    }

    private func openNewChatFromKeyboard() {
        guard !viewModel.isViewingCachedData, !navigation.isCreatingNewChat else { return }
        openNewChat()
    }

    private func openSearchFromKeyboard() {
        setDrawerOpen(true)
        Task { @MainActor in
            await Task.yield()
            searchFieldIsFocused = true
        }
    }

    private func refreshAfterReturningIfNeeded() {
        guard didCompleteInitialLoad else { return }
        returnRefreshID = UUID()
    }

    /// Runs a foreground return that had to wait for a load to settle.
    private func refreshAfterForegroundReturnIfReady() {
        guard foregroundRefresh.consumeIfReady(
            didCompleteInitialLoad: didCompleteInitialLoad,
            isLoading: viewModel.isLoading
        ) else { return }
        refreshAfterReturningIfNeeded()
    }

    private func monitorActiveSessionRows() async {
        while !Task.isCancelled {
            let taskID = activeSessionMonitorTaskID
            guard taskID.shouldPoll else { return }

            do {
                try await Task.sleep(for: ActiveSessionMonitorTaskID.pollInterval)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            await refreshActiveSessionRows(taskID)
        }
    }

    /// One poll tick: checks the active rows' streams and attention probes.
    private func refreshActiveSessionRows(_ taskID: ActiveSessionMonitorTaskID) async {
        let refreshResult = await viewModel.refreshActiveSessionStatesIfNeeded(
            streamIDs: taskID.streamIDs,
            modelContext: modelContext
        )
        if refreshResult == .reloaded || refreshResult == .failed {
            handleLastError()
        }
    }

    @MainActor
    private func switchActiveProfile(_ profile: ProfileSummary) async {
        let didSwitch = await viewModel.switchActiveProfile(profile)
        handleLastError()

        guard didSwitch else { return }

        await loadSessions()
    }

    private func loadSessions() async {
        await loadSessionRows()
        guard !Task.isCancelled else { return }
        await loadProjectsIfLive()
    }

    private func loadSessionRows() async {
        await viewModel.load(modelContext: modelContext)
        guard !Task.isCancelled else { return }
        handleLastError()
        startAutoArchivePassIfDue()
    }

    /// Starts this foreground's auto-archive pass after a live load. It runs
    /// in its own task so a refresh that replaces the load task can't cut it short.
    private func startAutoArchivePassIfDue() {
        guard viewModel.isAutoArchiveDue, autoArchiveTask == nil else { return }
        autoArchiveTask = Task {
            let archived = await viewModel.runAutoArchivePassIfDue(
                excludingSessionID: navigation.selectedSessionID,
                modelContext: modelContext
            )
            autoArchiveTask = nil
            guard !Task.isCancelled else { return }
            handleLastError()
            guard !archived.isEmpty else { return }
            pendingAutoArchived = archived
            showPendingAutoArchiveToast()
        }
    }

    /// "Archived N idle chats · Undo", shown once the drawer is open.
    private func showPendingAutoArchiveToast() {
        guard navigation.isDrawerOpen, !pendingAutoArchived.isEmpty else { return }
        let batch = pendingAutoArchived
        pendingAutoArchived = []
        let message = String(localized: "Archived \(batch.count) idle chats")
        actionToast.show(
            ActionToast(
                message: message,
                systemImage: "archivebox",
                accessibilityLabel: message,
                actionTitle: String(localized: "Undo"),
                action: {
                    Task {
                        _ = await viewModel.undoAutoArchive(batch, modelContext: modelContext)
                        handleLastError()
                    }
                }
            )
        )
    }

    /// The row menu's Summarize & Archive. A failure leaves the chat in place
    /// and says why in a toast that can retry.
    private func summarizeAndArchive(_ session: SessionSummary) async {
        if let failure = await viewModel.summarizeAndArchive(session, modelContext: modelContext) {
            handleLastError()
            actionToast.show(
                ActionToast(
                    message: String(localized: "Summary failed"),
                    systemImage: "exclamationmark.triangle",
                    accessibilityLabel: String.localizedStringWithFormat(
                        String(localized: "%@, %@"),
                        SessionRowView.displayTitle(for: session),
                        failure
                    ),
                    actionTitle: String(localized: "Retry"),
                    action: {
                        Task { await summarizeAndArchive(session) }
                    }
                )
            )
            return
        }
        guard !viewModel.sessions.contains(where: { $0.sessionId == session.sessionId }) else { return }
        removeSessionFromNavigation(session)
        SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
    }

    /// Skipped while the list shows cached rows: the server was unreachable a
    /// moment ago, so a projects request would only add a second error.
    private func loadProjectsIfLive() async {
        guard !viewModel.isViewingCachedData else { return }
        await viewModel.loadProjects()
        guard !Task.isCancelled else { return }
        handleLastError()
    }

    private func togglePinned(_ session: SessionSummary) async {
        let didChangePinState = await viewModel.setPinned(
            !(session.pinned ?? false),
            for: session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didChangePinState {
            SessionHaptics.pinStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    private var isArchiveToastHostShowing: Bool {
        navigation.isDrawerOpen
    }

    private func archive(_ session: SessionSummary) async {
        let archiveNumber = archiveToastRoute.archiveStarted()
        let didArchive = await viewModel.archive(
            session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didArchive {
            viewModel.recordManualArchive(session)
            removeSessionFromNavigation(session)
            SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
            if archiveToastRoute.archiveConfirmed(archiveNumber, isListShowing: isArchiveToastHostShowing) {
                showArchiveUndoToast(for: session)
            }
        }
    }

    /// "Archived · Undo" after the server confirms an archive (#865), on the
    /// host `archiveToastRoute` picked. A newer archive replaces the toast; the
    /// first session stays in Archived.
    private func showArchiveUndoToast(for session: SessionSummary) {
        let message = String(localized: "Archived")
        actionToast.show(
            ActionToast(
                message: message,
                systemImage: "archivebox",
                accessibilityLabel: String.localizedStringWithFormat(
                    String(localized: "%@, %@"),
                    SessionRowView.displayTitle(for: session),
                    message
                ),
                actionTitle: String(localized: "Undo"),
                action: {
                    Task { await undoArchive(session) }
                }
            )
        )
    }

    /// Restores the session in place. It does not reopen a chat the archive
    /// closed; a failure shows the "Session Action Failed" alert.
    private func undoArchive(_ session: SessionSummary) async {
        let didUnarchive = await viewModel.unarchive(
            session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didUnarchive {
            viewModel.forgetManualArchive(session)
            SessionHaptics.archiveStateChanged(isEnabled: isHapticsEnabled)
        }
    }

    private func delete(_ session: SessionSummary) async {
        let didDelete = await viewModel.delete(
            session,
            modelContext: modelContext,
            animation: SessionListMotion.sessionMutationAnimation(reduceMotion: reduceMotion)
        )
        handleLastError()

        if didDelete {
            await draftStore.discardDraft(for: draftKey(for: session))
            removeSessionFromNavigation(session)
            SessionHaptics.sessionDeleted(isEnabled: isHapticsEnabled)
        }
    }

    private func draftKey(for session: SessionSummary) -> ChatDraftKey {
        let normalizedSessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = normalizedSessionID.flatMap { $0.isEmpty ? nil : $0 } ?? session.id
        return .session(server: server, sessionID: sessionID)
    }

    private func rename(_ session: SessionSummary, to title: String) async -> Bool {
        let didChangeTitle = normalizedTitle(title) != normalizedTitle(session.title)
        let didRename = await viewModel.rename(session, to: title, modelContext: modelContext)
        handleLastError()

        if didRename, didChangeTitle {
            SessionHaptics.sessionRenamed(isEnabled: isHapticsEnabled)
        }

        return didRename
    }

    private func duplicate(_ session: SessionSummary) async {
        let duplicatedSession = await viewModel.duplicate(session, modelContext: modelContext)
        handleLastError()

        if let duplicatedSession {
            selectSession(duplicatedSession)
        }
    }

    private func move(_ session: SessionSummary, to projectID: String?) async {
        await viewModel.move(session, to: projectID, modelContext: modelContext)
        handleLastError()
    }

    private func export(_ session: SessionSummary, format: SessionExportFormat) async {
        let fileURL = await viewModel.export(session, format: format)
        handleLastError()

        if let fileURL {
            sessionExportShareItem = SessionExportShareItem(fileURL: fileURL)
        }
    }

    private func delete(_ project: ProjectSummary) async {
        let deletedProjectID = project.projectId
        let didDelete = await viewModel.delete(project, modelContext: modelContext)
        handleLastError()

        if didDelete, let deletedProjectID {
            navigation.path.removeAll { $0 == .project(deletedProjectID) }
        }
    }

    private func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleLastError() {
        if let lastError = viewModel.lastError {
            authManager.handleAPIError(lastError)
        }
    }

    private func openPendingSharedImportIfNeeded() {
        guard let reservation = pendingSharedImport else {
            return
        }

        let sharedImport = reservation.sharedImport
        let draft = HermesShareDraft.composerDraft(from: sharedImport.draft)
        guard !draft.isEmpty || !sharedImport.attachments.isEmpty else {
            didRoutePendingSharedImport(reservation)
            return
        }

        selectDestination(
            PendingNewChatRoute(
                initialDraft: draft,
                initialAttachments: sharedImport.attachments
            )
        )
        didRoutePendingSharedImport(reservation)
    }

    /// A push is resolved only on its server and against the live endpoint, so a
    /// stale cache cannot open a deleted session. The task belongs to this view;
    /// another tap, server switch or manual selection invalidates its result.
    private func openPendingWebuiPush() async {
        guard let destination = pendingWebuiPush, destination.server == server,
              authManager.state == .loggedIn(server: server), !Task.isCancelled else { return }
        sessionOpenTask?.cancel()
        viewModel.invalidateSessionOpening()
        let revision = navigation.rootRevision
        let session = await viewModel.loadSessionForDeepLink(
            id: destination.sessionID, modelContext: modelContext, isPush: true)
        guard !Task.isCancelled, pendingWebuiPush == destination,
              authManager.state == .loggedIn(server: server) else { return }
        guard navigation.rootRevision == revision else {
            pendingWebuiPush = nil
            return
        }
        handleLastError()
        // An expired cookie moves the app to sign-in. Keep the tap until the
        // rebuilt, signed-in session list can retry its owning server's lookup.
        guard authManager.state == .loggedIn(server: server) else { return }
        pendingWebuiPush = nil
        if let session { selectSession(session) }
    }

    /// Awaited (not fire-and-forget) so the cold-start `.task` can resolve it before
    /// `restoreLastSelectedSessionIfNeeded()` — otherwise the restore races the deep
    /// link's network load and wins with the previous session.
    private func openPendingDeepLinkedSessionIfNeeded() async {
        guard !Task.isCancelled else { return }

        while let sessionID = navigation.beginDeepLinkedSessionLoad(
            id: pendingDeepLinkedSessionID
        ) {
            pendingDeepLinkedSessionID = nil
            await openDeepLinkedSession(id: sessionID)
            navigation.finishDeepLinkedSessionLoad(id: sessionID)
            guard !Task.isCancelled else { return }
        }
    }

    private func openDeepLinkedSession(id sessionID: String) async {
        if let loadedSession = viewModel.sessions.first(where: { $0.sessionId == sessionID }) {
            selectSession(loadedSession)
            return
        }

        let session = await viewModel.loadSessionForDeepLink(id: sessionID, modelContext: modelContext)
        // Re-checked post-await: the view (and this task) may have been torn down —
        // e.g. dismissed, or the active server changed under `.id(server)` — while
        // the network load was in flight. Selecting or persisting for a session
        // whose owning view no longer exists is stale work, not a real navigation.
        guard !Task.isCancelled else { return }
        if let session {
            selectSession(session)
        }
        handleLastError()
    }

    /// Opens the New Chat composer in response to the "New Chat" App Intents (#337/#338),
    /// mirroring the "+" button. Carries `autoStartsVoiceInput` so the voice variant begins
    /// dictation once the composer appears. The request is cleared so it fires once per
    /// invocation.
    /// A Daily Brief notification tap: show the brief over whatever chat is open.
    private func openRequestedDailyBriefIfNeeded() {
        guard requestedDailyBrief else { return }
        requestedDailyBrief = false
        if navigation.path.last != .dailyDeck { navigation.showOnly(.dailyDeck) }
    }

    private func openRequestedNewChatIfNeeded() {
        guard let request = requestedNewChat else { return }
        requestedNewChat = nil
        selectDestination(
            PendingNewChatRoute(
                autoStartsVoiceInput: request.autoStartsVoiceInput,
                profileName: request.profileName,
                startsCall: request.startsCall
            )
        )
    }

    /// In-app New Chat (top bar, drawer, ⌘N). A project's own screen starts chats
    /// in that project (#875); system entry points never inherit one.
    private func openNewChat() {
        selectDestination(PendingNewChatRoute())
    }

    /// A circular floating New Chat button, bottom-right of the shell: the
    /// primary affordance, shown on the session list and every chat screen.
    /// Kept off `shellContainer`'s return so the type-checker has a small
    /// expression to chew (the type-checking-budget rule).
    private var newChatFab: some View {
        HapticButton {
            openNewChat()
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
        }
        .frame(width: 56, height: 56)
        .background(newChatFabBackground, in: Circle())
        .foregroundStyle(newChatFabForeground)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        .padding(16)
        .accessibilityLabel(String(localized: "New Chat"))
        .accessibilityIdentifier("chatNewChatFab")
    }

    /// Themed like the other primary action: the Header Logo Color when the
    /// user enables the tint, the accent otherwise.
    private var newChatFabBackground: Color {
        if tintsPrimaryActions {
            return HeaderLogoColor.color(for: themeHex)
        }
        return .accentColor
    }

    private var newChatFabForeground: Color {
        if tintsPrimaryActions {
            return HeaderLogoColor.prefersDarkForeground(for: themeHex) ? .black : .white
        }
        return Color.hxOnAccent
    }

    /// A new chat that opens straight into a voice call with Atlas.
    private func openNewCall() {
        selectDestination(PendingNewChatRoute(startsCall: true))
    }

    /// Calls from the empty new chat on screen, keeping its profile and project.
    private func callFromEmptyNewChat() {
        guard case .newChat(let route) = navigation.root else { return openNewCall() }
        selectDestination(PendingNewChatRoute(profileName: route.profileName, projectID: route.projectID, startsCall: true))
    }

    private func selectSession(_ session: SessionSummary) {
        selectDestination(session)
    }

    private func selectDestination(_ session: SessionSummary) {
        viewModel.invalidateSessionOpening()
        navigation.select(session)
    }

    private func selectDestination(_ route: PendingNewChatRoute) {
        viewModel.invalidateSessionOpening()
        navigation.select(route)
    }

    private func startOpeningSession(_ session: SessionSummary) {
        SessionOpenSignpost.begin(sessionID: session.sessionId)
        sessionOpenTask?.cancel()
        sessionOpenTask = Task { await openSession(session) }
    }

    private func openSession(_ session: SessionSummary) async {
        let sessionToOpen = await viewModel.sessionForOpening(session, modelContext: modelContext)
        guard !Task.isCancelled else { return }

        if let message = viewModel.actionErrorMessage {
            sessionOpenErrorMessage = message
        }

        if let sessionToOpen {
            selectSession(sessionToOpen)
        } else {
            // No chat will show to end the interval; a cancelled open is ended by
            // the newer `begin` instead.
            SessionOpenSignpost.end(sessionID: session.sessionId, messages: nil)
        }
    }

    private var sessionOpenErrorIsPresented: Binding<Bool> {
        Binding(
            get: { sessionOpenErrorMessage != nil },
            set: { isPresented in
                if !isPresented { sessionOpenErrorMessage = nil }
            }
        )
    }

    private func rememberCreatedSession(_ session: SessionSummary) {
        navigation.remember(session)
    }

    private func removeSessionFromNavigation(_ session: SessionSummary) {
        navigation.remove(sessionID: session.sessionId)
    }

}

/// Orders the shell's cold-start load: the session rows and a pending deep link
/// first, then projects and the active profile side by side.
enum SessionListInitialLoad {
    @MainActor
    static func run(
        resolvePendingDeepLink: @escaping @MainActor () async -> Void,
        loadSessions: @escaping @MainActor () async -> Void,
        sessionsDidLoad: @MainActor () -> Void,
        loadProjects: @escaping @MainActor () async -> Void,
        loadActiveProfile: @escaping @MainActor () async -> Void
    ) async {
        async let sessions: Void = loadSessions()
        await resolvePendingDeepLink()
        await sessions
        guard !Task.isCancelled else { return }
        sessionsDidLoad()
        await loadProjectsAndActiveProfile(loadProjects: loadProjects, loadActiveProfile: loadActiveProfile)
    }

    /// Runs the two loads concurrently; neither depends on the other. Also used
    /// by every later refresh of the list.
    @MainActor
    static func loadProjectsAndActiveProfile(
        loadProjects: @escaping @MainActor () async -> Void,
        loadActiveProfile: @escaping @MainActor () async -> Void
    ) async {
        async let activeProfile: Void = loadActiveProfile()
        await loadProjects()
        await activeProfile
    }
}

/// Runs the return refresh that `SessionListDestinationReturn` and
/// `SessionListForegroundRefresh` request. It reloads the rows, then runs one
/// poll tick when the poll was paused while a destination covered the compact
/// list, so badges such as Approval do not stay as they were before the push
/// until the restarted poll's first tick.
enum SessionListReturnRefresh {
    @MainActor
    static func run(
        refreshSessions: @MainActor () async -> Void,
        monitorTaskID: @MainActor () -> ActiveSessionMonitorTaskID,
        refreshActiveRows: @MainActor (ActiveSessionMonitorTaskID) async -> Void
    ) async {
        await refreshSessions()
        guard !Task.isCancelled else { return }
        // Read after the reload so the tick uses the rows that are streaming now.
        let taskID = monitorTaskID()
        guard taskID.needsTickOnReturn else { return }
        await refreshActiveRows(taskID)
    }
}

/// Refreshes the session list whenever the user leaves one destination for
/// another, so a row reflects whatever just happened in the chat it opened
/// (a rename, a `/clear`, new messages). Driven from the `destination`
/// `onChange` in `SessionListView`.
enum SessionListDestinationReturn {
    static func run(
        from oldValue: ShellRoot,
        to newValue: ShellRoot,
        suppressEmptyPlaceholders: () -> Void,
        refreshSessions: () -> Void
    ) {
        // A root that re-emits itself has no new server state to adopt.
        guard oldValue != newValue else { return }
        // Replacing one pending new-chat route with another stays on the same
        // screen, so it is not a return.
        if case .newChat = oldValue, case .newChat = newValue { return }

        if case .newChat = oldValue {
            // Keep this synchronous so an empty Untitled placeholder cannot
            // flash during the navigation transition. The refresh then adopts
            // the server's latest metadata for a new chat that became
            // contentful.
            suppressEmptyPlaceholders()
        }
        refreshSessions()
    }
}

struct HermesHeaderLogo: View {
    let selectedColor: Color

    private static let aspectRatio = 643.0 / 185.0

    var body: some View {
        ZStack {
            Image("hermes-fill-mask")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(selectedColor)

            Image("hermes-shading-overlay")
                .resizable()
                .scaledToFit()
                .blendMode(.multiply)

            Image("hermes-highlight")
                .resizable()
                .scaledToFit()
                .blendMode(.screen)

            Image("hermes-outline-shadow")
                .resizable()
                .scaledToFit()
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .compositingGroup()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ATLAS")
    }
}

/// A request from `ContentView` to open the New Chat composer. Carries whether voice
/// dictation should auto-start (the "New Chat with Voice" App Intent, #338) and an optional
/// profile name to pin the new session to (the "New Chat in <Profile>" App Intent, #339).
/// A fresh `id` each time so a repeat invocation re-triggers navigation even if the previous
/// value lingers.
struct NewChatRequest: Equatable {
    let id: UUID
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile; nil uses the server's
    /// active profile (the plain "+" / "New Chat" behavior).
    let profileName: String?
    /// When true, the new chat opens straight into a voice call.
    let startsCall: Bool

    init(autoStartsVoiceInput: Bool = false, profileName: String? = nil, startsCall: Bool = false) {
        self.id = UUID()
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
        self.startsCall = startsCall
    }
}

struct PendingNewChatRoute: Identifiable, Hashable {
    let id = UUID()
    let initialDraft: String
    let initialAttachments: [SharedAttachmentImport]
    /// When true, the composer auto-starts voice dictation on appear (#338).
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile (#339).
    let profileName: String?
    /// When set, the new session is created in this project (#875).
    let projectID: String?
    /// When true, the new chat opens straight into a voice call.
    let startsCall: Bool

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil,
        projectID: String? = nil,
        startsCall: Bool = false
    ) {
        self.initialDraft = initialDraft
        self.initialAttachments = initialAttachments
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
        self.projectID = projectID
        self.startsCall = startsCall
    }

    static func == (lhs: PendingNewChatRoute, rhs: PendingNewChatRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct SessionSearchTaskID: Hashable {
    let query: String
    let isViewingCachedData: Bool
}

/// Identity for the session list's active-row poll. SwiftUI restarts the poll
/// whenever this changes, and the poll runs only while `shouldPoll` holds.
/// The streaming-row poll runs only while the drawer shows the rows; opening it
/// again runs `SessionListReturnRefresh`, which reloads the rows and ticks once.
struct ActiveSessionMonitorTaskID: Hashable {
    /// Wait between polls. The open chat watches its own run over SSE, so the
    /// list only needs badges and the Working-to-done switch reasonably fresh.
    static let pollInterval: Duration = .seconds(3)

    let streamIDs: [String]
    let hasActiveRows: Bool
    let isViewingCachedData: Bool
    let isListVisible: Bool

    init(
        streamIDs: [String],
        hasActiveRows: Bool,
        isViewingCachedData: Bool,
        isDrawerOpen: Bool
    ) {
        self.streamIDs = streamIDs
        self.hasActiveRows = hasActiveRows
        self.isViewingCachedData = isViewingCachedData
        isListVisible = isDrawerOpen
    }

    var shouldPoll: Bool {
        hasActiveRows && isListVisible && !isViewingCachedData
    }

    /// The poll pauses while the drawer is closed, so reopening it ticks once.
    var needsTickOnReturn: Bool {
        shouldPoll
    }
}
