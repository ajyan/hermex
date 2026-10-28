import SwiftUI

extension BodyDayState {
    /// The `DeckDot` state this day wears: done filled, today ringed, ahead dashed, a rest day a
    /// faint ring, and a day the server didn't classify a small mark.
    var deckDotState: String {
        switch self {
        case .done: "done"
        case .today: "today"
        case .ahead: "ahead"
        case .off: "missed"
        case .unknown: "off"
        }
    }
}

/// One Monday-to-Sunday row of day dots on Body home ("Lifted", "Ran"), in the Daily Brief's dot
/// language and columns. The weekday letters sit above the first row only (`showsWeekdays`).
struct BodyWeekDots: View {
    let title: String
    var subtitle: String?
    let states: [BodyDayState]
    var showsWeekdays = false

    private var ink: Color { HermexPaper.training.glow }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsWeekdays { weekdays }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(AppFont.caption())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
                Spacer(minLength: 8)
                ForEach(0..<7, id: \.self) { index in
                    DeckDot(state: state(at: index).deckDotState, ink: ink)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: Self.summary(states)))
    }

    private var weekdays: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 8)
            ForEach(0..<7, id: \.self) { index in
                Text(verbatim: DeckDots.weekdays[index])
                    .font(AppFont.caption2(weight: state(at: index) == .today ? .heavy : nil))
                    .foregroundStyle(state(at: index) == .today ? Color.hxTextPrimary : Color.hxTextSecondary)
                    .frame(width: DeckDots.column)
            }
        }
        .accessibilityHidden(true)
    }

    private func state(at index: Int) -> BodyDayState {
        index < states.count ? states[index] : .unknown
    }

    /// "3 of 7 days" for VoiceOver, since the dots carry no text.
    static func summary(_ states: [BodyDayState]) -> String {
        let done = states.filter { $0 == .done }.count
        return done == 1 ? "1 day done this week" : "\(done) days done this week"
    }
}
