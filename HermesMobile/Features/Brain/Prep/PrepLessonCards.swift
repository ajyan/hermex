import SwiftUI

// A lesson as example-first cards (spec 2026-10-19 Track A, slice 3), swiped sideways: the case (a concrete
// situation and a question), the idea in up to three bullets, "Picture it" (a flow of small boxes) and "In your
// work", each card only when the lesson has it. Every card is a `.knowledge` run card; page dots sit below.

/// One card of a lesson, in swipe order.
enum PrepLessonCardKind: Hashable, CaseIterable {
    case theCase, idea, picture, work

    var title: String {
        switch self {
        case .theCase: "The case"
        case .idea: "The idea"
        case .picture: "Picture it"
        case .work: "In your work"
        }
    }

    /// The cards this lesson has, in order.
    static func cards(for cards: PrepLessonCards) -> [PrepLessonCardKind] {
        allCases.filter {
            switch $0 {
            case .theCase, .idea: true
            case .picture: cards.picture != nil
            case .work: cards.inYourWork != nil
            }
        }
    }
}

/// The lesson's cards, paged sideways, with page dots. Reduce Motion keeps the swipe (a gesture the user drives).
struct PrepLessonCardsView: View {
    let title: String
    let cards: PrepLessonCards
    @State private var page: PrepLessonCardKind? = .theCase

    private var kinds: [PrepLessonCardKind] { PrepLessonCardKind.cards(for: cards) }

    var body: some View {
        VStack(spacing: BrainStyle.m) {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: BrainStyle.m) {
                    ForEach(Array(kinds.enumerated()), id: \.element) { offset, kind in
                        PrepRunCard {
                            Text(verbatim: "\(offset + 1) of \(kinds.count) · \(kind.title)")
                                .font(BrainStyle.meta)
                                .foregroundStyle(HermexPaper.knowledge.glow)
                            card(kind)
                            Spacer(minLength: 0)
                        }
                        .containerRelativeFrame(.horizontal)
                        .id(kind)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            if kinds.count > 1 {
                HStack(spacing: BrainStyle.s) {
                    ForEach(kinds, id: \.self) { kind in
                        Circle()
                            .fill(kind == (page ?? .theCase) ? HermexPaper.knowledge.glow : Color.hxSeparator)
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: PrepCopy.cardPageLabel(page: page ?? .theCase, in: kinds)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: title))
    }

    @ViewBuilder
    private func card(_ kind: PrepLessonCardKind) -> some View {
        switch kind {
        case .theCase:
            Text(verbatim: cards.theCase.headline)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .foregroundStyle(HermexPaper.knowledge.glow)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: cards.theCase.body)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: cards.theCase.ask)
                .font(BrainStyle.rowTitle)
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .idea:
            VStack(alignment: .leading, spacing: BrainStyle.m) {
                ForEach(Array(cards.idea.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
                        Circle().fill(HermexPaper.knowledge.glow).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                            .accessibilityHidden(true)
                        (Text(verbatim: bullet.lead).bold() + Text(verbatim: " \(bullet.text)"))
                            .font(AppFont.body())
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .picture:
            if let picture = cards.picture {
                PrepFlowPicture(picture: picture)
            }
        case .work:
            if let work = cards.inYourWork {
                Text(verbatim: work)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// "Picture it": small bordered boxes joined by arrows, wrapping on a narrow screen, with optional labels under
/// the first and last box.
struct PrepFlowPicture: View {
    let picture: PrepLessonCards.Picture

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            FlowRow(spacing: BrainStyle.xs) {
                ForEach(Array(picture.steps.enumerated()), id: \.offset) { offset, step in
                    HStack(spacing: BrainStyle.xs) {
                        if offset > 0 {
                            Image(systemName: "arrow.right")
                                .font(BrainStyle.meta)
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                        Text(verbatim: step)
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .padding(.horizontal, BrainStyle.s)
                            .padding(.vertical, BrainStyle.xs)
                            .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
                                .strokeBorder(HermexPaper.knowledge.edge, lineWidth: 1))
                    }
                }
            }
            if picture.startLabel != nil || picture.endLabel != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let start = picture.startLabel {
                        Text(verbatim: "↑ \(start)")
                    }
                    Spacer(minLength: BrainStyle.s)
                    if let end = picture.endLabel {
                        Text(verbatim: "\(end) ↑")
                    }
                }
                .font(BrainStyle.meta)
                .foregroundStyle(HermexPaper.knowledge.glow)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PrepCopy.pictureLabel(picture)))
    }
}
