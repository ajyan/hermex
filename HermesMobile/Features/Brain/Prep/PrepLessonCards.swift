import SwiftUI

// A lesson as example-first cards (spec 2026-10-19 Track A, slice 3), swiped sideways: the case (a concrete
// situation and a question, with the full lesson behind "Show what went wrong"), the idea in up to three bullets
// and "In your work" when the lesson has it. Every card is a `.knowledge` run card; page dots sit below.
// "Picture it" was dropped on 2026-10-20: its word chips only repeated the bullets. "In code" (a prompt, Python
// or SQL that makes the idea concrete) sits after the idea when the lesson has one, and a lesson's vault diagram
// opens from "Open the diagram" under the cards (`PrepLessonDiagramButton`).

/// One card of a lesson, in swipe order.
enum PrepLessonCardKind: Hashable, CaseIterable {
    case theCase, idea, code, work

    var title: String {
        switch self {
        case .theCase: "The case"
        case .idea: "The idea"
        case .code: "In code"
        case .work: "In your work"
        }
    }

    /// The cards this lesson has, in order.
    static func cards(for cards: PrepLessonCards) -> [PrepLessonCardKind] {
        allCases.filter {
            switch $0 {
            case .theCase, .idea: true
            case .code: cards.code != nil
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
        case .code:
            if let code = cards.code {
                MarkdownRenderer(content: code.markdown)
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
        }
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
            Button { isOpen = true } label: {
                Label { Text(verbatim: "Open the diagram") } icon: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(HermexPaper.knowledge.glow)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(HermexPaper.knowledge.wash, in: Capsule())
                .overlay(Capsule().strokeBorder(HermexPaper.knowledge.edge, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Open the diagram: \(diagram.title)"))
            .accessibilityHint(Text(verbatim: "Opens an interactive diagram"))
            .sheet(isPresented: $isOpen) {
                DiagramSheet(title: diagram.title) { [loader, topic = diagram.topic] in try await loader(topic) }
            }
        }
    }
}
