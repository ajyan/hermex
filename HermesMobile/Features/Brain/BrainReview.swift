import SwiftData
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


/// One bite's words, parsed from Markdown once per deck rather than per drag frame.
struct BrainBiteText {
    let lead: AttributedString
    let detail: AttributedString?
    let accessibilityLabel: String

    init(bite: BrainBite) {
        lead = BrainArticleDigestView.inlineMarkdown(bite.text)
        let detailText = bite.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        detail = detailText.isEmpty ? nil : BrainArticleDigestView.inlineMarkdown(detailText)
        accessibilityLabel = [BrainBiteCopy.kicker(bite), String(lead.characters), BrainBiteCopy.attribution(bite), bite.detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

// MARK: - Review screen

/// Today's review as its own screen, opened from the Brain home's Today list: the deck of
/// bites fills the screen, ending on the summary card. The position is saved per server and
/// day, so the home's row and this screen agree.
struct BrainReviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: BrainHomeViewModel
    /// Pushes a bite's page onto the shell's stack.
    private let push: (BrainRoute) -> Void

    init(server: URL, modelContext: ModelContext, onAPIError: @escaping (Error) -> Void,
         push: @escaping (BrainRoute) -> Void) {
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainHomeViewModel(client: client, cache: cache, onAPIError: onAPIError))
        self.push = push
    }

    var body: some View {
        content
            .hxNavigationTitle("Review", subtitle: subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
            .onChange(of: scenePhase) { _, phase in
                // Left open overnight, the deck moves on to the new day's ten.
                if phase == .active, viewModel.needsNewDay { Task { await viewModel.load() } }
            }
    }

    private var subtitle: String? {
        let bites = viewModel.home.bites.count
        guard bites > 0 else { return nil }
        return viewModel.reviewIndex >= bites ? "Done" : "\(viewModel.reviewIndex + 1) of \(bites)"
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.reviewPages.isEmpty {
            deck
                .padding(.horizontal, 16)
                .padding(.vertical, BrainStyle.m)
        } else {
            switch viewModel.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label { Text(verbatim: "Couldn't load the review") } icon: { Image(systemName: "exclamationmark.triangle") }
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
                }
            case .unavailable, .loaded:
                if viewModel.deckFailed {
                    ContentUnavailableView {
                        Label { Text(verbatim: "Couldn't load the review") } icon: { Image(systemName: "wifi.exclamationmark") }
                    } description: {
                        Text(verbatim: "Check your connection and try again.")
                    } actions: {
                        Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
                    }
                } else {
                    ContentUnavailableView {
                        Label { Text(verbatim: "Nothing to review today") } icon: { Image(systemName: "rectangle.stack") }
                    } description: {
                        Text(verbatim: "Bites come from articles and highlights you've saved.")
                    }
                }
            }
        }
    }

    private var deck: some View {
        let bites = viewModel.home.bites
        return CardStack(
            pages: viewModel.reviewPages,
            index: $viewModel.reviewIndex,
            tilt: { DeckStackView.tilt(ofID: $0.id) }
        ) { page, contentOpacity in
            switch page {
            case .bite(let bite):
                BrainBiteCard(bite: bite, text: viewModel.biteTexts[bite.id] ?? BrainBiteText(bite: bite),
                              open: { push(Self.route(bite)) }, contentOpacity: contentOpacity)
            case .summary:
                BrainReviewSummaryCard(bites: bites, hasMore: viewModel.home.hasMore, failed: viewModel.dealMoreFailed,
                                       onMore: { await viewModel.dealMore() }, contentOpacity: contentOpacity)
            }
        } edge: { page in
            // Far down the stack only the card's paper shows, peeking out askew.
            let role = Self.cardRole(page)
            role.shape
                .fill(role.fill)
                .hxShadow(.stacked)
                .padding(.vertical, 12)
        }
    }

    private static func route(_ bite: BrainBite) -> BrainRoute {
        .bite(bite.ref.module, bite.ref.id, idea: bite.kind == .idea ? bite.index : nil)
    }

    private static func cardRole(_ page: BrainReviewPage) -> HXCardRole {
        switch page {
        case .bite(let bite): .glow(bite.paper)
        case .summary: .summary
        }
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
    /// The bite's words, parsed once per deck (`BrainHomeViewModel.biteTexts`).
    let text: BrainBiteText
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
                .font(AppFont.display(style: .largeTitle, weight: .semibold))
                .opacity(0.22)
                .padding(.top, 18)
                .accessibilityHidden(true)
        }
        Text(text.lead)
            .font(Self.leadFont(for: bite))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, bite.quotesSavedWords ? 10 : 14)
        if let attribution = BrainBiteCopy.attribution(bite) {
            Text(verbatim: attribution)
                .font(AppFont.subheadline(weight: .medium))
                .padding(.top, 12)
        }
        if let detail = text.detail {
            Text(detail)
                .font(AppFont.body())
                .lineSpacing(4)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
        }
    }

    private var accessibilityLabel: String { text.accessibilityLabel }

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
    /// The last "Ten more" failed.
    var failed = false
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
                if failed, !isDealing {
                    Text(verbatim: "Couldn't get ten more. Try again.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
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
