import SwiftUI

/// The app's corner radii (DESIGN.md § Shape), always drawn `.continuous`.
enum HXRadius {
    /// Inline code, thumbnails, small tiles.
    static let xs: CGFloat = 6
    /// Rows, attachment tiles, tool-log rows, buttons.
    static let sm: CGFloat = 10
    /// Object cards, inset blocks, choice buttons.
    static let md: CGFloat = 14
    /// Section cards, action cards, the expanded composer.
    static let lg: CGFloat = 18
    /// Hero papers: Daily Brief cards and the Goal hero.
    static let xl: CGFloat = 28
    /// A chip's capsule where only a rounded rectangle is accepted (a zoom source); the
    /// rectangle clamps it to half the chip's height.
    static let capsule: CGFloat = 999
}

/// The app's shadows (DESIGN.md § Elevation). Everything inline in chat is flat.
enum HXShadow {
    /// A lifted hero paper; `stacked` is a card waiting behind the top one.
    case paper, stacked
    /// The composer and floating glass controls.
    case float
    /// A card floating over a dimmed screen (the approval overlay).
    case modal
}

extension EnvironmentValues {
    /// The paper a glow surface is drawn in, so controls inside it (decision buttons, submit)
    /// take its hue instead of black or the accent. `nil` on the app's own surfaces.
    @Entry var hxPaper: HermexPaper?
}

extension View {
    func hxShadow(_ shadow: HXShadow) -> some View {
        modifier(HXShadowModifier(shadow: shadow))
    }

    /// Draws the content as a glow object (DESIGN.md § Components): the paper's wash and edge in
    /// a `radius` rounded rect, its hue as the tint, and the paper in `\.hxPaper` for the
    /// controls inside. Text keeps the canvas colors; titles opt into `paper.glow`.
    /// `opaque` lays the wash over `hxSurface`, for cards that float over transcript text.
    func glowSurface(_ paper: HermexPaper, cornerRadius radius: CGFloat, opaque: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return tint(paper.glow)
            .background(paper.wash, in: shape)
            .background(opaque ? Color.hxSurface : Color.clear, in: shape)
            .overlay(shape.strokeBorder(paper.edge, lineWidth: 0.5))
            .environment(\.hxPaper, paper)
    }
}

private struct HXShadowModifier: ViewModifier {
    let shadow: HXShadow
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch shadow {
        case .paper:
            content.shadow(color: .black.opacity(0.08), radius: 14, y: 6)
        case .stacked:
            content.shadow(color: .black.opacity(0.06), radius: 10, y: 4)
        case .float:
            content.shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 14, y: 6)
        case .modal:
            content.shadow(color: .black.opacity(0.22), radius: 18, y: 12)
        }
    }
}

/// The object key (DESIGN.md § The object key): which paper each kind of thing wears in chat
/// and the drawer. A color means a kind, so two things share a paper only when they are the
/// same kind of thing.
extension HermexPaper {
    /// An approval, clarification, or anything else waiting on the user.
    static let request = HermexPaper.opener
    /// A Brain or wiki page.
    static let knowledge = HermexPaper.wiki
    /// A file read, written, listed, or searched (grep, find).
    static let file = HermexPaper.notes
    /// A web search or fetch.
    static let web = HermexPaper.video
    /// Memory and skills: what Atlas knows about itself.
    static let recall = HermexPaper.advisor
    /// Shell, code, and everything without a kind of its own.
    static let tool = HermexPaper.plain
    /// Money: net worth, accounts, and the market card.
    static let money = HermexPaper.ledger
    /// The in-app feedback inbox and its drawer row.
    static let feedback = HermexPaper.notes

    static func forTool(_ kind: ToolCallSummaryFormatter.Kind) -> HermexPaper {
        switch kind {
        case .read, .write, .list, .search: .file
        case .web: .web
        case .skill, .memory: .recall
        case .shell, .delegate, .unknown: .tool
        }
    }
}

/// A section's title above its rows or card (DESIGN.md § Components): the rounded display
/// voice in sentence case, like the Brief opener's "Today · 8 cards". Never uppercase.
struct HXSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title)
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            Spacer(minLength: 8)
            if let trailing {
                Text(verbatim: trailing)
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The neutral card (DESIGN.md § Components): `hxSurface` with an `hxSeparator` hairline,
    /// `lg` corners by default. Settings sections, list groups, and the Brief opener use it.
    func hxCard(cornerRadius radius: CGFloat = HXRadius.lg) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Color.hxSurface, in: shape)
            .overlay(shape.strokeBorder(Color.hxSeparator, lineWidth: 0.5))
    }
}

/// What a card is, which decides its fill, edge, corners, and shadow (DESIGN.md § Components, Card).
enum HXCardRole {
    /// One kind of thing (a Brief card, a review bite, the Goal hero, Catch up): the paper's
    /// opaque `card` fill and `edge`, `xl` corners, the `paper` shadow.
    case glow(HermexPaper)
    /// Grouped content on any screen: `hxSurface`, an `hxSeparator` edge, `lg` corners, flat.
    case neutral
    /// A card that sits among glow cards but summarizes them (the Brief opener, the review
    /// summary): neutral, at `xl` with the `paper` shadow.
    case summary
    /// A glow object floating over other content (Prep's run and home cards): the paper's wash
    /// over `hxSurface` through `glowSurface`, so its tint and `\.hxPaper` reach the controls inside.
    case wash(HermexPaper)

    var radius: CGFloat {
        if case .neutral = self { return HXRadius.lg }
        return HXRadius.xl
    }

    var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    /// The bare fill, for a card far down a stack that shows only its paper.
    var fill: Color {
        switch self {
        case .glow(let paper): paper.card
        case .neutral, .summary: .hxSurface
        case .wash(let paper): paper.wash
        }
    }

    /// The headline's color: the hue on a colored card, primary text on a neutral one.
    var titleColor: Color {
        switch self {
        case .glow(let paper), .wash(let paper): paper.glow
        case .neutral, .summary: .hxTextPrimary
        }
    }
}

extension View {
    /// Draws the content as a card of `role`. `clipsContent` cuts the content to the card's
    /// corners, for cards whose words scroll inside them (deck cards).
    func hxCardSurface(_ role: HXCardRole, clipsContent: Bool = false) -> some View {
        modifier(HXCardSurface(role: role, clipsContent: clipsContent))
    }
}

private struct HXCardSurface: ViewModifier {
    let role: HXCardRole
    let clipsContent: Bool

    func body(content: Content) -> some View {
        let shape = role.shape
        let clipped = Group {
            if clipsContent { content.clipShape(shape) } else { content }
        }
        switch role {
        case .glow(let paper):
            clipped
                .background(paper.card, in: shape)
                .overlay(shape.strokeBorder(paper.edge, lineWidth: 0.5))
                .hxShadow(.paper)
        case .neutral:
            clipped.hxCard(cornerRadius: role.radius)
        case .summary:
            clipped.hxCard(cornerRadius: role.radius).hxShadow(.paper)
        case .wash(let paper):
            clipped.glowSurface(paper, cornerRadius: role.radius, opaque: true).hxShadow(.paper)
        }
    }
}

/// The one card (DESIGN.md § Components, Card): an optional kicker, a headline in the rounded
/// display voice (in the hue on a colored card), the body, and an optional footer, stacked
/// with `spacing` and padded on a `hxCardSurface`. Text keeps the colors its caller gives it;
/// only the headline takes the role's color. Cards whose words scroll inside them (deck cards)
/// use `hxCardSurface` directly.
struct HXCard<Kicker: View, Content: View, Footer: View>: View {
    let role: HXCardRole
    var title: String?
    var titleStyle: Font.TextStyle
    var spacing: CGFloat
    let kicker: Kicker
    let content: Content
    let footer: Footer

    /// The padding inside every card.
    static var padding: CGFloat { 16 }

    init(_ role: HXCardRole, title: String? = nil, titleStyle: Font.TextStyle = .headline, spacing: CGFloat = 8,
         @ViewBuilder kicker: () -> Kicker, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.role = role
        self.title = title
        self.titleStyle = titleStyle
        self.spacing = spacing
        self.kicker = kicker()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            kicker
            if let title {
                Text(verbatim: title)
                    .font(AppFont.display(style: titleStyle, weight: .semibold))
                    .foregroundStyle(role.titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Self.padding)
        .hxCardSurface(role)
    }
}

extension HXCard where Kicker == EmptyView, Footer == EmptyView {
    init(_ role: HXCardRole, title: String? = nil, titleStyle: Font.TextStyle = .headline, spacing: CGFloat = 8,
         @ViewBuilder content: () -> Content) {
        self.init(role, title: title, titleStyle: titleStyle, spacing: spacing,
                  kicker: { EmptyView() }, content: content, footer: { EmptyView() })
    }
}

/// The one header title (DESIGN.md § Header): centered, the rounded display voice, an optional
/// subtitle under it. Sits in the toolbar's principal slot, between the leading glass circle
/// and the trailing glass capsule.
struct HXNavigationTitle: View {
    let title: String
    var subtitle: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: title)
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let subtitle, !dynamicTypeSize.isAccessibilitySize {
                Text(verbatim: subtitle)
                    .font(AppFont.caption2())
                    .foregroundStyle(Color.hxTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [title, subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The shared header: an inline navigation title (it still names the back button) drawn as
    /// `HXNavigationTitle`.
    func hxNavigationTitle(_ title: String, subtitle: String? = nil) -> some View {
        navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HXNavigationTitle(title: title, subtitle: subtitle)
                }
            }
    }
}

/// A capsule naming one thing in its paper's glow: symbol, label, and an optional trailing
/// mark. Tool calls, run counts, Brain citations, and source badges are all this chip.
struct HXChip<Trailing: View>: View {
    let paper: HermexPaper
    var symbol: String?
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(AppFont.caption2(weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(verbatim: label)
                .font(AppFont.caption(weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            trailing()
        }
        .foregroundStyle(paper.glow)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(paper.wash, in: Capsule())
        .overlay(Capsule().strokeBorder(paper.edge, lineWidth: 0.5))
    }
}

extension HXChip where Trailing == EmptyView {
    init(paper: HermexPaper, symbol: String? = nil, label: String) {
        self.init(paper: paper, symbol: symbol, label: label) { EmptyView() }
    }
}

/// Chips left to right, wrapping onto new rows. A chip wider than the row (large text) is
/// offered the row's width so it truncates instead of running off the edge.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, maxWidth: width)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = Self.size(of: view, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private static func size(of view: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return view.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

// MARK: - Open card

/// The button an open card pins at its foot, naming where it leads ("Open the article").
struct HXCardAction {
    let title: String
    let perform: () -> Void
}

extension View {
    /// Makes a card open into itself (DESIGN.md § Components, Open card): a tap zooms the card
    /// to fill the screen in its role's fill, showing `full`, under a close button and `title`,
    /// with `action` pinned at the foot. Controls inside the card keep their taps, and a touch
    /// that moves (a swipe) never opens it. The action runs once the card has closed.
    func opensAsFullCard<Full: View>(
        _ role: HXCardRole,
        title: String? = nil,
        action: HXCardAction? = nil,
        @ViewBuilder full: @escaping () -> Full
    ) -> some View {
        modifier(OpensAsFullCard(role: role, title: title, action: action, full: full))
    }
}

private struct OpensAsFullCard<Full: View>: ViewModifier {
    let role: HXCardRole
    let title: String?
    let action: HXCardAction?
    let full: () -> Full

    @Namespace private var zoom
    @State private var isOpen = false
    /// The foot button's action, run after the cover is gone so a push lands on the stack.
    @State private var pending: HXCardAction?

    private static var sourceID: String { "card" }

    func body(content: Content) -> some View {
        content
            .matchedTransitionSource(id: Self.sourceID, in: zoom) { source in
                source.clipShape(role.shape)
            }
            .contentShape(role.shape)
            .onTapGesture { isOpen = true }
            .accessibilityAction(named: Text(verbatim: "Open Card")) { isOpen = true }
            .fullScreenCover(isPresented: $isOpen, onDismiss: runPending) {
                HXFullCard(role: role, title: title, action: action.map { action in
                    HXCardAction(title: action.title) {
                        pending = action
                        isOpen = false
                    }
                }, close: { isOpen = false }, content: full)
                .navigationTransition(.zoom(sourceID: Self.sourceID, in: zoom))
            }
    }

    private func runPending() {
        guard let action = pending else { return }
        pending = nil
        action.perform()
    }
}

/// A card opened to fill the screen: its role's fill edge to edge, a glass close button and the
/// title above the content, and the primary action at the foot. Swiping down also closes it.
private struct HXFullCard<Content: View>: View {
    let role: HXCardRole
    let title: String?
    let action: HXCardAction?
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let action { foot(action) }
            }
            .foregroundStyle(role.titleColor)
            .background(role.fill.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(AppFont.body(weight: .semibold))
                    .frame(width: 44, height: 44)
                    .adaptiveGlass(.regular, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Close"))
            Spacer(minLength: 0)
        }
        .overlay {
            if let title {
                Text(verbatim: title)
                    .font(AppFont.display(style: .subheadline, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 56)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func foot(_ action: HXCardAction) -> some View {
        Button(action: action.perform) {
            HStack(spacing: 6) {
                Text(verbatim: action.title)
                Image(systemName: "chevron.forward").accessibilityHidden(true)
            }
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(onFill)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // The card's own fill behind the button, so the words scroll under it, not around it.
        .background(role.fill.ignoresSafeArea(edges: .bottom))
    }

    /// A colored card's primary button fills with its glow; a neutral one's with Nous blue.
    private var fill: Color {
        switch role {
        case .glow(let paper), .wash(let paper): paper.glow
        case .neutral, .summary: .accentColor
        }
    }

    private var onFill: Color {
        switch role {
        case .glow(let paper), .wash(let paper): paper.onGlow
        case .neutral, .summary: .white
        }
    }
}
