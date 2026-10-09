import SwiftUI

/// The deterministic recipe for one generative cover: a pure function of an item's
/// `id` and primary tag, identical on every launch and device.
///
/// All the seeded work happens once in `make`; `BrainCoverView` only draws.
struct BrainCoverSpec: Equatable, Hashable, Sendable {
    enum Motif: CaseIterable, Hashable, Sendable {
        case circles, waves, bars
    }

    let motif: Motif
    /// Index into `BrainStyle.coverPalette`.
    let ramp: Int
    /// Six values in `0..<1` that shape the motif.
    let params: [Double]

    /// Tags pinned to a fixed ramp, so the most common topics keep a recognisable hue.
    static let tagRamps: [String: Int] = [
        "career": 0,
        "communication": 1,
        "habits": 2,
        "relationships": 3,
        "self": 4,
        "ai-agents": 5,
        "llm": 5,
        "ai-engineering": 5
    ]

    static func make(id: String, tag: String?) -> BrainCoverSpec {
        let hash = fnv1a64(id)
        var rng = SplitMix64(seed: hash)
        let motif = Motif.allCases[Int(rng.next() % UInt64(Motif.allCases.count))]
        let params = (0..<6).map { _ in rng.nextUnit() }
        let normalizedTag = tag?.trimmingCharacters(in: .whitespaces).lowercased()
        let ramp = normalizedTag.flatMap { tagRamps[$0] }
            ?? Int(hash % UInt64(BrainStyle.coverPalette.count))
        return BrainCoverSpec(motif: motif, ramp: ramp, params: params)
    }

    /// FNV-1a 64-bit over the UTF-8 bytes. Swift's `hashValue` is seeded per launch,
    /// so it must never stand in here.
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// SplitMix64: a tiny, well-mixed PRNG whose sequence depends only on its seed.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// A double in `0..<1` from the top 53 bits.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}

/// A flat abstract cover (circles, waves or bars) on a light tint of one hue.
///
/// Cheap in lists: the spec is precomputed, drawing is one `Canvas` pass with no
/// animation, and the view's only input is that value-type spec. `Equatable` lets a
/// caller add `.equatable()` where a parent re-renders often. In grids, apply
/// `.drawingGroup()` at the call site. Decorative only, so hidden from VoiceOver.
struct BrainCoverView: View, Equatable {
    let spec: BrainCoverSpec

    var body: some View {
        let ramp = BrainStyle.coverRamp(spec.ramp)
        Canvas(rendersAsynchronously: false) { context, size in
            BrainCoverRenderer.draw(spec, ramp: ramp, in: &context, size: size)
        }
        .accessibilityHidden(true)
    }
}

/// The drawing behind `BrainCoverView`, kept out of the view so `body` stays trivial.
enum BrainCoverRenderer {
    static func draw(_ spec: BrainCoverSpec, ramp: BrainCoverRamp, in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        guard rect.width > 0, rect.height > 0 else { return }
        context.fill(Path(rect), with: .color(ramp.background))
        let p = spec.params.count == 6 ? spec.params : Array(repeating: 0.5, count: 6)
        switch spec.motif {
        case .circles: drawCircles(p, ramp: ramp, in: &context, rect: rect)
        case .waves: drawWaves(p, ramp: ramp, in: &context, rect: rect)
        case .bars: drawBars(p, ramp: ramp, in: &context, rect: rect)
        }
    }

    private static func frac(_ value: Double) -> Double {
        value - value.rounded(.down)
    }

    private static func drawCircles(_ p: [Double], ramp: BrainCoverRamp, in context: inout GraphicsContext, rect: CGRect) {
        let side = min(rect.width, rect.height)
        let count = 2 + Int(p[0] * 3)
        let circles = (0..<count).map { index -> (CGPoint, CGFloat) in
            let i = Double(index)
            let center = CGPoint(x: rect.width * frac(p[1] + i * 0.618), y: rect.height * frac(p[2] + i * 0.382))
            let radius = side * (0.2 + 0.32 * frac(p[3] + i * 0.29))
            return (center, radius)
        }
        .sorted { $0.1 > $1.1 }

        for (index, circle) in circles.enumerated() {
            let (center, radius) = circle
            let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let color = index.isMultiple(of: 2) ? ramp.mid : ramp.strong.opacity(0.55)
            context.fill(disc, with: .color(color))
        }

        let dotRadius = side * (0.04 + 0.04 * p[5])
        let dot = CGPoint(x: rect.width * (0.15 + 0.7 * p[4]), y: rect.height * (0.15 + 0.7 * p[5]))
        context.fill(
            Path(ellipseIn: CGRect(x: dot.x - dotRadius, y: dot.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
            with: .color(ramp.strong)
        )
    }

    private static func drawWaves(_ p: [Double], ramp: BrainCoverRamp, in context: inout GraphicsContext, rect: CGRect) {
        let amplitude = rect.height * (0.05 + 0.08 * p[0])
        let cycles = 0.8 + 1.6 * p[1]
        let steps = 32
        let styles: [Color] = [ramp.mid.opacity(0.6), ramp.mid, ramp.strong.opacity(0.75)]

        for band in 0..<3 {
            let b = Double(band)
            let baseline = rect.height * (0.36 + 0.2 * b + 0.08 * (p[3] - 0.5))
            let phase = 2 * Double.pi * (p[2] + b * 0.23 + p[5] * 0.1)
            let bandCycles = cycles * (1 + 0.15 * b * p[4])
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.height))
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let y = baseline + amplitude * sin(2 * .pi * bandCycles * t + phase)
                path.addLine(to: CGPoint(x: rect.width * t, y: y))
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.closeSubpath()
            context.fill(path, with: .color(styles[band]))
        }
    }

    private static func drawBars(_ p: [Double], ramp: BrainCoverRamp, in context: inout GraphicsContext, rect: CGRect) {
        let count = 4 + Int(p[0] * 4)
        let inset = rect.width * 0.12
        let gap = rect.width * 0.04
        let bottom = rect.height * 0.86
        let usable = rect.width - inset * 2 - gap * CGFloat(count - 1)
        guard usable > 0 else { return }
        let barWidth = usable / CGFloat(count)
        let stride = 0.3 + 0.4 * p[2]
        let highlighted = min(count - 1, Int(p[5] * Double(count)))

        for index in 0..<count {
            let height = rect.height * (0.22 + 0.5 * frac(p[1] + Double(index) * stride))
            let bar = CGRect(
                x: inset + CGFloat(index) * (barWidth + gap),
                y: bottom - height,
                width: barWidth,
                height: height
            )
            let shape = Path(roundedRect: bar, cornerRadius: barWidth * 0.3, style: .continuous)
            let color = index == highlighted ? ramp.strong : ramp.mid.opacity(0.65 + 0.35 * p[3])
            context.fill(shape, with: .color(color))
        }
    }
}

#if DEBUG
#Preview("Covers") {
    let samples: [(String, String?)] = [
        ("wiki/virtues.md", "career"), ("wiki/networking.md", "communication"), ("journal/2026-01-02.md", "habits"),
        ("articles/one.md", "relationships"), ("people/sam.md", "self"), ("wiki/agents.md", "llm"),
        ("wiki/x.md", nil), ("wiki/y.md", "stoicism"), ("wiki/z.md", nil)
    ]
    let specs = (0..<8).flatMap { ramp in
        BrainCoverSpec.Motif.allCases.map { BrainCoverSpec(motif: $0, ramp: ramp, params: [0.42, 0.17, 0.63, 0.35, 0.8, 0.27]) }
    } + samples.map { BrainCoverSpec.make(id: $0.0, tag: $0.1) }
    return ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
                BrainCoverView(spec: spec)
                    .aspectRatio(BrainStyle.coverAspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: BrainStyle.thumbnailCorner, style: .continuous))
                    .drawingGroup()
            }
        }
        .padding(16)
    }
    .background(Color.hxCanvas)
}
#endif
