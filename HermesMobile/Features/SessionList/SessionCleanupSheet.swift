import SwiftUI
import Observation

/// The "Clean up old conversations" sheet.
///
/// Two stages:
/// - **Review** — shows auto-archive threads (archived directly) and stale
///   coding projects (each needs a checkbox so work is verified first).
/// - **Result** — after the run, shows how many were archived + Undo.
struct SessionCleanupSheet: View {
    @State var viewModel: SessionCleanupViewModel
    let idleDays: Int
    let onCompleted: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Clean up old chats")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onCompleted()
                            onDismiss()
                        }
                        .disabled(viewModel.phase == .running)
                    }
                }
        }
        .onAppear {
            Task { await viewModel.fetchAndClassify() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle, .loading:
            ProgressView("Loading conversations…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load conversations", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            reviewView
        case .running:
            VStack(spacing: 12) {
                ProgressView()
                Text("Archiving…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let archived, let failed):
            resultView(archived: archived, failed: failed)
        }
    }

    // MARK: - Review

    private var reviewView: some View {
        VStack(spacing: 0) {
            List {
                if viewModel.autoCandidates.isEmpty {
                    Text("No plain conversations are idle enough to auto-archive.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(viewModel.autoCandidates) { session in
                            row(for: session, note: "auto-archive")
                        }
                    } header: {
                        Text("Auto-archive (\(viewModel.autoCandidates.count))")
                    }
                }

                if !viewModel.projectCandidates.isEmpty {
                    Section {
                        ForEach(viewModel.projectCandidates) { session in
                            projectRow(for: session)
                        }
                    } header: {
                        Text("Coding projects (\(viewModel.projectCandidates.count))")
                    } footer: {
                        Text("Check a project only after you've verified its work is done.")
                    }
                }
            }
            .listStyle(.insetGrouped)

            if viewModel.projectCandidates.isEmpty && viewModel.autoCandidates.isEmpty {
                Text("Nothing is idle enough to clean up. 🎉")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            } else {
                Button {
                    Task { await viewModel.run() }
                } label: {
                    Text("Archive \(viewModel.totalToArchive) conversation\(viewModel.totalToArchive == 1 ? "" : "s")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.totalToArchive == 0)
                .padding()
            }
        }
    }

    private func row(for session: SessionSummary, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(SessionRowView.displayTitle(for: session))
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 8) {
                if let last = session.lastMessageAt ?? session.updatedAt {
                    Text(SessionRelativeDateFormatter.shared.localizedString(for: Date(timeIntervalSince1970: last), relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func projectRow(for session: SessionSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: confirmedProjectID(session) ? "checkmark.square.fill" : "square")
                .foregroundStyle(confirmedProjectID(session) ? Color.accentColor : .secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 3) {
                Text(SessionRowView.displayTitle(for: session))
                    .font(.body)
                    .lineLimit(1)
                if let last = session.lastMessageAt ?? session.updatedAt {
                    Text(SessionRelativeDateFormatter.shared.localizedString(for: Date(timeIntervalSince1970: last), relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggle(session)
        }
    }

    private func confirmedProjectID(_ session: SessionSummary) -> Bool {
        viewModel.confirmedProjectIDs.contains(session.id)
    }

    private func toggle(_ session: SessionSummary) {
        if viewModel.confirmedProjectIDs.contains(session.id) {
            viewModel.confirmedProjectIDs.remove(session.id)
        } else {
            viewModel.confirmedProjectIDs.insert(session.id)
        }
    }

    // MARK: - Result

    private func resultView(archived: Int, failed: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(failed == 0 ? Color.green : .orange)
            Text("Cleaned up")
                .font(.title3.weight(.semibold))
            Text(summaryText(archived: archived, failed: failed))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                if !viewModel.lastArchivedIDs.isEmpty {
                    Button("Undo") {
                        Task { await viewModel.undo() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                Button("Done") {
                    onCompleted()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryText(archived: Int, failed: Int) -> String {
        var parts: [String] = []
        if archived > 0 {
            parts.append("\(archived) conversation\(archived == 1 ? "" : "s") archived")
        } else {
            parts.append("Nothing archived")
        }
        if failed > 0 {
            parts.append("\(failed) failed")
        }
        return parts.joined(separator: " · ")
    }
}
