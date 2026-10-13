import SwiftUI

/// ✓ and ✗ for one label: marks generated content good or not good. Tapping the chosen
/// verdict again clears it. ✗ asks for an optional note first. Saving is non-optimistic: the
/// tapped button shows a spinner until the server answers, and a failure leaves the previous
/// label with an inline error. Neutral until chosen; the chosen verdict wears the accent.
/// English-only copy (personal fork).
struct RateControl: View {
    /// What is being rated, e.g. "Card", "Question", "This page".
    let label: String
    let key: LabelKey
    /// What the item is called, sent along so the feedback inbox can name it.
    var title: String?
    let labels: LabelsViewModel
    /// The unselected buttons' and label's color; on a glow card, the card's ink.
    var ink: Color = .hxTextSecondary

    @State private var isAskingNote = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(ink)
                Spacer(minLength: 8)
                button(.good)
                button(.bad)
            }
            if let error = labels.error(for: key) {
                Text(verbatim: error)
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxDanger)
            }
        }
        .accessibilityElement(children: .contain)
        .alert(Text(verbatim: "Not good"), isPresented: $isAskingNote) {
            TextField(text: $note) { Text(verbatim: "What's off? (optional)") }
            Button { save(.bad, note: note) } label: { Text(verbatim: "Save") }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        } message: {
            Text(verbatim: "A note also goes to your feedback inbox.")
        }
    }

    private func button(_ verdict: LabelVerdict) -> some View {
        let current = labels.verdict(for: key)
        let isSelected = current == verdict
        let pending = labels.pending[key]
        // A clear spins on the button being cleared.
        let spins = pending == verdict || (pending == .clear && isSelected)
        let symbol = verdict == .good ? "checkmark.circle" : "xmark.circle"
        return Button {
            if verdict == .bad, !isSelected {
                note = ""
                isAskingNote = true
            } else {
                save(verdict, note: nil)
            }
        } label: {
            ZStack {
                if spins {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isSelected ? "\(symbol).fill" : symbol)
                        .font(AppFont.title3())
                        .foregroundStyle(isSelected ? Color.accentColor : ink)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pending != nil)
        .accessibilityLabel(Text(verbatim: verdict == .good ? "Mark good" : "Mark not good"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save(_ verdict: LabelVerdict, note: String?) {
        let labels = labels, key = key, title = title
        Task { await labels.tap(verdict, for: key, note: note, title: title) }
    }
}

/// The Rate rows under a Daily Deck reflect card: the card's text, and its question while
/// the card's own question is the one showing (a regenerated or typed one isn't the
/// generator's).
struct DeckRateRows: View {
    let card: DeckCard
    let date: String
    let kind: String
    let showsQuestion: Bool
    let labels: LabelsViewModel
    let palette: DeckPalette

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.edge).frame(height: 0.5).accessibilityHidden(true)
            RateControl(label: "Card", key: .deckCard(date: date, kind: kind, cardID: card.id),
                        title: card.title, labels: labels, ink: palette.ink)
            if showsQuestion, card.question != nil {
                RateControl(label: "Question", key: .deckQuestion(date: date, kind: kind, cardID: card.id),
                            title: card.title ?? card.question, labels: labels, ink: palette.ink)
            }
        }
    }
}
