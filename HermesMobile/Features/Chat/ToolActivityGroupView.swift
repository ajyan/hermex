import SwiftUI

/// When a tool group's newest row fades in. Only a live group animates, as a
/// new call replaces its newest row; history, reloads, and the rows a
/// reattached stream replays draw in place, and Reduce Motion turns it off.
/// A group that appears whole (its first call) draws in place too, because
/// SwiftUI runs a transition only on the view it inserts, not its children.
enum ToolActivityEntrance {
    static func animatesNewestRow(isLive: Bool, isReplaying: Bool, reduceMotion: Bool) -> Bool {
        isLive && !isReplaying && !reduceMotion
    }
}

/// How a collapsed tool group reads (DESIGN.md § Components): live, its newest calls as
/// paper chips; settled, one summary line. Pure so the rules are unit-testable.
enum ToolActivityPresentation {
    /// Chips a live group shows before the rest fold into a `+N` chip.
    static let chipLimit = 4
    /// Longest chip label before it's cut with an ellipsis.
    static let chipLabelLimit = 24

    /// The newest `chipLimit` entries, oldest first, and how many earlier ones `+N` stands for.
    static func chips(_ entries: [ToolCallLogEntry]) -> (shown: [ToolCallLogEntry], hiddenCount: Int) {
        let shown = Array(entries.suffix(chipLimit))
        return (shown, entries.count - shown.count)
    }

    /// A chip's words: the call's target (file, command, query), else its verb.
    static func chipLabel(_ row: ToolCallLogRow) -> String {
        let label = row.detail ?? row.summary
        guard label.count > chipLabelLimit else { return label }
        return String(label.prefix(chipLabelLimit - 1)) + "…"
    }

    /// The settled line: the call itself when there's one, else how many steps ran.
    static func summaryTitle(_ entries: [ToolCallLogEntry]) -> String {
        if entries.count == 1, let row = entries.first?.row {
            return [row.summary, row.detail].compactMap { $0 }.joined(separator: " ")
        }
        return String(localized: "\(entries.count) steps")
    }

    /// Up to three distinct papers, in the order their kinds first ran.
    static func summaryPapers(_ entries: [ToolCallLogEntry]) -> [HermexPaper] {
        var papers: [HermexPaper] = []
        for entry in entries {
            let paper = HermexPaper.forTool(entry.row.kind)
            if !papers.contains(paper) { papers.append(paper) }
            if papers.count == 3 { break }
        }
        return papers
    }
}

/// A turn's tool calls. Collapsed, a live group shows its newest calls as paper chips and
/// a settled one folds to a summary line; either opens to the full log, one row per call.
struct ToolActivityGroupView: View {
    let group: ToolCallGroup
    var isLive = false
    /// True while a reattached stream replays calls the transcript missed.
    var isReplaying = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatDisclosureToggled) private var chatDisclosureToggled
    @AppStorage(ChatTranscriptDisplaySettings.toolCardsStartExpandedKey) private var startsExpanded = false
    @State private var userToggledExpansion: Bool?

    /// Whether the full log is shown. Follows "Expand Tools by Default"
    /// until the user taps the group.
    private var isExpanded: Bool {
        ChatTranscriptDisplaySettings.isCardExpanded(
            userToggled: userToggledExpansion,
            startsExpanded: startsExpanded
        )
    }

    @ViewBuilder
    var body: some View {
        let entries = ToolCallSummaryFormatter.entries(for: group.toolCalls, isLive: isLive)

        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if isExpanded {
                    collapseToggle
                    ForEach(entries) { entry in
                        ToolCallLogRowView(entry: entry)
                    }
                    .transition(ChatMotion.disclosureTransition(reduceMotion: reduceMotion))
                } else if isLive {
                    chipRow(entries)
                } else {
                    summaryLine(entries)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    /// The live chips' one-shot entrance: a 0.22 s fade on insertion only.
    private var newestChipTransition: AnyTransition {
        guard ToolActivityEntrance.animatesNewestRow(
            isLive: isLive,
            isReplaying: isReplaying,
            reduceMotion: reduceMotion
        ) else {
            return .identity
        }
        return ChatMotion.freshRowTransition(isUserRow: false, reduceMotion: reduceMotion)
    }

    private func toggleExpansion() {
        chatDisclosureToggled()
        withAnimation(ChatMotion.disclosure(reduceMotion: reduceMotion)) {
            userToggledExpansion = !isExpanded
        }
    }

    private func chipRow(_ entries: [ToolCallLogEntry]) -> some View {
        let chips = ToolActivityPresentation.chips(entries)
        return Button(action: toggleExpansion) {
            FlowRow(spacing: 5) {
                if chips.hiddenCount > 0 {
                    Text(verbatim: "+\(chips.hiddenCount)")
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.hxSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.hxSeparator, lineWidth: 0.5))
                }
                ForEach(chips.shown) { entry in
                    ToolCallChip(row: entry.row)
                        .transition(newestChipTransition)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .forcedLeftToRight()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entries.map(\.row.accessibilityLabel).joined(separator: "; "))
        .accessibilityHint(Text("Shows every tool call"))
    }

    private func summaryLine(_ entries: [ToolCallLogEntry]) -> some View {
        let failures = entries.filter(\.row.isFailure).count
        return Button(action: toggleExpansion) {
            HStack(spacing: 6) {
                HStack(spacing: -3) {
                    ForEach(Array(ToolActivityPresentation.summaryPapers(entries).enumerated()), id: \.offset) { _, paper in
                        Circle()
                            .fill(paper.paper)
                            .overlay(Circle().strokeBorder(paper.ink.opacity(0.35), lineWidth: 0.5))
                            .frame(width: 9, height: 9)
                    }
                }
                .frame(width: 20)

                Text(verbatim: ToolActivityPresentation.summaryTitle(entries))
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(Color.hxTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if failures > 0 {
                    Text("\(failures) failed")
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(Color.hxDanger)
                }

                Image(systemName: "chevron.right")
                    .font(AppFont.caption2(weight: .semibold))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(minHeight: TranscriptLogRowMetrics.minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Shows every tool call"))
    }

    private var collapseToggle: some View {
        Button(action: toggleExpansion) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 18)

                Text("Show fewer tool calls")
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(minHeight: TranscriptLogRowMetrics.minimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One tool call as a capsule in its kind's paper: icon, target, and a mark while it runs or
/// after it fails.
struct ToolCallChip: View {
    let row: ToolCallLogRow

    var body: some View {
        let paper = HermexPaper.forTool(row.kind)
        HStack(spacing: 5) {
            Image(systemName: row.icon)
                .font(AppFont.caption2(weight: .semibold))
            Text(verbatim: ToolActivityPresentation.chipLabel(row))
                .font(AppFont.caption(weight: .medium))
                .lineLimit(1)
            switch row.status {
            case .running:
                Image(systemName: "ellipsis")
                    .font(AppFont.caption2(weight: .bold))
                    .foregroundStyle(paper.secondaryInk)
            case .failure:
                Image(systemName: "xmark")
                    .font(AppFont.caption2(weight: .bold))
                    .foregroundStyle(Color.hxDanger)
            case .success, .interrupted:
                EmptyView()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(paper.ink)
        .background(paper.paper, in: Capsule())
        .environment(\.colorScheme, .light)
    }
}
