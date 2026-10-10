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

/// The app's two shadows (DESIGN.md § Elevation). Everything inline in chat is flat.
enum HXShadow {
    /// A lifted hero paper; `stacked` is a card waiting behind the top one.
    case paper, stacked
    /// The composer and floating glass controls.
    case float
}

extension EnvironmentValues {
    /// The paper a view is drawn on, so controls inside it (decision buttons, submit) take
    /// its ink instead of black or the accent. `nil` on the app's own surfaces.
    @Entry var hxPaper: HermexPaper?
}

extension View {
    func hxShadow(_ shadow: HXShadow) -> some View {
        modifier(HXShadowModifier(shadow: shadow))
    }

    /// Draws the content on `paper`: the paper fill in a `radius` rounded rect, ink as the
    /// foreground, and light appearance so system text and controls stay legible on it in
    /// either app appearance.
    func paperSurface(_ paper: HermexPaper, cornerRadius radius: CGFloat) -> some View {
        foregroundStyle(paper.ink)
            .tint(paper.ink)
            .background(paper.paper, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .environment(\.hxPaper, paper)
            .environment(\.colorScheme, .light)
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
        }
    }
}

/// The object key (DESIGN.md § The object key): which paper each kind of thing wears in chat
/// and the drawer. A color means a kind, so two things share a paper only when they are the
/// same kind of thing.
extension HermexPaper {
    /// An approval, clarification, or anything else waiting on the user.
    static let request = HermexPaper.opener
    /// A Brain or wiki page, and a search through the user's own knowledge.
    static let knowledge = HermexPaper.wiki
    /// A file read, written, or listed.
    static let file = HermexPaper.notes
    /// A web search or fetch.
    static let web = HermexPaper.video
    /// Memory and skills: what Atlas knows about itself.
    static let recall = HermexPaper.advisor
    /// Shell, code, and everything without a kind of its own.
    static let tool = HermexPaper.plain

    static func forTool(_ kind: ToolCallSummaryFormatter.Kind) -> HermexPaper {
        switch kind {
        case .read, .write, .list: .file
        case .search: .knowledge
        case .web: .web
        case .skill, .memory: .recall
        case .shell, .delegate, .unknown: .tool
        }
    }
}

/// Chips left to right, wrapping onto new rows.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
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
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
