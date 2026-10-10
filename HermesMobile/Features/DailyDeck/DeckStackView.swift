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
    /// Horizontal drag of the top card (negative: toward next). A positive drag pulls
    /// the previous card in from the left instead of moving the top one.
    @State private var dragX: CGFloat = 0
    /// Locks a drag to the axis it started on, so vertical scrolling never pages.
    @State private var dragAxis: Axis?
    @State private var droppingID: String?
    /// Feedback chosen in the sheet, applied once the sheet has finished closing.
    @State private var pendingFeedback: (card: DeckCard, feedback: DeckFeedback)?

    /// A page's resting tilt in the stack: about two degrees, left or right, fixed per page.
    static func tilt(of page: DeckPage) -> Double {
        page.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 2 == 0 ? 2.2 : -1.8
    }

    /// How far past the edge a card flies, as a multiple of the stack's width.
    private static let fly: CGFloat = 1.4
    private static let peek: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack {
                ForEach(layers(width: width)) { layer in
                    card(layer, width: width)
                }
            }
            .padding(.bottom, Self.peek * 2)
            .contentShape(Rectangle())
            .simultaneousGesture(drag(width: width))
            .accessibilityElement(children: .contain)
            .accessibilityScrollAction { edge in
                switch edge {
                case .trailing, .bottom: advance(width: width)
                case .leading, .top: retreat(width: width)
                }
            }
            .accessibilityAction(named: Text(verbatim: "Next Card")) { advance(width: width) }
            .accessibilityAction(named: Text(verbatim: "Previous Card")) { retreat(width: width) }
        }
        .padding(.horizontal, 16)
        .overlay(alignment: .bottom) { toast }
        .sensoryFeedback(.impact(weight: .light), trigger: viewModel.currentPage?.id)
        .sheet(item: $feedbackCard, onDismiss: applyPendingFeedback) { card in
            DeckFeedbackSheet(card: card, viewModel: viewModel) { feedback in
                pendingFeedback = (card, feedback)
                feedbackCard = nil
            }
        }
    }

    // MARK: Layers

    private struct Layer: Identifiable {
        let page: DeckPage
        /// 0 is the top card; each level below sits a little lower and smaller.
        let depth: CGFloat
        let x: CGFloat
        var id: String { page.id }
    }

    /// The cards to draw, top first. While the top card travels toward next (or drops),
    /// the ones under it rise by the same fraction, so committing never jumps.
    private func layers(width: CGFloat) -> [Layer] {
        let pages = viewModel.visiblePages, index = viewModel.index
        guard pages.indices.contains(index) else { return [] }
        let travel = width * 0.6
        let top: Layer, rise: CGFloat, firstBelow: Int
        if dragX > 0, index > 0 {
            // Pulling the previous card back in from the left, over the current one.
            let incoming = min(0, -Self.fly * width + dragX * Self.fly)
            top = Layer(page: pages[index - 1], depth: 0, x: incoming)
            rise = min(-incoming / travel, 1)
            firstBelow = index
        } else {
            top = Layer(page: pages[index], depth: 0, x: dragX)
            rise = droppingID == nil ? min(max(-dragX / travel, 0), 1) : 1
            firstBelow = index + 1
        }
        let below = (firstBelow..<min(firstBelow + 2, pages.count)).enumerated().map { offset, position in
            Layer(page: pages[position], depth: CGFloat(offset + 1) - rise, x: 0)
        }
        return [top] + below
    }

    @ViewBuilder
    private func card(_ layer: Layer, width: CGFloat) -> some View {
        let isTop = layer.depth == 0 && layer.page.id == viewModel.currentPage?.id
        let dropping = layer.page.id == droppingID
        Group {
            if layer.depth < 1.5 {
                DeckPageView(page: layer.page, viewModel: viewModel, file: file,
                             contentOpacity: max(0, 1 - Double(layer.depth) * 1.6))
            } else {
                // Far down the stack only the card's paper shows, peeking out askew.
                DeckPageView.shape
                    .fill(DeckPalette.of(layer.page).paper)
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                    .padding(.vertical, 12)
            }
        }
        .scaleEffect((1 - 0.04 * max(layer.depth, 0)) * (dropping ? 0.85 : 1), anchor: .bottom)
        // Cards under the top one sit a little askew, like a real deck; they straighten as they rise.
        .rotationEffect(.degrees(Self.tilt(of: layer.page) * min(max(layer.depth, 0), 1)))
        .offset(x: layer.x, y: Self.peek * max(layer.depth, 0) + (dropping ? 140 : 0))
        .rotationEffect(.degrees(Double(layer.x / width) * 12), anchor: .bottom)
        .opacity(dropping ? 0 : 1)
        .zIndex(-Double(layer.depth))
        .allowsHitTesting(isTop)
        .accessibilityHidden(!isTop)
        .transition(.opacity)
    }

    // MARK: Moving

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard droppingID == nil else { return }
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal, !reduceMotion else { return }
                dragX = resisted(value.translation.width)
            }
            .onEnded { value in
                defer { dragAxis = nil }
                guard dragAxis == .horizontal, droppingID == nil else { return }
                let moved = value.translation.width, flung = value.predictedEndTranslation.width
                if moved < -width * 0.3 || flung < -width * 0.6 {
                    advance(width: width)
                } else if moved > width * 0.3 || flung > width * 0.6 {
                    retreat(width: width)
                } else {
                    settle()
                }
            }
    }

    /// Past either end of the deck the card only gives a little.
    private func resisted(_ x: CGFloat) -> CGFloat {
        let atEnd = x < 0 ? viewModel.index >= viewModel.visiblePages.count - 1 : viewModel.index == 0
        return atEnd ? x * 0.2 : x
    }

    private func advance(width: CGFloat) {
        guard viewModel.index < viewModel.visiblePages.count - 1 else { return settle() }
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { viewModel.index += 1 }
            return
        }
        withAnimation(.spring(duration: 0.35, bounce: 0)) {
            dragX = -Self.fly * width
        } completion: {
            withoutAnimation {
                viewModel.index += 1
                dragX = 0
            }
        }
    }

    /// Pulls the previous card back over the top one, from wherever the drag left it.
    private func retreat(width: CGFloat) {
        guard viewModel.index > 0 else { return settle() }
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { viewModel.index -= 1 }
            return
        }
        let incoming = min(0, -Self.fly * width + max(dragX, 0) * Self.fly)
        withoutAnimation {
            viewModel.index -= 1
            dragX = incoming
        }
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { dragX = 0 }
    }

    private func settle() {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.3)) { dragX = 0 }
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
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
