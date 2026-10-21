import SwiftUI

// A lesson as example-first cards (spec 2026-10-19 Track A, slice 3), swiped sideways: the case (a concrete
// situation and a question, with the full lesson behind "Show what went wrong"), the idea in up to three bullets
// "In your work" when the lesson has it, and "Lock it in", which hides each idea under its lead so the user recalls
// it before checking. Every card is a `.knowledge` run card; page dots sit below.
// "Picture it" was dropped on 2026-10-20: its word chips only repeated the bullets.

/// One card of a lesson, in swipe order.
enum PrepLessonCardKind: Hashable, CaseIterable {
    case theCase, idea, work, lockIn

    var title: String {
        switch self {
        case .theCase: "The case"
        case .idea: "The idea"
        case .work: "In your work"
        case .lockIn: "Lock it in"
        }
    }

    /// The cards this lesson has, in order.
    static func cards(for cards: PrepLessonCards) -> [PrepLessonCardKind] {
        allCases.filter {
            switch $0 {
            case .theCase, .idea, .lockIn: true
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
    /// The idea bullets recalled on "Lock it in", by index.
    @State private var recalled: Set<Int> = []
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
                    VStack(alignment: .leading, spacing: BrainStyle.s) {
                        PrepCardLabel(title: "What went wrong")
                        MarkdownRenderer(content: ideaMD)
                    }
                    .transition(.opacity)
                } else {
                    Text(verbatim: "Make your call before you look.")
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextSecondary)
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
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                ForEach(Array(cards.idea.enumerated()), id: \.offset) { index, bullet in
                    PrepIdeaPoint(number: index + 1, lead: bullet.lead) {
                        Text(verbatim: bullet.text)
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
        case .lockIn:
            Text(verbatim: PrepCopy.lockInPrompt(cards.idea.count))
                .font(BrainStyle.rowTitle)
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                ForEach(Array(cards.idea.enumerated()), id: \.offset) { index, bullet in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { recalled.formSymmetricDifference([index]) }
                    } label: {
                        PrepIdeaPoint(number: index + 1, lead: bullet.lead) {
                            if recalled.contains(index) {
                                Text(verbatim: bullet.text)
                                    .font(AppFont.body())
                                    .foregroundStyle(Color.hxTextPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .transition(.opacity)
                            } else {
                                Text(verbatim: "Say it, then tap to check")
                                    .font(BrainStyle.rowTitle)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Text(verbatim: recalled.contains(index) ? "Hides it again" : "Shows the answer"))
                }
            }
            if recalled.count == cards.idea.count {
                Text(verbatim: "Now try the question.")
                    .font(BrainStyle.meta)
                    .foregroundStyle(HermexPaper.knowledge.glow)
                    .transition(.opacity)
            }
        }
    }
}

/// A small label inside a lesson card, in the Prep paper's glow.
private struct PrepCardLabel: View {
    let title: String

    var body: some View {
        Text(verbatim: title)
            .font(AppFont.display(style: .subheadline, weight: .semibold))
            .foregroundStyle(HermexPaper.knowledge.glow)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One idea point: its number, its lead as a short heading, and what it says (or a "tap to check" on Lock it in).
private struct PrepIdeaPoint<Detail: View>: View {
    let number: Int
    let lead: String
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.m) {
            Text(verbatim: "\(number)")
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(HermexPaper.knowledge.glow)
                .monospacedDigit()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: PrepCopy.ideaLead(lead))
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
        }
    }
}

/// The lesson's idea leads after its question is graded, so the rep ends on what to remember.
struct PrepTakeaway: View {
    let idea: [PrepLessonCards.Bullet]

    var body: some View {
        PrepRunCard {
            PrepCardLabel(title: "Take with you")
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                ForEach(Array(idea.enumerated()), id: \.offset) { index, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: BrainStyle.m) {
                        Text(verbatim: "\(index + 1)")
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(HermexPaper.knowledge.glow)
                            .monospacedDigit()
                            .accessibilityHidden(true)
                        Text(verbatim: PrepCopy.ideaLead(bullet.lead))
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
