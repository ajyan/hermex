import CoreGraphics

/// Geometry and settle rules for the chat shell's left drawer. Pure, so the
/// gesture's decisions are unit-tested without driving a real pan.
enum DrawerSettle {
    /// A pan must start this close to the left edge to open the drawer.
    static let edgeWidth: CGFloat = 20
    /// Open fraction at or past which a slow release settles open.
    static let openThreshold: CGFloat = 0.4
    /// Horizontal speed (pt/s) above which a release settles in its direction.
    static let flickVelocity: CGFloat = 600

    static func width(screenWidth: CGFloat, isAccessibilitySize: Bool) -> CGFloat {
        isAccessibilitySize ? screenWidth - 44 : screenWidth * 0.85
    }

    /// How open the drawer is mid-drag, 0…1. `translation` is positive rightward.
    static func openFraction(startedOpen: Bool, translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return startedOpen ? 1 : 0 }
        let offset = (startedOpen ? width : 0) + translation
        return min(max(offset / width, 0), 1)
    }

    /// Whether a released drag leaves the drawer open.
    static func isOpen(startedOpen: Bool, translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        if abs(velocity) > flickVelocity { return velocity > 0 }
        return openFraction(startedOpen: startedOpen, translation: translation, width: width) >= openThreshold
    }

    /// With the drawer open, only drags that start on the scrim or the drawer's
    /// trailing edge move it, so swiping a row reveals its actions instead.
    static func tracksCloseDrag(startX: CGFloat, width: CGFloat) -> Bool {
        startX >= width - edgeWidth
    }

    /// The edge pan opens the drawer only from the chat root, so the system
    /// back-swipe keeps working on pushed screens.
    static func allowsEdgeOpen(startX: CGFloat, pathIsEmpty: Bool) -> Bool {
        pathIsEmpty && startX <= edgeWidth
    }
}
