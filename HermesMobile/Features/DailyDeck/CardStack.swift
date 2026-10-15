import SwiftUI

/// A swipeable stack of cards: swipe left for the next card, right to pull the previous
/// one back on top. Only the top two cards render content; the third is a bare edge
/// peeking out underneath. Press and hold to fan the whole deck out, slide across it to
/// pick a card, and let go to jump there (`CardFan`). Under Reduce Motion the cards stay
/// put while dragging and crossfade on commit, and the fan opens without moving.
/// Callers own the horizontal padding and anything drawn over the stack.
struct CardStack<Page: Identifiable, Card: View, Edge: View>: View {
    let pages: [Page]
    @Binding var index: Int
    /// The page animating out of the stack (Not for Me); nil otherwise.
    var droppingID: Page.ID? = nil
    let tilt: (Page) -> Double
    @ViewBuilder let card: (Page, _ contentOpacity: Double) -> Card
    /// What a card far down the stack shows: its bare paper.
    @ViewBuilder let edge: (Page) -> Edge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Horizontal drag of the top card (negative: toward next). A positive drag pulls
    /// the previous card in from the left instead of moving the top one.
    @State private var dragX: CGFloat = 0
    /// Locks a drag to the axis it started on, so vertical scrolling never pages.
    @State private var dragAxis: Axis?
    /// The card a finger over the fanned deck points at; nil while the deck is stacked.
    @State private var fanPick: Int?
    /// Fans the deck if the touch is still held, unmoved, when it fires.
    @State private var hold: Task<Void, Never>?
    /// The touch moved before the hold fired, so it is a swipe or a scroll, not a hold.
    @State private var holdMoved = false

    /// How far past the edge a card flies, as a multiple of the stack's width.
    private static var fly: CGFloat { 1.4 }
    private static var peek: CGFloat { 8 }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack {
                ForEach(layers(width: width)) { layer in
                    cardView(layer, width: width, height: proxy.size.height)
                }
            }
            .padding(.bottom, Self.peek * 2)
            .contentShape(Rectangle())
            .simultaneousGesture(drag(width: width))
            .simultaneousGesture(fan(width: width))
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
        .sensoryFeedback(.impact(weight: .light), trigger: currentID)
        .sensoryFeedback(.selection, trigger: fanPick) { old, new in old != nil && new != nil }
        .sensoryFeedback(.impact(weight: .medium), trigger: fanPick == nil) { _, stacked in !stacked }
    }

    private var currentID: Page.ID? {
        pages.indices.contains(index) ? pages[index].id : nil
    }

    // MARK: Layers

    private struct Layer: Identifiable {
        let page: Page
        /// 0 is the top card; each level below sits a little lower and smaller.
        let depth: CGFloat
        let x: CGFloat
        /// Where the card sits in the fanned deck; nil while stacked.
        var fan: CardFan.Spot? = nil
        var id: Page.ID { page.id }
    }

    /// The cards to draw, top first. While the top card travels toward next (or drops),
    /// the ones under it rise by the same fraction, so committing never jumps.
    private func layers(width: CGFloat) -> [Layer] {
        guard pages.indices.contains(index) else { return [] }
        if let fanPick {
            return pages.indices.map { position in
                Layer(page: pages[position], depth: 0, x: 0,
                      fan: CardFan.spot(of: position, count: pages.count, width: width, picked: fanPick))
            }
        }
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
    private func cardView(_ layer: Layer, width: CGFloat, height: CGFloat) -> some View {
        let isTop = layer.fan == nil && layer.depth == 0 && layer.page.id == currentID
        let dropping = layer.page.id == droppingID
        let fan = layer.fan
        Group {
            // Fanned, only the picked card shows its words; the rest are bare paper.
            if fan?.isPicked ?? (layer.depth < 1.5) {
                card(layer.page, fan == nil ? max(0, 1 - Double(layer.depth) * 1.6) : 1)
            } else {
                edge(layer.page)
            }
        }
        .scaleEffect(fan?.scale ?? (1 - 0.04 * max(layer.depth, 0)) * (dropping ? 0.85 : 1), anchor: .bottom)
        // Cards under the top one sit a little askew, like a real deck; they straighten as they rise.
        .rotationEffect(.degrees(fan?.degrees ?? tilt(layer.page) * min(max(layer.depth, 0), 1)))
        .offset(x: fan?.x ?? layer.x,
                y: fan.map { $0.y - height * CardFan.rise } ?? Self.peek * max(layer.depth, 0) + (dropping ? 140 : 0))
        .rotationEffect(.degrees(Double(layer.x / width) * 12), anchor: .bottom)
        .opacity(dropping ? 0 : 1)
        .zIndex(fan?.zIndex ?? -Double(layer.depth))
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
                    // A finger scrubbing the fanned deck never pages it.
                    dragAxis = fanPick == nil && abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal : .vertical
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

    /// Press and hold to fan the deck out; the finger then picks a card, and letting go jumps there.
    /// A drag from touch-down with a timer rather than a `LongPressGesture`: a long press on the
    /// stack claims every touch, so taps on the card (opening it) never arrive.
    private func fan(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let fanPick {
                    let pick = CardFan.index(atX: value.location.x, count: pages.count, width: width)
                    if pick != fanPick {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { self.fanPick = pick }
                    }
                    return
                }
                if hypot(value.translation.width, value.translation.height) > 10 {
                    holdMoved = true
                    hold?.cancel()
                } else if hold == nil, !holdMoved, droppingID == nil, pages.count > 1 {
                    hold = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled, !holdMoved else { return }
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2)) {
                            dragX = 0
                            fanPick = index
                        }
                    }
                }
            }
            .onEnded { _ in
                hold?.cancel()
                hold = nil
                holdMoved = false
                guard let pick = fanPick else { return }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)) {
                    index = pick
                    fanPick = nil
                }
            }
    }

    /// Past either end of the deck the card only gives a little.
    private func resisted(_ x: CGFloat) -> CGFloat {
        let atEnd = x < 0 ? index >= pages.count - 1 : index == 0
        return atEnd ? x * 0.2 : x
    }

    private func advance(width: CGFloat) {
        guard index < pages.count - 1 else { return settle() }
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { index += 1 }
            return
        }
        withAnimation(.spring(duration: 0.35, bounce: 0)) {
            dragX = -Self.fly * width
        } completion: {
            withoutAnimation {
                index += 1
                dragX = 0
            }
        }
    }

    /// Pulls the previous card back over the top one, from wherever the drag left it.
    private func retreat(width: CGFloat) {
        guard index > 0 else { return settle() }
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { index -= 1 }
            return
        }
        let incoming = min(0, -Self.fly * width + max(dragX, 0) * Self.fly)
        withoutAnimation {
            index -= 1
            dragX = incoming
        }
        withAnimation(.spring(duration: 0.4, bounce: 0.15)) { dragX = 0 }
    }

    private func settle() {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.3)) { dragX = 0 }
    }
}

/// Runs a state change with animations disabled, so a commit never replays as motion.
func withoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}

/// Where each card sits while a `CardStack` is fanned out, and which card a finger over the
/// fan points at. The fan is an arc of small cards along the bottom of the stack, centered
/// on its middle card, that always fits the stack's width.
enum CardFan {
    struct Spot: Equatable {
        let x: CGFloat
        let y: CGFloat
        let degrees: Double
        let scale: CGFloat
        let zIndex: Double
        let isPicked: Bool
    }

    /// How far above the stack's bottom edge the fan sits, as a share of the stack's height.
    static let rise: CGFloat = 0.3
    private static let scale: CGFloat = 0.42
    private static let pickedScale: CGFloat = 0.5
    private static let pickedLift: CGFloat = 28

    /// Horizontal distance between neighboring cards, so the whole fan spans at most 70%
    /// of `width`.
    static func spacing(count: Int, width: CGFloat) -> CGFloat {
        guard count > 1 else { return 0 }
        return min(40, width * 0.7 / CGFloat(count - 1))
    }

    /// The card at `position`: spread from the middle, dropping and turning toward each end.
    /// The picked card rises, grows, and sits on top.
    static func spot(of position: Int, count: Int, width: CGFloat, picked: Int) -> Spot {
        let offset = CGFloat(position) - CGFloat(count - 1) / 2
        let turn = count > 1 ? min(6, 40 / Double(count - 1)) : 0
        let isPicked = position == picked
        return Spot(
            x: offset * spacing(count: count, width: width),
            y: offset * offset * 2.5 - (isPicked ? pickedLift : 0),
            degrees: Double(offset) * turn,
            scale: isPicked ? pickedScale : scale,
            zIndex: isPicked ? Double(count) : Double(position),
            isPicked: isPicked
        )
    }

    /// The card under a finger at `x`, in the stack's coordinates, clamped to the deck.
    static func index(atX x: CGFloat, count: Int, width: CGFloat) -> Int {
        guard count > 1 else { return 0 }
        let offset = (x - width / 2) / spacing(count: count, width: width)
        return min(max(Int((offset + CGFloat(count - 1) / 2).rounded()), 0), count - 1)
    }
}
