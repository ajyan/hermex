import SwiftUI

/// A seeded elliptical layout: the centre node at the midpoint, every other node on
/// one ellipse, and each neighbour's label beside its dot, pointing outward. Pure and
/// deterministic, so the same graph always lands the same way.
enum BrainGraphLayout {
    /// The ellipse's radii as shares of the width and height.
    static let radiusXScale: CGFloat = 0.20
    static let radiusYScale: CGFloat = 0.30
    /// A label's width as a share of the width; titles truncate inside it.
    static let labelWidthScale: CGFloat = 0.25
    /// More neighbours than this cannot all get a 44pt label row on a 180pt header.
    static let maxNeighbours = 6
    static let centerDot = BrainStyle.l
    static let neighbourDot = BrainStyle.s
    /// Gap between a dot and its label, as wide as the centre dot's radius. With
    /// `radiusXScale + labelWidthScale` at 0.45, a label plus gap and inset fits
    /// beside its dot on any width of 240pt or more, so no clamp pushes it back.
    static let labelGap = BrainStyle.s
    /// Labels and their hit-rects stay this far inside the header.
    static let edgeInset = BrainStyle.xs

    /// The neighbours shown: the heaviest first, ties by id, de-duplicated by id
    /// (first occurrence wins), without the centre, capped at `maxNeighbours`.
    static func visibleNodes(of graph: BrainGraph, centerID: String) -> [BrainGraphNode] {
        var seen = Set<String>()
        let unique = graph.nodes.filter { $0.id != centerID && seen.insert($0.id).inserted }
        return Array(
            unique.sorted { ($0.weight, $1.id) > ($1.weight, $0.id) }.prefix(maxNeighbours)
        )
    }

    static func positions(nodeIDs: [String], centerID: String, size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rx = size.width * radiusXScale
        let ry = size.height * radiusYScale
        // Sorted and de-duplicated, so input order never moves a node.
        let neighbours = Set(nodeIDs).subtracting([centerID]).sorted()
        let offset = seedOffset(centerID)

        var positions: [String: CGPoint] = [:]
        if nodeIDs.contains(centerID) {
            positions[centerID] = center
        }
        for (index, id) in neighbours.enumerated() {
            let angle = 2 * Double.pi * Double(index) / Double(neighbours.count) + offset
            positions[id] = CGPoint(
                x: center.x + rx * CGFloat(cos(angle)),
                y: center.y + ry * CGFloat(sin(angle))
            )
        }
        return positions
    }

    /// Each neighbour's label hit-rect, at least 44pt tall and `labelWidthScale` wide.
    /// A label sits outward from its dot: leading-aligned to the right of dots on the
    /// right half, trailing-aligned to the left of dots on the left half. Each half
    /// takes at most three labels, stacked so their rects never overlap; the ellipse
    /// and label widths keep every rect off every dot.
    static func labelFrames(nodeIDs: [String], centerID: String, size: CGSize, labelHeight: CGFloat) -> [String: CGRect] {
        let points = positions(nodeIDs: nodeIDs, centerID: centerID, size: size)
        let midX = size.width / 2
        let width = size.width * labelWidthScale
        let height = max(labelHeight, BrainStyle.minTapTarget)
        let neighbours = points.keys.filter { $0 != centerID }
            .sorted { (points[$0]!.x, $0) < (points[$1]!.x, $1) }

        // Balance the halves so neither stacks more than three 44pt rows.
        let perSide = 3
        let leftOfCentre = neighbours.filter { points[$0]!.x < midX }.count
        let leftCount = min(perSide, max(neighbours.count - perSide, leftOfCentre))
        let left = Array(neighbours.prefix(leftCount))
        let right = Array(neighbours.dropFirst(leftCount))

        var frames: [String: CGRect] = [:]
        let minY = edgeInset + height / 2
        let maxY = size.height - edgeInset - height / 2
        for (ids, isRight) in [(left, false), (right, true)] {
            let stacked = stack(ids.map { ($0, points[$0]!.y) }, height: height, minY: minY, maxY: maxY)
            for (id, midY) in stacked {
                let dotX = points[id]!.x
                let x: CGFloat
                if isRight {
                    let desired = max(dotX, midX) + labelGap
                    x = max(edgeInset, min(desired, size.width - edgeInset - width))
                } else {
                    let desired = min(dotX, midX) - labelGap - width
                    x = min(size.width - edgeInset - width, max(desired, edgeInset))
                }
                frames[id] = CGRect(x: x, y: midY - height / 2, width: width, height: height)
            }
        }
        return frames
    }

    /// Moves label centres the least needed so they sit `height` apart within
    /// `minY...maxY`, keeping their top-to-bottom order.
    private static func stack(_ labels: [(String, CGFloat)], height: CGFloat, minY: CGFloat, maxY: CGFloat) -> [(String, CGFloat)] {
        var sorted = labels.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        guard !sorted.isEmpty else { return [] }
        for index in sorted.indices {
            let floor = index == 0 ? minY : sorted[index - 1].1 + height
            sorted[index].1 = max(sorted[index].1, floor)
        }
        for index in sorted.indices.reversed() {
            let ceiling = index == sorted.count - 1 ? maxY : sorted[index + 1].1 - height
            sorted[index].1 = min(sorted[index].1, ceiling)
        }
        return sorted
    }

    /// A stable starting angle in `0..<2π` from the centre's id, so different pages
    /// do not all put their first neighbour at three o'clock.
    static func seedOffset(_ centerID: String) -> Double {
        var rng = SplitMix64(seed: BrainCoverSpec.fnv1a64(centerID))
        return rng.nextUnit() * 2 * Double.pi
    }
}

/// The reader's connection header: a static map of the page and its neighbours on
/// the page's cover hue. Edges and dots are one `Canvas` pass; neighbour labels are
/// buttons, placed in `BrainGraphLayout.labelFrames`, that open that node. No
/// physics and no animation.
struct BrainGraphView: View {
    let graph: BrainGraph
    let centerID: String
    let ramp: Int
    let onOpen: (BrainModuleID, String) -> Void

    static let height: CGFloat = 180
    @ScaledMetric(relativeTo: .caption) private var labelHeight: CGFloat = 20

    var body: some View {
        let colors = BrainStyle.coverRamp(ramp)
        let neighbours = BrainGraphLayout.visibleNodes(of: graph, centerID: centerID)
        let ids = [centerID] + neighbours.map(\.id)
        let visible = Set(ids)
        let edges = graph.edges.filter { visible.contains($0.a) && visible.contains($0.b) && $0.a != $0.b }

        GeometryReader { proxy in
            let size = proxy.size
            let positions = BrainGraphLayout.positions(nodeIDs: ids, centerID: centerID, size: size)
            let frames = BrainGraphLayout.labelFrames(
                nodeIDs: ids, centerID: centerID, size: size, labelHeight: labelHeight
            )
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { context, canvasSize in
                    context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(colors.background))
                    var lines = Path()
                    for edge in edges {
                        guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
                        lines.move(to: a)
                        lines.addLine(to: b)
                    }
                    context.stroke(lines, with: .color(colors.mid), lineWidth: 1.2)
                    for id in ids {
                        guard let point = positions[id] else { continue }
                        let isCenter = id == centerID
                        let side = isCenter ? BrainGraphLayout.centerDot : BrainGraphLayout.neighbourDot
                        let dot = Path(ellipseIn: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
                        context.fill(dot, with: .color(isCenter ? colors.strong : colors.mid))
                        if !isCenter {
                            context.stroke(dot, with: .color(colors.strong), lineWidth: 1)
                        }
                    }
                }
                .accessibilityHidden(true)

                ForEach(neighbours, id: \.id) { node in
                    if let frame = frames[node.id] {
                        label(for: node, in: frame, trailing: frame.midX < size.width / 2)
                    }
                }
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Connections"))
    }

    /// A label filling exactly its layout frame: the whole rect is the hit target,
    /// and the visible capsule hugs the dot's side of it.
    private func label(for node: BrainGraphNode, in frame: CGRect, trailing: Bool) -> some View {
        let title = node.title.isEmpty ? node.id : node.title
        return Button {
            onOpen(node.module, node.id)
        } label: {
            Text(verbatim: title)
                .font(BrainStyle.meta.weight(.medium))
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, BrainStyle.s)
                .padding(.vertical, BrainStyle.xs / 2)
                .background(Color.hxSurface.opacity(0.88), in: Capsule())
                .frame(width: frame.width, height: frame.height, alignment: trailing ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(x: frame.midX, y: frame.midY)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(Text(verbatim: "\(title), open"))
    }
}

#if DEBUG
#Preview("Graph header") {
    let nodes = [
        BrainGraphNode(module: .wiki, id: "wiki/virtues.md", title: "Virtues", weight: 9),
        BrainGraphNode(module: .wiki, id: "wiki/courage.md", title: "Courage under pressure and uncertainty", weight: 4),
        BrainGraphNode(module: .journal, id: "journal/2026-09-01.md", title: "Monday 1 September, a long walk home", weight: 2),
        BrainGraphNode(module: .articles, id: "articles/stoa.md", title: "The Stoa and the city: a short history", weight: 3),
        BrainGraphNode(module: .wiki, id: "wiki/temperance.md", title: "Temperance as a daily practice", weight: 1),
        BrainGraphNode(module: .people, id: "people/sam.md", title: "Sam Rivera from the design team", weight: 1),
        BrainGraphNode(module: .wiki, id: "wiki/justice.md", title: "Justice and fairness in small things", weight: 1)
    ]
    let edges = nodes.dropFirst().map { BrainGraphEdge(a: "wiki/virtues.md", b: $0.id) }
        + [BrainGraphEdge(a: "wiki/courage.md", b: "wiki/temperance.md")]
    return VStack(spacing: 16) {
        ForEach([0, 3, 5], id: \.self) { ramp in
            BrainGraphView(graph: BrainGraph(nodes: nodes, edges: edges), centerID: "wiki/virtues.md",
                           ramp: ramp, onOpen: { _, _ in })
        }
    }
    .background(Color.hxCanvas)
}
#endif
