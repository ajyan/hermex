import SwiftUI

/// Turn-end "File changes" recap card shown under the latest assistant turn for git
/// workspaces (issue #316, Slice D, surface B). The per-file list is derived from the
/// turn's tool-call metadata and joined to `git/status` for counts/chips. The card is
/// collapsible (default expanded); the header "Open diff" opens the turn's files in the
/// diff surface and each file row opens that surface at the file. The host owns the
/// actual sheet presentation.
struct GitTurnChangesCard: View {
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true
    @State private var isExpanded = true

    let summary: TurnFileChangeSummary
    /// Open the diff sheet for every changed file in the turn (header "Open diff").
    let onOpenAll: () -> Void
    /// Open a single file's diff (per-row tap). Only called for rows with a status match.
    let onOpenFile: (GitFile) -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous) }
    private var dividerColor: Color { Color.hxSeparator }
    private var showsTotals: Bool { summary.totalAdditions > 0 || summary.totalDeletions > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                divider
                ForEach(Array(summary.changes.enumerated()), id: \.element.id) { index, change in
                    fileRow(change)
                    if index != summary.changes.count - 1 {
                        divider.padding(.leading, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .hxCard(cornerRadius: HXRadius.md)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Changed files are `.file` objects: the icon sits on a log-sized glow tile.
            Image(systemName: "square.and.pencil")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(HermexPaper.file.glow)
                .frame(width: 20, height: 20)
                .background(HermexPaper.file.wash, in: RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous))
                .accessibilityHidden(true)

            Text("File changes")
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextSecondary)

            if showsTotals {
                DiffCountsLabel(additions: summary.totalAdditions, deletions: summary.totalDeletions)
            }

            Spacer(minLength: 8)

            if !summary.diffFiles.isEmpty {
                headerButton(systemImage: "arrow.up.right", accessibility: "Open diff") {
                    HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
                    onOpenAll()
                }
            }

            headerButton(
                systemImage: "chevron.down",
                accessibility: isExpanded
                    ? String(localized: "Collapse file changes")
                    : String(localized: "Expand file changes"),
                rotation: isExpanded ? 0 : -90
            ) {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    private func headerButton(
        systemImage: String,
        accessibility: String,
        rotation: Double = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private func fileRow(_ change: TurnFileChange) -> some View {
        Button {
            guard let file = change.gitFile else { return }
            HapticButtonHaptics.tap(isEnabled: isHapticsEnabled)
            onOpenFile(file)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(change.gitFile?.displayPath ?? change.path)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if change.additions > 0 || change.deletions > 0 {
                    DiffCountsLabel(additions: change.additions, deletions: change.deletions)
                }

                GitStatusChip(kind: change.changeKind)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(change.gitFile == nil)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(dividerColor).frame(height: 0.5)
    }
}
