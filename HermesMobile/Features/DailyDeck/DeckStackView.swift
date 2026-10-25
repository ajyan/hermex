import SwiftUI

/// The Daily Deck's cards in a `CardStack`, plus what the deck adds to it: "Not for Me"
/// drops a card out of the stack with an Undo toast, and its sheet takes the reason; pulling
/// up past a card's end opens Send feedback on it, with the card's ✓/✗ rows.
struct DeckStackView: View {
    let viewModel: DailyDeckViewModel
    /// The card whose "Not for Me" sheet is open; set by the toolbar menu.
    @Binding var feedbackCard: DeckCard?
    let file: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var droppingID: String?
    /// Feedback chosen in the sheet, applied once the sheet has finished closing.
    @State private var pendingFeedback: (card: DeckCard, feedback: DeckFeedback)?
    /// The Send feedback sheet a swipe up opened; nil while closed.
    @State private var swipeFeedback: SwipeFeedback?
    @Environment(FeedbackAvailability.self) private var availability: FeedbackAvailability?
    /// Set by the Daily Deck once the server's labels are read.
    @Environment(LabelsViewModel.self) private var labels: LabelsViewModel?

    /// A page's resting tilt in the stack: about two degrees, left or right, fixed per page id.
    static func tilt(ofID id: String) -> Double {
        id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 2 == 0 ? 2.2 : -1.8
    }

    /// True except on a page that answers in place (follow-ups, the week's question), whose
    /// AnswerBox needs the keyboard inset.
    private var ignoresKeyboard: Bool {
        viewModel.currentPage?.answersInPlace != true
    }

    var body: some View {
        CardStack(
            pages: viewModel.visiblePages,
            index: Binding(get: { viewModel.index }, set: { viewModel.index = $0 }),
            droppingID: droppingID,
            tilt: { Self.tilt(ofID: $0.id) }
        ) { page, contentOpacity in
            DeckPageView(page: page, viewModel: viewModel, file: file,
                         feedback: availability?.isAvailable == true ? { openFeedback(on: page) } : nil,
                         contentOpacity: contentOpacity)
        } edge: { page in
            // Far down the stack only the card's paper shows, peeking out askew.
            let role = DeckPalette.of(page, inV2Weekly: viewModel.isSealedWeekly).cardRole
            role.shape
                .fill(role.fill)
                .hxShadow(.stacked)
                .padding(.vertical, 12)
        }
        .padding(.horizontal, 16)
        // The deck's cards never hold a text field (only the follow-ups page does), so a
        // keyboard inset left over from AnswerBox would otherwise shrink the whole stack.
        .ignoresSafeArea(ignoresKeyboard ? .keyboard : [], edges: .bottom)
        .overlay(alignment: .bottom) { toast }
        .sheet(item: $feedbackCard, onDismiss: applyPendingFeedback) { card in
            DeckFeedbackSheet(card: card, viewModel: viewModel) { feedback in
                pendingFeedback = (card, feedback)
                feedbackCard = nil
            }
        }
        .sheet(item: $swipeFeedback) { sheet in
            if let availability {
                FeedbackSheet(context: sheet.context, client: availability.client, screenshot: sheet.screenshot,
                              ratings: sheet.ratings, labels: labels,
                              style: sheet.styleCard.map { DeckStyleChipsSection(card: $0, viewModel: viewModel) })
            }
        }
    }

    // MARK: Send feedback

    private struct SwipeFeedback: Identifiable {
        let id = UUID()
        let context: FeedbackContext
        let ratings: [FeedbackRating]
        /// The card whose writing style chips can rate; nil off a card or on one without a kind.
        let styleCard: DeckCard?
        let screenshot: UIImage?
    }

    private func openFeedback(on page: DeckPage) {
        var ratings: [FeedbackRating] = []
        var styleCard: DeckCard?
        if case .card(let card) = page {
            ratings = FeedbackRating.deck(card: card, date: viewModel.date, kind: viewModel.kind,
                                          showsQuestion: viewModel.question(for: card) == card.question)
            styleCard = DeckStyleChip.styleCards(card.type, deckKind: viewModel.kind) ? card : nil
        }
        swipeFeedback = SwipeFeedback(
            context: .dailyDeck(title: viewModel.title, date: viewModel.date, kind: viewModel.kind, page: page),
            ratings: ratings,
            styleCard: styleCard,
            // Taken before the sheet covers the card.
            screenshot: FeedbackScreenshot.capture(FeedbackScreenshot.keyWindow())
        )
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
