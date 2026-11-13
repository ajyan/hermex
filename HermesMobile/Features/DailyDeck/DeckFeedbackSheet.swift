import SwiftUI

/// "Not for Me" on one card: say what's off, then skip it or ask for less like it, or
/// keep the card with a different question (the next one the brief wrote, or your own).
/// Skipping hands the feedback back to the stack, which drops the card once the sheet closes.
struct DeckFeedbackSheet: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel
    let onDismissCard: (DeckFeedback) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reasons: Set<String> = []
    @State private var note = ""
    @State private var isAskingOwn = false
    @State private var ownQuestion = ""

    /// Leaving would throw away a typed note: the sheet asks first.
    private var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @State private var confirmsDiscard = false

    /// The card's own paper, which its reason chips wear; a neutral card's are plain, since its amber means waiting on you.
    private var paper: HermexPaper {
        let palette = DeckPalette.of(.card(card), inV2Weekly: viewModel.isSealedWeekly)
        return palette.isNeutralCard ? .plain : palette.colors
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(verbatim: "What's off about this card?")
                        .font(AppFont.headline())
                    FlowRow(spacing: 8) {
                        ForEach(DeckFeedback.reasons, id: \.id) { reason in
                            chip(reason.id, label: reason.label)
                        }
                    }
                    TextField(text: $note, axis: .vertical) { Text(verbatim: "Anything else? (optional)") }
                        .font(AppFont.body())
                        .lineLimit(1...4)
                        .padding(12)
                        .withDictation($note)
                        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))

                    VStack(spacing: 0) {
                        if !card.altQuestions.isEmpty {
                            row("Regenerate question", systemImage: "arrow.triangle.2.circlepath") {
                                dismiss()
                                withAnimation(HXMotion.swap(reduceMotion: reduceMotion)) {
                                    viewModel.regenerateQuestion(for: card)
                                }
                            }
                            Divider()
                        }
                        row("Ask my own question", systemImage: "pencil") {
                            ownQuestion = viewModel.question(for: card) ?? ""
                            isAskingOwn = true
                        }
                    }
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { verdictButtons }
                        VStack(spacing: 8) { verdictButtons }
                    }
                }
                .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle("Not for me")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { if hasNote { confirmsDiscard = true } else { dismiss() } } label: { Text(verbatim: "Cancel") }
                }
            }
            .confirmationDialog(Text(verbatim: "Discard your note?"), isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button(role: .destructive) { dismiss() } label: { Text(verbatim: "Discard note") }
                Button(role: .cancel) {} label: { Text(verbatim: "Keep editing") }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(hasNote)
        .alert(Text(verbatim: "Your question"), isPresented: $isAskingOwn) {
            TextField(text: $ownQuestion) { Text(verbatim: "What do you want to answer?") }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
            Button {
                viewModel.setOwnQuestion(ownQuestion, for: card)
                dismiss()
            } label: { Text(verbatim: "Use it") }
        } message: {
            Text(verbatim: "It replaces this card's question and is filed with your answer.")
        }
    }

    @ViewBuilder
    private var verdictButtons: some View {
        Button { send(.skip) } label: { Text(verbatim: "Skip card") }
            .buttonStyle(.chatDecision(.secondary))
        Button { send(.less) } label: { Text(verbatim: "Less like this") }
            .buttonStyle(.chatDecision(.primary))
    }

    private func send(_ verdict: DeckFeedback.Verdict) {
        let ordered = DeckFeedback.reasons.map(\.id).filter(reasons.contains)
        onDismissCard(DeckFeedback(verdict: verdict, reasons: ordered, note: note))
    }

    /// A reason as the card's chip; a chosen one carries a check.
    private func chip(_ id: String, label: String) -> some View {
        let isSelected = reasons.contains(id)
        return Button {
            if isSelected { reasons.remove(id) } else { reasons.insert(id) }
        } label: {
            HXChip(paper: paper, symbol: isSelected ? "checkmark" : nil, label: label)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(verbatim: title) } icon: { Image(systemName: systemImage) }
                .font(AppFont.body())
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}
