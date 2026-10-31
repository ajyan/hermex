import SwiftUI

/// ✓ and ✗ for one label: marks generated content good or not good. Tapping the chosen
/// verdict again clears it. ✗ asks for an optional note first. Saving is non-optimistic: the
/// tapped button shows a spinner until the server answers, and a failure leaves the previous
/// label with an inline error. Neutral until chosen; the chosen verdict wears the accent.
/// A confirmed ✗ on a Daily Deck label adds a row of optional reason chips under it.
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
    /// On a glow card, its paper: unselected reason chips wear it. Nil draws them neutral.
    var paper: HermexPaper?

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
            if labels.verdict(for: key) == .bad, !LabelReason.options(for: key).isEmpty {
                if labels.asksWhy(for: key) {
                    Text(verbatim: "Why?")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(ink)
                        .padding(.top, 2)
                }
                LabelReasonChips(key: key, title: title, labels: labels, paper: paper)
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

/// Why a ✗ is bad, as a wrapping row of chips: one tap saves the label again with that reason,
/// and tapping the chosen one clears it. A chip shows chosen once the server has it, in the
/// accent since it's a control; until then it spins. Unchosen chips wear the card's glow, or
/// stay neutral off a card. Each keeps a 44 pt hit row.
private struct LabelReasonChips: View {
    let key: LabelKey
    let title: String?
    let labels: LabelsViewModel
    let paper: HermexPaper?

    var body: some View {
        // No spacing between rows: each chip's 44 pt hit row already sets them apart.
        FlowRow(spacing: 0) {
            ForEach(LabelReason.options(for: key)) { reason in
                chip(reason).padding(.trailing, 6)
            }
        }
        .padding(.bottom, 4)
    }

    private func chip(_ reason: LabelReason) -> some View {
        let isSelected = labels.reason(for: key) == reason.key
        let spins = labels.pendingReasons[key] == reason.key
        return Button {
            let labels = labels, key = key, title = title
            Task { await labels.tapReason(reason.key, for: key, title: title) }
        } label: {
            face(reason, isSelected: isSelected, spins: spins)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(labels.isPending(key))
        .accessibilityLabel(Text(verbatim: "Reason: \(reason.label)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func face(_ reason: LabelReason, isSelected: Bool, spins: Bool) -> some View {
        if !isSelected, let paper {
            HXChip(paper: paper, label: reason.label) {
                if spins { ProgressView().controlSize(.mini) }
            }
        } else {
            // HXChip's capsule, filled with the accent when chosen and neutral otherwise.
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(AppFont.caption2(weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: reason.label)
                    .font(AppFont.caption(weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if spins { ProgressView().controlSize(.mini) }
            }
            .foregroundStyle(isSelected ? Color.hxOnAccent : Color.hxTextPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color.hxCanvas, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.hxSeparator, lineWidth: 0.5))
        }
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
                RateControl(label: rating.label, key: rating.key, title: rating.title, labels: labels,
                            ink: palette.ink, paper: palette.colors)
            }
        }
    }
}
