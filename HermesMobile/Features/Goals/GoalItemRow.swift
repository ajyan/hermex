import SwiftUI

/// Words for an item commitment (applications, outreach): counted by +1, not checked per day.
enum GoalItemCopy {
    static func countLine(_ row: GoalCommitmentProgress) -> String {
        "\(row.done) of \(row.target) this week"
    }

    /// The three latest notes, newest first; nil when no item has one.
    static func noteLine(_ row: GoalCommitmentProgress) -> String? {
        let notes = row.items.compactMap { $0.note?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return notes.isEmpty ? nil : notes.suffix(3).reversed().joined(separator: " · ")
    }

    static func spoken(_ row: GoalCommitmentProgress) -> String {
        "\(row.action), \(countLine(row))"
    }
}

/// An item commitment: its week count and latest notes, with a +1 chip that opens an inline
/// note field (Return or Add counts it) and, on long press, "Remove last". `onAdd` answers
/// whether the server took the item; when it didn't, the field reopens with the typed note.
struct GoalItemRow: View {
    let row: GoalCommitmentProgress
    let tint: GoalTint
    let isPending: Bool
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
                    Text(verbatim: GoalItemCopy.countLine(row)).brainText(.rowSubtitle).monospacedDigit()
                    if let notes = GoalItemCopy.noteLine(row) {
                        Text(verbatim: notes).brainText(.meta).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: GoalItemCopy.spoken(row)))
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
