import SwiftUI
import UIKit

/// The one style source for every Brain module (and modules built like it).
///
/// Views reference these roles and constants, never raw fonts or numbers, so the
/// five modules read as one library. Chrome stays neutral `hx*` plus the accent;
/// only covers and graph headers take a hue, from `coverPalette`.
enum BrainStyle {
    // MARK: Type roles (all Dynamic Type text styles)

    /// For in-content headings that stand in for a large navigation title. Screens
    /// themselves use `.navigationTitle` with the large display mode.
    static let screenTitle: Font = .largeTitle.weight(.bold)
    static let sectionCaption: Font = AppFont.footnote()
    static let rowTitle: Font = AppFont.body()
    static let rowSubtitle: Font = AppFont.subheadline()
    static let meta: Font = AppFont.caption()
    static let readerTitle: Font = AppFont.title(weight: .semibold)
    /// The only serif in the Brain: highlights and best-quote blocks.
    static let quote: Font = .system(.body, design: .serif).leading(.loose)

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

    static let cardCorner: CGFloat = 18
    static let cardHorizontalPadding: CGFloat = 16
    static let cardVerticalPadding: CGFloat = 14
    /// Corner for cover thumbnails and tiles inside rows.
    static let thumbnailCorner: CGFloat = 8
    /// Base side of a row's leading thumbnail; scale it with `@ScaledMetric`.
    static let thumbnailSize: CGFloat = 44
    /// Width over height for cover art on cards and grids.
    static let coverAspectRatio: CGFloat = 3 / 2
    /// Base side of a module icon tile (home rows); scale it with `@ScaledMetric`.
    static let iconSize: CGFloat = 32
    /// Base side of a search result's cover or avatar; scale it with `@ScaledMetric`.
    static let searchThumbnailSize: CGFloat = 28

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

    /// The 8 cover ramps, as `(background, mid, strong)` in `0xRRGGBB`, light then dark.
    /// Indices 0–5 are pinned to tags in `BrainCoverSpec.tagRamps`.
    static let coverPaletteValues: [(light: (UInt32, UInt32, UInt32), dark: (UInt32, UInt32, UInt32))] = [
        (light: (0xE6EEFC, 0xA9C2F0, 0x3F6FD1), dark: (0x16233A, 0x2C4A7A, 0x7FA4EC)), // 0 Nous blue
        (light: (0xE2F2F1, 0x9FD1CC, 0x2E8A83), dark: (0x12292A, 0x24504E, 0x6CC0B8)), // 1 teal
        (light: (0xE7F3E8, 0xAED4B2, 0x3E8B4C), dark: (0x172A1B, 0x2D5234, 0x7DC08A)), // 2 green
        (light: (0xFBEAE5, 0xEFB8A8, 0xC8604A), dark: (0x33201C, 0x5E3830, 0xE79A86)), // 3 coral
        (light: (0xEEE9F8, 0xC6B7E6, 0x6E54B5), dark: (0x241E36, 0x43385F, 0xA994E0)), // 4 purple
        (light: (0xFBF1DE, 0xEBCB8E, 0xA9761F), dark: (0x2E2414, 0x574321, 0xDDB062)), // 5 amber
        (light: (0xFAE8F0, 0xE9B3CB, 0xB4507E), dark: (0x321C27, 0x5A3247, 0xE08DB3)), // 6 pink
        (light: (0xEEF0F3, 0xC3C9D2, 0x5F6B7A), dark: (0x1E2228, 0x383F49, 0x9AA4B1))  // 7 gray
    ]

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

    /// The one card surface: `.hxSurface` in the 18pt continuous card shape with a
    /// hairline `hxSeparator` stroke. Shared by `BrainCard` and the quote cards.
    func brainCardSurface() -> some View {
        let shape = BrainStyle.cardShape()
        return background(Color.hxSurface, in: shape)
            .clipShape(shape)
            .overlay {
                shape.stroke(Color.hxSeparator.opacity(0.6), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
    }
}

extension BrainModuleID {
    /// The SF Symbol for the module's icon tile.
    var symbolName: String {
        switch self {
        case .people: "person.2"
        case .wiki: "books.vertical"
        case .articles: "newspaper"
        case .journal: "book.closed"
        case .highlights: "quote.opening"
        }
    }
}

// MARK: - Shared views

/// A module's SF Symbol in an accent-tinted rounded square, for a row's leading
/// slot. Decorative: the row's title names the module.
struct BrainModuleIcon: View {
    let symbolName: String
    @ScaledMetric(relativeTo: .body) private var side = BrainStyle.iconSize

    init(module: BrainModuleID) {
        self.symbolName = module.symbolName
    }

    init(systemName: String) {
        self.symbolName = systemName
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(BrainStyle.rowSubtitle.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: side, height: side)
            .background(
                Color.accentColor.opacity(0.14),
                in: RoundedRectangle(cornerRadius: BrainStyle.thumbnailCorner, style: .continuous)
            )
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
            .overlay { Circle().stroke(Color.hxSeparator, lineWidth: 0.7) }
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
    /// A trailing accent capsule (e.g. an upcoming birthday); read by VoiceOver.
    let badge: String?
    let subtitleLineLimit: Int

    init(
        @ViewBuilder leading: () -> Leading,
        title: String,
        subtitle: String? = nil,
        trailing: String? = nil,
        badge: String? = nil,
        subtitleLineLimit: Int = 2
    ) {
        self.leading = leading()
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.badge = badge
        self.subtitleLineLimit = subtitleLineLimit
    }

    var body: some View {
        HStack(alignment: .center, spacing: BrainStyle.m) {
            leading
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: title)
                    .brainText(.rowTitle)
                    .lineLimit(2)
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
                    .brainText(.meta)
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

/// A small accent-tinted capsule in the `meta` role, for a row's trailing badge.
struct BrainBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(BrainStyle.meta.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, BrainStyle.s)
            .padding(.vertical, BrainStyle.xs)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}

extension BrainRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, trailing: String? = nil, badge: String? = nil,
         subtitleLineLimit: Int = 2) {
        self.init(leading: { EmptyView() }, title: title, subtitle: subtitle, trailing: trailing,
                  badge: badge, subtitleLineLimit: subtitleLineLimit)
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
            BrainCoverView(spec: cover)
                .aspectRatio(BrainStyle.coverAspectRatio, contentMode: .fit)
                .drawingGroup()
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: item.title)
                    .brainText(.rowTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if style == .standard, !meta.isEmpty {
                    Text(verbatim: meta)
                        .brainText(.meta)
                        .lineLimit(2)
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
                Capsule().stroke(selected ? Color.clear : Color.hxSeparator, lineWidth: 0.7)
            }
            .contentShape(Capsule())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The one section header (list groups, Linked from, Further reading), with an optional trailing note.
struct BrainSectionHeader: View {
    let title: String
    var count: Int?
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
            Text(verbatim: title)
                .brainText(.sectionCaption)
                .fontWeight(.semibold)
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
