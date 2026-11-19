import CoreGraphics
import Foundation

/// The mannequin's skeletons: which joints join into drawn segments, at which width, and which
/// joint each one hangs from.
enum CueDiagramSkeleton {
    struct Bone: Equatable {
        let from: String
        let to: String
        let width: Double

        func joins(_ first: String, _ second: String) -> Bool {
            (from == first && to == second) || (from == second && to == first)
        }
    }

    /// The side view's near limbs and torso, in drawing order.
    static let sideNear = [
        Bone(from: "ankle", to: "toe", width: 9), Bone(from: "knee", to: "ankle", width: 11),
        Bone(from: "hip", to: "knee", width: 15), Bone(from: "hip", to: "shoulder", width: 19),
        Bone(from: "shoulder", to: "elbow", width: 10), Bone(from: "elbow", to: "hand", width: 8),
    ]
    /// The side view's optional far limbs, drawn first and fainter.
    static let sideFar = [
        Bone(from: "ankle2", to: "toe2", width: 9), Bone(from: "knee2", to: "ankle2", width: 11),
        Bone(from: "hip", to: "knee2", width: 15), Bone(from: "shoulder", to: "elbow2", width: 10),
        Bone(from: "elbow2", to: "hand2", width: 8),
    ]
    /// The front view's limbs; `l` and `r` are screen left and right.
    static let front = [
        Bone(from: "al", to: "tl", width: 8), Bone(from: "ar", to: "tr", width: 8),
        Bone(from: "pl", to: "kl", width: 14), Bone(from: "kl", to: "al", width: 10),
        Bone(from: "pr", to: "kr", width: 14), Bone(from: "kr", to: "ar", width: 10),
        Bone(from: "hl", to: "el", width: 8), Bone(from: "el", to: "sl", width: 10),
        Bone(from: "hr", to: "er", width: 8), Bone(from: "er", to: "sr", width: 10),
    ]
    /// The front view's torso, a polygon with a `frontTorsoStroke`-wide outline.
    static let frontTorso = ["sl", "sr", "pr", "pl"]
    static let frontTorsoStroke = 8.0
    static let headRadius = 12.0
    static let jointRadius = 3.2

    static let sideJointDots = ["knee", "hip", "shoulder", "elbow"]
    static let sideFarJointDots = ["knee2", "elbow2"]
    static let frontJointDots = ["el", "er", "sl", "sr"]

    /// The joint each joint hangs from: a `swing` joint travels on an arc around it.
    static let parent = [
        "knee": "hip", "ankle": "knee", "toe": "ankle", "shoulder": "hip", "head": "shoulder",
        "elbow": "shoulder", "hand": "elbow", "knee2": "hip", "ankle2": "knee2", "toe2": "ankle2",
        "elbow2": "shoulder", "hand2": "elbow2", "el": "sl", "hl": "el", "er": "sr", "hr": "er",
        "kl": "pl", "al": "kl", "tl": "al", "kr": "pr", "ar": "kr", "tr": "ar",
    ]
    /// The two joints a `solve` elbow or knee sits between.
    static let neighbours = [
        "knee": ["hip", "ankle"], "knee2": ["hip", "ankle2"], "elbow": ["shoulder", "hand"],
        "elbow2": ["shoulder", "hand2"], "el": ["sl", "hl"], "er": ["sr", "hr"],
        "kl": ["pl", "al"], "kr": ["pr", "ar"],
    ]
    /// The elbow a hand's forearm starts at, which a dumbbell lying `cross` lies across.
    static let forearmRoot = ["hand": "elbow", "hand2": "elbow2", "hl": "el", "hr": "er"]

    /// How many joints sit between this one and the root, so parents can move before children.
    static func depth(of joint: String) -> Int {
        var depth = 0
        var current = joint
        while let next = parent[current], depth < parent.count {
            current = next
            depth += 1
        }
        return depth
    }

    /// The width of the muscle drawn over the limb between two joints.
    static func muscleWidth(_ first: String, _ second: String) -> Double {
        let limb = (sideNear + sideFar + front).first { $0.joins(first, second) }?.width ?? 10
        switch limb {
        case 19: return 8
        case 14, 15: return 6
        case 8, 9: return 4
        default: return 5
        }
    }
}

/// The diagram's maths, as pure functions.
enum CueDiagramGeometry {
    static func distance(_ p: CGPoint, _ q: CGPoint) -> Double {
        hypot(p.x - q.x, p.y - q.y)
    }

    static func lerp(_ p: CGPoint, _ q: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
    }

    /// Where a `swing` joint sits at `progress`: on an arc around its parent, the bone's angle
    /// (the shortest way round) and length interpolated between the two poses.
    static func swing(start: CGPoint, startParent: CGPoint, end: CGPoint, endParent: CGPoint,
                      parent: CGPoint, progress: Double) -> CGPoint {
        let from = CGVector(dx: start.x - startParent.x, dy: start.y - startParent.y)
        let to = CGVector(dx: end.x - endParent.x, dy: end.y - endParent.y)
        let fromAngle = atan2(from.dy, from.dx)
        var turn = (atan2(to.dy, to.dx) - fromAngle + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        if turn < 0 { turn += 2 * .pi }
        turn -= .pi
        let fromLength = hypot(from.dx, from.dy)
        let length = fromLength + (hypot(to.dx, to.dy) - fromLength) * progress
        let angle = fromAngle + turn * progress
        return CGPoint(x: parent.x + length * cos(angle), y: parent.y + length * sin(angle))
    }

    /// Two-bone IK: the middle joint `upper` away from `p1` and `lower` away from `p2`, on the
    /// `side` (1 or -1) of the line from `p1` to `p2`. Out of reach, it lies on that line.
    static func solve(_ p1: CGPoint, _ p2: CGPoint, upper: Double, lower: Double, side: Double) -> CGPoint {
        let apart = max(distance(p1, p2), 1e-6)
        let reach = max(min(apart, upper + lower), abs(upper - lower))
        let along = (upper * upper - lower * lower + reach * reach) / (2 * reach)
        let off = max(upper * upper - along * along, 0).squareRoot()
        let ux = (p2.x - p1.x) / apart
        let uy = (p2.y - p1.y) / apart
        return CGPoint(x: p1.x + ux * along - uy * off * side, y: p1.y + uy * along + ux * off * side)
    }

    /// Which side of the line from `p1` to `p2` the point `middle` is on: positive or negative.
    static func side(_ p1: CGPoint, _ p2: CGPoint, _ middle: CGPoint) -> Double {
        (p2.x - p1.x) * (middle.y - p1.y) - (p2.y - p1.y) * (middle.x - p1.x)
    }
}

/// The rep's timing: hold the start pose, ease to the end of the effort, hold, ease back, hold.
enum CueDiagramMotion {
    /// Seconds for one rep, there and back.
    static let repDuration: TimeInterval = 4
    /// The fractions of a rep at which the effort starts and ends, and the return starts and ends.
    static let effortStart = 0.1
    static let effortEnd = 0.48
    static let returnStart = 0.62
    static let returnEnd = 0.92

    /// `cubic-bezier(0.45, 0, 0.2, 1)`: how far along the move is at the time fraction `u`.
    static func ease(_ u: Double) -> Double {
        let (x1, y1, x2, y2) = (0.45, 0.0, 0.2, 1.0)
        guard u > 0 else { return 0 }
        guard u < 1 else { return 1 }
        var low = 0.0
        var high = 1.0
        for _ in 0..<40 {
            let t = (low + high) / 2
            let x = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
            if x < u { low = t } else { high = t }
        }
        let t = (low + high) / 2
        return 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
    }

    /// How far the figure is from the start pose (0) to the end of the effort (1) at `phase`, the
    /// fraction of one rep that has passed.
    static func progress(phase: Double) -> Double {
        switch phase {
        case ..<effortStart: 0
        case ..<effortEnd: ease((phase - effortStart) / (effortEnd - effortStart))
        case ..<returnStart: 1
        case ..<returnEnd: 1 - ease((phase - returnStart) / (returnEnd - returnStart))
        default: 0
        }
    }
}

/// When a diagram moves: three reps from the moment it is played, then it rests on the start
/// pose. Under Reduce Motion it never plays and shows the end of the effort instead.
struct CueDiagramPlayback: Equatable {
    static let reps = 3
    static let duration = Double(reps) * CueDiagramMotion.repDuration

    /// When the current run of reps began; nil while resting.
    private(set) var startedAt: Date?

    var isPlaying: Bool { startedAt != nil }
    /// When the current run's last rep is back on the start pose.
    var endsAt: Date? { startedAt?.addingTimeInterval(Self.duration) }

    /// Starts three reps from the start pose, whether or not a run is under way.
    mutating func play(at now: Date, reduceMotion: Bool) {
        startedAt = reduceMotion ? nil : now
    }

    mutating func stop() {
        startedAt = nil
    }

    /// The pose to draw at `now`: 0 is the start pose, 1 the end of the effort.
    func progress(at now: Date, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        guard let startedAt else { return 0 }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 0, elapsed < Self.duration else { return 0 }
        let phase = elapsed.truncatingRemainder(dividingBy: CueDiagramMotion.repDuration) / CueDiagramMotion.repDuration
        return CueDiagramMotion.progress(phase: phase)
    }
}

/// A shape in a pose: part of a lit muscle.
enum CueDiagramShape: Equatable {
    case line(CGPoint, CGPoint, width: Double)
    case circle(CGPoint, radius: Double)
    case polygon([CGPoint])
}

/// One lift's diagram, ready to pose and draw: its data plus the two full poses.
struct CueDiagramFigure {
    typealias Pose = [String: CGPoint]

    let id: String
    let lift: CueDiagramLift
    let viewBox: CGRect
    let floorY: Double
    /// The start pose, `a`.
    let start: Pose
    /// The end of the effort, `b`: every joint, the ones that don't move included.
    let end: Pose
    /// The `swing` joints the skeleton can place, parents before children.
    private let swing: [String]
    /// The `solve` joints the skeleton can place.
    private let solve: [String]

    init(id: String, lift: CueDiagramLift, viewBox: CGRect = CueDiagramFile.defaultViewBox,
         floorY: Double = CueDiagramFile.defaultFloorY) {
        self.id = id
        self.lift = lift
        self.viewBox = viewBox
        self.floorY = floorY
        start = lift.a
        end = lift.a.merging(lift.b.filter { lift.a[$0.key] != nil }) { _, moved in moved }
        let pose = lift.a
        swing = lift.swing.enumerated()
            .filter { entry in
                guard pose[entry.element] != nil, let parent = CueDiagramSkeleton.parent[entry.element] else { return false }
                return pose[parent] != nil
            }
            .sorted { first, second in
                let (left, right) = (CueDiagramSkeleton.depth(of: first.element), CueDiagramSkeleton.depth(of: second.element))
                return left == right ? first.offset < second.offset : left < right
            }
            .map(\.element)
        solve = lift.solve.filter { joint in
            guard pose[joint] != nil, let between = CueDiagramSkeleton.neighbours[joint] else { return false }
            return between.allSatisfy { pose[$0] != nil }
        }
    }

    // MARK: Pose

    /// Every joint at `progress`, from the start pose (0) to the end of the effort (1): a straight
    /// line, except `swing` joints (an arc around the parent) and `solve` joints (two-bone IK).
    func pose(at progress: Double) -> Pose {
        var pose = start
        for (joint, from) in start {
            if let to = end[joint] { pose[joint] = CueDiagramGeometry.lerp(from, to, progress) }
        }
        for joint in swing {
            guard let parent = CueDiagramSkeleton.parent[joint], let from = start[joint], let to = end[joint],
                  let fromParent = start[parent], let toParent = end[parent], let placed = pose[parent] else { continue }
            pose[joint] = CueDiagramGeometry.swing(start: from, startParent: fromParent, end: to, endParent: toParent,
                                                   parent: placed, progress: progress)
        }
        for joint in solve {
            guard let between = CueDiagramSkeleton.neighbours[joint],
                  let from = start[joint], let to = end[joint],
                  let fromUpper = start[between[0]], let toUpper = end[between[0]],
                  let fromLower = start[between[1]], let toLower = end[between[1]],
                  let upper = pose[between[0]], let lower = pose[between[1]] else { continue }
            func length(_ first: Double, _ last: Double) -> Double { first + (last - first) * progress }
            let upperLength = length(CueDiagramGeometry.distance(fromUpper, from), CueDiagramGeometry.distance(toUpper, to))
            let lowerLength = length(CueDiagramGeometry.distance(from, fromLower), CueDiagramGeometry.distance(to, toLower))
            // Bend the way the poses bend: the pose where the joint sits further off the line decides.
            let startSide = CueDiagramGeometry.side(fromUpper, fromLower, from)
            let endSide = CueDiagramGeometry.side(toUpper, toLower, to)
            let side = abs(startSide) > abs(endSide) ? startSide : endSide
            pose[joint] = CueDiagramGeometry.solve(upper, lower, upper: upperLength, lower: lowerLength, side: side >= 0 ? 1 : -1)
        }
        return pose
    }

    // MARK: Bones

    /// The far limbs the figure has (side view only), drawn first and fainter.
    var farBones: [CueDiagramSkeleton.Bone] {
        lift.view == .side ? CueDiagramSkeleton.sideFar.filter(has) : []
    }

    /// The near limbs, and in side view the torso.
    var nearBones: [CueDiagramSkeleton.Bone] {
        (lift.view == .side ? CueDiagramSkeleton.sideNear : CueDiagramSkeleton.front).filter(has)
    }

    private func has(_ bone: CueDiagramSkeleton.Bone) -> Bool {
        start[bone.from] != nil && start[bone.to] != nil
    }

    // MARK: Points

    /// Where a point is in a pose: itself when fixed, else the joint or anchor it names. Nil for a
    /// name this figure doesn't have.
    func point(_ reference: CueDiagramPoint, in pose: Pose) -> CGPoint? {
        switch reference {
        case .fixed(let place): place
        case .named(let name): pose[name] ?? anchor(name, in: pose)
        }
    }

    /// A named place on the torso: `belly` and `chest` in side view, `chest` and `hands` from the front.
    private func anchor(_ name: String, in pose: Pose) -> CGPoint? {
        switch (lift.view, name) {
        case (.side, "belly"):
            guard let hip = pose["hip"], let shoulder = pose["shoulder"] else { return nil }
            return CueDiagramGeometry.lerp(hip, shoulder, 16.0 / 46)
        case (.side, "chest"):
            return torsoFrame(in: pose)?.at(0.82, 6)
        case (.front, "chest"):
            return quad(in: pose)?.at(0.5, 12.0 / 52)
        case (.front, "hands"):
            guard let left = pose["hl"], let right = pose["hr"] else { return nil }
            return CueDiagramGeometry.lerp(left, right, 0.5)
        default:
            return nil
        }
    }

    /// The side view's torso as a frame: along it from the hip, and off it toward the figure's
    /// front, which is to the right of the hip-to-shoulder direction.
    private struct TorsoFrame {
        let hip: CGPoint
        let up: CGVector
        let front: CGVector
        let length: Double

        func at(_ along: Double, _ off: Double) -> CGPoint {
            CGPoint(x: hip.x + up.dx * length * along + front.dx * off, y: hip.y + up.dy * length * along + front.dy * off)
        }
    }

    private func torsoFrame(in pose: Pose) -> TorsoFrame? {
        guard let hip = pose["hip"], let shoulder = pose["shoulder"] else { return nil }
        let distance = CueDiagramGeometry.distance(hip, shoulder)
        let length = distance == 0 ? 1 : distance
        let up = CGVector(dx: (shoulder.x - hip.x) / length, dy: (shoulder.y - hip.y) / length)
        return TorsoFrame(hip: hip, up: up, front: CGVector(dx: -up.dy, dy: up.dx), length: length)
    }

    /// The front view's torso as a quad: across it from the left side, and down it from the shoulders.
    private struct TorsoQuad {
        let shoulderLeft, shoulderRight, hipLeft, hipRight: CGPoint

        func at(_ across: Double, _ down: Double) -> CGPoint {
            CueDiagramGeometry.lerp(CueDiagramGeometry.lerp(shoulderLeft, shoulderRight, across),
                                    CueDiagramGeometry.lerp(hipLeft, hipRight, across), down)
        }
    }

    private func quad(in pose: Pose) -> TorsoQuad? {
        guard let sl = pose["sl"], let sr = pose["sr"], let pl = pose["pl"], let pr = pose["pr"] else { return nil }
        return TorsoQuad(shoulderLeft: sl, shoulderRight: sr, hipLeft: pl, hipRight: pr)
    }

    // MARK: Muscles

    /// A muscle's shapes in a pose; none for a segment or region this figure doesn't have.
    func shapes(for muscle: CueDiagramMuscle, in pose: Pose) -> [CueDiagramShape] {
        switch muscle {
        case .segment(let first, let second):
            guard let from = pose[first], let to = pose[second] else { return [] }
            return [.line(from, to, width: CueDiagramSkeleton.muscleWidth(first, second))]
        case .region(let name):
            return lift.view == .side ? sideRegion(name, in: pose) : frontRegion(name, in: pose)
        }
    }

    private func sideRegion(_ name: String, in pose: Pose) -> [CueDiagramShape] {
        guard let torso = torsoFrame(in: pose) else { return [] }
        switch name {
        case "abs": return [.line(torso.at(0.14, 4.5), torso.at(0.58, 4.5), width: 7)]
        case "chest": return [.line(torso.at(0.66, 4.5), torso.at(0.92, 4.5), width: 8)]
        case "back": return [.line(torso.at(0.42, -4.5), torso.at(0.92, -4.5), width: 7)]
        case "core": return [.line(torso.at(0.14, 0), torso.at(0.58, 0), width: 9)]
        case "glute": return [.circle(torso.at(-0.04, -3), radius: 7)]
        case "delt": return [.circle(torso.at(1, 0), radius: 6)]
        default: return []
        }
    }

    /// The paired regions take `-l` or `-r` to light one side.
    private func frontRegion(_ name: String, in pose: Pose) -> [CueDiagramShape] {
        guard let q = quad(in: pose) else { return [] }
        if name == "upper-back" {
            return [.polygon([q.at(0.16, 0.04), q.at(0.84, 0.04), q.at(0.62, 0.36), q.at(0.38, 0.36)])]
        }
        var base = name
        var only: String?
        if name.hasSuffix("-l") || name.hasSuffix("-r") {
            base = String(name.dropLast(2))
            only = String(name.suffix(1))
        }
        let left, right: CueDiagramShape
        switch base {
        case "lats":
            left = .polygon([q.shoulderLeft, q.at(0.388, 30.0 / 52), q.hipLeft])
            right = .polygon([q.shoulderRight, q.at(0.612, 30.0 / 52), q.hipRight])
        case "chest":
            left = .polygon([q.at(0.03, 0.1), q.at(0.47, 0.1), q.at(0.47, 0.38), q.at(0.1, 0.42)])
            right = .polygon([q.at(0.97, 0.1), q.at(0.53, 0.1), q.at(0.53, 0.38), q.at(0.9, 0.42)])
        case "obliques":
            left = .polygon([q.at(0.0, 0.46), q.at(0.34, 0.46), q.at(0.36, 0.98), q.at(0.02, 0.98)])
            right = .polygon([q.at(1.0, 0.46), q.at(0.66, 0.46), q.at(0.64, 0.98), q.at(0.98, 0.98)])
        case "delts":
            left = .circle(q.shoulderLeft, radius: 6.5)
            right = .circle(q.shoulderRight, radius: 6.5)
        default:
            return []
        }
        switch only {
        case "l": return [left]
        case "r": return [right]
        default: return [left, right]
        }
    }
}
