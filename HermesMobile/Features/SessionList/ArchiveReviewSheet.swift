import SwiftUI

/// Idle chats the keep model held back from auto-archive. Each one can be
/// summarized then archived, archived as is, or kept. Every choice trains the
/// model; failures show on the row and leave the chat where it is.
struct ArchiveReviewSheet: View {
    let viewModel: SessionListViewModel
    /// Called after a chat leaves the list, so the shell can close it if open.
    let didArchive: (SessionSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var errorsBySessionID: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.archiveReviewCandidates) { session in
                        row(session)
                    }
                } footer: {
                    Text("Summarize & Archive asks Atlas to save a digest to your second brain first. Your choices teach Atlas which chats you keep.")
                }
            }
            .navigationTitle(Text("Review Before Archiving"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: viewModel.archiveReviewCandidates.isEmpty) { _, isEmpty in
                if isEmpty { dismiss() }
            }
        }
    }

    private func row(_ session: SessionSummary) -> some View {
        let sessionID = session.sessionId ?? ""
        let isBusy = viewModel.isMutating(session)
        return VStack(alignment: .leading, spacing: 8) {
            Text(SessionRowView.displayTitle(for: session))
                .font(.body.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 6) {
                if let last = AutoArchivePolicy.lastActivity(of: session) {
                    Text(Date(timeIntervalSince1970: last), format: .relative(presentation: .named))
                }
                if let count = session.messageCount {
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text("\(count) messages")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = errorsBySessionID[sessionID] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.hxDanger)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await summarize(session) }
                } label: {
                    if viewModel.isSummarizing(session) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("Summarizing"))
                    } else {
                        Text("Summarize & Archive")
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Archive") {
                    Task { await archive(session) }
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button("Keep") {
                    viewModel.keepFromReview(session)
                }
                .buttonStyle(.borderless)
            }
            .font(.subheadline)
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
    }

    private func summarize(_ session: SessionSummary) async {
        let sessionID = session.sessionId ?? ""
        errorsBySessionID[sessionID] = nil
        if let failure = await viewModel.summarizeAndArchive(session, modelContext: modelContext) {
            errorsBySessionID[sessionID] = failure
        } else if !viewModel.sessions.contains(where: { $0.sessionId == session.sessionId }) {
            didArchive(session)
        }
    }

    private func archive(_ session: SessionSummary) async {
        let sessionID = session.sessionId ?? ""
        errorsBySessionID[sessionID] = nil
        if let failure = await viewModel.archiveFromReview(session, modelContext: modelContext) {
            errorsBySessionID[sessionID] = failure
        } else if !viewModel.sessions.contains(where: { $0.sessionId == session.sessionId }) {
            didArchive(session)
        }
    }
}
