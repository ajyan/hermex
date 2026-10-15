import SwiftUI

/// One commitment: short name and cue, with a check circle that marks Done on tap and
/// offers the 2-minute version, Skip and Missed on long press. A day the row's source (Prep)
/// counted shows done with a "Prep" caption, and a tap opens the menu to override it.
struct GoalCommitmentRow: View {
    let row: GoalCommitmentProgress
    let day: GoalDay
    /// The server's date for `day`, to look up in the row's `sourceDays`.
    let date: String
    let tint: GoalTint
    let isPending: Bool
    let onSelect: (GoalStatus) -> Void

    var body: some View {
        let isDue = day == .today ? row.dueToday : row.dueYesterday
        let explicit = day == .today ? row.today : row.yesterday
        let fromSource = explicit == nil && row.sourceDays.contains(date)
        let shown: GoalStatus? = fromSource ? .done : explicit
        HStack(spacing: BrainStyle.m) {
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: GoalsCopy.shortTitle(row.action)).brainText(.rowTitle)
                if !row.cue.isEmpty { Text(verbatim: row.cue).brainText(.rowSubtitle).lineLimit(2) }
                if fromSource { Text(verbatim: "Prep").brainText(.meta) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isDue || shown != nil ? 1 : 0.55)
            Group {
                if fromSource {
                    Menu { menuItems(explicit: explicit) } label: { circle(shown) }
                } else {
                    Menu { menuItems(explicit: explicit) } label: { circle(shown) } primaryAction: {
                        // Tap checks in as done; tapping a checked circle clears it.
                        onSelect(explicit == nil ? .done : .clear)
                    }
                }
            }
            .disabled(isPending)
            .accessibilityLabel(Text(verbatim: "\(GoalsCopy.shortTitle(row.action)), \(GoalDetailCopy.spoken(shown))\(fromSource ? ", counted by Prep" : "")"))
            .accessibilityHint(Text(verbatim: fromSource
                ? "Double-tap for options."
                : explicit == nil
                    ? "Double-tap to mark done. Hold for more options."
                    : "Double-tap to clear. Hold for more options."))
        }
        .padding(.vertical, BrainStyle.s)
        .frame(minHeight: BrainStyle.minTapTarget)
    }

    private func circle(_ shown: GoalStatus?) -> some View {
        GoalCheckCircle(status: shown, tint: tint, isPending: isPending)
    }

    @ViewBuilder
    private func menuItems(explicit: GoalStatus?) -> some View {
        ForEach(GoalDetailCopy.statusOptions, id: \.value) { option in
            let status = GoalStatus(rawValue: option.value) ?? .done
            Button {
                onSelect(status)
            } label: {
                Label(GoalDetailCopy.menuTitle(status, row: row), systemImage: GoalDetailCopy.symbol(status))
            }
            .disabled(status == .skip && GoalDetailCopy.skipDisabled(row, selected: explicit))
        }
        if explicit != nil {
            Divider()
            Button(role: .destructive) { onSelect(.clear) } label: {
                Label("Clear check-in", systemImage: "arrow.uturn.backward")
            }
        }
    }
}
