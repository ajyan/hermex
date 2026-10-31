import SwiftUI

/// The app's one set of motion curves (DESIGN.md § Motion). Pick by what is moving, never by
/// screen. Under Reduce Motion a curve snaps (`nil`); a panel, which must still read as a
/// change, crossfades instead. Do not substitute a shorter ease.
enum HXMotion {
    /// What a panel does under Reduce Motion, and what the deck does instead of flying a card.
    static let crossfade: Animation = .easeInOut(duration: 0.2)
    /// Rows in a list arriving one after another.
    static let rowStagger = 0.08
    /// Dots in a calendar or strip filling one after another.
    static let dotStagger = 0.025

    // MARK: Controls

    /// A control pressed down and released.
    static func press(duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: duration, extraBounce: 0)
    }

    /// A small state flip: a pick, a rating, a toggle, a hint or control chrome showing or hiding.
    static func quickState(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    /// Expanding or collapsing in place: show more, a peek, a section opening.
    static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0)
    }

    /// The chat composer's and the session search's chrome growing and shrinking.
    static func chrome(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0)
    }

    /// Scrolling to a row in code: the latest message, last night, the current exercise.
    static func scroll(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.20)
    }

    // MARK: Content and surfaces

    /// Content replaced in place: the next page, a new question, a refreshed chart, list rows
    /// added or removed.
    static func swap(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.25, extraBounce: 0)
    }

    /// A surface arriving or leaving over the screen: the drawer, a toast, an opened card, a
    /// picker over the composer.
    static func panel(reduceMotion: Bool) -> Animation {
        reduceMotion ? crossfade : .smooth(duration: 0.3, extraBounce: 0)
    }

    /// A deck card moving: swiped, flown off, pulled back, settled, fanned, or dropped. Under
    /// Reduce Motion the deck turns its page with `crossfade` instead.
    static func card(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)
    }

    // MARK: Reveals

    /// A row or tile arriving as its card comes on top. Stagger a list with `delay`, stepping by
    /// `rowStagger`.
    static func reveal(reduceMotion: Bool, delay: Double = 0) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.35).delay(delay)
    }

    /// A mark landing: a dot filling, a star, a seal, a bot's reaction.
    static func pop(reduceMotion: Bool, delay: Double = 0) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.3).delay(delay)
    }

    /// A number counting up or a ring drawing itself, once.
    static func draw(reduceMotion: Bool, delay: Double = 0) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 1.2).delay(delay)
    }

    // MARK: Chat

    /// Expanding or collapsing the clarification card above the composer. The
    /// card slides its own height past the bar's bottom edge on one ease-out
    /// clock, sized like the keyboard's; Reduce Motion snaps.
    static func clarificationToggle(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    // MARK: Transitions

    static func bottomOverlayTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// Entrance for a transcript row born moments ago: user rows fade up,
    /// assistant rows fade. The animation rides on the transition itself, so
    /// the row animates without wrapping the message append in `withAnimation`
    /// and without animating layout (the bottom anchor still snaps). Removal
    /// stays instant so an optimistic rollback never lingers. Reduce Motion
    /// disables the entrance entirely.
    static func freshRowTransition(isUserRow: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        let insertion: AnyTransition = isUserRow ? .opacity.combined(with: .offset(y: 8)) : .opacity
        return .asymmetric(insertion: insertion, removal: .identity)
            .animation(.smooth(duration: 0.22, extraBounce: 0))
    }
}
