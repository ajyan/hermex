import SwiftUI

extension ProjectSummary {
    var displayName: String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return String(localized: "Untitled Project") }
        return name
    }

    /// The server's color, else a stable pick from the project's identity. User data, not a token.
    var displayColor: Color {
        if let apiColor = Color(hexString: color) { return apiColor }
        let seed = (projectId ?? displayName).unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        switch seed % 5 {
        case 0: return .green
        case 1: return .blue
        case 2: return .red
        case 3: return .orange
        default: return .primary
        }
    }
}

/// Drawer › Projects: the server's projects, with create, rename, and delete.
/// The sheets and the delete confirmation live on the shell, which presents
/// them over any pushed screen.
struct ProjectsView: View {
    let viewModel: SessionListViewModel
    let openProject: (String) -> Void
    let createProject: () -> Void
    let renameProject: (ProjectSummary) -> Void
    let deleteProject: (ProjectSummary) -> Void

    var body: some View {
        List {
            ForEach(viewModel.projects) { project in
                row(for: project)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.hxCanvas)
        // Centered states instead of a lone list row, which drew a white band between separators.
        .overlay {
            if viewModel.projects.isEmpty {
                if viewModel.isLoadingProjects {
                    ProgressView("Loading projects...")
                } else {
                    ContentUnavailableView {
                        Label("No projects", systemImage: "folder")
                    } actions: {
                        Button("New Project", action: createProject)
                            .disabled(viewModel.isViewingCachedData || viewModel.isCreatingProject)
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: createProject) {
                    Label("New Project", systemImage: "folder.badge.plus")
                }
                .disabled(viewModel.isViewingCachedData || viewModel.isCreatingProject)
            }
        }
        .task { await viewModel.loadProjects() }
    }

    private func row(for project: ProjectSummary) -> some View {
        let count = project.projectId.map { id in viewModel.sessions.filter { $0.projectId == id }.count } ?? 0
        let actionsDisabled = viewModel.isViewingCachedData || viewModel.isRenamingProject
            || viewModel.isDeletingProject || project.projectId == nil

        return Button {
            if let projectID = project.projectId { openProject(projectID) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(project.displayColor)
                    .accessibilityHidden(true)
                Text(project.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.hxCanvas)
        .accessibilityValue(String(localized: "\(count) sessions"))
        .contextMenu {
            Button { renameProject(project) } label: { Label("Rename Project", systemImage: "pencil") }
                .disabled(actionsDisabled)
            Button(role: .destructive) { deleteProject(project) } label: { Label("Delete Project", systemImage: "trash") }
                .disabled(actionsDisabled)
        }
        .swipeActions {
            Button(role: .destructive) { deleteProject(project) } label: { Label("Delete Project", systemImage: "trash") }
                .disabled(actionsDisabled)
        }
    }
}

/// One project's chats, with a button that starts a new chat inside it.
struct ProjectDetailView: View {
    let viewModel: SessionListViewModel
    let projectID: String
    let automatedVisibility: AutomatedSessionVisibility
    let actions: SessionListRowActions
    let selectedSessionID: String?
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let startChat: () -> Void

    var body: some View {
        let sessions = viewModel.visibleSessions(
            searchText: "",
            selectedProjectID: projectID,
            automatedVisibility: automatedVisibility,
            filter: .all
        )

        List {
            Button(action: startChat) {
                Label("New Chat in Project", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(viewModel.isViewingCachedData)
            .listRowBackground(Color.hxCanvas)

            if sessions.isEmpty {
                ContentUnavailableView("No chats in this project", systemImage: "bubble.left")
                    .listRowBackground(Color.hxCanvas)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(sessions) { session in
                    SessionInteractiveRow(
                        viewModel: viewModel,
                        session: session,
                        showsMessageCount: showsMessageCount,
                        showsWorkspace: showsWorkspace,
                        selectedSessionID: selectedSessionID,
                        actions: actions,
                        searchText: ""
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.hxCanvas)
        .navigationTitle(viewModel.projects.first { $0.projectId == projectID }?.displayName ?? String(localized: "Project"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
