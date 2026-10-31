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
/// glow chips; settled, one chip per kind of tool with its count. Pure so the rules are
/// unit-testable.
enum ToolActivityPresentation {
    /// Chips a live group shows before the rest fold into a `+N` chip.
    static let chipLimit = 4
    /// Longest chip label before it's cut with an ellipsis.
    static let chipLabelLimit = 24

    /// One settled chip: how many calls of a kind ran, and how many of them failed.
    struct KindCount: Equatable, Identifiable {
        let kind: ToolCallSummaryFormatter.Kind
        let symbol: String
        var count: Int
        var failures: Int

        var id: String { symbol + "\(kind)" }
        var paper: HermexPaper { .forTool(kind) }
        var label: String { ToolActivityPresentation.countLabel(kind, count) }
    }

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

    /// A settled group's chips: one per kind, in the order each kind first ran.
    static func kindCounts(_ entries: [ToolCallLogEntry]) -> [KindCount] {
        var counts: [KindCount] = []
        for entry in entries {
            let failed = entry.row.isFailure ? 1 : 0
            if let index = counts.firstIndex(where: { $0.kind == entry.row.kind }) {
                counts[index].count += 1
                counts[index].failures += failed
            } else {
                counts.append(KindCount(kind: entry.row.kind, symbol: entry.row.icon, count: 1, failures: failed))
            }
        }
        return counts
    }

    static func countLabel(_ kind: ToolCallSummaryFormatter.Kind, _ count: Int) -> String {
        let one = count == 1
        switch kind {
        case .shell: return one ? String(localized: "1 command") : String(localized: "\(count) commands")
        case .read: return one ? String(localized: "1 read") : String(localized: "\(count) reads")
        case .write: return one ? String(localized: "1 edit") : String(localized: "\(count) edits")
        case .search: return one ? String(localized: "1 search") : String(localized: "\(count) searches")
        case .web: return one ? String(localized: "1 web lookup") : String(localized: "\(count) web lookups")
        case .list: return one ? String(localized: "1 listing") : String(localized: "\(count) listings")
        case .skill: return one ? String(localized: "1 skill") : String(localized: "\(count) skills")
        case .memory: return one ? String(localized: "1 memory") : String(localized: "\(count) memories")
        case .delegate: return one ? String(localized: "1 delegation") : String(localized: "\(count) delegations")
        case .unknown: return one ? String(localized: "1 tool call") : String(localized: "\(count) tool calls")
        }
    }
}

/// A turn's tool calls. Collapsed, a live group shows its newest calls as glow chips and a
/// settled one shows a chip per kind of tool; tapping either opens the full log.
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
                    .transition(HXMotion.disclosureTransition(reduceMotion: reduceMotion))
                } else if isLive {
                    chipRow(entries)
                } else {
                    kindCountRow(entries)
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
        return HXMotion.freshRowTransition(isUserRow: false, reduceMotion: reduceMotion)
    }

    private func toggleExpansion() {
        chatDisclosureToggled()
        withAnimation(HXMotion.disclosure(reduceMotion: reduceMotion)) {
            userToggledExpansion = !isExpanded
        }
    }

    private func chipRow(_ entries: [ToolCallLogEntry]) -> some View {
        let chips = ToolActivityPresentation.chips(entries)
        return disclosureButton(
            label: entries.map(\.row.accessibilityLabel).joined(separator: "; ")
        ) {
            if chips.hiddenCount > 0 {
                HXChip(paper: .tool, label: "+\(chips.hiddenCount)")
            }
            ForEach(chips.shown) { entry in
                ToolCallChip(row: entry.row)
                    .transition(newestChipTransition)
            }
        }
    }

    private func kindCountRow(_ entries: [ToolCallLogEntry]) -> some View {
        let counts = ToolActivityPresentation.kindCounts(entries)
        let spoken = counts.map { count in
            count.failures > 0 ? String(localized: "\(count.label), \(count.failures) failed") : count.label
        }
        return disclosureButton(label: spoken.joined(separator: ", ")) {
            ForEach(counts) { count in
                HXChip(paper: count.paper, symbol: count.symbol, label: count.label) {
                    if count.failures > 0 {
                        Image(systemName: "xmark")
                            .font(AppFont.caption2(weight: .bold))
                            .foregroundStyle(Color.hxDanger)
                    }
                }
            }
        }
    }

    /// A row of chips that opens the full log, at least a 44 pt target.
    private func disclosureButton<Chips: View>(
        label: String,
        @ViewBuilder chips: () -> Chips
    ) -> some View {
        Button(action: toggleExpansion) {
            FlowRow(spacing: 5) { chips() }
                .padding(.vertical, 4)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .forcedLeftToRight()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Text("Collapsed"))
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

/// One live tool call as a glow chip in its kind's paper: icon, target, and a mark while it
/// runs or after it fails.
struct ToolCallChip: View {
    let row: ToolCallLogRow

    var body: some View {
        HXChip(paper: .forTool(row.kind), symbol: row.icon, label: ToolActivityPresentation.chipLabel(row)) {
            switch row.status {
            case .running:
                Image(systemName: "ellipsis")
                    .font(AppFont.caption2(weight: .bold))
            case .failure:
                Image(systemName: "xmark")
                    .font(AppFont.caption2(weight: .bold))
                    .foregroundStyle(Color.hxDanger)
            case .success, .interrupted:
                EmptyView()
            }
        }
    }
}
