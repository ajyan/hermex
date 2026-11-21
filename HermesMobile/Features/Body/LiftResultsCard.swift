import SwiftUI

/// One work set as a 10 pt pip in the training glow: filled when it was done at its goal, a glow
/// ring when it was done short of it, and an empty ring when it wasn't done (a separator ring on a
/// neutral card, the paper's edge on a glow or wash card, where a separator would vanish). The lift-by-lift
/// results draw all three; Body home's lift rows get a yes or no per set from the server, so
/// theirs are filled or a glow ring. Baki's focus and watching pips are the same three marks;
/// the focus pips beside a cue are 8 pt.
struct BodySetPip: View {
    let state: LiftPip
    var size: CGFloat = 10
    @Environment(\.hxPaper) private var paper

    var body: some View {
        // Body's glow, or the card's own on a review card in another paper.
        let glow = (paper ?? .training).glow
        Circle()
            .strokeBorder(state == .notDone ? (paper?.edge ?? Color.hxSeparator) : glow, lineWidth: 1.5)
            .background(Circle().fill(state == .hit ? glow : Color.clear))
            .frame(width: size, height: size)
    }
}

/// A workout lift by lift, under a "Lifts" header: one neutral card with a row per lift, each a
/// row of pips for this workout over a row for the time before, its weight, and whether it went
/// up or down. The finish screen shows it once the workout is saved (`.today`), and a past
/// workout's page shows it with rows that open the lift's history (`.past`).
struct LiftResultsCard: View {
    let session: BodySession
    var frame: LiftResultsFrame = .today
    /// Each row opens its lift's history.
    var opensLifts = false

    var body: some View {
        let results = LiftResults.results(session)
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HXSectionHeader(title: "Lifts", trailing: frame.caption)
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { offset, result in
                        if offset > 0 { PrepRowDivider().padding(.leading, 14) }
                        if opensLifts {
                            NavigationLink(value: ShellPushDestination.bodyLift(result.id)) {
                                LiftResultRow(result: result, frame: frame, showsChevron: true)
                            }
                            .buttonStyle(.chatTactile(.card))
                            .accessibilityHint(Text(verbatim: "Opens this lift's history"))
                        } else {
                            LiftResultRow(result: result, frame: frame, showsChevron: false)
                        }
                    }
                }
                .hxCard()
            }
        }
    }
}

/// One lift in `LiftResultsCard`. At accessibility text sizes the weight drops under the pips, so
/// neither is squeezed.
private struct LiftResultRow: View {
    let result: LiftResult
    let frame: LiftResultsFrame
    let showsChevron: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var paper: HermexPaper { .training }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 7) {
                    sets
                    weight(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                sets.frame(maxWidth: .infinity, alignment: .leading)
                weight(alignment: .trailing)
            }
            if showsChevron { BodyChevron() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: LiftResults.spoken(result, frame: frame)))
    }

    /// The name over the two rows of pips. Both rows start in the same column and step by the same
    /// pitch, so set 2 today sits over set 2 last time.
    private var sets: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: result.name)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    label(frame.rowLabel)
                    pips(result.now)
                }
                if !result.last.isEmpty {
                    GridRow {
                        label(LiftResultsFrame.lastLabel)
                        pips(result.last)
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppFont.caption2())
            .foregroundStyle(.hxSecondary)
    }

    private func pips(_ states: [LiftPip]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                BodySetPip(state: state)
            }
        }
    }

    /// The weight, and under it how the lift compares: up in the training glow, down or the same
    /// in secondary text.
    private func weight(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(verbatim: result.weightLabel)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            if let change = result.change {
                HStack(spacing: 3) {
                    if let up = change.isUp {
                        Image(systemName: up ? "arrow.up" : "arrow.down")
                            .font(AppFont.caption2(weight: .semibold))
                    }
                    Text(verbatim: change.words)
                }
                .font(AppFont.caption())
                .foregroundStyle(change.isUp == true ? AnyShapeStyle(paper.glow) : AnyShapeStyle(.hxSecondary))
            }
        }
    }
}
