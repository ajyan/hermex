import SwiftUI

/// A weekly review's What changed card: each fix from the feedback loop whose status moved this
/// week, newest first. A row leads with the change, then what the user said (his words, in
/// serif) and the state as a chip. A shipped row offers Undo, which reverts the fix on the
/// vault's main branch after a confirmation; the server's reason shows under the row when it
/// refuses. Undo goes through the deck's view model so the open card and the stack agree.
struct DeckChangesCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var confirming: DeckChangeRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "What changed")
                .font(AppFont.display(style: .title2, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 30)
                .padding(.bottom, 16)
                .accessibilityAddTraits(.isHeader)
            if card.rows.isEmpty, let fallback = card.fallback {
                Text(verbatim: fallback)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(card.rows) { row in
                Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5)
                rowView(row)
            }
        }
        .confirmationDialog(
            Text(verbatim: "Undo this fix?"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { row in
            Button(role: .destructive) {
                Task { await viewModel.undoChange(row) }
            } label: {
                Text(verbatim: "Undo")
            }
        } message: { _ in
            Text(verbatim: "Reverts this change on the vault's main branch.")
        }
    }

    private func rowView(_ row: DeckChangeRow) -> some View {
        let state = viewModel.changeState(row)
        let stateLabel = state.label(recurred: row.recurred)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if !row.change.isEmpty {
                    Text(verbatim: row.change)
                        .font(AppFont.body(weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.said.isEmpty {
                    Text(verbatim: "“\(row.said)”")
                        .font(AppFont.serif(style: .subheadline))
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(verbatim: "You said: \(row.said)"))
                }
            }
            .accessibilityElement(children: .combine)
            HStack(alignment: .center, spacing: 10) {
                if !stateLabel.isEmpty {
                    HXChip(paper: palette.colors, symbol: Self.symbol(for: state), label: stateLabel)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: "Status: \(stateLabel)"))
                }
                Spacer(minLength: 0)
                if viewModel.undoingChangeID == row.id {
                    ProgressView()
                        .tint(palette.ink)
                        .accessibilityLabel(Text(verbatim: "Undoing"))
                } else if viewModel.canUndo(row) {
                    Button { confirming = row } label: { Text(verbatim: "Undo") }
                        .buttonStyle(.bordered)
                        .font(AppFont.subheadline(weight: .semibold))
                        .disabled(viewModel.undoingChangeID != nil)
                        .accessibilityLabel(Text(verbatim: row.change.isEmpty ? "Undo this fix" : "Undo \(row.change)"))
                        .accessibilityHint(Text(verbatim: "Reverts this change on the vault's main branch."))
                }
            }
            if let error = viewModel.changeErrors[row.id] {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(AppFont.footnote(weight: .medium))
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
    }

    /// The chip's mark; the label carries the meaning.
    private static func symbol(for state: DeckChangeRow.State) -> String? {
        switch state {
        case .shipped: "checkmark"
        case .merged: "arrow.triangle.merge"
        case .held: "checkmark.seal"
        case .recurred: "arrow.uturn.backward.circle"
        case .reverted: "arrow.uturn.backward"
        case .unknown: nil
        }
    }
}
