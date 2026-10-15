import SwiftUI

/// Where the user is in today's review deck: which day's deck, which batch of ten, which page.
struct BrainReviewPosition: Codable, Equatable {
    var day: String
    var batch: Int
    var index: Int
}

/// Per-server review position in UserDefaults. Keys end in `|<server absoluteString>` like
/// `DailyDeckStore`; `remove(for:)` runs when a server is removed.
struct BrainReviewStore {
    var defaults: UserDefaults = .standard

    private func key(_ server: URL) -> String { "brainReview.position|\(server.absoluteString)" }

    func position(for server: URL) -> BrainReviewPosition? {
        guard let data = defaults.data(forKey: key(server)) else { return nil }
        return try? JSONDecoder().decode(BrainReviewPosition.self, from: data)
    }

    func save(_ position: BrainReviewPosition, for server: URL) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: key(server))
    }

    func remove(for server: URL) {
        defaults.removeObject(forKey: key(server))
    }

    /// `2026-10-14` in the device's time zone: the review deck's day is the user's day.
    static func today() -> String { DailyDeckPaths.day(Date()) }
}

/// One page of the review pager: a bite, then a closing summary.
enum BrainReviewPage: Identifiable, Hashable {
    case bite(BrainBite)
    case summary

    var id: String {
        switch self {
        case .bite(let bite): bite.id
        case .summary: "summary"
        }
    }
}

// MARK: - Copy and papers

extension BrainBite {
    /// The Daily Deck palette a bite wears: reading for ideas and takeaways, the quote and book
    /// papers for saved words. Its symbol marks the bite in the summary's list.
    var deckPalette: DeckPalette {
        switch kind {
        case .quote: .quote
        case .highlight: .book
        case .idea, .takeaway, .unknown: .reading
        }
    }

    var paper: HermexPaper { deckPalette.colors }

    /// Quotes and highlights are someone's saved words: they get the serif and the quote mark.
    var quotesSavedWords: Bool { kind == .quote || kind == .highlight }
}

/// The review deck's words for a bite. English-only (personal fork).
enum BrainBiteCopy {
    /// The line above the bite: "Key idea · 2 of 5", "Your takeaway", "Quote", "Highlight".
    static func kicker(_ bite: BrainBite) -> String {
        switch bite.kind {
        case .idea, .unknown:
            guard let index = bite.index, let count = bite.count else { return "Key idea" }
            return "Key idea · \(index) of \(count)"
        case .takeaway: return "Your takeaway"
        case .quote: return "Quote"
        case .highlight: return "Highlight"
        }
    }

    /// The open card's foot button, naming the page it opens.
    static func open(_ bite: BrainBite) -> String {
        switch bite.ref.module {
        case .articles: "Open the article"
        case .highlights where bite.ref.id.hasPrefix("book:"): "Open the book"
        default: "Open the note"
        }
    }

    /// The bite's kind in one word, for the summary's rows.
    static func kind(_ bite: BrainBite) -> String {
        switch bite.kind {
        case .idea, .unknown: "Idea"
        case .takeaway: "Takeaway"
        case .quote: "Quote"
        case .highlight: "Highlight"
        }
    }

    /// "The Bitter Lesson · Rich Sutton": the source and its byline, whichever exist.
    static func attribution(_ bite: BrainBite) -> String? {
        let parts = [bite.ref.title, bite.byline]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Module strip

/// The Brain's modules as a sideways row of chips under search, each in its kind's paper
/// (DESIGN.md § Components). Interview prep joins at the end once Prep loads.
struct BrainModuleStrip: View {
    let modules: [BrainModule]
    let showsPrep: Bool

    private static let order: [BrainModuleID] = [.articles, .highlights, .people, .journal, .wiki]

    private var ordered: [BrainModule] {
        modules.sorted {
            (Self.order.firstIndex(of: $0.id) ?? Self.order.count) < (Self.order.firstIndex(of: $1.id) ?? Self.order.count)
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ordered, id: \.id) { module in
                    chip(.module(module.id), paper: module.id.paper, symbol: module.id.symbolName,
                         label: module.title.isEmpty ? module.id.defaultTitle : module.title)
                }
                if showsPrep {
                    chip(.prep(.home), paper: .knowledge, symbol: "target", label: "Interview prep")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ route: BrainRoute, paper: HermexPaper, symbol: String, label: String) -> some View {
        NavigationLink(value: ShellPushDestination.brainRoute(route)) {
            HXChip(paper: paper, symbol: symbol, label: label)
                .zoomSource(for: .brainRoute(route))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Deck card

/// A card of a Brain swipe deck, drawn like a Daily Deck reading card: a glow card in `paper`
/// (`xl` corners, the `paper` shadow) whose words scroll inside it with the shared
/// `moreBelowHint`. A tap opens the card to fill the screen (`opensAsFullCard`), where `open`
/// becomes the foot button ("Open the article"). The review's bites and a person's timeline use it.
struct BrainDeckCard<Content: View>: View {
    let paper: HermexPaper
    /// "Open the article": the open card's foot button, when the card has a page to open.
    let footer: String
    let open: (() -> Void)?
    let accessibilityLabel: String
    var accessibilityValue: String = ""
    /// One line pinned above the footer, outside the scrolling words (a same-day journal entry).
    var footnote: AttributedString?
    /// Cards under the top one show only their paper; their words fade in as they rise.
    var contentOpacity: Double = 1
    /// The card opened to fill the screen: its words without the card's own surface, and
    /// `open` as the foot button instead of the footer row.
    var isOpen = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let words = VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            // Short cards leave the drag to the screen's own scroll view.
            .scrollBounceBehavior(.basedOnSize)
            .moreBelowHint(fill: paper.card, mark: paper.glow)
            if let footnote {
                Text(footnote)
                    .font(AppFont.serif(style: .caption))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
            }
        }
        .foregroundStyle(paper.glow)
        .opacity(contentOpacity)

        if isOpen {
            words
        } else {
            words
                .hxCardSurface(.glow(paper), clipsContent: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .accessibilityValue(Text(verbatim: accessibilityValue))
                // A tap opens the card itself; its foot button then opens the page.
                .opensAsFullCard(.glow(paper), action: open.map { HXCardAction(title: footer, perform: $0) }) {
                    BrainDeckCard(paper: paper, footer: footer, open: open, accessibilityLabel: accessibilityLabel,
                                  accessibilityValue: accessibilityValue, footnote: footnote, isOpen: true,
                                  content: content)
                }
                .padding(.vertical, 12)
        }
    }
}

// MARK: - Bite card

/// One bite of the review deck, drawn like a Daily Deck reading card (`DeckCardView.reading`):
/// a `BrainDeckCard` in the bite's paper with its kicker, the lead (serif for saved words), the
/// attribution in the glow, and the detail. Long text scrolls inside the card. A tap opens the
/// card full screen with the bite's page as its foot button; swiping pages the deck.
struct BrainBiteCard: View {
    let bite: BrainBite
    let open: () -> Void
    /// Cards under the top one show only their paper; their words fade in as they rise.
    var contentOpacity: Double = 1

    var body: some View {
        BrainDeckCard(paper: bite.paper, footer: BrainBiteCopy.open(bite), open: open,
                      accessibilityLabel: accessibilityLabel, contentOpacity: contentOpacity) {
            reading
        }
    }

    @ViewBuilder
    private var reading: some View {
        Text(verbatim: BrainBiteCopy.kicker(bite))
            .font(AppFont.footnote(weight: .semibold))
        if bite.quotesSavedWords {
            Image(systemName: "quote.opening")
                .font(.system(size: 40, weight: .semibold))
                .opacity(0.22)
                .padding(.top, 18)
                .accessibilityHidden(true)
        }
        Text(BrainArticleDigestView.inlineMarkdown(bite.text))
            .font(Self.leadFont(for: bite))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, bite.quotesSavedWords ? 10 : 14)
        if let attribution = BrainBiteCopy.attribution(bite) {
            Text(verbatim: attribution)
                .font(AppFont.subheadline(weight: .medium))
                .padding(.top, 12)
        }
        if let detail = bite.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            Text(BrainArticleDigestView.inlineMarkdown(detail))
                .font(AppFont.body())
                .lineSpacing(4)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
        }
    }

    private var accessibilityLabel: String {
        let text = String(BrainArticleDigestView.inlineMarkdown(bite.text).characters)
        return [BrainBiteCopy.kicker(bite), text, BrainBiteCopy.attribution(bite), bite.detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    /// The Daily Deck's lead sizes (`DeckCardText.leadStyle`); the serif for saved words, the
    /// rounded display voice otherwise.
    static func leadFont(for bite: BrainBite) -> Font {
        let style = DeckCardText.leadStyle(length: bite.text.count, isQuote: bite.kind == .quote)
        return bite.quotesSavedWords ? AppFont.serif(style: style) : AppFont.display(style: style, weight: .semibold)
    }
}

// MARK: - Summary card

/// The deck's last page: a neutral card like the Brief opener, listing the batch's bites
/// (five, then "+ N more"), with "Ten more" when the server has another batch.
struct BrainReviewSummaryCard: View {
    let bites: [BrainBite]
    let hasMore: Bool
    let onMore: () async -> Void
    var contentOpacity: Double = 1

    @State private var isDealing = false

    private static let shown = 5

    /// The bite's source, or its own words when the source has no title.
    private static func title(_ bite: BrainBite) -> String {
        bite.ref.title.isEmpty ? String(BrainArticleDigestView.inlineMarkdown(bite.text).characters) : bite.ref.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "That's today's ten")
                        .font(AppFont.display(style: .title2, weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: "New bites tomorrow morning.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(bites.prefix(Self.shown)) { bite in
                            let palette = bite.deckPalette
                            // A Brief opener row, with the kind in its glow.
                            DeckAheadRow(symbol: palette.symbol, ink: palette.ink, wash: palette.colors.wash,
                                         title: Self.title(bite), kind: BrainBiteCopy.kind(bite), kindColor: palette.ink)
                        }
                        if bites.count > Self.shown {
                            Text(verbatim: "+ \(bites.count - Self.shown) more")
                                .font(AppFont.subheadline())
                                .foregroundStyle(Color.hxTextSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                        }
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            if hasMore {
                Button {
                    guard !isDealing else { return }
                    isDealing = true
                    Task {
                        await onMore()
                        isDealing = false
                    }
                } label: {
                    // The style draws a neutral capsule on the app's surface; the label takes
                    // Nous blue while enabled, since this is a control (DESIGN.md principle 5);
                    // during a fetch the label takes the style's disabled foreground (a label color
                    // would otherwise override it).
                    Text(verbatim: "Ten more").foregroundStyle(isDealing ? Color.hxTextSecondary : Color.accentColor)
                }
                .buttonStyle(.chatDecision(.secondary))
                .disabled(isDealing)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .opacity(contentOpacity)
        .hxCardSurface(.summary, clipsContent: true)
        .padding(.vertical, 12)
    }
}
