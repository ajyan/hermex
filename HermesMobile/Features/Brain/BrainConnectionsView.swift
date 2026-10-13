import SwiftUI

/// The reader's connection decisions, kept out of the views so they can be tested.
enum BrainConnectionsLayout {
    /// Linked mentions shown before "Show all N".
    static let mentionPreviewCount = 5
    /// A horizontal drag this long, and mostly sideways, pages through the hub.
    static let swipeDistance: CGFloat = 80

    /// The linked-page cards: the page's links without repeats or itself, in server order.
    static func linkCards(_ page: BrainPage) -> [BrainRef] {
        var seen: Set<String> = [page.item.id]
        return page.links.filter { seen.insert($0.id).inserted }
    }

    /// A page with links shows them as cards under the title; one without keeps its cover.
    static func showsCover(_ page: BrainPage) -> Bool {
        linkCards(page).isEmpty
    }

    /// The pager shows only when the page sits in its hub's list and has a neighbour there.
    static func showsPager(_ hub: BrainHubContext?) -> Bool {
        guard let hub, hub.index != nil else { return false }
        return hub.prev != nil || hub.next != nil
    }

    /// "4 of 14", the page's place among its hub's pages.
    static func position(_ hub: BrainHubContext) -> String? {
        guard let index = hub.index, hub.count > 0 else { return nil }
        return "\(index + 1) of \(hub.count)"
    }

    /// +1 for a swipe left (next page), -1 for a swipe right (previous), nil otherwise.
    static func swipeStep(_ translation: CGSize) -> Int? {
        guard abs(translation.width) >= swipeDistance,
              abs(translation.width) > abs(translation.height) * 2
        else { return nil }
        return translation.width < 0 ? 1 : -1
    }

    /// Where the mention sits in the snippet: the first case-insensitive match, or nil.
    static func mentionRange(in snippet: String, mention: String) -> Range<String.Index>? {
        let needle = mention.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return snippet.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// The snippet with the mention marked in the page's paper.
    static func highlighted(_ snippet: String, mention: String, paper: HermexPaper) -> AttributedString {
        var text = AttributedString(snippet)
        guard let range = mentionRange(in: snippet, mention: mention),
              let lower = AttributedString.Index(range.lowerBound, within: text),
              let upper = AttributedString.Index(range.upperBound, within: text)
        else { return text }
        text[lower..<upper].foregroundColor = paper.glow
        text[lower..<upper].backgroundColor = paper.wash
        text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        return text
    }

    /// "Showing 8 of 13" under a capped list; nil when every item is shown.
    static func cappedFooter(shown: Int, total: Int) -> String? {
        total > shown ? "Showing \(shown) of \(total)" : nil
    }
}

/// Where the page sits: "Brain › <hub>", the hub tappable. Nous blue, since it navigates.
struct BrainTrail: View {
    let hub: BrainRef

    var body: some View {
        HStack(spacing: BrainStyle.xs) {
            Text(verbatim: "Brain")
                .foregroundStyle(Color.hxTextSecondary)
            Image(systemName: "chevron.forward")
                .font(BrainStyle.meta.weight(.semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .accessibilityHidden(true)
            NavigationLink(value: ShellPushDestination.brainRoute(.page(hub.module, hub.id))) {
                Text(verbatim: hub.title.isEmpty ? hub.id : hub.title)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "In \(hub.title), open"))
        }
        .font(BrainStyle.rowSubtitle)
        .frame(minHeight: BrainStyle.minTapTarget / 2, alignment: .leading)
    }
}

/// The pages this page links to, as a sideways row of small glow cards in each kind's paper.
struct BrainLinkCardsRow: View {
    let refs: [BrainRef]

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Links to", count: refs.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: BrainStyle.s) {
                    ForEach(refs, id: \.id) { ref in
                        NavigationLink(value: ShellPushDestination.brainRoute(.page(ref.module, ref.id))) {
                            BrainLinkCard(ref: ref)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }
}

/// One linked page: its kind, title and opening line on a wash of its paper.
struct BrainLinkCard: View {
    let ref: BrainRef
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 156
    /// One height for every card in the row: a two-line title and a two-line snippet.
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 118

    var body: some View {
        let paper = ref.module.paper
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            Text(verbatim: ref.module.kindName)
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(paper.glow)
            Text(verbatim: ref.title.isEmpty ? ref.id : ref.title)
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(paper.glow)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !ref.snippet.isEmpty {
                Text(verbatim: ref.snippet)
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(width: width, height: height, alignment: .topLeading)
        .glowSurface(paper, cornerRadius: HXRadius.md)
        .contentShape(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [ref.title, ref.module.kindName, ref.snippet]
            .filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(.isLink)
    }
}

/// Linked or unlinked mentions: each source, then the words around the mention with the
/// mention marked in the page's paper. Rows open the source.
struct BrainMentionSection: View {
    let title: String
    let count: Int
    let refs: [BrainRef]
    /// The page being read, whose paper marks the mention.
    let paper: HermexPaper
    var footer: String?
    var showAllTitle: String?
    var onShowAll: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: title, count: count)
            VStack(spacing: 0) {
                // Rows never reorder ("Show all" only appends), so position is a stable id.
                ForEach(Array(refs.enumerated()), id: \.offset) { index, ref in
                    if index > 0 { separator }
                    NavigationLink(value: ShellPushDestination.brainRoute(.page(ref.module, ref.id))) {
                        BrainMentionRow(ref: ref, paper: paper)
                    }
                    .buttonStyle(.plain)
                }
                if let showAllTitle {
                    separator
                    Button(action: onShowAll) {
                        Text(verbatim: showAllTitle)
                            .font(BrainStyle.rowSubtitle)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, BrainStyle.cardHorizontalPadding)
            .brainCardSurface()
            if let footer {
                Text(verbatim: footer)
                    .brainText(.meta)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color.hxSeparator).frame(height: 0.5).accessibilityHidden(true)
    }
}

/// One mention: a kind dot and the source's title, then the snippet with the mention marked.
struct BrainMentionRow: View {
    let ref: BrainRef
    let paper: HermexPaper
    @ScaledMetric(relativeTo: .subheadline) private var dot: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            HStack(spacing: BrainStyle.s) {
                Circle()
                    .fill(ref.module.paper.glow)
                    .frame(width: dot, height: dot)
                    .accessibilityHidden(true)
                Text(verbatim: ref.title.isEmpty ? ref.id : ref.title)
                    .font(BrainStyle.rowSubtitle.weight(.semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(BrainStyle.meta.weight(.semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .accessibilityHidden(true)
            }
            if !ref.snippet.isEmpty {
                Text(BrainConnectionsLayout.highlighted(ref.snippet, mention: ref.mention, paper: paper))
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(Color.hxTextSecondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, BrainStyle.m)
        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A glass bar over the page's foot: previous and next in the hub, and where you are.
struct BrainHubPager: View {
    let hub: BrainHubContext
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton(-1, ref: hub.prev, symbol: "chevron.backward", label: "Previous")
            VStack(spacing: 1) {
                Text(verbatim: hub.ref.title)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
                if let position = BrainConnectionsLayout.position(hub) {
                    Text(verbatim: position)
                        .font(AppFont.caption2())
                        .foregroundStyle(Color.hxTextSecondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            stepButton(1, ref: hub.next, symbol: "chevron.forward", label: "Next")
        }
        .padding(.horizontal, BrainStyle.xs)
        // Surface-tinted so the labels stay legible over body text scrolling beneath.
        .adaptiveGlass(isInteractive: true, tint: Color.hxSurface.opacity(0.75), in: Capsule())
        .hxShadow(.float)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func stepButton(_ step: Int, ref: BrainRef?, symbol: String, label: String) -> some View {
        Button { onStep(step) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: BrainStyle.minTapTarget, height: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ref == nil ? Color.hxTextSecondary.opacity(0.4) : Color.accentColor)
        .disabled(ref == nil)
        .accessibilityLabel(Text(verbatim: ref.map { "\(label): \($0.title)" } ?? label))
    }
}

#if DEBUG
#Preview("Connections") {
    let refs = [
        BrainRef(module: .wiki, id: "wiki/openai.md", title: "OpenAI", snippet: "The lab behind GPT and Codex."),
        BrainRef(module: .people, id: "crm/contacts/sam.md", title: "Sam Rivera"),
        BrainRef(module: .journal, id: "journal/2026-09-01.md", title: "Monday 1 September")
    ]
    let mentions = [
        BrainRef(module: .wiki, id: "wiki/openai.md", title: "OpenAI",
                 snippet: "Anthropic is the safety-first counterpart; the two define the frontier.", mention: "Anthropic")
    ]
    let hub = BrainHubContext(ref: BrainRef(module: .wiki, id: "wiki/career.md", title: "Software Engineer Career"),
                              index: 3, count: 14, prev: refs[0], next: refs[0])
    return NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                BrainTrail(hub: hub.ref)
                BrainLinkCardsRow(refs: refs)
                BrainMentionSection(title: "Linked mentions", count: 1, refs: mentions, paper: .wiki)
            }
            .padding(BrainStyle.l)
        }
        .safeAreaInset(edge: .bottom) { BrainHubPager(hub: hub) { _ in }.padding(.horizontal, BrainStyle.l) }
        .background(Color.hxCanvas)
    }
}
#endif
