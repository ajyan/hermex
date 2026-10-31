import SwiftUI

/// Words for an item commitment (applications, outreach): counted by +1, not checked per day.
enum GoalItemCopy {
    /// The three latest notes, newest first; nil when no item has one.
    static func noteLine(_ row: GoalCommitmentProgress) -> String? {
        let notes = row.items.compactMap { $0.note?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return notes.isEmpty ? nil : notes.suffix(3).reversed().joined(separator: " · ")
    }

    /// "Outreach: 3 of 5 this week".
    static func spoken(_ row: GoalCommitmentProgress) -> String {
        GoalPips(row, name: GoalsCopy.shortTitle(row.action)).spoken
    }
}

/// An item commitment: its week as pips and latest notes, with a +1 chip that opens an inline
/// note field (Return or Add counts it) and, on long press, "Remove last". `onAdd` answers
/// whether the server took the item; when it didn't, the field reopens with the typed note.
struct GoalItemRow: View {
    let row: GoalCommitmentProgress
    let tint: GoalTint
    let isPending: Bool
    /// Short two weeks running (the server's never-miss-twice flag): shows the chip.
    var atRisk = false
    let onAdd: (String?) async -> Bool
    let onRemoveLast: () -> Void

    @State private var isAdding = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HStack(spacing: BrainStyle.m) {
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    Text(verbatim: row.action).brainText(.rowTitle)
                    let pips = GoalPips(row, name: GoalsCopy.shortTitle(row.action))
                    HStack(spacing: BrainStyle.s) {
                        GoalPipRow(pips: pips, ink: tint.fill)
                        Text(verbatim: pips.count).brainText(.meta).monospacedDigit().lineLimit(1)
                    }
                    if atRisk { GoalAtRiskChip(row: row, paper: tint.paper) }
                    if let notes = GoalItemCopy.noteLine(row) {
                        Text(verbatim: notes).brainText(.meta).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: atRisk
                    ? "\(GoalItemCopy.spoken(row)). \(GoalPips.atRiskSpoken(row))"
                    : GoalItemCopy.spoken(row)))
                .accessibilityAction(named: Text(verbatim: "Remove last")) { if !row.items.isEmpty { onRemoveLast() } }
                Button {
                    isAdding.toggle()
                } label: {
                    HXChip(paper: tint.paper, label: "+1")
                        .frame(minWidth: BrainStyle.minTapTarget, minHeight: BrainStyle.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPending)
                .accessibilityLabel(Text(verbatim: "Add \(row.action)"))
                .accessibilityHint(Text(verbatim: "Opens a note field."))
            }
            if isAdding {
                HStack(spacing: BrainStyle.s) {
                    TextField("Note (optional)", text: $note)
                        .font(BrainStyle.rowSubtitle)
                        .focused($noteFocused)
                        .onAppear { noteFocused = true }
                        .submitLabel(.done)
                        .onSubmit(add)
                        .padding(.horizontal, BrainStyle.m)
                        .frame(minHeight: BrainStyle.minTapTarget - 8)
                        .background(Color.hxSeparator.opacity(0.45), in: RoundedRectangle(cornerRadius: HXRadius.sm))
                    Button(action: add) {
                        Text(verbatim: "Add")
                            .font(BrainStyle.rowSubtitle.weight(.semibold))
                            .foregroundStyle(tint.on)
                            .padding(.horizontal, BrainStyle.l)
                            .frame(minHeight: BrainStyle.minTapTarget - 8)
                            .background(tint.fill, in: Capsule())
                            .frame(minHeight: BrainStyle.minTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isPending)
                }
            }
        }
        .padding(.vertical, BrainStyle.s)
        .frame(minHeight: BrainStyle.minTapTarget)
        .contextMenu {
            Button { onRemoveLast() } label: { Label("Remove last", systemImage: "arrow.uturn.backward") }
                .disabled(row.items.isEmpty || isPending)
        }
    }

    /// Counts the item with the typed note, or none when the field is blank. The count shows at
    /// once; if the save fails, the note comes back in a reopened field (unless he's typing anew).
    private func add() {
        let typed = note
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        note = ""
        isAdding = false
        noteFocused = false
        Task {
            guard await !onAdd(trimmed.isEmpty ? nil : trimmed) else { return }
            if note.isEmpty { note = typed }
            isAdding = true
        }
    }
}
