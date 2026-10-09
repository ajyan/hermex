import SwiftUI

/// A seeded radial layout: the centre node at the midpoint, every other node on one
/// ring. Pure and deterministic, so the same graph always lands the same way.
enum BrainGraphLayout {
    /// The ring radius as a share of the shorter side.
    static let ringScale: CGFloat = 0.36

    static func positions(nodeIDs: [String], centerID: String, size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * ringScale
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
                x: center.x + radius * CGFloat(cos(angle)),
                y: center.y + radius * CGFloat(sin(angle))
            )
        }
        return positions
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
/// buttons that open that node. No physics and no animation.
struct BrainGraphView: View {
    let graph: BrainGraph
    let centerID: String
    let ramp: Int
    let onOpen: (BrainModuleID, String) -> Void

    static let height: CGFloat = 180
    /// More neighbours than this would overlap on a phone-width ring.
    static let maxNeighbours = 8
    private static let centerDot: CGFloat = 16
    private static let neighbourDot: CGFloat = 9
    private static let labelMaxWidth: CGFloat = 120

    /// The neighbours shown: the heaviest first, ties by id, capped to fit.
    static func visibleNodes(of graph: BrainGraph, centerID: String) -> [BrainGraphNode] {
        var seen = Set<String>()
        let unique = graph.nodes.filter { $0.id != centerID && seen.insert($0.id).inserted }
        return Array(
            unique.sorted { ($0.weight, $1.id) > ($1.weight, $0.id) }.prefix(maxNeighbours)
        )
    }

    var body: some View {
        let colors = BrainStyle.coverRamp(ramp)
        let neighbours = Self.visibleNodes(of: graph, centerID: centerID)
        let ids = [centerID] + neighbours.map(\.id)
        let visible = Set(ids)
        let edges = graph.edges.filter { visible.contains($0.a) && visible.contains($0.b) && $0.a != $0.b }

        GeometryReader { proxy in
            let size = proxy.size
            let positions = BrainGraphLayout.positions(nodeIDs: ids, centerID: centerID, size: size)
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
                        let side = isCenter ? Self.centerDot : Self.neighbourDot
                        let dot = Path(ellipseIn: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
                        context.fill(dot, with: .color(isCenter ? colors.strong : colors.mid))
                        if !isCenter {
                            context.stroke(dot, with: .color(colors.strong), lineWidth: 1)
                        }
                    }
                }
                .accessibilityHidden(true)

                ForEach(neighbours, id: \.id) { node in
                    if let point = positions[node.id] {
                        label(for: node)
                            .position(labelPosition(for: point, in: size))
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

    private func label(for node: BrainGraphNode) -> some View {
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
                .frame(maxWidth: Self.labelMaxWidth)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, BrainStyle.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(Text(verbatim: "\(title), open"))
    }

    /// Below the dot for nodes under the centre line, above it otherwise, kept inside
    /// the header horizontally.
    private func labelPosition(for point: CGPoint, in size: CGSize) -> CGPoint {
        let below = point.y >= size.height / 2
        let y = point.y + (below ? 1 : -1) * (Self.neighbourDot / 2 + 10)
        let half = Self.labelMaxWidth / 2
        let x = size.width > 2 * (half + BrainStyle.s)
            ? min(max(point.x, half + BrainStyle.s), size.width - half - BrainStyle.s)
            : size.width / 2
        return CGPoint(x: x, y: y)
    }
}

#if DEBUG
#Preview("Graph header") {
    let nodes = [
        BrainGraphNode(module: .wiki, id: "wiki/virtues.md", title: "Virtues", weight: 9),
        BrainGraphNode(module: .wiki, id: "wiki/courage.md", title: "Courage", weight: 4),
        BrainGraphNode(module: .journal, id: "journal/2026-09-01.md", title: "1 September", weight: 2),
        BrainGraphNode(module: .articles, id: "articles/stoa.md", title: "The Stoa and the city", weight: 3),
        BrainGraphNode(module: .wiki, id: "wiki/temperance.md", title: "Temperance", weight: 1),
        BrainGraphNode(module: .people, id: "people/sam.md", title: "Sam Rivera", weight: 1)
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
