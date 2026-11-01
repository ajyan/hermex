import OSLog
import SwiftUI

/// The call's centerpiece, the memory constellation (prototype: "Atlas Orb Study"). Atlas is a
/// 3D cloud of stars with no drawn outline: knots of stars around each memory point, threads
/// along the links between them, a soft halo, and faint dust on a thin shell that hints the
/// sphere. A slow noise field drifts every star and the cloud turns in 3D with perspective.
///
/// Phases (`VoiceCallScenePhase`) blend over about a third of a second: listening is cooler
/// and shimmers with the mic; thinking sends the stars out as a flock; each memory Atlas finds
/// lights as a node in its paper and part of the flock streams to it; when the reply starts
/// the flock lands in the shape of this turn's constellation; speaking is warmer, swells with
/// Atlas's voice, and pulses the memories in turn. A cut-off snaps at once. Every new set of
/// memories gets a fresh random layout, so no two turns draw the same constellation.
///
/// `focus` is the cloud's slot in this view's coordinates; the flock flies past it. Reduce
/// Motion pauses the timeline and draws each phase still, crossfading between them.
struct VoiceCallStarfield: View {
    let levels: VoiceCallAudioLevels
    let phase: VoiceCallScenePhase
    let sources: [VoiceCallSource]
    let focus: CGRect
    var interruptions = 0
    var replyStarts = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = StarfieldModel()

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    guard !focus.isEmpty else { return }
                    model.render(
                        in: &context,
                        size: size,
                        focus: focus,
                        time: timeline.date.timeIntervalSinceReferenceDate,
                        input: StarfieldInput(
                            phase: phase, sources: sources, interruptions: interruptions, replyStarts: replyStarts
                        ),
                        levels: levels,
                        still: reduceMotion
                    )
                }
            }
            // Still frames change by crossfade; the live field never rebuilds.
            .id(reduceMotion ? phase.rawValue : -1)
            .transition(.opacity)
        }
        .animation(reduceMotion ? HXMotion.crossfade : nil, value: phase)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the starfield reads from the call each frame.
struct StarfieldInput {
    var phase: VoiceCallScenePhase
    var sources: [VoiceCallSource]
    var interruptions: Int
    var replyStarts: Int
}

// MARK: - Simulation

/// One star. Its role fixes where it lives in the cloud; `x`/`y` are its eased screen spot.
private struct Star {
    /// 0 knot (around a memory point), 1 thread (along a link), 2 halo, 3 dust (on the shell).
    var role: Int
    var j: Int
    var t: Double
    var g: SIMD3<Double>
    /// Dust only: its direction on the shell.
    var dir: SIMD3<Double>
    var lag: Double
    var k: Double
    var flockA: Double
    var flockR: Double
    var size: Double
    var x = 0.0, y = 0.0, z = 0.0, p = 1.0
    var placed = false
    /// The drift field at the star's home, minus 0.5 (dust uses `x`), refreshed every third frame.
    var drift = SIMD3<Double>.zero
    /// The flock's wander, minus 0.5, refreshed with `drift`.
    var wander = SIMD2<Double>.zero
}

/// A memory lit in the constellation.
private struct StarNode {
    var source: VoiceCallSource
    var slot: SIMD2<Double>
    var litAt: Double
    var color: SIMD3<Double>
}

/// The phase blend: one weight per phase, `interrupt` folded into `listen`.
private struct PhaseWeights {
    var idle = 1.0, listen = 0.0, think = 0.0, tools = 0.0, converge = 0.0, speak = 0.0

    mutating func ease(toward phase: VoiceCallScenePhase, amount: Double) {
        func step(_ value: inout Double, _ on: Bool) { value += ((on ? 1 : 0) - value) * amount }
        step(&idle, phase == .idle)
        step(&listen, phase == .listen || phase == .interrupt)
        step(&think, phase == .think)
        step(&tools, phase == .tools)
        step(&converge, phase == .converge)
        step(&speak, phase == .speak)
    }
}

/// The starfield's state, stepped and drawn from the Canvas on the main thread each frame.
/// Deliberately not observable: only the Canvas redraws, never the call screen around it.
final class StarfieldModel {
    /// Stars in the cloud's knots, threads and halo, and faint ones on the shell.
    static let cloudCount = 2000
    static let dustCount = 1400
    /// Every fifth of the first stars, joined by faint lines while they flock.
    private static let linkerCount = 170
    private static let stagger = 0.3

    private var stars: ContiguousArray<Star>
    private var nodes: [StarNode] = []
    private var slots: [SIMD2<Double>]
    private var shapeSlots: [SIMD3<Double>]
    /// The knots the cloud folds around: this turn's memories, at least four.
    private var shape: [SIMD3<Double>]
    /// Set once the call clears the turn's memories: the old constellation stays, dimmed, until
    /// the next turn's first memory arrives with a fresh layout.
    private var awaitingTurn = false
    private var random = SystemRandomNumberGenerator()

    private var lastTime: TimeInterval?
    private var frame = 0
    private var clock = 0.0
    private var seed = SIMD3<Double>(11, 37, 63)
    private var weights = PhaseWeights()
    private var form = 1.0
    private var mic = 0.0
    private var voice = 0.0
    private var impulse = 0.0
    private var yaw = 0.0
    private var interruptions: Int?
    private var replyStarts: Int?
    private var convergeUntil = -Double.infinity
    private var interruptUntil = -Double.infinity
    private var phase = VoiceCallScenePhase.idle
    private var wasStill = false

    #if DEBUG
    private var frameTimes: [Double] = []
    private static let logsFrameTimes = ProcessInfo.processInfo.arguments.contains("--voice-call-lab-perf")
    #endif

    init() {
        var rng = StarfieldRandom(seed: 42)
        func uniform() -> Double { Double.random(in: 0..<1, using: &rng) }
        func gauss() -> Double {
            var u = 0.0
            while u == 0 { u = uniform() }
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * uniform())
        }
        var stars = ContiguousArray<Star>()
        stars.reserveCapacity(Self.cloudCount + Self.dustCount)
        for _ in 0..<Self.cloudCount {
            let r = uniform()
            stars.append(Star(
                role: r < 0.4 ? 0 : r < 0.68 ? 1 : 2, j: Int(uniform() * 12), t: uniform(),
                g: SIMD3(gauss(), gauss(), gauss()), dir: .zero, lag: 1.1 + uniform() * 3.3, k: uniform(),
                flockA: uniform() * 2 * .pi, flockR: 0.35 + uniform() * 0.75, size: 0.6 + uniform() * 0.8
            ))
        }
        for _ in 0..<Self.dustCount {
            let u = uniform() * 2 - 1, a = uniform() * 2 * .pi, r = (1 - u * u).squareRoot()
            stars.append(Star(
                role: 3, j: 0, t: 0, g: SIMD3(gauss(), gauss(), gauss()), dir: SIMD3(cos(a) * r, u, sin(a) * r),
                lag: 0.9 + uniform() * 2.6, k: uniform(), flockA: uniform() * 2 * .pi,
                flockR: 0.5 + uniform() * 0.7, size: 0.35 + uniform() * 0.45
            ))
        }
        self.stars = stars
        var system = SystemRandomNumberGenerator()
        let layout = ConstellationLayout.turn(using: &system)
        slots = layout.slots
        shapeSlots = layout.shape
        shape = Array(layout.shape.prefix(4))
        seed = SIMD3(Double.random(in: 0..<90), Double.random(in: 0..<90), Double.random(in: 0..<90))
    }

    // MARK: Stepping

    func render(
        in context: inout GraphicsContext,
        size: CGSize,
        focus: CGRect,
        time: TimeInterval,
        input: StarfieldInput,
        levels: VoiceCallAudioLevels,
        still: Bool
    ) {
        let interval = performanceSignposter.beginInterval("Starfield Frame")
        #if DEBUG
        let started = CACurrentMediaTime()
        #endif
        let dt = advance(time: time, input: input, levels: levels, still: still)
        let scene = Scene(size: size, focus: focus, model: self)
        let nodeSpots = place(scene: scene, dt: dt, still: still)
        draw(in: &context, scene: scene, nodeSpots: nodeSpots)
        frame += 1
        performanceSignposter.endInterval("Starfield Frame", interval)
        #if DEBUG
        recordFrame(CACurrentMediaTime() - started)
        #endif
    }

    /// Moves time, events, the phase blend and the levels forward; returns the frame's step.
    private func advance(time: TimeInterval, input: StarfieldInput, levels: VoiceCallAudioLevels, still: Bool) -> Double {
        let dt = still ? 0 : min(max(time - (lastTime ?? time), 0), 0.05)
        lastTime = still ? nil : time
        clock += dt
        syncNodes(to: input.sources)

        // A cut-off kicks the cloud tight; a reply starting lands the flock with a new drift.
        if let known = interruptions, input.interruptions > known, !still {
            impulse = 1
            interruptUntil = clock + VoiceCallScenePhase.interruptSeconds
        }
        interruptions = input.interruptions
        if let known = replyStarts, input.replyStarts > known, !still {
            convergeUntil = clock + VoiceCallScenePhase.convergeSeconds
            seed = SIMD3(Double.random(in: 0..<90), Double.random(in: 0..<90), Double.random(in: 0..<90))
        }
        replyStarts = input.replyStarts

        if still {
            phase = input.phase
            weights = PhaseWeights(idle: 0)
            weights.ease(toward: phase, amount: 1)
            form = 1
            mic = 0
            voice = 0
            impulse = 0
            return 0
        }
        phase = VoiceCallScenePhase.resolved(
            base: input.phase, now: clock, convergeUntil: convergeUntil, interruptUntil: interruptUntil
        )
        weights.ease(toward: phase, amount: 1 - exp(-dt * (phase == .interrupt ? 16 : 3.2)))
        let flocking = phase == .think || phase == .tools
        let formRate = phase == .converge ? 2.2 : flocking ? 1.7 : 3
        form += ((flocking ? 0 : 1) - form) * (1 - exp(-dt * formRate))

        let raw = levels.read(at: ProcessInfo.processInfo.systemUptime)
        let hearing = phase == .listen || phase == .interrupt
        mic += ((hearing ? Double(raw.mic) : 0) - mic) * (1 - exp(-dt * 16))
        voice += ((phase == .speak ? Double(raw.voice) : 0) - voice) * (1 - exp(-dt * (phase == .interrupt ? 40 : 16)))
        impulse *= exp(-dt * 3.2)
        yaw += dt * (0.16 + 0.55 * mic * weights.listen + 0.3 * voice * weights.speak) + impulse * dt * 3
        return dt
    }

    /// Matches the lit nodes to the turn's memories: a new turn's first memory reshuffles the
    /// layout; later ones join it, each lighting a beat after the one before.
    private func syncNodes(to sources: [VoiceCallSource]) {
        guard !sources.isEmpty else {
            awaitingTurn = !nodes.isEmpty
            return
        }
        let continues = !awaitingTurn && nodes.count <= sources.count
            && zip(nodes, sources).allSatisfy { $0.source.id == $1.id }
        if !continues {
            let layout = ConstellationLayout.turn(using: &random)
            slots = layout.slots
            shapeSlots = layout.shape
            nodes = []
            awaitingTurn = false
        }
        guard nodes.count < sources.count else { return }
        for source in sources[nodes.count...] where nodes.count < slots.count {
            let litAt = max(clock, (nodes.last?.litAt ?? clock - Self.stagger) + Self.stagger)
            nodes.append(StarNode(
                source: source, slot: slots[nodes.count], litAt: litAt, color: StarSprites.rgb(of: source.kind)
            ))
        }
        shape = Array(shapeSlots.prefix(max(nodes.count, 4)))
    }

    private func lit(_ node: StarNode, still: Bool) -> Double {
        still ? 1 : starEaseOut((clock - node.litAt) / 0.5)
    }

    // MARK: Placing

    /// The frame's screen geometry and the blend values every star reads.
    private struct Scene {
        let width, height, m, cx, cy, radius, fw, fh, sc, swell: Double
        let ca, sa, cb, sb: Double

        init(size: CGSize, focus: CGRect, model: StarfieldModel) {
            width = size.width
            height = size.height
            m = min(width, height)
            cx = focus.midX
            cy = focus.midY
            radius = min(m * 0.34, focus.height * 0.46)
            fw = width * 0.33
            fh = height * 0.22
            sc = m / 420 + 0.4
            let w = model.weights
            swell = 1 + 0.06 * model.voice * w.speak + 0.03 * model.mic * w.listen - 0.08 * model.impulse
            ca = cos(model.yaw)
            sa = sin(model.yaw)
            let pitch = 0.42 + 0.12 * sin(model.clock * 0.21)
            cb = cos(pitch)
            sb = sin(pitch)
        }

        /// Turns a cloud point and puts it on screen with perspective: x, y, depth, scale.
        @inline(__always)
        func project(_ v: SIMD3<Double>) -> (x: Double, y: Double, z: Double, scale: Double) {
            let x1 = v.x * ca + v.z * sa, z1 = -v.x * sa + v.z * ca
            let y2 = v.y * cb - z1 * sb, z2 = v.y * sb + z1 * cb
            let scale = 2.8 / (2.8 - z2)
            return (cx + x1 * radius * scale, cy - y2 * radius * scale, z2, scale)
        }
    }

    /// A lit memory on screen this frame.
    fileprivate struct NodeSpot {
        var x, y, alpha: Double
        var color: SIMD3<Double>
        var kind: VoiceCallSourceKind
        var label: String
    }

    /// Eases every star toward its spot this frame: home in the cloud, or out in the flock.
    private func place(scene: Scene, dt: Double, still: Bool) -> [NodeSpot] {
        let w = weights, clock = clock, seed = seed, impulse = impulse
        let homeK = starSmoothStep(form)
        let spots = nodes.enumerated().map { index, node in
            let projected = scene.project(shapeSlots[index] * scene.swell)
            return NodeSpot(
                x: starLerp(scene.cx + node.slot.x * scene.fw, projected.x, homeK),
                y: starLerp(scene.cy + node.slot.y * scene.fh, projected.y, homeK),
                alpha: lit(node, still: still), color: node.color, kind: node.source.kind, label: node.source.label
            )
        }
        let attractors = (
            SIMD2(scene.cx + cos(clock * 0.55) * scene.fw * 0.55, scene.cy + sin(clock * 0.8) * scene.fh * 0.55),
            SIMD2(scene.cx + cos(clock * 0.43 + 2.4) * scene.fw * 0.7, scene.cy + sin(clock * 0.61 + 1.1) * scene.fh * 0.7)
        )
        let jitter = mic * w.listen * scene.m * 0.006
        let amp = 0.5 * w.idle + 0.3 * w.listen + 0.4 * w.think + 0.4 * w.tools + 0.35 * w.converge
            + (0.3 + 0.25 * voice) * w.speak
        let flocking = homeK < 0.999
        let refreshAll = still || frame < 3 || wasStill
        wasStill = still
        let refreshLane = frame % 3
        let landing = phase == .converge ? 2.3 : 1
        let shape = shape
        let tick = Int32(truncatingIfNeeded: Int(clock * 20))
        let driftTime = clock * 0.05, wanderTime = clock * 0.22

        stars.withUnsafeMutableBufferPointer { buffer in
            for i in buffer.indices {
                var star = buffer[i]
                let refresh = refreshAll || i % 3 == refreshLane
                let base = Self.base(of: star, shape: shape)
                if refresh {
                    star.drift = Self.drift(at: base, star: star, seed: seed, time: driftTime)
                    if flocking {
                        let x = Double(i) * 0.07
                        star.wander = SIMD2(StarNoise.value(x, wanderTime, 1) - 0.5, StarNoise.value(x, wanderTime, 9) - 0.5)
                    }
                }
                let home = Self.home(of: star, base: base, amp: amp)
                let projected = scene.project(home * scene.swell)
                var tx = projected.x, ty = projected.y
                if jitter > 0 {
                    tx += (StarNoise.hash(Int32(truncatingIfNeeded: i), tick, 1) - 0.5) * jitter
                }
                if flocking {
                    let attractor = star.k < 0.5 ? attractors.0 : attractors.1
                    let orbit = star.flockA + clock * 0.3
                    var fx = starLerp(attractor.x, scene.cx + cos(orbit) * scene.fw * star.flockR, 0.55) + star.wander.x * scene.m * 0.22
                    var fy = starLerp(attractor.y, scene.cy + sin(orbit) * scene.fh * star.flockR, 0.55) + star.wander.y * scene.m * 0.22
                    if w.tools > 0.02, !spots.isEmpty, star.k < 0.55 {
                        let node = spots[i % spots.count]
                        if node.alpha > 0 {
                            let pull = node.alpha * w.tools * (0.55 + 0.45 * sin(clock * 1.6 + star.k * 9))
                            fx = starLerp(fx, node.x + star.wander.x * scene.m * 0.07, pull)
                            fy = starLerp(fy, node.y + star.wander.y * scene.m * 0.07, pull)
                        }
                    }
                    tx = starLerp(fx, tx, homeK)
                    ty = starLerp(fy, ty, homeK)
                }
                if star.placed, !still {
                    let follow = 1 - exp(-dt * star.lag * landing * (1 + 7 * impulse))
                    star.x += (tx - star.x) * follow
                    star.y += (ty - star.y) * follow
                } else {
                    star.x = tx
                    star.y = ty
                    star.placed = true
                }
                star.z = projected.z
                star.p = projected.scale
                buffer[i] = star
            }
        }
        return spots
    }

    /// A star's place in the cloud before the drift: in a knot, along a thread, or in the halo.
    @inline(__always)
    private static func base(of star: Star, shape: [SIMD3<Double>]) -> SIMD3<Double> {
        let n = shape.count
        switch star.role {
        case 0:
            return shape[star.j % n] + star.g * 0.12
        case 1:
            let edge = star.j % (n - 1)
            let a = shape[edge], b = shape[edge + 1]
            return a + (b - a) * star.t + star.g * 0.045
        case 2:
            return star.g * 0.4
        default:
            return star.dir
        }
    }

    @inline(__always)
    private static func drift(at p: SIMD3<Double>, star: Star, seed: SIMD3<Double>, time: Double) -> SIMD3<Double> {
        if star.role == 3 {
            let q = p * 1.5
            return SIMD3(StarNoise.value(q.x + seed.x, q.y + seed.y, q.z + time) - 0.5, 0, 0)
        }
        let q = p * 1.3
        return SIMD3(
            StarNoise.value(q.x + seed.x, q.y + seed.y, q.z + time) - 0.5,
            StarNoise.value(q.y + seed.y + 17.3, q.z + seed.z, q.x + time + 5.1) - 0.5,
            StarNoise.value(q.z + seed.z + 31.7, q.x + seed.x + 3, q.y + time + 9.4) - 0.5
        )
    }

    @inline(__always)
    private static func home(of star: Star, base: SIMD3<Double>, amp: Double) -> SIMD3<Double> {
        if star.role == 3 {
            let radius = 0.9 + star.g.x * 0.035
            return base * radius * (1 + 0.06 * star.drift.x * amp * 2)
        }
        var p = base + star.drift * amp
        let r = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        if r > 0.88 { p *= (0.88 + (r - 0.88) * 0.25) / r }
        return p
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, scene: Scene, nodeSpots: [NodeSpot]) {
        let w = weights
        let flock = 1 - form
        let inShape = starSmoothStep(form)
        drawLinks(in: &context, scene: scene, alpha: flock * (w.think + 0.45 * w.tools))

        let resting = w.think * 0.5 + w.listen * 0.25 + w.idle * 0.25
        let constellation = max(w.tools, w.converge, w.speak * 0.85, nodeSpots.isEmpty ? 0 : resting) * (1 - 0.6 * impulse)
        drawEdges(in: &context, spots: nodeSpots, alpha: constellation)

        var light = context
        light.blendMode = .plusLighter
        if inShape > 0.02 {
            let hue = 236 - 22 * w.listen + 24 * w.speak + 10 * w.think
            let rgb = StarSprites.hsl(hue, 0.85, 0.62)
            let level = (0.1 + 0.1 * max(mic * w.listen, voice * w.speak)) * inShape
            for point in shape {
                let projected = scene.project(point * scene.swell)
                let radius = scene.radius * 0.55 * projected.scale
                let center = CGPoint(x: projected.x, y: projected.y)
                light.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(
                        Gradient(colors: [StarSprites.color(rgb, level), StarSprites.color(rgb, 0)]),
                        center: center, startRadius: 0, endRadius: radius
                    )
                )
            }
        }
        drawStars(in: &light, scene: scene, spots: nodeSpots, inShape: inShape)

        let speaking = voice * w.speak
        let pulsing = nodeSpots.isEmpty ? -1 : Int(clock * 0.9) % nodeSpots.count
        for (index, spot) in nodeSpots.enumerated() {
            let alpha = spot.alpha * constellation
            guard alpha >= 0.01 else { continue }
            let size = 26 * (1 + (index == pulsing ? 0.5 * speaking : 0)) * scene.sc
            light.opacity = min(alpha, 1)
            light.draw(StarSprites.resolved(spot.kind, in: light),
                       in: CGRect(x: spot.x - size / 2, y: spot.y - size / 2, width: size, height: size))
        }

        // Labels name the memories while the flock is out; the chips under the cloud take over.
        var labels = context
        for spot in nodeSpots {
            let alpha = spot.alpha * flock * constellation
            guard alpha >= 0.02 else { continue }
            let text = labels.resolve(
                Text(verbatim: spot.label).font(AppFont.caption2(weight: .medium)).foregroundStyle(Color.hxTextPrimary)
            )
            let half = text.measure(in: CGSize(width: scene.width, height: 40)).width / 2
            let x = min(max(spot.x, half + 12), scene.width - half - 12)
            labels.opacity = min(alpha, 1)
            labels.draw(text, at: CGPoint(x: x, y: spot.y + 18 * scene.sc), anchor: .center)
        }
    }

    /// Faint lines between nearby flocking stars, bucketed by strength into a few paths.
    private func drawLinks(in context: inout GraphicsContext, scene: Scene, alpha: Double) {
        guard alpha > 0.02 else { return }
        let threshold = scene.m * 0.085, threshold2 = threshold * threshold
        let bucketCount = 6
        var buckets = Array(repeating: Path(), count: bucketCount)
        stars.withUnsafeBufferPointer { buffer in
            for i in 0..<Self.linkerCount {
                let a = buffer[i * 5]
                let shimmer = 0.55 + 0.45 * sin(clock * 2.2 + Double(i) * 0.7)
                for j in (i + 1)..<Self.linkerCount {
                    let b = buffer[j * 5]
                    let dx = a.x - b.x, dy = a.y - b.y, d2 = dx * dx + dy * dy
                    guard d2 <= threshold2 else { continue }
                    let strength = (1 - d2.squareRoot() / threshold) * shimmer
                    let bucket = min(bucketCount - 1, Int(strength * Double(bucketCount)))
                    buckets[bucket].move(to: CGPoint(x: a.x, y: a.y))
                    buckets[bucket].addLine(to: CGPoint(x: b.x, y: b.y))
                }
            }
        }
        for (index, path) in buckets.enumerated() where !path.isEmpty {
            let strength = (Double(index) + 0.5) / Double(bucketCount)
            context.stroke(path, with: .color(StarSprites.link.opacity(strength * 0.42 * alpha)), lineWidth: 0.6)
        }
    }

    /// The constellation: each memory joined to the next in its colors, drawn as it lights.
    private func drawEdges(in context: inout GraphicsContext, spots: [NodeSpot], alpha: Double) {
        guard spots.count > 1 else { return }
        for index in 1..<spots.count {
            let a = spots[index - 1], b = spots[index]
            let edge = min(a.alpha, b.alpha) * alpha
            guard edge >= 0.01 else { continue }
            let start = CGPoint(x: a.x, y: a.y)
            let end = CGPoint(x: starLerp(a.x, b.x, b.alpha), y: starLerp(a.y, b.y, b.alpha))
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [StarSprites.color(a.color, 0.75 * edge), StarSprites.color(b.color, 0.75 * edge)]),
                startPoint: start, endPoint: CGPoint(x: b.x, y: b.y)
            ), lineWidth: 1.1)
        }
    }

    private func drawStars(in context: inout GraphicsContext, scene: Scene, spots: [NodeSpot], inShape: Double) {
        let w = weights, clock = clock
        let hues = StarSprites.resolvedHues(in: context)
        let papers = Dictionary(uniqueKeysWithValues: Set(spots.map(\.kind)).map { ($0, StarSprites.resolved($0, in: context)) })
        let roleAlpha = [0.85, 0.75, 0.42, 0.46], roleSize = [3.6, 3.6, 2.6, 2.7]
        let hueBase = w.speak * 5 - w.listen * 2 + w.think
        let lastHue = Double(hues.count - 1)
        stars.withUnsafeBufferPointer { buffer in
            for i in buffer.indices {
                let star = buffer[i]
                let depth = 0.5 + 0.5 * star.z
                let twinkle = 0.7 + 0.3 * sin(clock * (1.3 + star.k * 2) + Double(i))
                let alpha = starLerp((star.role == 3 ? 0.4 : 0.85) * twinkle,
                                 roleAlpha[star.role] * (0.25 + 0.75 * depth) * twinkle, inShape)
                guard alpha >= 0.01 else { continue }
                let size = starLerp(star.size * 5.2,
                                roleSize[star.role] * star.size * star.p * star.p * (0.75 + 0.5 * depth), inShape) * scene.sc
                let rect = CGRect(x: star.x - size / 2, y: star.y - size / 2, width: size, height: size)
                context.opacity = min(alpha, 1)
                // A few knot stars wear their memory's paper once it's lit.
                if star.role == 0, star.k < 0.3, inShape > 0.3, !spots.isEmpty {
                    let node = spots[star.j % spots.count]
                    if node.alpha > 0.5, let sprite = papers[node.kind] {
                        context.draw(sprite, in: rect)
                        continue
                    }
                }
                let bucket = (3 + Double(star.role) * 2 + star.g.y * 1.5 + hueBase).rounded()
                context.draw(hues[Int(min(max(bucket, 0), lastHue))], in: rect)
            }
        }
    }

    #if DEBUG
    /// With `--voice-call-lab-perf`, prints the mean and worst frame (step and draw calls)
    /// every 240 frames.
    private func recordFrame(_ seconds: Double) {
        guard Self.logsFrameTimes else { return }
        frameTimes.append(seconds * 1000)
        guard frameTimes.count >= 240 else { return }
        let mean = frameTimes.reduce(0, +) / Double(frameTimes.count)
        let sorted = frameTimes.sorted()
        print(String(format: "starfield frame ms: mean %.2f p95 %.2f max %.2f (%d stars)",
                     mean, sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0, stars.count))
        frameTimes.removeAll(keepingCapacity: true)
    }
    #endif
}
