import SwiftUI

// The parts of a deck by job's cards (vault 2026-10-27): the opener's tag lines and Today's one, the
// card anatomy every act card drawn by `DeckCardView.reading` shares (a kind label, a title, the body,
// and the one ask), and the one layout every idea card shares (`DeckIdea`).

extension DeckCard {
    /// An act card's kind label after its symbol: the palette's name, then what this one is
    /// ("Check-in · Roger Federer", "Letter to her · 80 days to go", "Looking back · Stony Brook",
    /// "A year ago · Tue, Oct 28, 2025"). An idea card's is `DeckIdea.kindLine`.
    func kindLabel(_ palette: DeckPalette, advisor: String? = nil) -> String {
        let detail: String?
        if isLetter {
            detail = self.lines.first
        } else if isPast || isFuture {
            detail = self.title
        } else if self.type == .prompt, !isDream {
            detail = self.voice ?? advisor
        } else {
            detail = self.dateLabel
        }
        guard let detail, !detail.isEmpty else { return palette.name }
        return "\(palette.name) · \(detail)"
    }

    /// Whether this card's question is its title (a check-in or a letter), so the ask below is the answer alone.
    var asksInTitle: Bool { self.type == .prompt }

    /// `text` in curly quotes, unless it already wears quote marks.
    static func quoted(_ text: String) -> String {
        let marks: Set<Character> = ["“", "\"", "‘", "'"]
        return text.first.map(marks.contains) == true ? text : "“\(text)”"
    }
}

/// An act card's first line: its kind's symbol and its kind label, in the card's supporting ink
/// (`DeckPalette.secondaryInk`), at full strength.
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
        .foregroundStyle(ink)
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

/// An idea card's words in the one layout every idea card shares: the kind line, the idea as a sentence, the
/// source's own lines, the take, and what he wrote that it links to. Decks have carried ideas in four shapes
/// (a gist with labelled parts, a book highlight with its context, a long piece's map, quotes with a link);
/// each maps onto these slots, so an old deck reads like a new one.
struct DeckIdea: Equatable {
    /// "Book highlight · Carol Dweck, Mindset"; a card written from a summary says so: "From your notes · summary".
    let kindLine: String
    /// The idea in a sentence. Nil when the card has none of its own (an old highlight titled with its book's name).
    let sentence: String?
    /// The source's words, verbatim. Empty on a summary card.
    let quotes: [DeckPiece.Quote]
    let take: String?
    let linked: DeckThread?
    /// Written from a summary: none of the source's own text was on hand, so there are no quotes.
    let isSummary: Bool

    init(_ card: DeckCard, palette: DeckPalette) {
        let text = DeckCardText(card)
        // A saved quote, or a book highlight from before ideas had a gist: `body` is the source's own words.
        let isVerbatim = card.itemKind == "quote" || (card.itemKind == "book" && card.gist == nil)
        let source: String?
        if isVerbatim {
            sentence = nil
            source = card.itemKind == "book"
                ? Self.joined([card.source, card.title == card.source ? nil : card.title], ", ") : text.attribution
            take = card.take ?? card.context
        } else if card.act != nil {
            sentence = card.title ?? card.gist.flatMap { DeckCardText.split($0).0 }
            source = card.source
            let gist = card.title == nil ? card.gist.flatMap { DeckCardText.split($0).1 } : card.gist
            take = card.take ?? gist ?? card.context ?? (card.gist == nil ? card.body : nil)
        } else {
            // A deck from before cards named their act: its lead sentence, where it's from, and the rest.
            sentence = text.lead
            source = text.attribution
            take = card.take ?? text.detail
        }
        var lines = card.quotes.isEmpty ? (card.piece?.quotes ?? []) : card.quotes
        if lines.isEmpty, isVerbatim, let body = card.body { lines = [DeckPiece.Quote(text: body, at: nil)] }
        lines = lines.map { DeckPiece.Quote(text: Self.unquoted($0.text), at: $0.at) }.filter { !$0.text.isEmpty }
        isSummary = card.isFromSummary ?? lines.isEmpty
        quotes = isSummary ? [] : lines
        linked = card.linked
        // "Your notes" under "From your notes" says the same thing twice.
        let named = source.flatMap { palette.name.localizedCaseInsensitiveContains($0) ? nil : $0 }
        kindLine = Self.joined([palette.name, isSummary ? "summary" : nil, named], " · ") ?? palette.name
    }

    /// `text` without the quote marks around it (the quote row draws its own), or the stray full stop after them.
    static func unquoted(_ text: String) -> String {
        let marks: Set<Character> = ["“", "”", "\"", "‘", "’"]
        var words = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if words.hasSuffix("."), let before = words.dropLast().last, marks.contains(before) { words = words.dropLast() }
        if let first = words.first, let last = words.last, words.count > 1, marks.contains(first), marks.contains(last),
           !words.dropFirst().dropLast().contains(where: { $0 == "“" || $0 == "\"" }) {
            words = words.dropFirst().dropLast()
        }
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joined(_ parts: [String?], _ separator: String) -> String? {
        let kept = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: separator)
    }
}

extension DeckCard {
    /// The module a card is about, as its open card's foot button: a goal card opens its goal (Goals when it
    /// holds several), the dinner card Meals, the training card Body. Nil for a card with no module of its own.
    var moduleDestination: (title: String, screen: ShellPushDestination)? {
        switch self.type {
        case .goal:
            if self.goals.count == 1, let slug = self.goals.first { return ("Open the goal", .goal(slug)) }
            return ("Open Goals", .goals)
        case .dinner: return ("Open Meals", .meals)
        case .training: return ("Open Body", .body)
        case .weekMoney: return ("Open Money", .money)
        default: return nil
        }
    }

    /// A card that brings an idea from something he saved: a deck by job's `ideas` act, and before acts, every
    /// reflect card but a year-ago entry and a weekly review's own.
    var isIdea: Bool {
        if let act = self.act { return act == "ideas" && !isMandarin }
        return self.type == .reflect && self.itemKind != "on_this_day" && self.chapter == nil && self.month == nil
    }
}

/// An idea card's source lines, its take, and what he wrote that it links to, in that order.
struct DeckIdeaBody: View {
    let idea: DeckIdea
    let palette: DeckPalette
    /// The take's emphasis; the card's `markdown`, which parses it once.
    var markdown: (String) -> AttributedString = inlineMarkdown

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !idea.quotes.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(idea.quotes, id: \.self) { quote in
                        DeckQuoteRow(text: quote.text, at: quote.at, palette: palette)
                    }
                }
                .padding(.top, 18)
            }
            if let take = idea.take {
                (Text(verbatim: "The take. ").font(AppFont.body(weight: .semibold)) + Text(markdown(take)).font(AppFont.body()))
                    .lineSpacing(3)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
                    .textSelection(.enabled)
            }
            if let linked = idea.linked {
                DeckLinkedBlock(thread: linked, palette: palette).padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "You wrote": his own earlier words an idea links to, on an inset block in the card's wash. A small label, the
/// words in the saved-words serif, and where he wrote them.
struct DeckLinkedBlock: View {
    let thread: DeckThread
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: thread.label.flatMap { $0.isEmpty ? nil : $0 } ?? "You wrote")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.secondaryInk)
            Text(verbatim: DeckIdea.unquoted(thread.quote))
                .font(AppFont.serif(style: .body))
                .lineSpacing(3)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let at = thread.at, !at.isEmpty {
                Text(verbatim: at)
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// An idea card's answer box: his take once written, else where it goes. The card holds no text field, so the
/// box opens the writing sheet.
struct DeckAnswerBoxLabel: View {
    let text: String?
    let prompt: String
    let palette: DeckPalette

    var body: some View {
        let written = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        Text(verbatim: written ?? prompt)
            .font(AppFont.body())
            .foregroundStyle(written == nil ? Color.hxTextSecondary : Color.hxTextPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous).strokeBorder(palette.colors.edge, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
    }
}

/// "The parts": a bullet per part, its label bold before its text. An idea card's parts, and a Piece
/// card's steps.
struct DeckPartsList: View {
    let parts: [(label: String?, text: String)]
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "The parts")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.secondaryInk)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•").accessibilityHidden(true)
                        (Text(verbatim: part.label.map { "\($0): " } ?? "").font(AppFont.subheadline(weight: .semibold))
                            + Text(verbatim: part.text).font(AppFont.subheadline()))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Color.hxTextPrimary)
                    .accessibilityElement(children: .combine)
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
                        .foregroundStyle(palette.secondaryInk)
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
                    .foregroundStyle(palette.secondaryInk)
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
                    .foregroundStyle(palette.secondaryInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
