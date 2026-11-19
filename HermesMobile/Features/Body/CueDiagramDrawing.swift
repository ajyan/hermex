import SwiftUI

/// A cue diagram's four colours: the figure, its equipment, the cue with the working muscle, and
/// the surface behind it, which joint dots and the spine dashes are cut out in.
struct CueDiagramPalette: Equatable {
    let figure: Color
    let gear: Color
    let cue: Color
    let stage: Color

    /// Only the cue and the muscle wear the paper. The figure is primary text at full strength:
    /// softened, the muscle drawn on it in the paper's glow is too close to it to read.
    init(paper: HermexPaper, stage: Color) {
        figure = .hxTextPrimary
        gear = .hxTextSecondary
        cue = paper.glow
        self.stage = stage
    }
}

extension CueDiagramFigure {
    /// Draws the diagram at `progress` (0 the start pose, 1 the end of the effort), scaled to fit
    /// `size` and centred in it.
    func draw(in context: inout GraphicsContext, size: CGSize, progress: Double, palette: CueDiagramPalette) {
        let scale = min(size.width / viewBox.width, size.height / viewBox.height)
        guard scale > 0, scale.isFinite else { return }
        context.translateBy(x: (size.width - viewBox.width * scale) / 2, y: (size.height - viewBox.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -viewBox.minX, y: -viewBox.minY)
        CueDiagramPainter(figure: self, pose: pose(at: progress), progress: progress, palette: palette).paint(context)
    }
}

/// Draws one frame, in the diagram's own coordinates and in the schema's order: fixed equipment,
/// the ghost of the start pose, arrows and lines, the figure, held equipment, the spine dashes,
/// then rings and dots.
private struct CueDiagramPainter {
    let figure: CueDiagramFigure
    let pose: CueDiagramFigure.Pose
    let progress: Double
    let palette: CueDiagramPalette

    private var lift: CueDiagramLift { figure.lift }

    func paint(_ context: GraphicsContext) {
        for prop in lift.props { drawFixed(prop, context) }
        drawGhost(context)
        for cue in lift.cues { drawUnder(cue, context) }
        drawBody(context)
        for prop in lift.props { drawAttached(prop, context) }
        drawSpine(context)
        for cue in lift.cues { drawOver(cue, context) }
    }

    // MARK: Figure

    /// Where the rep starts, faint behind the moving figure.
    private func drawGhost(_ context: GraphicsContext) {
        let ghost = palette.figure.opacity(0.13)
        for bone in figure.farBones + figure.nearBones {
            limb(bone, in: figure.start, ghost, context)
        }
        if lift.view == .front {
            layer(context, opacity: 0.13) { torso(in: figure.start, $0) }
        }
        if let head = figure.start["head"] {
            disc(head, CueDiagramSkeleton.headRadius, ghost, context)
        }
    }

    private func drawBody(_ context: GraphicsContext) {
        switch lift.view {
        case .front:
            torso(in: pose, context)
            for bone in figure.nearBones { limb(bone, in: pose, palette.figure, context) }
            drawMuscles(context)
            drawHead(context)
            jointDots(CueDiagramSkeleton.frontJointDots, context)
        case .side:
            let far = figure.farBones
            if !far.isEmpty {
                layer(context, opacity: 0.55) { faint in
                    for bone in far { limb(bone, in: pose, palette.figure, faint) }
                    jointDots(CueDiagramSkeleton.sideFarJointDots, faint)
                }
            }
            for bone in figure.nearBones { limb(bone, in: pose, palette.figure, context) }
            drawHead(context)
            drawMuscles(context)
            jointDots(CueDiagramSkeleton.sideJointDots, context)
        }
    }

    private func limb(_ bone: CueDiagramSkeleton.Bone, in pose: CueDiagramFigure.Pose, _ color: Color, _ context: GraphicsContext) {
        guard let from = pose[bone.from], let to = pose[bone.to] else { return }
        line(from, to, color, width: bone.width, context)
    }

    /// The front view's torso: the shoulder and hip corners, filled, with a rounded outline.
    private func torso(in pose: CueDiagramFigure.Pose, _ context: GraphicsContext) {
        let corners = CueDiagramSkeleton.frontTorso.compactMap { pose[$0] }
        guard corners.count == CueDiagramSkeleton.frontTorso.count else { return }
        let path = polygon(corners)
        context.fill(path, with: .color(palette.figure))
        context.stroke(path, with: .color(palette.figure),
                       style: StrokeStyle(lineWidth: CueDiagramSkeleton.frontTorsoStroke, lineJoin: .round))
    }

    private func drawHead(_ context: GraphicsContext) {
        guard let head = pose["head"] else { return }
        disc(head, CueDiagramSkeleton.headRadius, palette.figure, context)
    }

    private func jointDots(_ joints: [String], _ context: GraphicsContext) {
        for joint in joints {
            guard let center = pose[joint] else { continue }
            let dot = circle(center, CueDiagramSkeleton.jointRadius)
            context.fill(dot, with: .color(palette.stage))
            context.stroke(dot, with: .color(palette.figure), lineWidth: 1.6)
        }
    }

    /// The working muscle, a quarter lit at the start and fully lit at the end of the effort.
    private func drawMuscles(_ context: GraphicsContext) {
        let shapes = lift.muscles.flatMap { figure.shapes(for: $0, in: pose) }
        guard !shapes.isEmpty else { return }
        layer(context, opacity: 0.25 + 0.75 * progress) { lit in
            for shape in shapes {
                switch shape {
                case .line(let from, let to, let width): line(from, to, palette.cue, width: width, lit)
                case .circle(let center, let radius): disc(center, radius, palette.cue, lit)
                case .polygon(let corners): lit.fill(polygon(corners), with: .color(palette.cue))
                }
            }
        }
    }

    /// The neutral-spine dashes along the torso, cut out in the stage colour.
    private func drawSpine(_ context: GraphicsContext) {
        guard lift.spine, lift.view == .side, let hip = pose["hip"], let shoulder = pose["shoulder"] else { return }
        line(hip, shoulder, palette.stage.opacity(0.5 + 0.5 * progress), width: 2.2, dash: [3, 4], context)
    }

    // MARK: Equipment

    /// Equipment that stands on its own, under the figure.
    private func drawFixed(_ prop: CueDiagramProp, _ context: GraphicsContext) {
        switch prop {
        case .floor(let from, let to):
            line(CGPoint(x: from, y: figure.floorY), CGPoint(x: to, y: figure.floorY), palette.gear, width: 4, context)
        case .wall(let x):
            line(CGPoint(x: x, y: figure.viewBox.minY + 4), CGPoint(x: x, y: figure.floorY), palette.gear, width: 4, context)
        case .box(let frame):
            context.stroke(Path(roundedRect: frame, cornerSize: CGSize(width: 3, height: 3)), with: .color(palette.gear),
                           style: StrokeStyle(lineWidth: 4, lineJoin: .round))
        case .bench(let from, let to, let posts):
            for post in posts {
                let top = CueDiagramGeometry.lerp(from, to, post)
                line(top, CGPoint(x: top.x, y: figure.floorY), palette.gear, width: 3, context)
            }
            line(from, to, palette.gear, width: 6, context)
        case .link(.bar, let from, let to) where !from.isAttached && !to.isAttached:
            drawLink(.bar, from, to, context)
        case .link, .dumbbell, .plate, .handle:
            break
        }
    }

    /// Equipment the figure holds or that is tied to it, over the figure.
    private func drawAttached(_ prop: CueDiagramProp, _ context: GraphicsContext) {
        switch prop {
        case .link(let kind, let from, let to) where kind != .bar || from.isAttached || to.isAttached:
            drawLink(kind, from, to, context)
        case .plate(let at):
            guard let center = figure.point(at, in: pose) else { return }
            disc(center, 9, palette.gear, context)
            disc(center, 2.5, palette.stage, context)
        case .handle(let at):
            guard let center = figure.point(at, in: pose) else { return }
            disc(center, 4.5, palette.gear, context)
        case .dumbbell(let at, let lie, let radius):
            guard let center = figure.point(at, in: pose) else { return }
            guard lie != .end else { return disc(center, radius, palette.gear, context) }
            // Seen lengthwise: upright, or across the forearm that holds it.
            var along = CGVector(dx: 0, dy: 1)
            if lie == .cross, case .named(let hand) = at, let elbow = CueDiagramSkeleton.forearmRoot[hand].flatMap({ pose[$0] }) {
                let distance = CueDiagramGeometry.distance(elbow, center)
                let length = distance == 0 ? 1 : distance
                along = CGVector(dx: -(center.y - elbow.y) / length, dy: (center.x - elbow.x) / length)
            }
            let ends = [-1.0, 1.0].map { CGPoint(x: center.x + along.dx * 8.5 * $0, y: center.y + along.dy * 8.5 * $0) }
            line(ends[0], ends[1], palette.gear, width: 4, context)
            for end in ends { disc(end, 5.5, palette.gear, context) }
        case .link, .floor, .wall, .box, .bench:
            break
        }
    }

    /// A bar, a band or a cable between two points; a cable's fixed end gets a pulley.
    private func drawLink(_ kind: CueDiagramProp.Link, _ from: CueDiagramPoint, _ to: CueDiagramPoint, _ context: GraphicsContext) {
        guard let start = figure.point(from, in: pose), let end = figure.point(to, in: pose) else { return }
        let width: Double = switch kind {
        case .bar: 4
        case .band: 3
        case .cable: 1.8
        }
        line(start, end, palette.gear, width: width, context)
        guard kind == .cable else { return }
        for case .fixed(let pulley) in [from, to] {
            disc(pulley, 3.5, palette.gear, context)
        }
    }

    // MARK: Cue marks

    /// Arrows and lines, under the figure.
    private func drawUnder(_ cue: CueDiagramCue, _ context: GraphicsContext) {
        switch cue {
        case .arrow(let from, let to, let dashed, let onEffort):
            guard let start = figure.point(from, in: pose), let end = figure.point(to, in: pose) else { return }
            layer(context, opacity: onEffort ? progress : 1) { mark in
                line(start, end, palette.cue, width: 3.2, dash: dashed ? [1, 7] : [], mark)
                arrowhead(from: start, to: end, mark)
            }
        case .line(let from, let to):
            guard let start = figure.point(from, in: pose), let end = figure.point(to, in: pose) else { return }
            line(start, end, palette.cue, width: 4, context)
        case .ring, .dot:
            break
        }
    }

    /// Rings and dots, over the figure.
    private func drawOver(_ cue: CueDiagramCue, _ context: GraphicsContext) {
        switch cue {
        case .dot(let at):
            guard let center = figure.point(at, in: pose) else { return }
            let dot = circle(center, 4.5)
            context.fill(dot, with: .color(palette.cue))
            context.stroke(dot, with: .color(palette.stage), lineWidth: 1.5)
        case .ring(let at, let rx, let ry, let pulse):
            guard let center = figure.point(at, in: pose) else { return }
            let tighten = pulse ? 1 - 0.2 * progress : 1
            let frame = CGRect(x: center.x - rx * tighten, y: center.y - ry * tighten, width: 2 * rx * tighten, height: 2 * ry * tighten)
            context.stroke(Path(ellipseIn: frame), with: .color(palette.cue), style: StrokeStyle(lineWidth: 2.4, dash: [3, 4]))
        case .arrow, .line:
            break
        }
    }

    /// An open chevron at the arrow's end, pointing along it. Its tip sits just past the end of the line.
    private func arrowhead(from start: CGPoint, to end: CGPoint, _ context: GraphicsContext) {
        let length = CueDiagramGeometry.distance(start, end)
        guard length > 0 else { return }
        let along = CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length)
        func place(_ forward: Double, _ sideways: Double) -> CGPoint {
            CGPoint(x: end.x + along.dx * forward - along.dy * sideways, y: end.y + along.dy * forward + along.dx * sideways)
        }
        var chevron = Path()
        chevron.move(to: place(-8.64, -5.76))
        chevron.addLine(to: place(1.44, 0))
        chevron.addLine(to: place(-8.64, 5.76))
        context.stroke(chevron, with: .color(palette.cue), style: StrokeStyle(lineWidth: 3.168, lineCap: .round, lineJoin: .round))
    }

    // MARK: Marks

    private func line(_ from: CGPoint, _ to: CGPoint, _ color: Color, width: Double, dash: [CGFloat] = [], _ context: GraphicsContext) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
    }

    private func disc(_ center: CGPoint, _ radius: Double, _ color: Color, _ context: GraphicsContext) {
        context.fill(circle(center, radius), with: .color(color))
    }

    private func circle(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }

    private func polygon(_ corners: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(corners)
        path.closeSubpath()
        return path
    }

    /// Draws `content` as one group at `opacity`, so shapes that overlap inside it don't darken
    /// each other.
    private func layer(_ context: GraphicsContext, opacity: Double, _ content: (GraphicsContext) -> Void) {
        guard opacity > 0 else { return }
        guard opacity < 1 else { return content(context) }
        var faded = context
        faded.opacity = opacity
        faded.drawLayer { content($0) }
    }
}
