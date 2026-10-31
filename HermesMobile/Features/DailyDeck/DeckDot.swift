import SwiftUI

// Shared with the Goals widget (HermesLiveActivityWidget), so it needs only SwiftUI.

/// The dot grid every front row shares, so day dots and pips line up in the same columns: one fixed
/// column per day (or pip), the dot centered in it, and every row starting at the same leading edge.
enum DeckDots {
    static let column: CGFloat = 26
    static let dot: CGFloat = 16
    static let weekdays = ["M", "T", "W", "T", "F", "S", "S"]
}

/// One dot. `ink` is the card's ink; a done day is filled, today ringed, yesterday waiting on its check-in
/// ringed with a plus, a missed day a faint ring, a skipped day half-filled, a day ahead dashed, a day it
/// isn't due a small mark.
struct DeckDot: View {
    let state: String
    let ink: Color
    /// The fixed column the dot sits centered in.
    var column: CGFloat = DeckDots.column

    var body: some View {
        ZStack {
            switch state {
            case "done":
                Circle().fill(ink)
            case "skip":
                Circle().fill(ink.opacity(0.35))
            case "today":
                Circle().strokeBorder(ink, lineWidth: 1.75)
            case "ask":
                Circle().strokeBorder(ink, lineWidth: 1.75)
                Capsule().fill(ink).frame(width: 7, height: 1.75)
                Capsule().fill(ink).frame(width: 1.75, height: 7)
            case "ahead":
                Circle().strokeBorder(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            case "off":
                Circle().fill(ink.opacity(0.2)).frame(width: 4, height: 4)
            default:  // missed
                Circle().strokeBorder(ink.opacity(0.35), lineWidth: 1)
            }
        }
        .frame(width: DeckDots.dot, height: DeckDots.dot)
        .frame(width: column)
    }
}
