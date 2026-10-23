import SwiftUI

// A lesson as example-first cards (spec 2026-10-19 Track A, slice 3), swiped sideways: the case (a concrete
// situation and a question, with the full lesson behind "Show what went wrong"), the idea in up to three bullets
// "In your work" when the lesson has it, and "Lock it in", which hides each idea under its lead so the user recalls
// it before checking. Every card is a `.knowledge` run card; page dots sit below.
// "Picture it" was dropped on 2026-10-20: its word chips only repeated the bullets. "In code" (a prompt, Python
// or SQL that makes the idea concrete) sits after the idea when the lesson has one, and a lesson's vault diagram
// opens from "Open the diagram" under the cards (`PrepLessonDiagramButton`).

/// One card of a lesson, in swipe order.
enum PrepLessonCardKind: Hashable, CaseIterable {
    case theCase, idea, code, work, lockIn

    var title: String {
        switch self {
        case .theCase: "The case"
        case .idea: "The idea"
        case .code: "In code"
        case .work: "In your work"
        case .lockIn: "Lock it in"
        }
    }

    /// The cards this lesson has, in order.
    static func cards(for cards: PrepLessonCards) -> [PrepLessonCardKind] {
        allCases.filter {
            switch $0 {
            case .theCase, .idea, .lockIn: true
            case .code: cards.code != nil
            case .work: cards.inYourWork != nil
            }
        }
    }
}

/// The lesson's cards, paged sideways, with page dots. The pager takes the current card's height, so a long card
/// never spills over what follows. Reduce Motion keeps the swipe (a gesture the user drives).
struct PrepLessonCardsView: View {
    let title: String
    let cards: PrepLessonCards
    /// The lesson's full worked explanation, which answers the case's question.
    let ideaMD: String
    @State private var page: PrepLessonCardKind? = .theCase
    @State private var revealed = false
    /// The idea bullets recalled on "Lock it in", by index.
    @State private var recalled: Set<Int> = []
    /// Each card's natural height, measured as it lays out.
    @State private var heights: [PrepLessonCardKind: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kinds: [PrepLessonCardKind] { PrepLessonCardKind.cards(for: cards) }

    var body: some View {
        VStack(spacing: BrainStyle.m) {
            ScrollView(.horizontal) {
                // Eager: a lesson has at most five cards, and each is measured before it is shown.
                HStack(alignment: .top, spacing: BrainStyle.m) {
                    ForEach(Array(kinds.enumerated()), id: \.element) { offset, kind in
                        PrepRunCard {
                            Text(verbatim: "\(offset + 1) of \(kinds.count) · \(kind.title)")
                                .font(BrainStyle.meta)
                                .foregroundStyle(HermexPaper.knowledge.glow)
                            card(kind)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[kind] = $0 }
                        .containerRelativeFrame(.horizontal)
                        .id(kind)
                    }
                }
                .scrollTargetLayout()
            }
            .frame(height: heights[page ?? .theCase], alignment: .top)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: page)
            .scrollTargetBehavior(.viewAligned)  // .paging pages by the view width and drifts by the spacing
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
        case .code:
            if let code = cards.code {
                PrepCodeBlock(code: code)
                if let caption = code.caption {
                    Text(verbatim: caption)
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.hxTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                                Text(verbatim: "Tap to check")
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
                Text(verbatim: "Locked in.")
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

/// The lesson's idea leads, each with its first sentence, after its question is graded, so the rep ends on what
/// to remember.
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
                        VStack(alignment: .leading, spacing: BrainStyle.xs) {
                            Text(verbatim: PrepCopy.ideaLead(bullet.lead))
                                .font(AppFont.body(weight: .semibold))
                                .foregroundStyle(Color.hxTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: PrepCopy.takeawayLine(bullet.text))
                                .font(AppFont.body())
                                .foregroundStyle(Color.hxTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Reads a lesson diagram's `atlas-ui` fragment from the screen's server. Prep screens put it in the environment,
/// so every `PrepLessonBody` can open its diagram without threading a client through.
struct PrepDiagramLoader: Sendable {
    let client: PrepDataClient?

    func callAsFunction(_ topic: String) async throws -> String {
        guard let client else { throw CancellationError() }
        return try await client.diagram(topic: topic).html
    }
}

private struct PrepDiagramLoaderKey: EnvironmentKey {
    static let defaultValue = PrepDiagramLoader(client: nil)
}

extension EnvironmentValues {
    var prepDiagramLoader: PrepDiagramLoader {
        get { self[PrepDiagramLoaderKey.self] }
        set { self[PrepDiagramLoaderKey.self] = newValue }
    }
}

/// "Open the diagram" under a lesson's cards: the Brief's secondary button in the knowledge paper, opening the
/// diagram in the shared `DiagramSheet`.
struct PrepLessonDiagramButton: View {
    let diagram: PrepDiagramRef
    @Environment(\.prepDiagramLoader) private var loader
    @State private var isOpen = false

    var body: some View {
        if loader.client != nil {
            Button { isOpen = true } label: { OpenDiagramLabel(paper: .knowledge) }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Open the diagram: \(diagram.title)"))
            .accessibilityHint(Text(verbatim: "Opens an interactive diagram"))
            .sheet(isPresented: $isOpen) {
                DiagramSheet(title: diagram.title) { [loader, topic = diagram.topic] in try await loader(topic) }
            }
        }
    }
}

/// The "In code" artifact: monospaced on an inset, small enough that an authored 46-column line fits a phone card;
/// anything wider scrolls sideways inside the block, never the card.
struct PrepCodeBlock: View {
    let code: PrepLessonCards.Code

    var body: some View {
        ScrollView(.horizontal) {
            Text(verbatim: code.body)
                .font(AppFont.mono(style: .caption))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(BrainStyle.m)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hxCanvas, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
            .strokeBorder(HermexPaper.knowledge.edge, lineWidth: 1))
        .accessibilityLabel(Text(verbatim: "Code, \(code.lang): \(code.body)"))
    }
}
