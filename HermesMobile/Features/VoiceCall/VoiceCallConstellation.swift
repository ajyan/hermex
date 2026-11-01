import SwiftUI
import UIKit

// MARK: - Layout

/// Where a turn's memories sit: random points in a ring, kept apart from each other and from
/// the center, and the 3D shape the cloud folds into around them.
enum ConstellationLayout {
    /// `count` points with radius in `rMin...rMax` of a unit disc, each at least `minGap` from
    /// the others. Falls back to an evenly spaced ring at a random turn when sampling can't fit
    /// them, which still keeps the gap for up to six points.
    static func scatter<G: RandomNumberGenerator>(
        count: Int, rMin: Double, rMax: Double, minGap: Double, using rng: inout G
    ) -> [SIMD2<Double>] {
        for _ in 0..<60 {
            var points: [SIMD2<Double>] = []
            for _ in 0..<count {
                var placed: SIMD2<Double>?
                for _ in 0..<40 where placed == nil {
                    let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
                    let radius = rMin + (rMax - rMin) * Double.random(in: 0...1, using: &rng).squareRoot()
                    let candidate = SIMD2(cos(angle) * radius, sin(angle) * radius)
                    if points.allSatisfy({ distance($0, candidate) >= minGap }) { placed = candidate }
                }
                guard let placed else { break }
                points.append(placed)
            }
            if points.count == count { return points }
        }
        let turn = Double.random(in: 0..<(2 * .pi), using: &rng)
        return (0..<count).map { index in
            let angle = Double(index) / Double(max(count, 1)) * 2 * .pi + turn
            return SIMD2(cos(angle) * rMax, sin(angle) * rMax)
        }
    }

    /// The cloud's knots for laid-out points: the same arrangement, flipped to y-up and pulled
    /// in, at a random depth each.
    static func shape<G: RandomNumberGenerator>(of points: [SIMD2<Double>], using rng: inout G) -> [SIMD3<Double>] {
        points.map { SIMD3($0.x * 0.68, -$0.y * 0.68, Double.random(in: -1...1, using: &rng) * 0.45) }
    }

    /// A fresh layout for one turn's memories.
    static func turn<G: RandomNumberGenerator>(using rng: inout G) -> (slots: [SIMD2<Double>], shape: [SIMD3<Double>]) {
        let slots = scatter(count: VoiceCallSources.cap, rMin: 0.45, rMax: 1.0, minGap: 0.5, using: &rng)
        return (slots, shape(of: slots, using: &rng))
    }

    private static func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y).squareRoot()
    }
}

/// SplitMix64: a small seeded generator, so the star cloud is the same every call and tests can
/// replay a layout.
struct StarfieldRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Sprites and noise

/// The stars' glow sprites: a small radial gradient per hue, pre-rendered once. The cloud's own
/// light, drawn per frame in a Canvas, so its raw colors are not design tokens (DESIGN.md § Motion);
/// the memories wear their papers' dark glows, since the call is always dark.
enum StarSprites {
    /// Fourteen hues from cyan through violet to magenta, picked per star by role and phase.
    static let hueImages: [Image] = (0..<14).map { Image(uiImage: render(hsl(196 + Double($0) * 10, 0.85, 0.72))) }
    static let paperImages: [VoiceCallSourceKind: Image] = Dictionary(
        uniqueKeysWithValues: VoiceCallSourceKind.allCases.map { ($0, Image(uiImage: render(rgb(of: $0)))) }
    )
    static let link = color(SIMD3(200, 205, 255) / 255, 1)

    static func resolvedHues(in context: GraphicsContext) -> [GraphicsContext.ResolvedImage] {
        hueImages.map { context.resolve($0) }
    }

    static func resolved(_ kind: VoiceCallSourceKind, in context: GraphicsContext) -> GraphicsContext.ResolvedImage {
        context.resolve(paperImages[kind] ?? hueImages[0])
    }

    /// A memory kind's paper glow, as the dark appearance draws it.
    static func rgb(of kind: VoiceCallSourceKind) -> SIMD3<Double> {
        let hex = kind.paper.values.glowDark
        return SIMD3(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)) / 255
    }

    static func color(_ rgb: SIMD3<Double>, _ opacity: Double) -> Color {
        Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z, opacity: min(max(opacity, 0), 1)) // design-drift: allow
    }

    static func hsl(_ hue: Double, _ s: Double, _ l: Double) -> SIMD3<Double> {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func channel(_ t: Double) -> Double {
            let t = (t + 1).truncatingRemainder(dividingBy: 1)
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return SIMD3(channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    /// White at the heart, the hue around it, fading out.
    private static func render(_ rgb: SIMD3<Double>) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { renderer in
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            func tint(_ alpha: Double) -> CGColor {
                CGColor(colorSpace: space, components: [rgb.x, rgb.y, rgb.z, alpha]) ?? CGColor(gray: 1, alpha: alpha)
            }
            let colors = [CGColor(gray: 1, alpha: 1), tint(0.95), tint(0.26), tint(0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.14, 0.38, 1]) else { return }
            let center = CGPoint(x: 32, y: 32)
            renderer.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                                  endCenter: center, endRadius: 32, options: [])
        }
    }
}

/// 3D value noise for the drift and the flock's wander: smooth, cheap, and the same on every run.
enum StarNoise {
    @inline(__always)
    static func hash(_ x: Int32, _ y: Int32, _ z: Int32) -> Double {
        var h = UInt32(bitPattern: x) &* 374_761_393 &+ UInt32(bitPattern: y) &* 668_265_263
            &+ UInt32(bitPattern: z) &* 1_440_662_683
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h ^ (h >> 16)) / 4_294_967_296
    }

    static func value(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let fx = x.rounded(.down), fy = y.rounded(.down), fz = z.rounded(.down)
        let xi = Int32(truncatingIfNeeded: Int(fx)), yi = Int32(truncatingIfNeeded: Int(fy)), zi = Int32(truncatingIfNeeded: Int(fz))
        let xf = x - fx, yf = y - fy, zf = z - fz
        let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf), w = zf * zf * (3 - 2 * zf)
        let c000 = hash(xi, yi, zi), c100 = hash(xi &+ 1, yi, zi)
        let c010 = hash(xi, yi &+ 1, zi), c110 = hash(xi &+ 1, yi &+ 1, zi)
        let c001 = hash(xi, yi, zi &+ 1), c101 = hash(xi &+ 1, yi, zi &+ 1)
        let c011 = hash(xi, yi &+ 1, zi &+ 1), c111 = hash(xi &+ 1, yi &+ 1, zi &+ 1)
        let near = starLerp(starLerp(c000, c100, u), starLerp(c010, c110, u), v)
        let far = starLerp(starLerp(c001, c101, u), starLerp(c011, c111, u), v)
        return starLerp(near, far, w)
    }
}

/// Shared by the starfield's simulation and drawing.
@inline(__always) func starLerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

func starSmoothStep(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return x * x * (3 - 2 * x)
}

func starEaseOut(_ x: Double) -> Double {
    guard x > 0 else { return 0 }
    return 1 - pow(1 - min(x, 1), 3)
}
