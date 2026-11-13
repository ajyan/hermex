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

/// An item commitment: its week as pips and latest notes, with a +1 chip that counts one at once.
/// For a few seconds after, Note and Undo take the +1's place (same height, so nothing below moves);
/// Note opens an inline field under the row. On long press, "Remove last".
struct GoalItemRow: View {
    let row: GoalCommitmentProgress
    let tint: GoalTint
    let isPending: Bool
    /// Short two weeks running (the server's never-miss-twice flag): shows the chip.
    var atRisk = false
    /// The day of the +1 just counted while Add note and Undo are offered; nil otherwise.
    let recentDate: String?
    let actions: GoalItemActions

    @State private var draft: GoalItemNoteDraft?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                Group {
                    if recentDate != nil, draft == nil {
                        GoalItemOffer(isPending: isPending, actions: actions, compact: true) { draft = $0 }
                    } else {
                        plusOne
                    }
                }
                .transition(.opacity)
            }
            if draft != nil {
                GoalItemNoteField(draft: $draft, isPending: isPending, actions: actions)
                    .transition(.opacity)
            }
        }
        .animation(HXMotion.quickState(reduceMotion: reduceMotion), value: recentDate != nil)
        .animation(HXMotion.disclosure(reduceMotion: reduceMotion), value: draft != nil)
        .announcesOffer(recentDate != nil, label: "Counted")
        .padding(.vertical, BrainStyle.s)
        .frame(minHeight: BrainStyle.minTapTarget)
        .contextMenu {
            Button { actions.removeLast() } label: { Label("Remove last", systemImage: "arrow.uturn.backward") }
                .disabled(row.items.isEmpty || isPending)
        }
    }

    private var plusOne: some View {
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
}

/// The note being written for a +1: the day of the item it notes (nil once that item came off, so
/// saving counts a new one with the note), and the words so far.
struct GoalItemNoteDraft: Equatable {
    var date: String?
    var text = ""
}

/// Add note and Undo for the +1 just counted, each a 44 pt link: Nous blue on the app's own
/// surfaces, the card's glow on a Brief card (`\.hxPaper`). `compact` drops the leading label for
/// the +1's own slot; `onNote` opens the field for the item's day.
private struct GoalItemOffer: View {
    var label: String?
    let isPending: Bool
    let actions: GoalItemActions
    var compact = false
    let onNote: (GoalItemNoteDraft) -> Void
    @Environment(\.hxPaper) private var paper

    var body: some View {
        HStack(spacing: BrainStyle.s) {
            if let label {
                Text(verbatim: label).brainText(.meta)
                Text(verbatim: "·").brainText(.meta).accessibilityHidden(true)
            }
            link(compact ? "Note" : "Add note") {
                guard let date = actions.takeRecent() else { return }
                onNote(GoalItemNoteDraft(date: date))
            }
            .accessibilityLabel(Text(verbatim: "Add note"))
            if !compact { Text(verbatim: "·").brainText(.meta).accessibilityHidden(true) }
            link("Undo", action: actions.undo)
        }
        .disabled(isPending)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(BrainStyle.rowSubtitle.weight(.semibold))
                .foregroundStyle(paper?.glow ?? Color.accentColor)
                .frame(minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The inline note field Add note opens. Saving notes the item just counted (`GoalItemActions.note`);
/// if the save fails the field comes back with the typed note, and if the item came off without its
/// noted copy landing, saving again counts it anew with the note. Leaving it empty closes it.
private struct GoalItemNoteField: View {
    @Binding var draft: GoalItemNoteDraft?
    let isPending: Bool
    let actions: GoalItemActions

    @FocusState private var focused: Bool
    /// The card's paper on a Brief card; nil on the app's own surfaces, where Save is Nous blue.
    @Environment(\.hxPaper) private var paper

    var body: some View {
        HStack(spacing: BrainStyle.s) {
            TextField("Note (optional)", text: Binding(get: { draft?.text ?? "" }, set: { draft?.text = $0 }))
                .font(BrainStyle.rowSubtitle)
                .focused($focused)
                .onAppear { focused = true }
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, BrainStyle.m)
                .frame(minHeight: BrainStyle.minTapTarget - 8)
                .background(Color.hxSeparator.opacity(0.45), in: RoundedRectangle(cornerRadius: HXRadius.sm))
            let colors = ChatDecisionButtonStyle.primaryColors(on: paper)
            Button(action: save) {
                Text(verbatim: draft?.date == nil ? "Add" : "Save")
                    .font(BrainStyle.rowSubtitle.weight(.semibold))
                    .foregroundStyle(colors.text)
                    .padding(.horizontal, BrainStyle.l)
                    .frame(minHeight: BrainStyle.minTapTarget - 8)
                    .background(colors.fill, in: Capsule())
                    .frame(minHeight: BrainStyle.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPending)
        }
        .onChange(of: focused) { _, isFocused in
            // Leaving an empty field closes it; the item stays as it was counted.
            if !isFocused, let draft, draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.draft = nil }
        }
    }

    /// Notes the item just counted, or counts a new one with the note once that item came off.
    private func save() {
        guard let current = draft else { return }
        let typed = current.text
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = nil
        focused = false
        guard !trimmed.isEmpty else { return }
        let actions = actions
        Task { @MainActor in
            var date = current.date
            if let noted = date {
                switch await actions.note(noted, trimmed) {
                case .saved: return
                case .unchanged: date = noted
                case .removed: date = nil
                }
            } else if await actions.add(trimmed) {
                return
            }
            draft = GoalItemNoteDraft(date: date, text: typed)
        }
    }
}

/// What follows a +1 counted from Goals home: "Outreach counted · Add note · Undo" while the offer
/// lasts, then the note field, on a floating bar over the bottom of the screen so nothing on it moves.
/// Empty when there is nothing to offer.
struct GoalItemFollowUp: View {
    /// Leads the offer: "Outreach counted".
    let label: String
    let isPending: Bool
    let recentDate: String?
    let actions: GoalItemActions

    @State private var draft: GoalItemNoteDraft?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if draft != nil {
                bar { GoalItemNoteField(draft: $draft, isPending: isPending, actions: actions) }
            } else if recentDate != nil {
                bar { GoalItemOffer(label: label, isPending: isPending, actions: actions) { draft = $0 } }
            }
        }
        .animation(HXMotion.panel(reduceMotion: reduceMotion), value: recentDate != nil)
        .animation(HXMotion.panel(reduceMotion: reduceMotion), value: draft != nil)
        .announcesOffer(recentDate != nil, label: label)
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, BrainStyle.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hxCard()
            .hxShadow(.float)
            .transition(HXMotion.bottomOverlayTransition(reduceMotion: reduceMotion))
    }
}

private extension View {
    /// Tells VoiceOver the +1 landed and what it can do next, once each time the offer opens.
    func announcesOffer(_ isOffered: Bool, label: String) -> some View {
        onChange(of: isOffered) { _, offered in
            guard offered else { return }
            AccessibilityNotification.Announcement("\(label). Add note or undo.").post()
        }
    }
}
