import SwiftUI
import UIKit

/// The left-drawer layout: `main` slides right under a scrim while `drawer` slides
/// in. The drag offset lives here, so a drag frame re-renders only this container;
/// `main` and `drawer` arrive already built and are not re-evaluated per frame.
struct DrawerContainer<Main: View, Drawer: View>: View {
    let isOpen: Bool
    /// Whether a rightward pan may open the drawer (the chat root is on screen).
    let canEdgeOpen: Bool
    /// Called once a drag starts that can open the drawer, so it can be built in time.
    let willOpen: () -> Void
    let setOpen: (Bool) -> Void
    @ViewBuilder let main: Main
    @ViewBuilder let drawer: Drawer

    /// Animated reset, so a release glides from the finger to the settled state
    /// instead of snapping back to it first.
    @GestureState(resetTransaction: Transaction(animation: HXMotion.panel(reduceMotion: false)))
    private var drag: CGFloat = 0
    /// Whether the current pan started on sideways-scrolling content, probed once per pan.
    @State private var startProbe = SidewaysScrollProbe()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let width = DrawerSettle.width(
                screenWidth: proxy.size.width,
                isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
            )
            let fraction = DrawerSettle.openFraction(startedOpen: isOpen, translation: drag, width: width)
            let shift = reduceMotion ? 0 : fraction * width

            ZStack(alignment: .leading) {
                main
                    .offset(x: shift)
                    .accessibilityHidden(isOpen)

                // Always present so it animates with the chat; inserting it would
                // snap it to its final offset while the chat is still sliding.
                Color.black.opacity(0.3 * fraction)
                    .ignoresSafeArea()
                    .offset(x: shift)
                    .contentShape(Rectangle())
                    .onTapGesture { setOpen(false) }
                    .allowsHitTesting(fraction > 0)
                    .accessibilityHidden(true)

                drawer
                    .frame(width: width)
                    .background(Color.hxCanvas.ignoresSafeArea())
                    .offset(x: reduceMotion ? 0 : (fraction - 1) * width)
                    .opacity(reduceMotion ? fraction : 1)
                    .allowsHitTesting(isOpen)
                    .accessibilityHidden(!isOpen)
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { setOpen(false) }

                if isOpen {
                    Button("Close chats") { setOpen(false) }
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
            .simultaneousGesture(dragGesture(width: width))
        }
    }

    /// Tracks a closed drawer's rightward pan from the chat root, and an open
    /// drawer's pan from the scrim or its trailing edge (row swipes stay with rows).
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .updating($drag) { value, state, _ in
                guard tracks(value, width: width) else { return }
                state = value.translation.width
            }
            .onChanged { value in
                if !isOpen, tracks(value, width: width) { willOpen() }
            }
            .onEnded { value in
                guard tracks(value, width: width) else { return }
                setOpen(DrawerSettle.isOpen(
                    startedOpen: isOpen,
                    translation: value.translation.width,
                    velocity: value.velocity.width,
                    width: width
                ))
            }
    }

    private func tracks(_ value: DragGesture.Value, width: CGFloat) -> Bool {
        guard abs(value.translation.width) > abs(value.translation.height) else { return false }
        if isOpen {
            return DrawerSettle.tracksCloseDrag(startX: value.startLocation.x, width: width)
        }
        guard canEdgeOpen, value.translation.width > 0 else { return false }
        return DrawerSettle.allowsOpenDrag(
            startX: value.startLocation.x,
            translationX: value.translation.width,
            pathIsEmpty: canEdgeOpen,
            startsOnSidewaysScroller: startProbe.startsOnSidewaysScroller(value.startLocation)
        )
    }
}

/// Answers whether a pan's start point lies on a UIKit scroll view that scrolls
/// sideways (SwiftUI's horizontal `ScrollView`, a code block, a web card). It hit-tests
/// once per pan and caches the answer by start point, so a drag frame costs a compare.
/// A reference type held in `@State`: updating the cache never re-renders the drawer.
@MainActor
final class SidewaysScrollProbe {
    private var start: CGPoint?
    private var result = false

    func startsOnSidewaysScroller(_ point: CGPoint) -> Bool {
        if point == start { return result }
        start = point
        result = Self.scrollsSideways(at: point)
        return result
    }

    private static func scrollsSideways(at point: CGPoint) -> Bool {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var view = window?.hitTest(point, with: nil)
        while let current = view {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled,
               scrollView.contentSize.width > scrollView.bounds.width + 1 {
                return true
            }
            view = current.superview
        }
        return false
    }
}
