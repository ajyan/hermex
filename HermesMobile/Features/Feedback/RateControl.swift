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

/// One ✓/✗ row: what it rates, its label key, and the item's name for the feedback inbox.
struct FeedbackRating: Identifiable {
    let label: String
    let key: LabelKey
    let title: String?
    var id: LabelKey { key }

    /// A Daily Deck reflect card's rows: its text, and its question while the card's own
    /// question is the one showing (a regenerated or typed one isn't the generator's).
    /// Other cards have none.
    static func deck(card: DeckCard, date: String, kind: String, showsQuestion: Bool) -> [FeedbackRating] {
        guard card.type == .reflect else { return [] }
        var rows = [FeedbackRating(label: "Card", key: .deckCard(date: date, kind: kind, cardID: card.id), title: card.title)]
        if showsQuestion, card.question != nil {
            rows.append(FeedbackRating(label: "Question", key: .deckQuestion(date: date, kind: kind, cardID: card.id),
                                       title: card.title ?? card.question))
        }
        return rows
    }
}

/// The Rate rows under a reflect card in Rate earlier cards, in the card's ink.
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
            ForEach(FeedbackRating.deck(card: card, date: date, kind: kind, showsQuestion: showsQuestion)) { rating in
                RateControl(label: rating.label, key: rating.key, title: rating.title, labels: labels, ink: palette.ink)
            }
        }
    }
}
