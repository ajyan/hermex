import SwiftUI
import UIKit

/// The one style source for every Brain module (and modules built like it).
///
/// Views reference these roles and constants, never raw fonts or numbers, so the
/// five modules read as one library. Chrome stays neutral `hx*` plus the accent;
/// covers and graph headers take a hue from `coverPalette`, and module icons wear the
/// Brain's object paper, `HermexPaper.knowledge`.
enum BrainStyle {
    // MARK: Type roles (all Dynamic Type text styles)

    /// For in-content headings that stand in for a large title. Screens themselves use
    /// the shared header, `.hxNavigationTitle`.
    static let screenTitle: Font = AppFont.display(style: .largeTitle)
    static let sectionCaption: Font = AppFont.footnote()
    static let rowTitle: Font = AppFont.body()
    static let rowSubtitle: Font = AppFont.subheadline()
    static let meta: Font = AppFont.caption()
    static let readerTitle: Font = AppFont.display(style: .title)
    /// The only serif in the Brain: highlights and best-quote blocks.
    static let quote: Font = AppFont.serif().leading(.loose)

    /// A text role: its font plus its colour (nil keeps the inherited primary colour).
    enum Role: CaseIterable {
        case screenTitle, sectionCaption, rowTitle, rowSubtitle, meta, readerTitle, quote

        var font: Font {
            switch self {
            case .screenTitle: BrainStyle.screenTitle
            case .sectionCaption: BrainStyle.sectionCaption
            case .rowTitle: BrainStyle.rowTitle
            case .rowSubtitle: BrainStyle.rowSubtitle
            case .meta: BrainStyle.meta
            case .readerTitle: BrainStyle.readerTitle
            case .quote: BrainStyle.quote
            }
        }

        var color: Color {
            switch self {
            case .sectionCaption, .rowSubtitle, .meta: .hxTextSecondary
            case .screenTitle, .rowTitle, .readerTitle, .quote: .hxTextPrimary
            }
        }
    }

    // MARK: Spacing (one 4pt grid)

    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    /// The smallest tappable height (Apple's 44pt minimum).
    static let minTapTarget: CGFloat = 44

    // MARK: Shapes (matched to `SectionCard`)

    static let cardCorner: CGFloat = HXRadius.lg
    static let cardHorizontalPadding: CGFloat = 16
    static let cardVerticalPadding: CGFloat = 14
    /// Corner for cover thumbnails and tiles inside rows.
    static let thumbnailCorner: CGFloat = HXRadius.xs
    /// Base side of a row's leading thumbnail; scale it with `@ScaledMetric`.
    static let thumbnailSize: CGFloat = 44
    /// Width over height for cover art on cards and grids.
    static let coverAspectRatio: CGFloat = 3 / 2
    /// Base side of a module icon tile (home rows); scale it with `@ScaledMetric`.
    static let iconSize: CGFloat = 32
    /// Base side of a search result's cover or avatar; scale it with `@ScaledMetric`.
    static let searchThumbnailSize: CGFloat = 28
    /// The smallest a deck gets on a short screen (landscape, the largest text).
    static let minimumDeckHeight: CGFloat = 240
    /// A person's timeline deck: shorter than the review, since most encounters are a few lines;
    /// longer ones scroll inside the card. Scale it with `@ScaledMetric`.
    static let timelineDeckHeight: CGFloat = 300
    /// Height kept free when a deck is cut to the reader's visible height, so its section header
    /// and the top of the next section still show around it.
    static let deckViewportMargin: CGFloat = 48

    static func cardShape() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
    }

    // MARK: Dates

    /// An ISO day, alone or leading a datetime ("2026-03-25", "2026-03-25T23:30:00Z").
    private static let isoDatePattern =
        #"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?)?$"#

    /// Parses only real `yyyy-MM-dd` days, in UTC so the day never shifts.
    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    /// The one Brain date format: an ISO day or datetime as a medium date
    /// ("Mar 25, 2026"), taking the day as written. Anything else (an impossible
    /// date, a title such as "Oct 7, 2026", free text) passes through unchanged.
    static func displayDate(_ iso: String, locale: Locale = .current) -> String {
        let trimmed = iso.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: isoDatePattern, options: .regularExpression) != nil,
              let date = isoDay.date(from: String(trimmed.prefix(10)))
        else { return iso }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.locale = locale
        style.calendar = Calendar(identifier: .gregorian)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return date.formatted(style)
    }

    // MARK: Cover palette

    /// The 8 cover ramps, as `(background, mid, strong)` in `0xRRGGBB`, light then dark, drawn
    /// from the shared papers (DESIGN.md § Color) so a cover's hue is the same one the Brief
    /// and chat use. Light: the paper, its hue, its light glow. Dark: the hue faint and stronger
    /// over the navy canvas, then its dark glow. Indices 0–5 are pinned to tags in
    /// `BrainCoverSpec.tagRamps`.
    static let coverPaletteValues: [(light: (UInt32, UInt32, UInt32), dark: (UInt32, UInt32, UInt32))] =
        [HermexPaper.quote, .video, .wiki, .reading, .notes, .opener, .book, .plain].map { paper in
            let v = paper.values
            let canvas: UInt32 = 0x0D1117
            return (light: (v.paper, HermexPaper.mix(v.hue, over: 0xFFFFFF, 0.55), v.glowLight),
                    dark: (HermexPaper.mix(v.hue, over: canvas, 0.16), HermexPaper.mix(v.hue, over: canvas, 0.38), v.glowDark))
        }


    /// Built once: a fresh dynamic `UIColor` never equals another, so rebuilding per
    /// view would defeat SwiftUI's diffing (same reasoning as `HermexPalette.colors`).
    static let coverPalette: [BrainCoverRamp] = coverPaletteValues.map { values in
        BrainCoverRamp(
            background: dynamic(values.light.0, values.dark.0),
            mid: dynamic(values.light.1, values.dark.1),
            strong: dynamic(values.light.2, values.dark.2)
        )
    }

    /// The ramp at `index`, wrapping any out-of-range value.
    static func coverRamp(_ index: Int) -> BrainCoverRamp {
        let count = coverPalette.count
        return coverPalette[((index % count) + count) % count]
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        let lightColor = HermexPalette.uiColor(light << 8 | 0xFF)
        let darkColor = HermexPalette.uiColor(dark << 8 | 0xFF)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }
}

/// One hue ramp: a light tint for the ground, a mid tone and a strong accent.
struct BrainCoverRamp: Equatable {
    let background: Color
    let mid: Color
    let strong: Color
}

extension View {
    /// Applies a Brain text role's font and colour.
    func brainText(_ role: BrainStyle.Role) -> some View {
        font(role.font).foregroundStyle(role.color)
    }
}

extension View {
    /// The one Brain list look: plain, on `.hxCanvas`.
    func brainListStyle() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.hxCanvas.ignoresSafeArea())
    }

    /// The one Brain list row background: `.hxSurface`.
    func brainListRow() -> some View {
        listRowBackground(Color.hxSurface)
            .listRowSeparatorTint(Color.hxSeparator)
    }

    /// A list row that sits on the canvas without a separator: chip bars, pickers,
    /// banners, card rows and inline states. `edgeToEdge` drops the row insets, for
    /// content that scrolls sideways and pads itself.
    @ViewBuilder
    func brainListClearRow(edgeToEdge: Bool = false) -> some View {
        let row = listRowBackground(Color.clear).listRowSeparator(.hidden)
        if edgeToEdge {
            row.listRowInsets(EdgeInsets())
        } else {
            row
        }
    }

    /// The one card surface: the neutral `.hxCard()`, clipped to its shape so covers
    /// keep the corners. Shared by `BrainCard` and the quote cards.
    func brainCardSurface() -> some View {
        clipShape(BrainStyle.cardShape()).hxCard(cornerRadius: BrainStyle.cardCorner)
    }
}

extension BrainModuleID {
    /// The paper a page of this kind wears inside the Brain (DESIGN.md § The object key):
    /// its source's Daily Brief paper. Chat citations stay `.knowledge`.
    var paper: HermexPaper {
        switch self {
        case .wiki: .wiki
        case .people: .advisor
        case .journal: .past
        case .articles: .reading
        case .highlights: .book
        // Letters to his daughter wear the Daily Deck's Dad card paper.
        case .letters: .advisor
        }
    }

    /// One page of this kind, for card and row labels ("Wiki", "Person").
    var kindName: String {
        switch self {
        case .wiki: "Wiki"
        case .people: "Person"
        case .journal: "Journal"
        case .articles: "Article"
        case .highlights: "Highlight"
        case .letters: "Letter"
        }
    }

    /// The SF Symbol for the module's icon tile.
    var symbolName: String {
        switch self {
        case .people: "person.2"
        case .wiki: "books.vertical"
        case .articles: "newspaper"
        case .journal: "book.closed"
        case .highlights: "quote.opening"
        case .letters: "heart"
        }
    }
}

// MARK: - Shared views

/// A module's SF Symbol on a glow tile in its paper (each kind's `BrainModuleID.paper`),
/// or a neutral tile without one, for a row's leading slot. Decorative: the row's title
/// names the module.
struct BrainModuleIcon: View {
    let symbolName: String
    let paper: HermexPaper?
    @ScaledMetric(relativeTo: .body) private var side = BrainStyle.iconSize

    init(systemName: String, paper: HermexPaper? = nil) {
        self.symbolName = systemName
        self.paper = paper
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
        Image(systemName: symbolName)
            .font(BrainStyle.rowSubtitle.weight(.semibold))
            .foregroundStyle(paper?.glow ?? Color.hxTextSecondary)
            .frame(width: side, height: side)
            .background(paper?.wash ?? Color.hxCanvas, in: shape)
            .overlay(shape.strokeBorder(paper?.edge ?? Color.hxSeparator, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// A person's initials in a neutral circle, for a row's leading slot. Decorative:
/// the row's title carries the name.
struct BrainMonogram: View {
    let name: String
    var size: CGFloat = BrainStyle.thumbnailSize
    /// The initials' role font; larger avatars (the person card) pass a larger role.
    var font: Font = BrainStyle.meta

    /// Up to two initials, from the first two words of `name`.
    static func initials(for name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
    }

    var body: some View {
        Text(verbatim: Self.initials(for: name))
            .font(font.weight(.semibold))
            .foregroundStyle(Color.hxTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: size, height: size)
            .background(Color.hxCanvas, in: Circle())
            .overlay { Circle().strokeBorder(Color.hxSeparator, lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

/// The one Brain row: a leading slot (cover thumbnail, avatar or icon), a title, an
/// optional subtitle and an optional trailing count or badge.
struct BrainRow<Leading: View>: View {
    let leading: Leading
    let title: String
    let subtitle: String?
    let trailing: String?
    /// The trailing text's colour when it marks an object (a due catch-up's opener glow).
    let trailingTint: Color?
    /// A trailing accent capsule (e.g. an upcoming birthday); read by VoiceOver.
    let badge: String?
    let subtitleLineLimit: Int
    /// Nil lets the title wrap in full (the card grows), for rows whose title is a sentence.
    let titleLineLimit: Int?

    init(
        @ViewBuilder leading: () -> Leading,
        title: String,
        subtitle: String? = nil,
        trailing: String? = nil,
        trailingTint: Color? = nil,
        badge: String? = nil,
        subtitleLineLimit: Int = 2,
        titleLineLimit: Int? = 2
    ) {
        self.leading = leading()
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.trailingTint = trailingTint
        self.badge = badge
        self.subtitleLineLimit = subtitleLineLimit
        self.titleLineLimit = titleLineLimit
    }

    var body: some View {
        HStack(alignment: .center, spacing: BrainStyle.m) {
            leading
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: title)
                    .brainText(.rowTitle)
                    .lineLimit(titleLineLimit)
                    .fixedSize(horizontal: false, vertical: titleLineLimit == nil)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .brainText(.rowSubtitle)
                        .lineLimit(subtitleLineLimit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let badge, !badge.isEmpty {
                BrainBadge(text: badge)
            }
            if let trailing, !trailing.isEmpty {
                Text(verbatim: trailing)
                    .font(BrainStyle.Role.meta.font)
                    .foregroundStyle(trailingTint ?? BrainStyle.Role.meta.color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, BrainStyle.s)
        .frame(minHeight: BrainStyle.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A small capsule in the Brain's glow and the `meta` role, for a row's trailing badge.
struct BrainBadge: View {
    let text: String

    var body: some View {
        let paper = HermexPaper.knowledge
        Text(verbatim: text)
            .font(BrainStyle.meta.weight(.semibold))
            .foregroundStyle(paper.glow)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, BrainStyle.s)
            .padding(.vertical, BrainStyle.xs)
            .background(paper.wash, in: Capsule())
            .overlay(Capsule().strokeBorder(paper.edge, lineWidth: 0.5))
    }
}

extension BrainRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, trailing: String? = nil, badge: String? = nil,
         subtitleLineLimit: Int = 2, titleLineLimit: Int? = 2) {
        self.init(leading: { EmptyView() }, title: title, subtitle: subtitle, trailing: trailing,
                  badge: badge, subtitleLineLimit: subtitleLineLimit, titleLineLimit: titleLineLimit)
    }
}

/// The one Brain card: a cover on top, then the title and a meta line, on the
/// `SectionCard` corner and padding. Used by the cover grids. The `tile` style
/// (book grids) drops the visible meta line and tightens the padding; VoiceOver
/// still reads the meta.
struct BrainCard: View {
    enum Style { case standard, tile }

    let item: BrainItem
    private let style: Style
    /// Built once per card, never in `body`.
    private let cover: BrainCoverSpec
    private let meta: String

    init(item: BrainItem, style: Style = .standard) {
        self.item = item
        self.style = style
        self.cover = BrainCoverSpec.make(id: item.id, tag: item.tags.first)
        self.meta = Self.metaLine(for: item)
    }

    /// The meta line: subtitle (source, kind) and date, whichever are present.
    static func metaLine(for item: BrainItem, locale: Locale = .current) -> String {
        [item.subtitle, BrainStyle.displayDate(item.date, locale: locale)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        let shape = BrainStyle.cardShape()
        let padding = style == .tile ? BrainStyle.s : BrainStyle.cardHorizontalPadding
        VStack(alignment: .leading, spacing: 0) {
            // A clear box sized by the card's width carries the cover, so the cover
            // always spans the full card instead of fitting a narrower proposal.
            Color.clear
                .aspectRatio(BrainStyle.coverAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { BrainCoverView(spec: cover).drawingGroup() }
                .clipped()
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: item.title)
                    .brainText(.rowTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if style == .standard, !meta.isEmpty {
                    Text(verbatim: meta)
                        .brainText(.meta)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, padding)
            .padding(.vertical, style == .tile ? BrainStyle.s : BrainStyle.cardVerticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .brainCardSurface()
        .contentShape(shape)
        // One element reading the title and the meta, in both styles; the cover is decorative.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [item.title, meta].filter { !$0.isEmpty }.joined(separator: ", ")))
    }
}

/// The one tag chip, for filters and reader tags. Purely visual: wrap it in a
/// `Button` to make it act. Selected chips take the accent colour.
struct BrainTagChip: View {
    let tag: String
    var selected: Bool = false

    var body: some View {
        Text(verbatim: tag)
            .font(BrainStyle.sectionCaption.weight(.medium))
            .foregroundStyle(selected ? Color.hxOnAccent : Color.hxTextPrimary)
            .lineLimit(1)
            .padding(.horizontal, BrainStyle.m)
            .padding(.vertical, BrainStyle.s)
            .background {
                Capsule().fill(selected ? Color.accentColor : Color.hxSurface)
            }
            .overlay {
                Capsule().strokeBorder(selected ? Color.clear : Color.hxSeparator, lineWidth: 0.5)
            }
            .contentShape(Capsule())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The one section header (list groups, Linked from, Further reading), with an optional
/// count and trailing note. The title matches `HXSectionHeader`: rounded display, sentence case.
struct BrainSectionHeader: View {
    let title: String
    var count: Int?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
            Text(verbatim: title)
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            if let count {
                Text(verbatim: "\(count)")
                    .brainText(.sectionCaption)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if let trailing, !trailing.isEmpty {
                Text(verbatim: trailing)
                    .brainText(.sectionCaption)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
#Preview("Rows, cards, chips") {
    let items = [
        BrainItem(module: .articles, id: "articles/one.md", title: "How to give feedback that lands",
                  subtitle: "Harvard Business Review", date: "2026-09-30", tags: ["communication"]),
        BrainItem(module: .wiki, id: "wiki/agents.md", title: "Agent loops", subtitle: "Concept",
                  date: "2026-08-12", tags: ["llm"])
    ]
    return ScrollView {
        VStack(alignment: .leading, spacing: BrainStyle.l) {
            BrainSectionHeader(title: "Further reading", count: 12)
            ForEach(items) { item in
                BrainRow(leading: {
                    BrainCoverView(spec: .make(id: item.id, tag: item.tags.first))
                        .frame(width: BrainStyle.thumbnailSize, height: BrainStyle.thumbnailSize)
                        .clipShape(RoundedRectangle(cornerRadius: BrainStyle.thumbnailCorner, style: .continuous))
                }, title: item.title, subtitle: item.subtitle, trailing: "3")
            }
            BrainRow(title: "Sam Rivera", subtitle: "Friend")
            HStack(spacing: BrainStyle.s) {
                BrainTagChip(tag: "career", selected: true)
                BrainTagChip(tag: "habits")
                BrainTagChip(tag: "llm")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: BrainStyle.m), GridItem(.flexible())],
                      spacing: BrainStyle.m) {
                ForEach(items) { BrainCard(item: $0) }
            }
            Text(verbatim: "The obstacle is the way.")
                .brainText(.quote)
        }
        .padding(BrainStyle.l)
    }
    .background(Color.hxCanvas)
}
#endif
