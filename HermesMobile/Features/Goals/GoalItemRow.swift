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

/// What an item row's controls do, wired to its screen's model (`itemActions`).
struct GoalItemActions {
    /// Counts one more with an optional note; answers whether the server took it.
    let add: (String?) async -> Bool
    let removeLast: () -> Void
    /// Takes back the +1 just counted.
    let undo: () -> Void
    /// Ends the Add note · Undo offer and returns the day of the +1 it was for; nil once it passed.
    let takeRecent: () -> String?
    /// Puts a note on the item counted on that day.
    let note: (_ date: String, _ note: String) async -> GoalItemNoteOutcome
}

extension GoalDetailViewModel {
    func itemActions(_ id: String) -> GoalItemActions {
        GoalItemActions(
            add: { await self.addItem(commitment: id, note: $0) },
            removeLast: { Task { await self.removeLastItem(commitment: id) } },
            undo: { Task { await self.undoItem(commitment: id) } },
            takeRecent: { self.recentItems.take(.commitment(id)) },
            note: { await self.noteItem(commitment: id, date: $0, note: $1) }
        )
    }
}

extension GoalsHomeViewModel {
    func itemActions(slug: String, commitment id: String) -> GoalItemActions {
        GoalItemActions(
            add: { await self.addItem(slug: slug, commitment: id, note: $0) },
            removeLast: { Task { await self.removeLastItem(slug: slug, commitment: id) } },
            undo: { Task { await self.undoItem(slug: slug, commitment: id) } },
            takeRecent: { self.recentItems.take(Self.key(slug, .commitment(id))) },
            note: { await self.noteItem(slug: slug, commitment: id, date: $0, note: $1) }
        )
    }

    /// The day of the +1 just counted on this row while it offers Add note and Undo.
    func recentItemDate(slug: String, commitment id: String) -> String? {
        recentItems.date(for: Self.key(slug, .commitment(id)))
    }
}

/// An item commitment: its week as pips and latest notes, with a +1 chip that counts one at once
/// and then offers Add note and Undo for a few seconds (`GoalItemFollowUp`); on long press,
/// "Remove last".
struct GoalItemRow: View {
    let row: GoalCommitmentProgress
    let tint: GoalTint
    let isPending: Bool
    /// Short two weeks running (the server's never-miss-twice flag): shows the chip.
    var atRisk = false
    /// The day of the +1 just counted while Add note and Undo are offered; nil otherwise.
    let recentDate: String?
    let actions: GoalItemActions

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
                .accessibilityAction(named: Text(verbatim: "Remove last")) {
                    if !row.items.isEmpty { actions.removeLast() }
                }
                Button {
                    Task { _ = await actions.add(nil) }
                } label: {
                    HXChip(paper: tint.paper, label: "+1")
                        .frame(minWidth: BrainStyle.minTapTarget, minHeight: BrainStyle.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPending)
                .accessibilityLabel(Text(verbatim: "Add \(row.action)"))
                .accessibilityHint(Text(verbatim: "Counts one now. Add a note or undo it right after."))
            }
            GoalItemFollowUp(label: "Counted", tint: tint, isPending: isPending, recentDate: recentDate,
                             actions: actions)
        }
        .padding(.vertical, BrainStyle.s)
        .frame(minHeight: BrainStyle.minTapTarget)
        .contextMenu {
            Button { actions.removeLast() } label: { Label("Remove last", systemImage: "arrow.uturn.backward") }
                .disabled(row.items.isEmpty || isPending)
        }
    }
}

/// What follows a +1 on an item row: "Counted · Add note · Undo" while the offer lasts, then, after
/// Add note, an inline note field. Saving it notes the item just counted (`GoalItemActions.note`); if
/// the save fails the field comes back with the typed note, and if the item came off without its
/// noted copy landing, saving again counts it anew with the note. Empty when there is nothing to offer.
struct GoalItemFollowUp: View {
    /// Leads the offer: "Counted", or "Outreach counted" off the row.
    let label: String
    let tint: GoalTint
    let isPending: Bool
    let recentDate: String?
    let actions: GoalItemActions

    /// The day of the item the field notes; nil once it is a plain +1 with a note.
    @State private var noteDate: String?
    @State private var isNoting = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isNoting {
                noteField.transition(.opacity)
            } else if recentDate != nil {
                offer.transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: recentDate != nil)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isNoting)
    }

    private var offer: some View {
        HStack(spacing: BrainStyle.s) {
            Text(verbatim: label).brainText(.meta)
            Text(verbatim: "·").brainText(.meta).accessibilityHidden(true)
            link("Add note") {
                guard let date = actions.takeRecent() else { return }
                noteDate = date
                isNoting = true
            }
            Text(verbatim: "·").brainText(.meta).accessibilityHidden(true)
            link("Undo", action: actions.undo)
        }
        .disabled(isPending)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(BrainStyle.rowSubtitle.weight(.semibold))
                .foregroundStyle(tint.fill)
                .frame(minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var noteField: some View {
        HStack(spacing: BrainStyle.s) {
            TextField("Note (optional)", text: $note)
                .font(BrainStyle.rowSubtitle)
                .focused($noteFocused)
                .onAppear { noteFocused = true }
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, BrainStyle.m)
                .frame(minHeight: BrainStyle.minTapTarget - 8)
                .background(Color.hxSeparator.opacity(0.45), in: RoundedRectangle(cornerRadius: HXRadius.sm))
            Button(action: save) {
                Text(verbatim: noteDate == nil ? "Add" : "Save")
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
        .onChange(of: noteFocused) { _, focused in
            // Leaving an empty field closes it; the item stays as it was counted.
            if !focused, isNoting, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { close() }
        }
    }

    private func close() {
        isNoting = false
        noteDate = nil
        note = ""
    }

    /// Notes the item just counted, or counts a new one with the note once that item came off.
    private func save() {
        let typed = note
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = noteDate
        guard !trimmed.isEmpty else { return close() }
        note = ""
        isNoting = false
        noteFocused = false
        Task {
            if let date {
                switch await actions.note(date, trimmed) {
                case .saved: noteDate = nil; return
                case .unchanged: noteDate = date
                case .removed: noteDate = nil
                }
            } else if await actions.add(trimmed) {
                return
            }
            if note.isEmpty { note = typed }
            isNoting = true
        }
    }
}
