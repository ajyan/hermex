import SwiftUI

// A lesson as example-first cards (spec 2026-10-19 Track A, slice 3), swiped sideways: the case (a concrete
// situation and a question, with the full lesson behind "Show what went wrong"), the idea in up to three bullets
// and "In your work" when the lesson has it. Every card is a `.knowledge` run card; page dots sit below.
// "Picture it" was dropped on 2026-10-20: its word chips only repeated the bullets.

/// One card of a lesson, in swipe order.
enum PrepLessonCardKind: Hashable, CaseIterable {
    case theCase, idea, work

    var title: String {
        switch self {
        case .theCase: "The case"
        case .idea: "The idea"
        case .work: "In your work"
        }
    }

    /// The cards this lesson has, in order.
    static func cards(for cards: PrepLessonCards) -> [PrepLessonCardKind] {
        allCases.filter {
            switch $0 {
            case .theCase, .idea: true
            case .work: cards.inYourWork != nil
            }
        }
    }
}

/// The lesson's cards, paged sideways, with page dots. Reduce Motion keeps the swipe (a gesture the user drives).
struct PrepLessonCardsView: View {
    let title: String
    let cards: PrepLessonCards
    /// The lesson's full worked explanation, which answers the case's question.
    let ideaMD: String
    @State private var page: PrepLessonCardKind? = .theCase
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            Text(verbatim: PrepCopy.caseBody(cards.theCase.body))
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: cards.theCase.ask)
                .font(BrainStyle.rowTitle)
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !ideaMD.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if revealed {
                    MarkdownRenderer(content: ideaMD)
                        .transition(.opacity)
                } else {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { revealed = true }
                    } label: {
                        Text(verbatim: "Show what went wrong")
                            .font(BrainStyle.rowTitle)
                            .frame(minHeight: BrainStyle.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
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
