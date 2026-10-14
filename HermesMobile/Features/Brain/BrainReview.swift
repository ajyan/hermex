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

    /// The card's footer, naming what a tap opens.
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
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bite card

/// One bite of the review deck, drawn like a Daily Deck reading card (`DeckCardView.reading`):
/// a glow card in the bite's paper with its kicker, the lead (serif for saved words), the
/// attribution in the glow, the detail, and a footer naming what a tap opens. Long text
/// scrolls inside the card. The whole card opens the bite's page; swiping pages the deck.
struct BrainBiteCard: View {
    let bite: BrainBite
    let open: () -> Void
    /// Cards under the top one show only their paper; their words fade in as they rise.
    var contentOpacity: Double = 1

    @State private var overflows = false

    static let shape = RoundedRectangle(cornerRadius: HXRadius.xl, style: .continuous)

    var body: some View {
        let paper = bite.paper
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { reading }
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            // Short bites leave the drag to the Brain home's own scroll view.
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y > geometry.containerSize.height + 8
            } action: { _, more in
                overflows = more
            }
            .overlay(alignment: .bottom) { moreHint }
            footer
        }
        .foregroundStyle(paper.glow)
        .opacity(contentOpacity)
        .background(paper.card, in: Self.shape)
        .overlay(Self.shape.strokeBorder(paper.edge, lineWidth: 0.5))
        .clipShape(Self.shape)
        .hxShadow(.paper)
        // A tap, not a Button: a Button fires on release even after the finger has dragged the
        // card across, so a swipe would open the page. A tap gesture fails once the touch moves.
        .contentShape(Self.shape)
        .onTapGesture(perform: open)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityHint(Text(verbatim: BrainBiteCopy.open(bite)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .padding(.vertical, 12)
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

    /// "Open the article" and a chevron over a hairline in the paper's edge.
    private var footer: some View {
        HStack {
            Text(verbatim: BrainBiteCopy.open(bite))
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward").accessibilityHidden(true)
        }
        .font(AppFont.subheadline(weight: .semibold))
        .padding(.top, 14)
        .padding(.bottom, 22)
        .overlay(alignment: .top) { Rectangle().fill(bite.paper.edge).frame(height: 0.5) }
        .padding(.horizontal, 24)
    }

    /// A soft fade and arrow while there is more card below (as on a Daily Deck card).
    @ViewBuilder
    private var moreHint: some View {
        if overflows {
            LinearGradient(colors: [bite.paper.card.opacity(0), bite.paper.card], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .overlay(alignment: .bottom) {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(bite.paper.glow.opacity(0.45))
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let text = String(BrainArticleDigestView.inlineMarkdown(bite.text).characters)
        return [BrainBiteCopy.kicker(bite), text, BrainBiteCopy.attribution(bite), bite.detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    /// The Daily Deck's lead sizes (`DeckCardText.leadFont`): a quote at title size, everything
    /// else smaller as it grows; the serif for saved words, the rounded display voice otherwise.
    static func leadFont(for bite: BrainBite) -> Font {
        let count = bite.text.count
        let style: Font.TextStyle = bite.kind == .quote ? .title
            : count > 480 ? .body : count > 220 ? .title3 : .title2
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "That's today's ten")
                        .font(AppFont.display(style: .title2, weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "New bites tomorrow morning.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.top, 4)
                    VStack(spacing: 0) {
                        ForEach(bites.prefix(Self.shown)) { bite in
                            BrainReviewSummaryRow(bite: bite)
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
                    // Nous blue, since this is a control (DESIGN.md principle 5).
                    Text(verbatim: "Ten more").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.chatDecision(.secondary))
                .disabled(isDealing)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .opacity(contentOpacity)
        .clipShape(BrainBiteCard.shape)
        .hxCard(cornerRadius: HXRadius.xl)
        .hxShadow(.paper)
        .padding(.vertical, 12)
    }
}

/// One of the summary's rows, as on the Brief opener's list of cards ahead (`DeckAheadRow`):
/// the kind's symbol on a wash tile, the source's title, and the kind in one word.
private struct BrainReviewSummaryRow: View {
    let bite: BrainBite

    var body: some View {
        let palette = bite.deckPalette
        HStack(spacing: 10) {
            Image(systemName: palette.symbol)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(width: 26, height: 26)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.xs + 2, style: .continuous))
                .accessibilityHidden(true)
            Text(verbatim: bite.ref.title.isEmpty ? String(BrainArticleDigestView.inlineMarkdown(bite.text).characters) : bite.ref.title)
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: BrainBiteCopy.kind(bite))
                .font(AppFont.caption())
                .foregroundStyle(palette.ink)
                .lineLimit(1)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}
