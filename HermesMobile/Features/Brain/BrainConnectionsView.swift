import SwiftUI

/// The reader's connection decisions, kept out of the views so they can be tested.
enum BrainConnectionsLayout {
    /// Linked mentions shown before "Show all N".
    static let mentionPreviewCount = 5

    /// The linked-page cards: the page's links without repeats or itself, in server order,
    /// and without what the page already shows elsewhere: its hub (the trail names it) and,
    /// on a hub, its own pages (In this hub lists them).
    static func linkCards(_ page: BrainPage) -> [BrainRef] {
        var seen: Set<String> = [page.item.id]
        if let hub = page.hub { seen.insert(hub.ref.id) }
        seen.formUnion(page.hubPages.map(\.id))
        return page.links.filter { seen.insert($0.id).inserted }
    }

    /// The hub's pages shown before "Show all N" on the hub itself.
    static let hubPreviewCount = 3

    /// A hub's own pages as its page lists them: without the hub it sits in itself, which
    /// the trail and the pager already name.
    static func hubPages(_ page: BrainPage) -> [BrainRef] {
        page.hubPages.filter { $0.id != page.hub?.ref.id && $0.id != page.item.id }
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

    /// Where the mention sits in the snippet: the first case-insensitive match, or nil.
    static func mentionRange(in snippet: String, mention: String) -> Range<String.Index>? {
        let needle = mention.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        return snippet.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// A mention longer than this (usually a page's full title) is marked in the glow only,
    /// without the wash, so it doesn't swamp the words around it.
    static let longMention = 30

    /// The snippet with the mention marked in the page's paper.
    static func highlighted(_ snippet: String, mention: String, paper: HermexPaper) -> AttributedString {
        var text = AttributedString(snippet)
        guard let range = mentionRange(in: snippet, mention: mention),
              let lower = AttributedString.Index(range.lowerBound, within: text),
              let upper = AttributedString.Index(range.upperBound, within: text)
        else { return text }
        text[lower..<upper].foregroundColor = paper.glow
        if mention.count <= longMention {
            text[lower..<upper].backgroundColor = paper.wash
        }
        text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        return text
    }

    /// "Showing 8 of 13" under a capped list; nil when every item is shown.
    static func cappedFooter(shown: Int, total: Int) -> String? {
        total > shown ? "Showing \(shown) of \(total)" : nil
    }
}

/// Where the page sits: "Brain", then its hub when it has one. Both are Nous blue, since they
/// navigate: "Brain" goes to the Brain home from any page, including one opened from chat.
struct BrainTrail: View {
    let hub: BrainRef?
    @Environment(\.openBrainRoute) private var openBrainRoute

    var body: some View {
        HStack(spacing: BrainStyle.xs) {
            Button { openBrainRoute.openHome() } label: {
                Text(verbatim: "Brain")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            // A taller hit area than the line draws, so the trail stays compact.
            .contentShape(.interaction, Rectangle().inset(by: -11))
            .disabled(openBrainRoute.homeHandler == nil)
            .accessibilityLabel(Text(verbatim: "Brain home"))
            if let hub {
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
                                .zoomSource(for: .brainRoute(.page(ref.module, ref.id)), cornerRadius: HXRadius.md)
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
/// Tapping where you are lists the hub's pages.
struct BrainHubPager: View {
    let hub: BrainHubContext
    let onStep: (Int) -> Void
    var onShowPages: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 0) {
            stepButton(-1, ref: hub.prev, symbol: "chevron.backward", label: "Previous")
            Button { onShowPages?() } label: {
                VStack(spacing: 1) {
                    // At accessibility sizes the hub's name is in the trail; the bar keeps the place.
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(verbatim: hub.ref.title)
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .lineLimit(1)
                    }
                    if let position = BrainConnectionsLayout.position(hub) {
                        Text(verbatim: position)
                            .font(AppFont.caption2())
                            .foregroundStyle(Color.hxTextSecondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onShowPages == nil || hub.pages.isEmpty)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(verbatim: "Lists the pages in this hub"))
            stepButton(1, ref: hub.next, symbol: "chevron.forward", label: "Next")
        }
        .padding(.horizontal, BrainStyle.xs)
        // Opaque under the glass, so body text scrolling beneath never shows through the labels.
        .background(Color.hxSurface, in: Capsule())
        .adaptiveGlass(isInteractive: true, tint: Color.hxSurface, in: Capsule())
        .hxShadow(.float)
    }

    private func stepButton(_ step: Int, ref: BrainRef?, symbol: String, label: String) -> some View {
        Button { onStep(step) } label: {
            Image(systemName: symbol)
                .font(AppFont.body(weight: .semibold))
                .frame(minWidth: BrainStyle.minTapTarget, minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ref == nil ? Color.hxTextSecondary.opacity(0.4) : Color.accentColor)
        .disabled(ref == nil)
        .accessibilityLabel(Text(verbatim: ref.map { "\(label): \($0.title)" } ?? label))
    }
}

/// A hub's pages, in pager order, the current one checked. Picking another closes the sheet
/// and the reader moves to it, as a pager step would.
struct BrainHubPagesSheet: View {
    let hub: BrainHubContext
    let currentID: String
    let onPick: (BrainRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var numberWidth = BrainStyle.searchThumbnailSize

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(hub.pages.enumerated()), id: \.element.id) { index, ref in
                    let isCurrent = ref.id == currentID
                    Button {
                        dismiss()
                        if !isCurrent { onPick(ref) }
                    } label: {
                        HStack(spacing: BrainStyle.m) {
                            Text(verbatim: "\(index + 1)")
                                .brainText(.meta)
                                .monospacedDigit()
                                .frame(width: numberWidth, alignment: .trailing)
                            BrainRow(title: ref.title.isEmpty ? ref.id : ref.title, subtitle: ref.snippet)
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .font(BrainStyle.rowSubtitle.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.hxSurface)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.hxCanvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: hub.ref.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
