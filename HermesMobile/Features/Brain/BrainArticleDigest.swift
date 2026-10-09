import SwiftUI

/// An article or video note read as a digest instead of one long page. The agent
/// writes every summary in one outline (`## One-paragraph gist`, `## Key ideas` as a
/// numbered list with **bold** headlines, `## Best quotes`, `## Connections`,
/// `## One takeaway for Andrew`); `parse` turns that outline into parts, and returns
/// nil for any page that doesn't follow it, so those keep the plain markdown reader.
struct BrainArticleDigest: Equatable {
    struct Idea: Equatable, Identifiable {
        let number: Int
        let headline: String
        /// The explanation under the headline, as markdown (may hold `brain://` links).
        let detail: String
        var id: Int { number }
    }

    struct Section: Equatable, Identifiable {
        let title: String
        let markdown: String
        var id: String { title }
    }

    var gist: String
    var ideas: [Idea]
    /// A `Key ideas` section that isn't a numbered list, shown as plain markdown.
    var ideasMarkdown: String?
    var quotes: [String]
    var takeaway: String?
    /// Every other section (Connections, The question, …), in page order.
    var otherSections: [Section]

    static func parse(_ markdown: String) -> BrainArticleDigest? {
        var gist: String?
        var ideas: [Idea] = []
        var ideasMarkdown: String?
        var quotes: [String] = []
        var takeaway: String?
        var others: [Section] = []

        for (title, body) in sections(markdown) {
            let key = title.lowercased()
            if key.hasPrefix("one-paragraph gist") || key == "gist" {
                gist = body
            } else if key.hasPrefix("key ideas") {
                let parsed = numberedIdeas(body)
                if parsed.isEmpty { ideasMarkdown = body } else { ideas = parsed }
            } else if key.hasPrefix("best quotes") {
                quotes = blockQuotes(body)
                if quotes.isEmpty, !body.isEmpty { others.append(Section(title: title, markdown: body)) }
            } else if key.contains("takeaway") {
                takeaway = body
            } else if !body.isEmpty {
                others.append(Section(title: title, markdown: body))
            }
        }
        guard let gist, !gist.isEmpty, !ideas.isEmpty || ideasMarkdown != nil else { return nil }
        return BrainArticleDigest(gist: gist, ideas: ideas, ideasMarkdown: ideasMarkdown, quotes: quotes,
                                  takeaway: takeaway, otherSections: others)
    }

    /// `## ` sections as (title, trimmed body). Text before the first heading is dropped.
    static func sections(_ markdown: String) -> [(String, String)] {
        var result: [(String, [String])] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                result.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), []))
            } else if !result.isEmpty {
                result[result.count - 1].1.append(line)
            }
        }
        return result.map { ($0.0, $0.1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static let itemStart = /^(\d+)\.\s+(.*)$/
    private static let boldLead = /^\*\*(.+?)\*\*\s*[—–:.\-]?\s*(.*)$/

    /// `1. **Headline** — explanation` items; continuation lines stay with their item.
    static func numberedIdeas(_ body: String) -> [Idea] {
        var items: [(Int, [String])] = []
        for line in body.components(separatedBy: "\n") {
            if let match = line.wholeMatch(of: itemStart), let number = Int(match.1) {
                items.append((number, [String(match.2)]))
            } else if !items.isEmpty {
                items[items.count - 1].1.append(line)
            }
        }
        return items.map { number, lines in
            let first = lines[0]
            let rest = lines.dropFirst().joined(separator: "\n")
            let headline: String
            var detail: String
            if let match = first.wholeMatch(of: boldLead) {
                headline = String(match.1)
                detail = String(match.2)
            } else {
                headline = first
                detail = ""
            }
            if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detail += (detail.isEmpty ? "" : "\n") + dedented(rest)
            }
            return Idea(number: number, headline: headline,
                        detail: detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Consecutive `>` lines become one quote; surrounding quotation marks are dropped
    /// because the quote card already reads as a quote.
    static func blockQuotes(_ body: String) -> [String] {
        var quotes: [String] = []
        var current: [String] = []
        func flush() {
            let text = current.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { quotes.append(unquoted(text)) }
            current = []
        }
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                current.append(String(trimmed.drop(while: { $0 == ">" })).trimmingCharacters(in: .whitespaces))
            } else {
                flush()
            }
        }
        flush()
        return quotes
    }

    /// A gist long enough to fold behind "Read more" (about four lines on a phone).
    static func isLong(_ markdown: String) -> Bool {
        markdown.split(whereSeparator: \.isWhitespace).count > 60
    }

    /// A one-line plain-text preview of markdown: links keep their label, emphasis
    /// markers and line breaks go.
    static func plainPreview(_ markdown: String) -> String {
        var text = markdown.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.1) }
        for marker in ["**", "__", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        // Single `*`/`_` emphasis markers at a word's edge; `snake_case` keeps its underscores.
        text = text.replacing(/(^|[^\w*])[*_](\S)/) { $0.1 + $0.2 }
        text = text.replacing(/(\S)[*_]([^\w*]|$)/) { $0.1 + $0.2 }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func unquoted(_ text: String) -> String {
        let marks: Set<Character> = ["\"", "“", "”"]
        guard let first = text.first, let last = text.last, text.count > 1,
              marks.contains(first), marks.contains(last) else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func dedented(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in line.hasPrefix("   ") ? String(line.dropFirst(3)) : line }
            .joined(separator: "\n")
    }
}

/// The digest layout: a gist card, numbered key-idea cards that expand to their
/// explanation, quote cards, a highlighted takeaway, then the remaining sections.
/// Built only from `BrainStyle` pieces so it reads like the rest of Brain. Links
/// inside markdown go through the `openURL` action the reader installs.
struct BrainArticleDigestView: View {
    let digest: BrainArticleDigest
    @State private var expanded: Set<Int> = []
    @State private var showsFullGist = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xl) {
            gistCard
            ideasSection
            if !digest.quotes.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    BrainSectionHeader(title: "Best quotes", count: digest.quotes.count)
                    ForEach(Array(digest.quotes.enumerated()), id: \.offset) { _, quote in
                        BrainQuoteCard(highlight: BrainHighlight(text: quote))
                    }
                }
            }
            if let takeaway = digest.takeaway, !takeaway.isEmpty {
                takeawayCard(takeaway)
            }
            ForEach(digest.otherSections) { section in
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    BrainSectionHeader(title: section.title)
                    MarkdownRenderer(content: section.markdown)
                }
            }
        }
    }

    private var gistCard: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Text(verbatim: "In short")
                .brainText(.sectionCaption)
                .fontWeight(.semibold)
            if showsFullGist || !BrainArticleDigest.isLong(digest.gist) {
                MarkdownRenderer(content: digest.gist)
            } else {
                Text(verbatim: BrainArticleDigest.plainPreview(digest.gist))
                    .brainText(.rowTitle)
                    .lineLimit(4)
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showsFullGist = true }
                } label: {
                    Text(verbatim: "Read more")
                        .font(BrainStyle.sectionCaption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brainCardSurface()
    }

    @ViewBuilder
    private var ideasSection: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HStack(alignment: .firstTextBaseline) {
                BrainSectionHeader(title: "Key ideas", count: digest.ideas.isEmpty ? nil : digest.ideas.count)
                if digest.ideas.contains(where: { !$0.detail.isEmpty }) {
                    Button(action: toggleAll) {
                        Text(verbatim: allExpanded ? "Collapse all" : "Expand all")
                            .font(BrainStyle.sectionCaption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let markdown = digest.ideasMarkdown {
                MarkdownRenderer(content: markdown)
            }
            ForEach(digest.ideas) { idea in
                ideaCard(idea)
            }
        }
    }

    private func ideaCard(_ idea: BrainArticleDigest.Idea) -> some View {
        let isExpanded = expanded.contains(idea.number)
        let canExpand = !idea.detail.isEmpty
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            Button { toggle(idea.number) } label: {
                HStack(alignment: .firstTextBaseline, spacing: BrainStyle.m) {
                    Text(verbatim: "\(idea.number)")
                        .brainText(.meta)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Color.accentColor.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: BrainStyle.xs) {
                        Text(Self.inlineMarkdown(idea.headline))
                            .brainText(.rowTitle)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if canExpand, !isExpanded {
                            Text(verbatim: BrainArticleDigest.plainPreview(idea.detail))
                                .brainText(.rowSubtitle)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    if canExpand {
                        Image(systemName: "chevron.down")
                            .font(BrainStyle.meta)
                            .foregroundStyle(Color.hxTextSecondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityValue(Text(verbatim: canExpand ? (isExpanded ? "Expanded" : "Collapsed") : ""))
            .accessibilityHint(Text(verbatim: canExpand ? "Shows or hides the explanation" : ""))
            if isExpanded {
                MarkdownRenderer(content: idea.detail)
                    .padding(.leading, 22 + BrainStyle.m)
            }
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brainCardSurface()
    }

    private func takeawayCard(_ takeaway: String) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Label {
                Text(verbatim: "Your takeaway").fontWeight(.semibold)
            } icon: {
                Image(systemName: "lightbulb")
            }
            .font(BrainStyle.sectionCaption)
            .foregroundStyle(Color.accentColor)
            MarkdownRenderer(content: takeaway)
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: BrainStyle.cardShape())
        .overlay {
            BrainStyle.cardShape().stroke(Color.accentColor.opacity(0.25), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
    }

    private var allExpanded: Bool {
        digest.ideas.filter { !$0.detail.isEmpty }.allSatisfy { expanded.contains($0.number) }
    }

    private func toggle(_ number: Int) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            if expanded.contains(number) { expanded.remove(number) } else { expanded.insert(number) }
        }
    }

    private func toggleAll() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            expanded = allExpanded ? [] : Set(digest.ideas.filter { !$0.detail.isEmpty }.map(\.number))
        }
    }

    /// Inline markdown (bold, italic, code) for a one-line headline; falls back to the raw text.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
