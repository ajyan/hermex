import SwiftUI

struct MemoryView: View {
    let server: URL
    let onAPIError: (Error) -> Void

    @State private var viewModel: MemoryViewModel
    @State private var editingSection: MemorySection?

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: MemoryViewModel(server: server))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle(String(localized: "Memory"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadMemory() }
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
            .sheet(item: $editingSection) { section in
                MemoryEditSheet(
                    section: section,
                    initialContent: viewModel.content(for: section),
                    isSaving: viewModel.isSaving,
                    errorMessage: viewModel.actionErrorMessage
                ) { content in
                    let didSave = await viewModel.save(section: section, content: content)
                    if let lastError = viewModel.lastError {
                        onAPIError(lastError)
                    }
                    return didSave
                }
            }
            .task {
                await loadMemory()
            }
            .transcriptLinks()
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            ProgressView("Loading memory...")
        } else if let errorMessage = viewModel.errorMessage, !viewModel.hasLoaded {
            ContentUnavailableView {
                Label("Could Not Load Memory", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") {
                    Task { await loadMemory() }
                }
            }
        } else if !viewModel.hasLoaded {
            ProgressView("Loading memory...")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(MemorySection.allCases) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            MemorySectionHeader(
                                section: section,
                                modifiedAt: viewModel.modifiedAt(for: section),
                                isEditingDisabled: viewModel.isSaving
                            ) {
                                viewModel.clearActionError()
                                editingSection = section
                            }
                            .padding(.horizontal, 4)

                            MemorySectionContent(
                                section: section,
                                content: viewModel.content(for: section)
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hxCard()
                        }
                    }

                    if viewModel.showsProjectContext {
                        VStack(alignment: .leading, spacing: 8) {
                            ProjectContextSectionHeader(modifiedAt: viewModel.projectContextMtime)
                                .padding(.horizontal, 4)

                            MarkdownRenderer(content: viewModel.projectContextText ?? "")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .hxCard()

                            ProjectContextSectionFooter(
                                detail: viewModel.projectContextDetail,
                                isShadowed: viewModel.isProjectContextShadowed
                            )
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                            .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
            .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            .refreshable {
                await loadMemory()
            }
            // Wide tables fade into the card they sit on.
            .environment(\.markdownTableEdgeFadeColor, Color.hxSurface)
        }
    }

    private func loadMemory() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

private struct MemorySectionHeader: View {
    let section: MemorySection
    let modifiedAt: Date?
    let isEditingDisabled: Bool
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            MemoryHeaderTitle(title: section.title, systemImage: section.systemImage)
            Spacer()
            if let modifiedAt {
                Text("Modified \(modifiedAt, style: .relative) ago")
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
            }
            Button(action: onEdit) {
                Label("Edit \(section.title)", systemImage: "pencil")
                    .labelStyle(.iconOnly)
            }
            .disabled(isEditingDisabled)
            .buttonStyle(.borderless)
        }
    }
}

/// A Memory section's title: its icon on the `.recall` glow tile (DESIGN.md § The object
/// key) beside the rounded display voice in sentence case.
private struct MemoryHeaderTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(HermexPaper.recall.glow)
                .frame(width: 24, height: 24)
                .background(HermexPaper.recall.wash, in: RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous))
                .accessibilityHidden(true)

            Text(verbatim: title)
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Header for the read-only project-context document: no edit affordance — the
/// server has no write path for this section — so a lock icon marks it read-only.
private struct ProjectContextSectionHeader: View {
    let modifiedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            MemoryHeaderTitle(title: String(localized: "Project Context"), systemImage: "folder.badge.gearshape")
            Spacer()
            if let modifiedAt {
                Text("Modified \(modifiedAt, style: .relative) ago")
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Read-only"))
        }
    }
}

private struct ProjectContextSectionFooter: View {
    let detail: String?
    let isShadowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let detail {
                Text(verbatim: detail)
            }
            if isShadowed {
                Text("A workspace-local file is overriding the global project context.")
            }
        }
    }
}

private struct MemorySectionContent: View {
    let section: MemorySection
    let content: String

    var body: some View {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(section.emptyMessage)
                .foregroundStyle(.secondary)
                .italic()
        } else {
            MarkdownRenderer(content: content)
        }
    }
}

private struct MemoryEditSheet: View {
    let section: MemorySection
    let isSaving: Bool
    let errorMessage: String?
    let onSave: (String) async -> Bool

    @State private var content: String
    @Environment(\.dismiss) private var dismiss

    init(
        section: MemorySection,
        initialContent: String,
        isSaving: Bool,
        errorMessage: String?,
        onSave: @escaping (String) async -> Bool
    ) {
        self.section = section
        self.isSaving = isSaving
        self.errorMessage = errorMessage
        self.onSave = onSave
        _content = State(initialValue: initialContent)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $content)
                        .font(AppFont.mono(style: .body))
                        .frame(minHeight: 320)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isSaving)
                        .accessibilityLabel(section.title)
                } header: {
                    HXSectionHeader(title: section.title)
                        .textCase(nil)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(AppFont.footnote())
                            .foregroundStyle(.hxDanger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle(String(localized: "Edit \(section.title)"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await onSave(content) {
                                dismiss()
                            }
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .adaptiveFormPresentation()
    }
}

private extension MemorySection {
    var title: String {
        switch self {
        case .memory:
            return String(localized: "My Notes")
        case .user:
            return String(localized: "User Profile")
        case .soul:
            return String(localized: "Agent Soul")
        }
    }

    var emptyMessage: String {
        switch self {
        case .memory:
            return String(localized: "No notes yet.")
        case .user:
            return String(localized: "No profile yet.")
        case .soul:
            return String(localized: "No soul defined yet.")
        }
    }

    var systemImage: String {
        switch self {
        case .memory:
            return "brain"
        case .user:
            return "person.crop.circle"
        case .soul:
            return "sparkles"
        }
    }
}
