import SwiftUI

/// Live loudness for the call visual. The mic side is written from the audio
/// thread; Atlas's side comes from the synthesizer's word callbacks or, for a
/// voice played from audio, its measured loudness. The orb reads both every frame. Deliberately not observable: only the orb's Canvas
/// redraws, never the call screen around it.
final class VoiceCallAudioLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: Float = 0
    private var wordAt: TimeInterval = -.infinity
    private var wordStrength: Float = 0
    private var voiceLevel: Float = 0

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

    /// Atlas's measured loudness, 0...1, for a voice played from audio.
    func setVoice(_ level: Float) {
        lock.withLock { voiceLevel = min(max(level, 0), 1) }
    }

    /// Atlas stopped talking (finished, cut off, or held).
    func voiceStopped() {
        lock.withLock {
            wordStrength = 0
            voiceLevel = 0
        }
    }

    /// Mic level and Atlas's voice envelope at `time`. The envelope swells over
    /// a spoken word and decays over the next ~third of a second, with a fast
    /// syllable ripple so a long word doesn't read as one flat bump.
    func read(at time: TimeInterval) -> (mic: Float, voice: Float) {
        let (mic, wordAt, strength, measured) = lock.withLock {
            (self.mic, self.wordAt, self.wordStrength, self.voiceLevel)
        }
        let age = time - wordAt
        guard strength > 0, age >= 0, age < 1.2 else { return (mic, measured) }
        let attack = min(1, age / 0.05)
        let decay = exp(-max(0, age - 0.05) / 0.28)
        let ripple = 0.78 + 0.22 * sin(age * 31)
        return (mic, max(measured, strength * Float(attack * decay * ripple)))
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

/// The call's centerpiece: a breathing glow. A soft wash of light rises from
/// the bottom of the screen, and an edgeless glow at `focus` breathes slowly
/// at rest and swells and brightens with the voice (the user's while
/// listening, Atlas's while it talks). `focus` is the glow's slot in this
/// view's coordinates; the light reaches past it. Reduce Motion gets a still
/// glow that only changes color with the call state.
struct VoiceCallOrb: View {
    let levels: VoiceCallAudioLevels
    let mood: VoiceCallOrbMood
    let focus: CGRect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OrbMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                guard !focus.isEmpty else { return }
                let frame = motion.advance(
                    to: timeline.date.timeIntervalSinceReferenceDate,
                    levels: levels,
                    mood: mood,
                    still: reduceMotion
                )
                OrbRenderer.draw(frame, in: &context, size: size, focus: focus)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Motion

/// One frame's worth of glow state.
private struct OrbFrame {
    /// Loudness, smoothed.
    var energy: Double
    /// Slow envelope: the glow's swell with phrases.
    var swell: Double
    /// Idle breathing, -1...1.
    var breath: Double
    var palette: OrbPalette
}

/// Smooths levels, breathing, and colors from frame to frame. Mutated only
/// from the Canvas renderer on the main thread; not observed.
private final class OrbMotion {
    /// One slow breath at rest, in seconds.
    private static let breathPeriod: Double = 4.2

    private var lastTime: TimeInterval?
    private var mic: Double = 0
    private var voice: Double = 0
    private var swell: Double = 0
    private var palette: OrbPalette?

    func advance(to time: TimeInterval, levels: VoiceCallAudioLevels, mood: VoiceCallOrbMood, still: Bool) -> OrbFrame {
        let target = mood.palette
        guard !still else {
            lastTime = nil
            palette = target
            return OrbFrame(energy: 0, swell: 0, breath: 0, palette: target)
        }
        let dt = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time

        let raw = levels.read(at: ProcessInfo.processInfo.systemUptime)
        let hearsUser = mood == .listening || mood == .attention
        mic = Self.follow(mic, to: hearsUser ? Double(raw.mic) : 0, dt: dt, attack: 14, release: 4)
        voice = Self.follow(voice, to: mood == .speaking ? Double(raw.voice) : 0, dt: dt, attack: 14, release: 3.5)
        let energy = max(mic, voice)
        swell = Self.follow(swell, to: energy, dt: dt, attack: 5, release: 2)

        // Thinking breathes a little quicker, so a wait still feels alive.
        let period = mood == .thinking ? Self.breathPeriod * 0.6 : Self.breathPeriod
        let breath = sin(time * 2 * .pi / period)

        let current = palette ?? target
        palette = current.mixed(toward: target, amount: 1 - exp(-3 * dt))
        return OrbFrame(energy: energy, swell: swell, breath: breath, palette: palette ?? target)
    }

    /// Exponential follow: quick to rise, slower to fall.
    private static func follow(_ value: Double, to target: Double, dt: Double, attack: Double, release: Double) -> Double {
        let rate = target > value ? attack : release
        return value + (target - value) * (1 - exp(-rate * dt))
    }
}

// MARK: - Drawing

private enum OrbRenderer {
    static func draw(_ frame: OrbFrame, in context: inout GraphicsContext, size: CGSize, focus: CGRect) {
        let palette = frame.palette
        let screen = CGRect(origin: .zero, size: size)

        // The wash rising from the bottom, brighter as the voice swells.
        context.fill(
            Path(screen),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: palette.color(\.c, opacity: 0.30 + 0.22 * frame.swell + 0.03 * frame.breath), location: 0),
                    .init(color: palette.color(\.b, opacity: 0.12 + 0.1 * frame.swell), location: 0.42),
                    .init(color: .clear, location: 1),
                ]),
                center: CGPoint(x: size.width / 2, y: size.height),
                startRadius: 0,
                endRadius: size.height * (0.62 + 0.12 * frame.swell)
            )
        )

        // The glow: no edge, just light fading out, breathing at rest and
        // swelling with the voice.
        let center = CGPoint(x: focus.midX, y: focus.midY)
        let base = min(focus.width, focus.height) * 0.5
        let radius = base * (0.88 + 0.06 * frame.breath + 0.32 * frame.swell + 0.08 * frame.energy)
        let brightness = 0.72 + 0.06 * frame.breath + 0.28 * frame.energy
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: palette.color(\.a, opacity: 0.78 * brightness), location: 0),
                    .init(color: palette.color(\.b, opacity: 0.6 * brightness), location: 0.32),
                    .init(color: palette.color(\.c, opacity: 0.3 * brightness), location: 0.62),
                    .init(color: .clear, location: 1),
                ]),
                center: center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }
}

/// Glow colors, kept as raw components so state changes can cross-fade per frame.
private struct OrbPalette {
    /// The glow's heart.
    var a: SIMD3<Double>
    /// Its body.
    var b: SIMD3<Double>
    /// Its outer reach, and the wash from below.
    var c: SIMD3<Double>

    // Prismatic takes on Hermes's Nous blue (#0053FD): the user leans cyan, Atlas violet.
    /// The user: cyan into electric blue into Nous blue.
    static let user = OrbPalette(a: [0.24, 0.88, 1.00], b: [0.29, 0.52, 1.00], c: [0.00, 0.33, 0.99])
    /// Atlas: electric blue into violet, over Nous blue.
    static let atlas = OrbPalette(a: [0.45, 0.75, 1.00], b: [0.54, 0.36, 1.00], c: [0.00, 0.33, 0.99])
    static let amber = OrbPalette(a: [1.00, 0.78, 0.30], b: [1.00, 0.52, 0.20], c: [0.95, 0.35, 0.30])
    static let slate = OrbPalette(a: [0.55, 0.62, 0.75], b: [0.38, 0.44, 0.58], c: [0.30, 0.34, 0.48])

    func mixed(toward other: OrbPalette, amount: Double) -> OrbPalette {
        OrbPalette(
            a: a + (other.a - a) * amount,
            b: b + (other.b - b) * amount,
            c: c + (other.c - c) * amount
        )
    }

    func color(_ component: KeyPath<OrbPalette, SIMD3<Double>>, opacity: Double = 1) -> Color {
        let rgb = self[keyPath: component]
        return Color(red: rgb.x, green: rgb.y, blue: rgb.z, opacity: opacity)
    }
}
