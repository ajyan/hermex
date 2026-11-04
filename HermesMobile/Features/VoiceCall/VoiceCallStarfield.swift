import OSLog
import SwiftUI

/// The call's centerpiece, a mind of stars. Atlas is a 3D cloud with no drawn outline: knots of
/// stars around each memory point and threads along the links between them, every star joined to
/// its nearest neighbors by faint fibers (`MindNetwork`), inside a geodesic membrane (`MindLattice`)
/// with a soft rim of light. A slow noise field drifts every star and the cloud turns in 3D with
/// perspective.
///
/// Phases (`VoiceCallScenePhase`) blend over about a third of a second, and the ball never breaks:
/// listening is cooler, the membrane trembles with the mic, and each word heard closes in from the
/// surface as a shell of light; thinking sends seekers (`MindSeekers`) walking the network, lighting
/// what they visit; each memory Atlas finds pulls signals in through the network until it ignites in
/// its paper, and a fiber route grows from the last memory to it; as the reply starts, a pulse runs
/// that chain and the network rings out from it once; speaking is warmer, and each phrase of
/// Atlas's voice spreads hop by hop from the memory it's speaking from. A cut-off snaps at once.
/// Every new set of memories gets a fresh random layout, so no two turns draw the same mind.
///
/// `focus` is the cloud's slot in this view's coordinates. Reduce Motion pauses the timeline and
/// draws each phase still, crossfading between them.
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
        // Memory names inside the cloud stay small; the chips under it carry large text.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
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
    /// 0 knot (around a memory point), 1 thread (along a link), 2 halo.
    var role: Int
    var j: Int
    var t: Double
    var g: SIMD3<Double>
    var lag: Double
    var k: Double
    var size: Double
    var x = 0.0, y = 0.0, z = 0.0, p = 1.0
    var placed = false
    /// The drift field at the star's home, minus 0.5, refreshed every third frame.
    var drift = SIMD3<Double>.zero
    /// How hard the star fires this frame: it brightens and swells.
    var fire = 0.0
}

/// A memory lit in the constellation.
private struct StarNode {
    var source: VoiceCallSource
    var litAt: Double
    var color: SIMD3<Double>
}

/// A phrase of Atlas's voice, spreading from the knot it was spoken from.
private struct Phrase {
    var at: Double
    var strength: Double
    var knot: Int
}

/// A spark running along one fiber.
private struct Spark {
    var link: Int
    var at: Double
    var life: Double
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
    static let cloudCount = 2000
    private static let stagger = 0.3
    /// How long the linking pulse takes to run the chain, and how long the network then rings.
    private static let chainSeconds = 0.8
    private static let ringSeconds = 1.2
    private static let seekerCount = 6

    private var stars: ContiguousArray<Star>
    private var nodes: [StarNode] = []
    private var shapeSlots: [SIMD3<Double>]
    /// The knots the cloud folds around: this turn's memories, at least four.
    private var shape: [SIMD3<Double>]
    /// Set once the call clears the turn's memories: the old constellation stays, dimmed, until
    /// the next turn's first memory arrives with a fresh layout.
    private var awaitingTurn = false
    private var random = SystemRandomNumberGenerator()

    private var network = MindNetwork()
    private var networkShape: [SIMD3<Double>] = []
    /// The shape being wired off the main thread, if any.
    private var wiringShape: [SIMD3<Double>]?
    private let lattice = MindLattice.shared
    private var seekers = MindSeekers()
    private var sparks: [Spark] = []
    private var heard = VoicePulses(rise: 0.12, spacing: 0.22, life: 1.6)
    private var spoken = VoicePulses(rise: 0.16, spacing: 1.1, life: 2.4)
    private var phrases: [Phrase] = []
    private var speakingKnot = 0
    private var phrasesOnKnot = 0
    private var lastPhraseAt = -Double.infinity
    /// When this reply's linking started, and the hops from its chain for the ring that follows.
    private var linkAt = -Double.infinity
    private var ringHops: [UInt8] = []

    private var lastTime: TimeInterval?
    private var frame = 0
    private var clock = 0.0
    private var seed = SIMD3<Double>(11, 37, 63)
    private var weights = PhaseWeights()
    private var mic = 0.0
    /// Atlas's voice as the mind shows it: a slow swell per phrase (0.25 s up, ~0.9 s down),
    /// never a flicker per word.
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
        stars.reserveCapacity(Self.cloudCount)
        for _ in 0..<Self.cloudCount {
            let r = uniform()
            stars.append(Star(
                role: r < 0.4 ? 0 : r < 0.68 ? 1 : 2, j: Int(uniform() * 12), t: uniform(),
                g: SIMD3(gauss(), gauss(), gauss()), lag: 1.1 + uniform() * 3.3, k: uniform(),
                size: 0.6 + uniform() * 0.8
            ))
        }
        self.stars = stars
        var system = SystemRandomNumberGenerator()
        let layout = ConstellationLayout.turn(using: &system)
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
        rewireIfNeeded()
        let scene = Scene(size: size, focus: focus, model: self)
        let nodeSpots = place(scene: scene, dt: dt, still: still)
        draw(in: &context, scene: scene, nodeSpots: nodeSpots, still: still)
        frame += 1
        performanceSignposter.endInterval("Starfield Frame", interval)
        #if DEBUG
        recordFrame(CACurrentMediaTime() - started)
        #endif
    }

    /// Moves time, events, the phase blend, the levels and the searches forward; returns the frame's step.
    private func advance(time: TimeInterval, input: StarfieldInput, levels: VoiceCallAudioLevels, still: Bool) -> Double {
        let dt = still ? 0 : min(max(time - (lastTime ?? time), 0), 0.05)
        lastTime = still ? nil : time
        clock += dt
        syncNodes(to: input.sources)

        // A cut-off kicks the cloud tight; a reply starting links the memories and drifts anew.
        if let known = interruptions, input.interruptions > known, !still {
            impulse = 1
            interruptUntil = clock + VoiceCallScenePhase.interruptSeconds
        }
        interruptions = input.interruptions
        if let known = replyStarts, input.replyStarts > known, !still {
            convergeUntil = clock + VoiceCallScenePhase.convergeSeconds
            seed = SIMD3(Double.random(in: 0..<90), Double.random(in: 0..<90), Double.random(in: 0..<90))
            startLinking()
        }
        replyStarts = input.replyStarts

        if still {
            phase = input.phase
            weights = PhaseWeights(idle: 0)
            weights.ease(toward: phase, amount: 1)
            mic = 0
            voice = 0
            impulse = 0
            heard.reset()
            spoken.reset()
            phrases = []
            sparks = []
            return 0
        }
        phase = VoiceCallScenePhase.resolved(
            base: input.phase, now: clock, convergeUntil: convergeUntil, interruptUntil: interruptUntil
        )
        weights.ease(toward: phase, amount: 1 - exp(-dt * (phase == .interrupt ? 16 : 3.2)))

        let raw = levels.read(at: ProcessInfo.processInfo.systemUptime)
        let hearing = phase == .listen || phase == .interrupt
        mic += ((hearing ? Double(raw.mic) : 0) - mic) * (1 - exp(-dt * 16))
        impulse *= exp(-dt * 3.2)
        heard.step(level: hearing ? Double(raw.mic) : 0, at: clock, dt: dt)
        if spoken.step(level: phase == .speak ? Double(raw.voice) : 0, at: clock, dt: dt, cutOff: phase == .interrupt) {
            phraseStarted(strength: spoken.started.last?.strength ?? 0.7)
        }
        if phase == .interrupt { phrases = [] }
        phrases.removeAll { clock - $0.at > spoken.life }
        var swell = 0.0
        for phrase in phrases {
            let age = clock - phrase.at
            swell += (1 - swell) * phrase.strength * 0.7 * min(1, age / 0.25) * exp(-age / 0.9)
        }
        voice = phase == .speak ? swell : 0

        let searching = weights.think + weights.tools
        if searching > 0.02 {
            if seekers.walkers.isEmpty {
                seekers.reset(count: Self.seekerCount, starCount: stars.count, at: clock, using: &random)
            }
            seekers.step(at: clock, network: network, using: &random)
        }
        stepSparks(searching: searching)
        yaw += dt * (0.16 + 0.5 * mic * weights.listen + 0.1 * searching + 0.12 * voice * weights.speak) + impulse * dt * 3
        return dt
    }

    /// Each phrase spreads from the memory being spoken from; the voice moves to the next memory
    /// after a pause or every third phrase.
    private func phraseStarted(strength: Double) {
        let knots = max(nodes.count, 1)
        if clock - lastPhraseAt > 1.4 || phrasesOnKnot >= 3 {
            speakingKnot = (speakingKnot + 1) % knots
            phrasesOnKnot = 0
        }
        speakingKnot %= knots
        phrasesOnKnot += 1
        lastPhraseAt = clock
        phrases.append(Phrase(at: clock, strength: strength, knot: speakingKnot))
    }

    /// The reply starts: the chain of found memories links up, and the voice starts on the first.
    private func startLinking() {
        rewireIfNeeded()
        linkAt = clock
        speakingKnot = 0
        phrasesOnKnot = 0
        lastPhraseAt = clock
        let count = max(nodes.count, 1)
        var sources = Array(network.hubs.prefix(count))
        for route in network.routes.prefix(count - 1) { sources += route }
        ringHops = network.breadthFirst(from: sources)
    }

    /// Sparks run along random fibers: rare and slow at rest, quick and many while Atlas searches.
    private func stepSparks(searching: Double) {
        sparks.removeAll { clock - $0.at > $0.life }
        guard !network.links.isEmpty, sparks.count < 60 else { return }
        if Double.random(in: 0..<1, using: &random) < 0.1 + 0.6 * searching {
            sparks.append(Spark(
                link: Int.random(in: 0..<network.links.count, using: &random), at: clock, life: starLerp(1, 0.45, searching)
            ))
        }
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
            shapeSlots = ConstellationLayout.turn(using: &random).shape
            nodes = []
            awaitingTurn = false
        }
        guard nodes.count < sources.count else { return }
        for source in sources[nodes.count...] where nodes.count < shapeSlots.count {
            let litAt = max(clock, (nodes.last?.litAt ?? clock - Self.stagger) + Self.stagger)
            nodes.append(StarNode(source: source, litAt: litAt, color: StarSprites.rgb(of: source.kind)))
        }
        shape = Array(shapeSlots.prefix(max(nodes.count, 4)))
    }

    /// Joins the stars anew whenever the cloud's shape changes. The wiring takes tens of
    /// milliseconds, so it runs off the main thread; the old fibers stay until it lands.
    private func rewireIfNeeded() {
        guard shape != networkShape, shape != wiringShape else { return }
        let shape = shape
        let points = stars.map { Self.base(of: $0, shape: shape) }, bends = stars.map(\.k)
        wiringShape = shape
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let network = MindNetwork(points: points, knots: shape, bends: bends)
            DispatchQueue.main.async {
                guard let self, self.wiringShape == shape else { return }
                self.network = network
                self.networkShape = shape
                self.wiringShape = nil
                self.sparks = []
            }
        }
    }

    private func lit(_ node: StarNode, still: Bool) -> Double {
        still ? 1 : starEaseOut((clock - node.litAt) / 0.5)
    }

    // MARK: Placing

    /// The frame's screen geometry and the blend values every star reads.
    private struct Scene {
        let width, height, m, cx, cy, radius, sc, swell: Double
        let ca, sa, cb, sb: Double

        init(size: CGSize, focus: CGRect, model: StarfieldModel) {
            width = size.width
            height = size.height
            m = min(width, height)
            cx = focus.midX
            cy = focus.midY
            radius = min(m * 0.34, focus.height * 0.46)
            sc = m / 420 + 0.4
            let w = model.weights
            swell = 1 + 0.02 * model.voice * w.speak + 0.03 * model.mic * w.listen - 0.08 * model.impulse
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
        var litAt: Double
    }

    /// Eases every star toward its home in the cloud and works out how hard it fires.
    private func place(scene: Scene, dt: Double, still: Bool) -> [NodeSpot] {
        let w = weights, clock = clock, seed = seed, impulse = impulse
        let spots = nodes.enumerated().map { index, node in
            let projected = scene.project(shapeSlots[index] * scene.swell)
            return NodeSpot(
                x: projected.x, y: projected.y, alpha: lit(node, still: still), color: node.color,
                kind: node.source.kind, label: node.source.label, litAt: node.litAt
            )
        }
        let jitter = mic * w.listen * scene.m * 0.006
        let amp = 0.5 * w.idle + 0.3 * w.listen + 0.4 * w.think + 0.4 * w.tools + 0.35 * w.converge
            + (0.3 + 0.25 * voice) * w.speak
        let refreshAll = still || frame < 3 || wasStill
        wasStill = still
        let refreshLane = frame % 3
        let shape = shape
        let tick = Int32(truncatingIfNeeded: Int(clock * 20))
        let driftTime = clock * 0.05

        // What fires this frame: words heard closing in from the surface, the seekers' visits,
        // signals gathering into each memory as it's found, the ring after linking, and phrases.
        let heardShells = still ? [] : heard.started.map {
            (front: 0.97 - (clock - $0.at) * 0.75, strength: $0.strength * (1 - (clock - $0.at) / heard.life))
        }
        let scan = (w.think + w.tools) * (1 - 0.5 * w.converge)
        let visited = seekers.visited
        let gathering = still ? [] : nodes.enumerated().compactMap { index, node -> (hops: [UInt8], litAt: Double)? in
            guard index < network.hops.count, clock - node.litAt < 0.4, node.litAt - clock < 0.8 else { return nil }
            return (network.hops[index], node.litAt)
        }
        let ringAge = clock - linkAt - Self.chainSeconds
        let ringHops = ringHops
        let ringing = !still && ringAge >= 0 && ringAge < Self.ringSeconds && ringHops.count == stars.count
        let spreading = still ? [] : phrases.compactMap { phrase -> (hops: [UInt8], age: Double, strength: Double)? in
            guard phrase.knot < network.hops.count else { return nil }
            return (network.hops[phrase.knot], clock - phrase.at, phrase.strength)
        }
        let wired = network.hops.first?.count == stars.count

        stars.withUnsafeMutableBufferPointer { buffer in
            for i in buffer.indices {
                var star = buffer[i]
                let refresh = refreshAll || i % 3 == refreshLane
                let base = Self.base(of: star, shape: shape)
                if refresh { star.drift = Self.drift(at: base, star: star, seed: seed, time: driftTime) }
                let home = Self.home(of: star, base: base, amp: amp)
                let projected = scene.project(home * scene.swell)
                var tx = projected.x
                let ty = projected.y
                if jitter > 0 {
                    tx += (StarNoise.hash(Int32(truncatingIfNeeded: i), tick, 1) - 0.5) * jitter
                }
                if star.placed, !still {
                    let follow = 1 - exp(-dt * star.lag * (1 + 7 * impulse))
                    star.x += (tx - star.x) * follow
                    star.y += (ty - star.y) * follow
                } else {
                    star.x = tx
                    star.y = ty
                    star.placed = true
                }
                star.z = projected.z
                star.p = projected.scale

                var fire = 0.0
                if !still {
                    let d = (home * home).sum().squareRoot()
                    for shell in heardShells {
                        let off = d - shell.front
                        fire += 0.7 * shell.strength * exp(-off * off / 0.012)
                    }
                    if scan > 0.02, i < visited.count {
                        let age = clock - visited[i]
                        if age < 1.2 { fire += 0.7 * scan * exp(-age / 0.45) }
                    }
                    if wired {
                        for gather in gathering {
                            let h = gather.hops[i]
                            guard h <= 12 else { continue }
                            let arrive = clock - (gather.litAt - Double(h) * 0.06) - 0.05
                            if arrive > -0.15, arrive < 0.3 { fire += 0.9 * exp(-arrive * arrive / 0.006) * (1 - Double(h) / 24) }
                        }
                        if ringing {
                            let h = ringHops[i]
                            if h <= 10 {
                                let ring = ringAge - Double(h) * 0.045
                                if ring > -0.05, ring < 0.4 { fire += 0.9 * exp(-ring * ring / 0.003) * (1 - Double(h) / 12) }
                            }
                        }
                        for phrase in spreading {
                            let h = phrase.hops[i]
                            guard h <= 14 else { continue }
                            let wave = phrase.age - Double(h) * 0.12
                            if wave > -0.2, wave < 0.7 { fire += phrase.strength * pow(0.9, Double(h)) * exp(-wave * wave / 0.03) }
                        }
                    }
                }
                star.fire = fire
                buffer[i] = star
            }
        }
        // The linking pulse lights the star it's passing.
        if let head = chainHead(), head.star < stars.count { stars[head.star].fire += 1.2 }
        return spots
    }

    /// Where the linking pulse is on the chain of found routes: its star, which route, how far along.
    private func chainHead() -> (star: Int, route: Int, position: Double)? {
        let age = clock - linkAt
        guard age >= 0, age < Self.chainSeconds, nodes.count > 1 else { return nil }
        let routes = network.routes.prefix(nodes.count - 1)
        let total = routes.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        var head = age / Self.chainSeconds * Double(total)
        for (index, route) in routes.enumerated() {
            if head < Double(route.count) { return (route[Int(head)], index, head) }
            head -= Double(route.count)
        }
        return nil
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
        default:
            return star.g * 0.4
        }
    }

    @inline(__always)
    private static func drift(at p: SIMD3<Double>, star: Star, seed: SIMD3<Double>, time: Double) -> SIMD3<Double> {
        let q = p * 1.3
        return SIMD3(
            StarNoise.value(q.x + seed.x, q.y + seed.y, q.z + time) - 0.5,
            StarNoise.value(q.y + seed.y + 17.3, q.z + seed.z, q.x + time + 5.1) - 0.5,
            StarNoise.value(q.z + seed.z + 31.7, q.x + seed.x + 3, q.y + time + 9.4) - 0.5
        )
    }

    @inline(__always)
    private static func home(of star: Star, base: SIMD3<Double>, amp: Double) -> SIMD3<Double> {
        var p = base + star.drift * amp
        let r = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        if r > 0.88 { p *= (0.88 + (r - 0.88) * 0.25) / r }
        return p
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, scene: Scene, nodeSpots: [NodeSpot], still: Bool) {
        let w = weights
        let resting = w.think * 0.5 + w.listen * 0.25 + w.idle * 0.25
        let constellation = max(w.tools, w.converge, w.speak * 0.85, nodeSpots.isEmpty ? 0 : resting) * (1 - 0.6 * impulse)
        let hue = 236 - 22 * w.listen + 24 * w.speak + 10 * w.think
        let tint = StarSprites.hsl(hue, 0.85, 0.62)
        let scan = (w.think + w.tools) * (1 - 0.5 * w.converge)

        var light = context
        light.blendMode = .plusLighter
        drawGlow(in: &light, scene: scene, tint: tint)
        drawFibers(in: &light, hue: hue, still: still)
        drawSeekers(in: &light, scan: scan, still: still)
        drawMembrane(in: &light, scene: scene, hue: hue, scan: scan, still: still)
        drawRoutes(in: &light, spots: nodeSpots, constellation: constellation, still: still)
        drawStars(in: &light, scene: scene, spots: nodeSpots, constellation: constellation)

        let speaking = voice * w.speak
        for (index, spot) in nodeSpots.enumerated() {
            let alpha = spot.alpha * constellation
            guard alpha >= 0.01 else { continue }
            let flash = still || clock < spot.litAt ? 0 : exp(-(clock - spot.litAt) / 0.35)
            let pulse = index == speakingKnot ? 0.5 * speaking : 0
            let size = 26 * (1 + pulse + 1.2 * flash) * scene.sc
            light.opacity = min(alpha, 1)
            light.draw(StarSprites.resolved(spot.kind, in: light),
                       in: CGRect(x: spot.x - size / 2, y: spot.y - size / 2, width: size, height: size))
        }

        // The ring after linking blooms softly over the whole mind.
        let ringAge = clock - linkAt - Self.chainSeconds
        if !still, ringAge >= 0, ringAge < 1.4 {
            let bloom = exp(-pow(ringAge - 0.3, 2) / 0.06) * 0.22
            let radius = scene.radius * 1.25
            let center = CGPoint(x: scene.cx, y: scene.cy)
            let glow = SIMD3(220.0, 205, 255) / 255
            light.opacity = 1
            light.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [StarSprites.color(glow, bloom), StarSprites.color(glow, 0)]),
                    center: center, startRadius: scene.radius * 0.1, endRadius: radius
                )
            )
        }

        // Labels name the memories while Atlas searches; the chips under the cloud take over.
        // A name goes under its memory, else over it, else is left out: names never overlap.
        var labels = context
        let naming = max(w.think, w.tools, 0.6 * w.converge)
        var placed: [CGRect] = []
        for spot in nodeSpots {
            let alpha = spot.alpha * naming * constellation
            guard alpha >= 0.02 else { continue }
            let text = labels.resolve(
                Text(verbatim: spot.label).font(AppFont.caption2(weight: .medium)).foregroundStyle(Color.hxTextPrimary)
            )
            let size = text.measure(in: CGSize(width: scene.width * 0.6, height: 40))
            let x = min(max(spot.x, size.width / 2 + 12), scene.width - size.width / 2 - 12)
            let offset = 18 * scene.sc
            let spots = [spot.y + offset, spot.y - offset].map {
                CGRect(x: x - size.width / 2 - 3, y: $0 - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
            }
            guard let rect = spots.first(where: { candidate in !placed.contains { $0.intersects(candidate) } }) else { continue }
            placed.append(rect)
            labels.opacity = min(alpha, 1)
            labels.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        }
    }

    /// A soft glow around each knot.
    private func drawGlow(in context: inout GraphicsContext, scene: Scene, tint: SIMD3<Double>) {
        let w = weights
        let level = 0.1 + 0.1 * max(mic * w.listen, voice * w.speak)
        for point in shape {
            let projected = scene.project(point * scene.swell)
            let radius = scene.radius * 0.55 * projected.scale
            let center = CGPoint(x: projected.x, y: projected.y)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [StarSprites.color(tint, level), StarSprites.color(tint, 0)]),
                    center: center, startRadius: 0, endRadius: radius
                )
            )
        }
    }

    /// The synapses: faint bowed fibers by depth, brighter where a signal is crossing, and sparks.
    private func drawFibers(in context: inout GraphicsContext, hue: Double, still: Bool) {
        guard !network.links.isEmpty else { return }
        var depthPaths = [Path(), Path(), Path()]
        var litPaths = [Path(), Path(), Path(), Path()]
        let links = network.links
        stars.withUnsafeBufferPointer { buffer in
            for link in links {
                let a = buffer[link.a], b = buffer[link.b]
                let control = CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * link.bend, y: (a.y + b.y) / 2 + (b.x - a.x) * link.bend)
                let depth = 0.5 + 0.25 * (a.z + b.z)
                let lane = depth < 0.4 ? 0 : depth < 0.7 ? 1 : 2
                depthPaths[lane].move(to: CGPoint(x: a.x, y: a.y))
                depthPaths[lane].addQuadCurve(to: CGPoint(x: b.x, y: b.y), control: control)
                let fire = max(a.fire, b.fire)
                if fire > 0.12 {
                    let bucket = min(3, Int(min(fire * 0.5, 0.65) / 0.65 * 4))
                    litPaths[bucket].move(to: CGPoint(x: a.x, y: a.y))
                    litPaths[bucket].addQuadCurve(to: CGPoint(x: b.x, y: b.y), control: control)
                }
            }
        }
        let fiber = StarSprites.hsl(hue + 8, 0.85, 0.74)
        for (lane, alpha) in [0.03, 0.06, 0.1].enumerated() {
            context.stroke(depthPaths[lane], with: .color(StarSprites.color(fiber, alpha)), lineWidth: 0.5)
        }
        let litColor = SIMD3(225.0, 205, 255) / 255
        for (bucket, path) in litPaths.enumerated() where !path.isEmpty {
            context.stroke(path, with: .color(StarSprites.color(litColor, (Double(bucket) + 0.5) / 4 * 0.65)), lineWidth: 0.9)
        }
        guard !still else { return }
        let spark = SIMD3(235.0, 220, 255) / 255
        for item in sparks where item.link < links.count {
            let link = links[item.link]
            let a = stars[link.a], b = stars[link.b]
            let u = (clock - item.at) / item.life
            let cx = (a.x + b.x) / 2 - (b.y - a.y) * link.bend, cy = (a.y + b.y) / 2 + (b.x - a.x) * link.bend
            let x = (1 - u) * (1 - u) * a.x + 2 * (1 - u) * u * cx + u * u * b.x
            let y = (1 - u) * (1 - u) * a.y + 2 * (1 - u) * u * cy + u * u * b.y
            context.fill(Path(ellipseIn: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2)),
                         with: .color(StarSprites.color(spark, sin(.pi * u) * 0.8)))
        }
    }

    /// Thinking's seekers: a fading trail behind each and a bright head, sliding along its fiber.
    private func drawSeekers(in context: inout GraphicsContext, scan: Double, still: Bool) {
        guard scan > 0.02, !still else { return }
        let violet = SIMD3(215.0, 195, 255) / 255
        for walker in seekers.walkers {
            let points = (walker.trail + [walker.at]).map { CGPoint(x: stars[$0].x, y: stars[$0].y) }
            for index in points.indices.dropFirst() {
                var segment = Path()
                segment.move(to: points[index - 1])
                segment.addLine(to: points[index])
                let fade = Double(index) / Double(points.count)
                context.stroke(segment, with: .color(StarSprites.color(violet, 0.7 * scan * fade)), lineWidth: 0.9)
            }
            var head = CGPoint(x: stars[walker.at].x, y: stars[walker.at].y)
            if let next = walker.next {
                let u = min(1, (clock - walker.stepStart) / MindSeekers.stepSeconds)
                var segment = Path()
                segment.move(to: head)
                head = CGPoint(x: starLerp(head.x, stars[next].x, u), y: starLerp(head.y, stars[next].y, u))
                segment.addLine(to: head)
                context.stroke(segment, with: .color(StarSprites.color(violet, 0.7 * scan)), lineWidth: 0.9)
            }
            let radius = clock < walker.dwellUntil ? 12.0 : 6
            context.fill(
                Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [StarSprites.color(SIMD3(1, 1, 1), 0.9 * scan), StarSprites.color(violet, 0)]),
                    center: head, startRadius: 0, endRadius: radius
                )
            )
        }
    }

    /// The membrane: a geodesic net, brighter toward the limb, that trembles with the user's
    /// voice, lights where seekers pass under it, takes on a found memory's color near it, brightens
    /// as the network rings, and carries light outward from the memory Atlas is speaking from.
    private func drawMembrane(in context: inout GraphicsContext, scene: Scene, hue: Double, scan: Double, still: Bool) {
        let w = weights
        let ringAge = clock - linkAt - Self.chainSeconds
        let ring = !still && ringAge >= 0 ? 0.5 * exp(-pow(ringAge - 0.4, 2) / 0.03) : 0
        let words = still ? 0 : heard.started.reduce(0) { $0 + 0.5 * $1.strength * exp(-(clock - $1.at) / 0.18) }
        let probes: [SIMD3<Double>] = still || scan < 0.02 ? [] : seekers.walkers.map { walker in
            let point = Self.base(of: stars[walker.at], shape: shape)
            return point / max((point * point).sum().squareRoot(), 0.001)
        }
        let found = nodes.enumerated().compactMap { index, node -> (direction: SIMD3<Double>, strength: Double, color: Int)? in
            guard index < shapeSlots.count else { return nil }
            let strength = lit(node, still: still) * max(w.tools, w.converge * 0.8, w.speak * 0.35)
            guard strength > 0 else { return nil }
            let knot = shapeSlots[index]
            return (knot / max((knot * knot).sum().squareRoot(), 0.001), strength, index)
        }
        var speakingDirection: SIMD3<Double>?
        if !still, speakingKnot < shapeSlots.count, !phrases.isEmpty {
            let knot = shapeSlots[speakingKnot]
            speakingDirection = knot / max((knot * knot).sum().squareRoot(), 0.001)
        }
        let tremble = still ? 0 : mic * w.listen

        var projected: [(x: Double, y: Double, z: Double)] = []
        var fires: [Double] = []
        var colors: [Int] = []
        projected.reserveCapacity(lattice.points.count)
        fires.reserveCapacity(lattice.points.count)
        colors.reserveCapacity(lattice.points.count)
        for point in lattice.points {
            let unit = point / lattice.radius
            var scale = 1.0
            if tremble > 0.01 {
                let lon = atan2(unit.z, unit.x), lat = asin(min(max(unit.y, -1), 1))
                scale += tremble * 0.07 * (0.5 + 0.5 * sin(3 * lon + clock * 2.6) * cos(2 * lat - clock * 1.9))
            }
            let screen = scene.project(point * scale * scene.swell)
            projected.append((screen.x, screen.y, screen.z))
            var fire = tremble * 0.35 + words + ring
            for probe in probes { fire += 0.6 * scan * pow(max(0, (unit * probe).sum()), 18) }
            var color = -1, best = 0.15
            for memory in found {
                let near = memory.strength * pow(max(0, (unit * memory.direction).sum()), 10)
                fire += 0.8 * near
                if near > best {
                    best = near
                    color = memory.color
                }
            }
            if let direction = speakingDirection {
                let angle = acos(min(max((unit * direction).sum(), -1), 1))
                for phrase in phrases where phrase.knot == speakingKnot {
                    let wave = clock - phrase.at - angle * 0.55
                    fire += phrase.strength * exp(-wave * wave / 0.05) * (1 - angle / 3.3)
                }
            }
            fires.append(min(fire, 1.1))
            colors.append(color)
        }

        // Edges in a few alpha buckets per color: the net's own violet, or a found memory's paper.
        let groups = nodes.count + 1, buckets = 6
        var edgePaths = Array(repeating: Path(), count: groups * buckets)
        for edge in lattice.edges {
            let a = projected[edge.a], b = projected[edge.b]
            let limb = 1 - abs((a.z + b.z) / 2) / lattice.radius
            let front = a.z + b.z > 0 ? 1.0 : 0.45
            let fire = (fires[edge.a] + fires[edge.b]) / 2
            let alpha = min(0.6, (0.025 + 0.11 * limb * limb) * front + 0.35 * fire * front)
            guard alpha >= 0.012 else { continue }
            let color = max(colors[edge.a], colors[edge.b])
            let group = color >= 0 && color < nodes.count ? color + 1 : 0
            let bucket = min(buckets - 1, Int(alpha / 0.6 * Double(buckets)))
            edgePaths[group * buckets + bucket].move(to: CGPoint(x: a.x, y: a.y))
            edgePaths[group * buckets + bucket].addLine(to: CGPoint(x: b.x, y: b.y))
        }
        let net = StarSprites.hsl(hue + 14, 0.8, 0.72)
        for (index, path) in edgePaths.enumerated() where !path.isEmpty {
            let group = index / buckets, bucket = index % buckets
            let color = group == 0 ? net : nodes[group - 1].color
            context.stroke(path, with: .color(StarSprites.color(color, (Double(bucket) + 0.5) / Double(buckets) * 0.6)), lineWidth: 0.5)
        }
        var dots = Path()
        var brightDots = Path()
        for (index, point) in projected.enumerated() {
            let front = point.z > 0 ? 1.0 : 0.4
            let radius = 0.8 + fires[index]
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            if fires[index] * front > 0.25 {
                brightDots.addEllipse(in: rect)
            } else if front > 0.5 {
                dots.addEllipse(in: rect)
            }
        }
        context.fill(dots, with: .color(StarSprites.color(SIMD3(210, 190, 255) / 255, 0.2)))
        context.fill(brightDots, with: .color(StarSprites.color(SIMD3(225, 210, 255) / 255, 0.7)))
    }

    /// Each memory joined to the next along the network's own fibers, the route growing as the
    /// next one ignites; while linking, a pulse runs the chain and each route flares as it passes.
    private func drawRoutes(in context: inout GraphicsContext, spots: [NodeSpot], constellation: Double, still: Bool) {
        guard spots.count > 1 else { return }
        let w = weights
        let routes = network.routes
        let total = Double(routes.prefix(spots.count - 1).reduce(0) { $0 + $1.count })
        let linkAge = clock - linkAt
        let head = still ? nil : chainHead()
        var before = 0.0
        for index in 1..<spots.count where index - 1 < routes.count {
            let route = routes[index - 1]
            defer { before += Double(route.count) }
            let reveal = still ? 1 : min(spots[index - 1].alpha, starEaseOut((clock - spots[index].litAt) / 0.8))
            let passed = !still && total > 0 && linkAge >= 0 ? linkAge - (before + Double(route.count)) / total * Self.chainSeconds : -1
            let flare = passed >= 0 ? exp(-passed / 0.6) : 0
            let alpha = min(1, reveal * constellation * (0.55 + 0.45 * w.converge) + 0.4 * flare * reveal)
            guard alpha >= 0.01, route.count > 1 else { continue }
            let upto = max(1, Int((Double(route.count) * reveal).rounded()))
            var path = Path()
            for (step, star) in route.prefix(upto).enumerated() {
                let point = CGPoint(x: stars[star].x, y: stars[star].y)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let start = CGPoint(x: stars[route[0]].x, y: stars[route[0]].y)
            let end = CGPoint(x: stars[route[upto - 1]].x, y: stars[route[upto - 1]].y)
            context.stroke(path, with: .linearGradient(
                Gradient(colors: [StarSprites.color(spots[index - 1].color, 0.75 * alpha), StarSprites.color(spots[index].color, 0.75 * alpha)]),
                startPoint: start, endPoint: end
            ), lineWidth: 1.3 + 0.8 * flare)
            guard let head, head.route == index - 1 else { continue }
            let at = Int(head.position)
            guard at + 1 < route.count else { continue }
            let from = stars[route[at]], to = stars[route[at + 1]], u = head.position - Double(at)
            let center = CGPoint(x: starLerp(from.x, to.x, u), y: starLerp(from.y, to.y, u))
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)),
                with: .radialGradient(
                    Gradient(colors: [
                        StarSprites.color(SIMD3(1, 1, 1), 0.95), StarSprites.color(spots[index].color, 0.6),
                        StarSprites.color(spots[index].color, 0)
                    ]),
                    center: center, startRadius: 0, endRadius: 8
                )
            )
        }
    }

    private func drawStars(in context: inout GraphicsContext, scene: Scene, spots: [NodeSpot], constellation: Double) {
        let w = weights, clock = clock
        let hues = StarSprites.resolvedHues(in: context)
        let spike = context.resolve(StarSprites.spikeImage)
        let papers = Dictionary(uniqueKeysWithValues: Set(spots.map(\.kind)).map { ($0, StarSprites.resolved($0, in: context)) })
        let roleAlpha = [0.85, 0.75, 0.42], roleSize = [3.6, 3.6, 2.6]
        let hueBase = w.speak * 5 - w.listen * 2 + w.think
        let lastHue = Double(hues.count - 1)
        let dim = 1 - 0.25 * (w.think + w.tools)
        stars.withUnsafeBufferPointer { buffer in
            for i in buffer.indices {
                let star = buffer[i]
                let depth = 0.5 + 0.5 * star.z
                let twinkle = 0.75 + 0.25 * sin(clock * (0.9 + star.k * 1.6) + Double(i))
                let fire = min(star.fire, 1.3)
                let alpha = roleAlpha[star.role] * (0.25 + 0.75 * depth) * twinkle * dim * (1 + 1.3 * fire)
                guard alpha >= 0.01 else { continue }
                let size = roleSize[star.role] * star.size * star.p * star.p * (0.75 + 0.5 * depth) * (1 + 0.3 * fire) * scene.sc
                let rect = CGRect(x: star.x - size / 2, y: star.y - size / 2, width: size, height: size)
                context.opacity = min(alpha, 1)
                // Knot stars wear their memory's paper once it's lit.
                if star.role == 0, star.k < 0.45, !spots.isEmpty {
                    let node = spots[star.j % spots.count]
                    if node.alpha * constellation > 0.3, let sprite = papers[node.kind] {
                        context.draw(sprite, in: rect)
                        continue
                    }
                }
                let bucket = (3 + Double(star.role) * 2 + star.g.y * 1.5 + hueBase).rounded()
                context.draw(hues[Int(min(max(bucket, 0), lastHue))], in: rect)
                // The brightest few, facing us, catch thin diffraction spikes.
                if star.role < 2, star.size > 1.32, depth > 0.45 {
                    let spikeSize = size * 1.9
                    context.opacity = min(alpha * 0.8, 1)
                    context.draw(spike, in: CGRect(x: star.x - spikeSize / 2, y: star.y - spikeSize / 2, width: spikeSize, height: spikeSize))
                }
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
        print(String(format: "starfield frame ms: mean %.2f p95 %.2f max %.2f (%d stars, %d fibers)",
                     mean, sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0, stars.count, network.links.count))
        frameTimes.removeAll(keepingCapacity: true)
    }
    #endif
}
