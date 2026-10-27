import SwiftUI

// The parts of a deck by job's cards (vault 2026-10-27): the opener's tag lines and Today's one, and the
// card anatomy every act card drawn by `DeckCardView.reading` shares: a kind label, a title, the body,
// and the one ask.

extension DeckCard {
    /// An act card's kind label after its symbol: the palette's name, then what this one is ("Video · Idea 1 of 2",
    /// "Check-in · Roger Federer", "Letter to her · 80 days to go", "A year ago · Tue, Oct 28, 2025").
    /// `idea` is the card's place among the deck's ideas.
    func kindLabel(_ palette: DeckPalette, idea: (number: Int, of: Int)? = nil, advisor: String? = nil) -> String {
        let detail: String?
        if let idea {
            detail = "Idea \(idea.number) of \(idea.of)"
        } else if isLetter {
            detail = lines.first
        } else if type == .prompt, !isDream {
            detail = voice ?? advisor
        } else {
            detail = dateLabel
        }
        guard let detail, !detail.isEmpty else { return palette.name }
        return "\(palette.name) · \(detail)"
    }

    /// Whether this card's question is its title (a check-in or a letter), so the ask below is the answer alone.
    var asksInTitle: Bool { type == .prompt }

    /// `text` in curly quotes, unless it already wears quote marks.
    static func quoted(_ text: String) -> String {
        let marks: Set<Character> = ["“", "\"", "‘", "'"]
        return text.first.map(marks.contains) == true ? text : "“\(text)”"
    }
}

extension DeckAct {
    /// Where an idea card sits among the deck's ideas, counted on the pages shown; nil for any other card.
    static func ideaPosition(of card: DeckCard, in pages: [DeckPage]) -> (number: Int, of: Int)? {
        guard card.act == "ideas" else { return nil }
        let ideas = pages.filter { $0.act == "ideas" }.map(\.id)
        guard let index = ideas.firstIndex(of: card.id) else { return nil }
        return (index + 1, ideas.count)
    }
}

/// An act card's first line: its kind's symbol and its kind label, in the card's ink.
struct DeckKindLabel: View {
    let symbol: String
    let text: String
    let ink: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
        .font(AppFont.footnote(weight: .semibold))
        .foregroundStyle(ink.opacity(0.75))
        .padding(.trailing, 24)
    }
}

/// The opener's tag lines, each after its mark: the check-in, the race, the due date, a birthday.
struct DeckTagLines: View {
    let tags: [DeckTag]

    @ScaledMetric(relativeTo: .footnote) private var markWidth: CGFloat = 18

    var body: some View {
        ForEach(tags, id: \.self) { tag in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: tag.symbol)
                    .frame(width: markWidth)
                    .accessibilityHidden(true)
                Text(verbatim: tag.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(AppFont.footnote())
        }
    }
}

/// The opener's "Today's one": the day's pick, and yesterday's words behind it.
struct DeckTodayOnePanel: View {
    let one: DeckTodayOne
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Today's one")
                .font(AppFont.caption(weight: .heavy))
                .textCase(.uppercase)
                .foregroundStyle(palette.ink.opacity(0.75))
            Text(verbatim: one.label)
                .font(AppFont.display(style: .title3, weight: .bold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let quote = one.quote, !quote.isEmpty {
                Text(verbatim: DeckCard.quoted(quote))
                    .font(AppFont.serif(style: .subheadline))
                    .italic()
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Text(verbatim: "You, yesterday")
                    .font(AppFont.caption())
                    .foregroundStyle(palette.ink.opacity(0.75))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// An idea card's body: where it's from, its gist, the source's own words, and its parts.
struct DeckIdeaBody: View {
    let card: DeckCard
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let source = card.source {
                Text(verbatim: source)
                    .font(AppFont.subheadline())
                    .foregroundStyle(palette.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            if let gist = card.gist ?? card.body {
                Text(inlineMarkdown(gist))
                    .font(AppFont.body())
                    .lineSpacing(3)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .textSelection(.enabled)
            }
            if !card.quotes.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(card.quotes, id: \.self) { quote in
                        DeckQuoteRow(text: quote.text, at: quote.at, palette: palette)
                    }
                }
                .padding(.top, 20)
            }
            if !card.parts.isEmpty {
                Text(verbatim: "The parts")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.75))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.parts, id: \.self) { part in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "•").accessibilityHidden(true)
                            (Text(verbatim: "\(part.label): ").font(AppFont.subheadline(weight: .semibold))
                                + Text(verbatim: part.text).font(AppFont.subheadline()))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Color.hxTextPrimary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A verbatim quote in the saved-words serif with a quote mark, and who said it; the Piece card's look.
struct DeckQuoteRow: View {
    let text: String
    let at: String?
    let palette: DeckPalette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: text)
                    .font(AppFont.serif(style: .body))
                    .lineSpacing(3)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let at, !at.isEmpty {
                    Text(verbatim: at)
                        .font(AppFont.footnote(weight: .medium))
                        .foregroundStyle(palette.ink.opacity(0.75))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Yesterday's words a check-in or letter picks up from: a small label, the quote in italic serif, and where it was said.
struct DeckThreadView: View {
    let thread: DeckThread
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = thread.label, !label.isEmpty {
                Text(verbatim: label)
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.75))
            }
            Text(verbatim: DeckCard.quoted(thread.quote))
                .font(AppFont.serif(style: .body))
                .italic()
                .lineSpacing(3)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let at = thread.at, !at.isEmpty {
                Text(verbatim: at)
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.ink.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
