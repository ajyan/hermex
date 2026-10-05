import SwiftUI

/// Live loudness for the call visual. The mic side is written from the audio
/// thread, Atlas's side from the synthesizer's word callbacks; the orb reads
/// both every frame. Deliberately not observable: only the orb's Canvas
/// redraws, never the call screen around it.
final class VoiceCallAudioLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: Float = 0
    private var wordAt: TimeInterval = -.infinity
    private var wordStrength: Float = 0

    /// Mic loudness, 0...1 above the noise floor.
    func setMic(_ level: Float) {
        lock.withLock { mic = min(max(level, 0), 1) }
    }

    /// Atlas started saying a word. Longer words land harder.
    func wordSpoken(length: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let strength = Float(min(1, 0.45 + Double(length) / 14))
        lock.withLock {
            wordAt = time
            wordStrength = strength
        }
    }

    /// Atlas stopped talking (finished, cut off, or held).
    func voiceStopped() {
        lock.withLock { wordStrength = 0 }
    }

    /// Mic level and Atlas's voice envelope at `time`. The envelope swells over
    /// a spoken word and decays over the next ~third of a second, with a fast
    /// syllable ripple so a long word doesn't read as one flat bump.
    func read(at time: TimeInterval) -> (mic: Float, voice: Float) {
        let (mic, wordAt, strength) = lock.withLock { (self.mic, self.wordAt, self.wordStrength) }
        let age = time - wordAt
        guard strength > 0, age >= 0, age < 1.2 else { return (mic, 0) }
        let attack = min(1, age / 0.05)
        let decay = exp(-max(0, age - 0.05) / 0.28)
        let ripple = 0.78 + 0.22 * sin(age * 31)
        return (mic, strength * Float(attack * decay * ripple))
    }
}

/// What the orb is showing. Colors and motion follow it; loudness comes from
/// `VoiceCallAudioLevels`.
enum VoiceCallOrbMood: Equatable {
    case connecting, listening, thinking, speaking, attention, quiet

    fileprivate var palette: OrbPalette {
        switch self {
        case .connecting, .quiet: .slate
        case .listening: .user
        case .thinking, .speaking: .atlas
        case .attention: .amber
        }
    }
}

/// The call's centerpiece: a soft, layered blob that deforms with the user's
/// voice while listening and with Atlas's while it talks. Reduce Motion gets a
/// still orb that only changes color with the call state.
struct VoiceCallOrb: View {
    let levels: VoiceCallAudioLevels
    let mood: VoiceCallOrbMood

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OrbMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let frame = motion.advance(
                    to: timeline.date.timeIntervalSinceReferenceDate,
                    levels: levels,
                    mood: mood,
                    still: reduceMotion
                )
                OrbRenderer.draw(frame, in: &context, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Motion

/// One frame's worth of orb state.
private struct OrbFrame {
    var energy: Double
    var micShare: Double
    var phase: Double
    var spin: Double
    var breath: Double
    var palette: OrbPalette
}

/// Smooths levels and colors from frame to frame. Mutated only from the
/// Canvas renderer on the main thread; not observed.
private final class OrbMotion {
    private var lastTime: TimeInterval?
    private var mic: Double = 0
    private var voice: Double = 0
    private var phase: Double = 0
    private var spin: Double = 0
    private var breath: Double = 0
    private var palette: OrbPalette?

    func advance(to time: TimeInterval, levels: VoiceCallAudioLevels, mood: VoiceCallOrbMood, still: Bool) -> OrbFrame {
        let target = mood.palette
        guard !still else {
            lastTime = nil
            palette = target
            return OrbFrame(energy: 0, micShare: 0, phase: 0, spin: 0, breath: 0, palette: target)
        }
        let dt = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time

        let raw = levels.read(at: ProcessInfo.processInfo.systemUptime)
        let hearsUser = mood == .listening || mood == .attention
        mic = Self.follow(mic, to: hearsUser ? Double(raw.mic) : 0, dt: dt)
        voice = Self.follow(voice, to: mood == .speaking ? Double(raw.voice) : 0, dt: dt)
        let energy = max(mic, voice)

        // Faster churn when there's sound, so motion speeds up instead of jumping.
        phase += dt * (0.35 + 2.8 * energy)
        let spinRate: Double = switch mood {
        case .thinking: 1.1
        case .connecting: 0.6
        default: 0.12
        }
        spin += dt * spinRate
        let breathTarget: Double = switch mood {
        case .thinking: 0.10 + 0.06 * sin(time * 2.4)
        case .connecting: 0.05 + 0.04 * sin(time * 3.2)
        case .listening, .attention: 0.03 + 0.02 * sin(time * 1.3)
        default: 0.02
        }
        breath = Self.follow(breath, to: breathTarget, dt: dt, attack: 4, release: 4)

        let current = palette ?? target
        palette = current.mixed(toward: target, amount: 1 - exp(-4 * dt))
        return OrbFrame(
            energy: energy,
            micShare: energy > 0.001 ? mic / (mic + voice) : (hearsUser ? 1 : 0),
            phase: phase,
            spin: spin,
            breath: breath,
            palette: palette ?? target
        )
    }

    /// Exponential follow: quick to rise, slower to fall, like a VU meter.
    private static func follow(_ value: Double, to target: Double, dt: Double, attack: Double = 22, release: Double = 7) -> Double {
        let rate = target > value ? attack : release
        return value + (target - value) * (1 - exp(-rate * dt))
    }
}

// MARK: - Drawing

private enum OrbRenderer {
    private static let pointCount = 96

    static func draw(_ frame: OrbFrame, in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.30
        let scale = 1 + 0.14 * frame.energy + frame.breath
        let palette = frame.palette

        // Halo
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: radius * 0.45))
            let r = radius * scale * (1.15 + 0.15 * frame.energy)
            layer.opacity = 0.35 + 0.3 * frame.energy
            layer.fill(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .color(palette.glow)
            )
        }

        // Blobs, lighter where they overlap.
        let amplitude = 0.03 + 0.12 * frame.energy
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            for index in 0..<3 {
                let layerRadius = radius * scale * (0.98 - 0.07 * Double(index))
                let path = blob(
                    center: center,
                    radius: layerRadius,
                    amplitude: amplitude * (1 + 0.25 * Double(index)),
                    phase: frame.phase * (1 + 0.35 * Double(index)) + Double(index) * 2.1,
                    spin: frame.spin * (index.isMultiple(of: 2) ? 1 : -1.3) + Double(index)
                )
                let colors = palette.layer(index)
                layer.opacity = 0.62
                layer.fill(
                    path,
                    with: .radialGradient(
                        Gradient(colors: [colors.0, colors.1]),
                        center: CGPoint(x: center.x - layerRadius * 0.25, y: center.y - layerRadius * 0.3),
                        startRadius: 0,
                        endRadius: layerRadius * 1.4
                    )
                )
            }
        }

        // Specular core gives the orb depth.
        let coreRadius = radius * scale * 0.55
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius * 1.1,
                width: coreRadius * 2,
                height: coreRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.28 + 0.2 * frame.energy), Color.white.opacity(0)]),
                center: CGPoint(x: center.x - coreRadius * 0.3, y: center.y - coreRadius * 0.5),
                startRadius: 0,
                endRadius: coreRadius
            )
        )
    }

    /// A closed wobbling loop: a circle pushed in and out by a few slow harmonics.
    private static func blob(center: CGPoint, radius: Double, amplitude: Double, phase: Double, spin: Double) -> Path {
        var path = Path()
        for step in 0...pointCount {
            let angle = Double(step) / Double(pointCount) * 2 * .pi
            let theta = angle + spin
            let wobble = 0.55 * sin(3 * theta + phase)
                + 0.30 * sin(5 * theta - phase * 1.3)
                + 0.15 * sin(7 * theta + phase * 2.1)
            let r = radius * (1 + amplitude * wobble)
            let point = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Orb colors, kept as raw components so state changes can cross-fade per frame.
private struct OrbPalette {
    var a: SIMD3<Double>
    var b: SIMD3<Double>
    var c: SIMD3<Double>

    /// The user: cool cyan into blue.
    static let user = OrbPalette(a: [0.30, 0.85, 1.00], b: [0.20, 0.45, 1.00], c: [0.45, 0.30, 0.95])
    /// Atlas: violet into magenta with a warm edge.
    static let atlas = OrbPalette(a: [0.62, 0.40, 1.00], b: [0.95, 0.35, 0.75], c: [1.00, 0.58, 0.35])
    static let amber = OrbPalette(a: [1.00, 0.78, 0.30], b: [1.00, 0.52, 0.20], c: [0.95, 0.35, 0.30])
    static let slate = OrbPalette(a: [0.55, 0.62, 0.75], b: [0.38, 0.44, 0.58], c: [0.50, 0.48, 0.65])

    func mixed(toward other: OrbPalette, amount: Double) -> OrbPalette {
        OrbPalette(
            a: a + (other.a - a) * amount,
            b: b + (other.b - b) * amount,
            c: c + (other.c - c) * amount
        )
    }

    var glow: Color { Self.color(b) }

    func layer(_ index: Int) -> (Color, Color) {
        switch index {
        case 0: (Self.color(a), Self.color(b, opacity: 0.1))
        case 1: (Self.color(b), Self.color(c, opacity: 0.1))
        default: (Self.color(c), Self.color(a, opacity: 0.1))
        }
    }

    private static func color(_ rgb: SIMD3<Double>, opacity: Double = 1) -> Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z, opacity: opacity)
    }
}
