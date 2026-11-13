import SwiftUI

/// The shell's left drawer: search, the second brain's sections, the filtered recents, and
/// a Settings bar pinned to the bottom. The shell owns all state and actions;
/// `sessions` arrives already searched, filtered, and sorted.
struct ChatDrawerView<ServerMenu: View>: View {
    let viewModel: SessionListViewModel
    @Binding var searchText: String
    var searchFocus: FocusState<Bool>.Binding
    @Binding var filter: RecentsFilter
    let sessions: [SessionSummary]
    let isSearching: Bool
    /// What each section holds today, by section. A section with nothing to say is absent.
    let notes: [DrawerSection: String]
    /// The Status bar's note; nil hides the bar (no answer yet, or a server without Status).
    let status: AtlasStatusDrawerNote?
    let selectedSessionID: String?
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let actions: SessionListRowActions
    let serverName: String
    let canCreateNewChat: Bool
    let onNewChat: () -> Void
    /// Runs an auto-archive pass now ("Clean up old chats"). nil hides the row.
    let onOpen: (ShellPushDestination) -> Void
    /// Opens the sheet of idle chats waiting for a keep-or-archive decision.
    let onReviewArchiveCandidates: () -> Void
    let refresh: () async -> Void
    @ViewBuilder let serverMenu: () -> ServerMenu

    @ScaledMetric(relativeTo: .title2) private var composeButtonSize: CGFloat = 56

    var body: some View {
        let sections = DrawerSessionSections(sessions, isSearching: isSearching)

        return VStack(spacing: 0) {
            // Containers (search, selected row) sit 8pt in; their content lines up at 20pt.
            searchField
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 8)

            List {
                if !isSearching {
                    navigationRows

                    if viewModel.isViewingCachedData {
                        OfflineCacheBanner()
                            .padding(.top, 8)
                            .sessionsScreenListRow()
                    }

                    if !viewModel.archiveReviewCandidates.isEmpty {
                        archiveReviewBanner(count: viewModel.archiveReviewCandidates.count)
                            .padding(.top, 8)
                            .sessionsScreenListRow()
                    }

                    if !sections.pinned.isEmpty {
                        pinnedSection(sections.pinned)
                    }

                    recentsHeader
                        .sessionsScreenListRow()
                }

                if showsFilterEmptyState {
                    filterEmptyState
                        .sessionsScreenListRow()
                }

                SessionListRowsSection(
                    viewModel: viewModel,
                    searchText: searchText,
                    sessions: sections.recents,
                    emptyTitle: isSearching ? String(localized: "No matching sessions") : String(localized: "No sessions yet"),
                    emptyDescription: isSearching ? String(localized: "Try another search.") : nil,
                    isSearchActive: isSearching,
                    showsMessageCount: showsMessageCount,
                    showsWorkspace: showsWorkspace,
                    selectedSessionID: selectedSessionID,
                    actions: actions,
                    suppressEmptyState: showsFilterEmptyState || !sections.pinned.isEmpty,
                    showsHeader: isSearching
                )
            }
            .listStyle(.plain)
            // On the List itself: a refresh action set higher up is inherited by
            // every ScrollView below it.
            .refreshable { await refresh() }
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // Room below the last row so the compose button never hides it.
            .contentMargins(.bottom, composeButtonSize + 32, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                if !isSearching { composeButton }
            }

            if let status {
                AtlasStatusDrawerBar(note: status) { onOpen(.status) }
            }
            settingsBar
        }
        .background(Color.hxCanvas.ignoresSafeArea())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused(searchFocus)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
    }

    /// The second brain's sections, in `DrawerSection` order. The operator screens
    /// (Projects, Tasks, Kanban, Feedback) live in Settings' Tools card.
    private var navigationRows: some View {
        ForEach(DrawerSection.allCases, id: \.self) { section in
            drawerRow(section, note: notes[section]) { onOpen(section.destination) }
        }
    }

    /// Floating bottom-right New Chat, where messaging apps put compose.
    private var composeButton: some View {
        Button(action: onNewChat) {
            Image(systemName: "square.and.pencil")
                .font(.title2.weight(.medium))
                .frame(width: composeButtonSize, height: composeButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .adaptiveGlass(isInteractive: true, in: Circle())
        .disabled(!canCreateNewChat)
        .accessibilityLabel(String(localized: "New Chat"))
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    /// A section row: its icon in its paper's glow on a faint wash tile, its name, and a
    /// trailing note of what it holds today when it has one.
    private func drawerRow(
        _ section: DrawerSection,
        note: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(AppFont.body())
                    .foregroundStyle(section.paper.glow)
                    .frame(width: 30, height: 30)
                    .background(section.paper.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(AppFont.body())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                if let note {
                    Spacer(minLength: 8)
                    Text(note)
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .sessionsScreenListRow()
    }

    /// "N chats to review before archiving", above the chat rows.
    private func archiveReviewBanner(count: Int) -> some View {
        Button(action: onReviewArchiveCandidates) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("\(count) chats to review before archiving")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func pinnedSection(_ pinned: [SessionSummary]) -> some View {
        Text("Pinned")
            .font(AppFont.display(style: .headline, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .accessibilityAddTraits(.isHeader)
            .sessionsScreenListRow()

        ForEach(pinned) { session in
            SessionInteractiveRow(
                viewModel: viewModel,
                session: session,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace,
                selectedSessionID: selectedSessionID,
                actions: actions
            )
        }
    }

    private var recentsHeader: some View {
        // Side by side when it fits; stacked at the largest text sizes.
        ViewThatFits(in: .horizontal) {
            HStack {
                recentsTitle
                Spacer()
                filterMenu
            }
            VStack(alignment: .leading, spacing: 0) {
                recentsTitle
                filterMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var recentsTitle: some View {
        Text("Recents")
            .font(AppFont.display(style: .headline, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                ForEach(viewModel.availableRecentsFilters, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(filter.title)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            // Explicit color: a Menu label otherwise renders the tint at secondary opacity.
            .foregroundStyle(Color(.secondaryLabel))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Showing \(filter.title) chats"))
    }

    private var showsFilterEmptyState: Bool {
        !isSearching && filter != .all && sessions.isEmpty && !viewModel.sessions.isEmpty
    }

    private var filterEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No \(filter.title) chats")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Show All") { filter = .all }
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var settingsBar: some View {
        Button {
            onOpen(.settings(nil))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .accessibilityHidden(true)
                Text("Settings")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                Text(serverName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityHint("Opens Settings. Long press to switch servers.")
        .contextMenu { serverMenu() }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.hxSeparator)
                .frame(height: 1 / UIScreen.main.scale)
        }
    }
}

/// Splits the drawer's rows into a Pinned section above Recents, each keeping
/// the incoming order. Search shows one flat list of matches instead.
struct DrawerSessionSections: Equatable {
    let pinned: [SessionSummary]
    let recents: [SessionSummary]

    init(_ sessions: [SessionSummary], isSearching: Bool) {
        guard !isSearching else {
            pinned = []
            recents = sessions
            return
        }
        pinned = sessions.filter { $0.pinned == true }
        recents = sessions.filter { $0.pinned != true }
    }
}
