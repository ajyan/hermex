import SwiftUI

// Small pieces Baki's coaching shares across the workout, Body home and the Form page: the slot a
// lift's cue diagram will fill, the focus pips, what he is watching, and the pain-score stepper.

/// Where a lift's animated cue diagram goes: a 96 pt square beside the cue on the open lift's card,
/// and a 220 pt tall stage above the title on the Form page (`large`). The diagrams ship in a later
/// change, keyed by lift id; until then the slot draws nothing and takes no room.
struct CueDiagramSlot: View {
    let liftID: String
    var large = false

    /// The square beside the cue.
    static let side: CGFloat = 96
    /// The stage's height on the Form page.
    static let largeHeight: CGFloat = 220

    var body: some View {
        EmptyView()
    }
}

/// A focus as three pips: one per earlier check, then empty rings for the days still to come.
/// 8 pt beside a cue, 10 pt on the Form page.
struct BodyFocusPips: View {
    let checks: [String]
    var size: CGFloat = 8

    var body: some View {
        HStack(spacing: size / 2) {
            ForEach(Array(WorkoutCoach.focusPips(checks).enumerated()), id: \.offset) { _, pip in
                BodySetPip(state: pip, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WorkoutCoach.focusPipsSpoken(checks)))
    }
}

/// The patterns Baki is watching, inside his card on Body home: "Watching" over one row per
/// pattern, its name with a pip per recent session, and what happens next under it.
struct BodyWatchingList: View {
    let items: [BodyWatching]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Watching")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(verbatim: WorkoutCoach.watchingCaption(items))
                    .font(AppFont.caption())
                    .foregroundStyle(.hxSecondary)
            }
            .padding(.bottom, 4)
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                if offset > 0 { BakiRule() }
                row(item)
            }
        }
    }

    private func row(_ item: BodyWatching) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: item.name)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ForEach(Array(WorkoutCoach.watchingPips(item).enumerated()), id: \.offset) { _, pip in
                        BodySetPip(state: pip)
                    }
                }
            }
            if !item.next.isEmpty {
                Text(verbatim: item.next)
                    .font(AppFont.footnote())
                    .foregroundStyle(.hxSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WorkoutCoach.watchingSpoken(item)))
    }
}

/// The 0 to 10 pain score: minus, the number, plus. The finish check and the body check before a
/// workout both use it. The first tap from no score starts at 5.
struct BodyPainStepper: View {
    let score: Int?
    let step: (Int) -> Void

    private var paper: HermexPaper { .training }

    var body: some View {
        HStack(spacing: 14) {
            button(symbol: "minus", label: "Less pain", delta: -1)
            Text(verbatim: score.map(String.init) ?? "—")
                .font(AppFont.display(style: .title2, weight: .bold))
                .foregroundStyle(paper.glow)
                .monospacedDigit()
                .frame(minWidth: 44)
                .accessibilityLabel(Text(verbatim: score.map { "Pain \($0) out of 10" } ?? "No score yet"))
            button(symbol: "plus", label: "More pain", delta: 1)
        }
    }

    private func button(symbol: String, label: String, delta: Int) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(paper.glow)
                .frame(width: 44, height: 44)
                .background(paper.wash, in: Circle())
                .overlay(Circle().strokeBorder(paper.edge, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
    }
}
