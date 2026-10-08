import SwiftUI

/// The shell's left drawer: search, navigation rows, the filtered recents, and
/// a Settings bar pinned to the bottom. The shell owns all state and actions;
/// `sessions` arrives already searched, filtered, and sorted.
struct ChatDrawerView<ServerMenu: View>: View {
    let viewModel: SessionListViewModel
    @Binding var searchText: String
    var searchFocus: FocusState<Bool>.Binding
    @Binding var filter: RecentsFilter
    let sessions: [SessionSummary]
    let isSearching: Bool
    let sectionVisibility: SidebarSectionVisibility
    let selectedSessionID: String?
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let actions: SessionListRowActions
    let serverName: String
    let canCreateNewChat: Bool
    let onNewChat: () -> Void
    let onOpen: (ShellPushDestination) -> Void
    let refresh: () async -> Void
    @ViewBuilder let serverMenu: () -> ServerMenu

    @ScaledMetric(relativeTo: .title2) private var composeButtonSize: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
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
                    sessions: sessions,
                    emptyTitle: isSearching ? String(localized: "No matching sessions") : String(localized: "No sessions yet"),
                    emptyDescription: isSearching ? String(localized: "Try another search.") : nil,
                    isSearchActive: isSearching,
                    showsMessageCount: showsMessageCount,
                    showsWorkspace: showsWorkspace,
                    selectedSessionID: selectedSessionID,
                    actions: actions,
                    suppressEmptyState: showsFilterEmptyState,
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
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var navigationRows: some View {
        if sectionVisibility.projects {
            drawerRow(String(localized: "Projects"), systemImage: "folder") { onOpen(.projects) }
        }
        if sectionVisibility.tasks {
            drawerRow(String(localized: "Tasks"), systemImage: "calendar.badge.clock") { onOpen(.tasks) }
        }
        if sectionVisibility.kanban {
            drawerRow(String(localized: "Kanban"), systemImage: "rectangle.split.3x1") { onOpen(.kanban) }
        }
        drawerRow("Daily Brief", systemImage: "sun.horizon") { onOpen(.dailyDeck) }
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

    private func drawerRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .sessionsScreenListRow()
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
            .font(.headline)
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
