import SwiftUI

/// The Daily Deck as a stack of cards: swipe left for the next card, right to pull the
/// previous one back on top. Only the top two cards render content; the third is a bare
/// edge peeking out underneath. "Not for Me" drops a card out of the stack with an Undo
/// toast. Under Reduce Motion the cards stay put while dragging and crossfade on commit.
struct DeckStackView: View {
    let viewModel: DailyDeckViewModel
    /// The card whose "Not for Me" sheet is open; set by the toolbar menu.
    @Binding var feedbackCard: DeckCard?
    let file: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var droppingID: String?
    /// Feedback chosen in the sheet, applied once the sheet has finished closing.
    @State private var pendingFeedback: (card: DeckCard, feedback: DeckFeedback)?

    /// A page's resting tilt in the stack: about two degrees, left or right, fixed per page id.
    static func tilt(ofID id: String) -> Double {
        id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 2 == 0 ? 2.2 : -1.8
    }

    var body: some View {
        CardStack(
            pages: viewModel.visiblePages,
            index: Binding(get: { viewModel.index }, set: { viewModel.index = $0 }),
            droppingID: droppingID,
            tilt: { Self.tilt(ofID: $0.id) }
        ) { page, contentOpacity in
            DeckPageView(page: page, viewModel: viewModel, file: file, contentOpacity: contentOpacity)
        } edge: { page in
            // Far down the stack only the card's paper shows, peeking out askew.
            DeckPageView.shape
                .fill(DeckPalette.of(page).paper)
                .hxShadow(.stacked)
                .padding(.vertical, 12)
        }
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) { toast }
        .sheet(item: $feedbackCard, onDismiss: applyPendingFeedback) { card in
            DeckFeedbackSheet(card: card, viewModel: viewModel) { feedback in
                pendingFeedback = (card, feedback)
                feedbackCard = nil
            }
        }
    }

    // MARK: Not for Me

    private func applyPendingFeedback() {
        guard let (card, feedback) = pendingFeedback else { return }
        pendingFeedback = nil
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { viewModel.dismiss(card, feedback: feedback) }
            return
        }
        withAnimation(.easeIn(duration: 0.28)) {
            droppingID = card.id
        } completion: {
            withoutAnimation {
                viewModel.dismiss(card, feedback: feedback)
                droppingID = nil
            }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let dismissal = viewModel.lastDismissal {
            HStack(spacing: 8) {
                Image(systemName: "hand.thumbsdown").foregroundStyle(.secondary)
                let title = dismissal.card.title ?? "this card"
                Text(verbatim: viewModel.answer(for: dismissal.card)?.feedback?.verdict == .less
                     ? "Less like this: \(title)" : "Skipped: \(title)")
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)) { viewModel.undoDismissal() } } label: {
                    Text(verbatim: "Undo").font(AppFont.subheadline(weight: .semibold))
                }
            }
            .font(AppFont.subheadline())
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .adaptiveGlass(.regular, fallbackMaterial: .regularMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .task(id: dismissal.card.id) {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { viewModel.clearDismissal() }
            }
        }
    }
}
