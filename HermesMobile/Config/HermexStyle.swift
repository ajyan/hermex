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

    static func forTool(_ kind: ToolCallSummaryFormatter.Kind) -> HermexPaper {
        switch kind {
        case .read, .write, .list, .search: .file
        case .web: .web
        case .skill, .memory: .recall
        case .shell, .delegate, .unknown: .tool
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
