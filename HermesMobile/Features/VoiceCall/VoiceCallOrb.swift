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

/// What the orb is showing. Colors and form follow it; loudness comes from
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

    /// Whose turn it is, told by shape as well as color: a tight glow with an open ring while
    /// the call listens, the ring closed and resting while Atlas thinks, a wide bloom while it talks.
    fileprivate var form: OrbForm {
        switch self {
        case .listening: OrbForm(spread: 0, ring: 1, ringOpen: 1)
        case .attention: OrbForm(spread: 0.2, ring: 1, ringOpen: 1)
        case .thinking: OrbForm(spread: 0.15, ring: 1, ringOpen: 0)
        case .speaking: OrbForm(spread: 1, ring: 0, ringOpen: 0)
        case .connecting: OrbForm(spread: 0.3, ring: 0, ringOpen: 0)
        case .quiet: OrbForm(spread: 0, ring: 0.4, ringOpen: 0)
        }
    }
}

/// The glow's shape for one mood.
private struct OrbForm {
    /// 0 is the tight listening glow, 1 the wide speaking bloom.
    var spread: Double
    /// How visible the ring around the glow is.
    var ring: Double
    /// 1 is the ring open and following the mic, 0 closed onto the glow.
    var ringOpen: Double
}

/// The call's centerpiece: a breathing glow. A soft wash of light rises from
/// the bottom of the screen; at `focus`, an edgeless glow holds three soft
/// lights that orbit and mix. Its form says whose turn it is: listening is a
/// tight, cool glow inside a ring that swells with the user's voice and closes
/// when the turn is sent; thinking rests the ring on the glow and breathes;
/// Atlas speaking blooms wide and warm with its voice. `focus` is the glow's
/// slot in this view's coordinates; the light reaches past it. Each new
/// `interruptions` count snaps straight to the new form, with no blend, so
/// cutting Atlas off lands at once. Reduce Motion gets a still glow in each
/// mood's form and color.
struct VoiceCallOrb: View {
    let levels: VoiceCallAudioLevels
    let mood: VoiceCallOrbMood
    let focus: CGRect
    var interruptions = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OrbMotion()

    var body: some View {
        // 30 fps: the motion is time-based and soft, and a call can run for a long time.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                guard !focus.isEmpty else { return }
                let frame = motion.advance(
                    to: timeline.date.timeIntervalSinceReferenceDate,
                    levels: levels,
                    mood: mood,
                    interruptions: interruptions,
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
    /// Slow envelope: the glow's swell with phrases.
    var swell: Double
    /// Fast envelope: the pulse with each syllable.
    var pulse: Double
    /// The user's voice, smoothed, for the listening ring.
    var mic: Double
    /// Idle breathing, -1...1.
    var breath: Double
    /// How far the inner lights have turned.
    var spin: Double
    /// 0...1: the thinking beam fading in and out.
    var swirl: Double
    var form: OrbForm
    var palette: OrbPalette
}

/// Smooths levels, breathing, turning, form, and colors from frame to frame.
/// Mutated only from the Canvas renderer on the main thread; not observed.
private final class OrbMotion {
    /// One slow breath at rest, in seconds.
    private static let breathPeriod: Double = 4.2

    private var lastTime: TimeInterval?
    private var mic: Double = 0
    private var voice: Double = 0
    private var swell: Double = 0
    private var pulse: Double = 0
    private var spin: Double = 0
    private var swirl: Double = 0
    private var form: OrbForm?
    private var palette: OrbPalette?
    private var interruptions = 0

    func advance(
        to time: TimeInterval,
        levels: VoiceCallAudioLevels,
        mood: VoiceCallOrbMood,
        interruptions: Int,
        still: Bool
    ) -> OrbFrame {
        let target = mood.palette
        let shape = mood.form
        guard !still else {
            lastTime = nil
            palette = target
            form = shape
            self.interruptions = interruptions
            return OrbFrame(swell: 0, pulse: 0, mic: 0, breath: 0, spin: 0, swirl: 0, form: shape, palette: target)
        }
        let dt = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time

        // Cut off: Atlas's voice and bloom are gone the same frame, no cross-fade.
        if interruptions != self.interruptions {
            self.interruptions = interruptions
            palette = target
            form = shape
            voice = 0
            swell = 0
            pulse = 0
        }

        let raw = levels.read(at: ProcessInfo.processInfo.systemUptime)
        let hearsUser = mood == .listening || mood == .attention
        mic = Self.follow(mic, to: hearsUser ? Double(raw.mic) : 0, dt: dt, attack: 16, release: 5)
        voice = Self.follow(voice, to: mood == .speaking ? Double(raw.voice) : 0, dt: dt, attack: 16, release: 4)
        let energy = max(mic, voice)
        swell = Self.follow(swell, to: energy, dt: dt, attack: 5, release: 2)
        pulse = Self.follow(pulse, to: energy, dt: dt, attack: 30, release: 9)

        let thinking = mood == .thinking || mood == .connecting
        swirl = Self.follow(swirl, to: thinking ? 1 : 0, dt: dt, attack: 2, release: 3)
        // The lights drift at rest and quicken with the voice; thinking stays calm.
        spin += dt * (0.3 + 1.4 * pulse + 0.35 * swirl)

        let breath = sin(time * 2 * .pi / Self.breathPeriod)

        // The ring closes in about a quarter second when the turn is sent; the glow reshapes
        // over about half a second.
        let current = form ?? shape
        form = OrbForm(
            spread: Self.follow(current.spread, to: shape.spread, dt: dt, attack: 6, release: 6),
            ring: Self.follow(current.ring, to: shape.ring, dt: dt, attack: 8, release: 8),
            ringOpen: Self.follow(current.ringOpen, to: shape.ringOpen, dt: dt, attack: 12, release: 12)
        )
        palette = (palette ?? target).mixed(toward: target, amount: 1 - exp(-5 * dt))
        return OrbFrame(
            swell: swell, pulse: pulse, mic: mic, breath: breath,
            spin: spin, swirl: swirl, form: form ?? shape, palette: palette ?? target
        )
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
        let spread = frame.form.spread
        // The voice moves the whole screen only in Atlas's bloom; listening keeps the light close.
        let reach = 0.4 + 0.6 * spread
        let bottom = CGPoint(x: size.width / 2 + sin(frame.spin * 0.6) * size.width * 0.1, y: size.height)

        // Two faint fields of light high in the background, drifting slowly and
        // swelling with each syllable, in the speaker's colors.
        let fields: [(color: SIMD3<Double>, x: Double, y: Double, phase: Double)] = [
            (palette.a, 0.18, 0.22, 0),
            (palette.b, 0.84, 0.36, 2.4),
        ]
        for field in fields {
            let drift = CGPoint(
                x: size.width * field.x + sin(frame.spin * 0.35 + field.phase) * size.width * 0.12,
                y: size.height * field.y + cos(frame.spin * 0.3 + field.phase) * size.height * 0.05
            )
            let fieldRadius = size.width * (0.45 + 0.15 * spread + reach * (0.12 * frame.swell + 0.1 * frame.pulse))
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    Gradient(colors: [
                        palette.color(field.color, opacity: reach * (0.07 + 0.08 * frame.swell + 0.16 * frame.pulse)),
                        .clear,
                    ]),
                    center: drift, startRadius: 0, endRadius: fieldRadius
                )
            )
        }

        // The wash rising from the bottom: low and cool while listening, rising and
        // brightening with Atlas's voice.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: palette.color(\.c, opacity: reach * (0.3 + 0.2 * frame.swell + 0.3 * frame.pulse) + 0.04 * frame.breath), location: 0),
                    .init(color: palette.color(\.b, opacity: reach * (0.1 + 0.1 * frame.swell + 0.14 * frame.pulse)), location: 0.42),
                    .init(color: .clear, location: 1),
                ]),
                center: bottom,
                startRadius: 0,
                endRadius: size.height * (0.38 + 0.26 * spread + reach * (0.12 * frame.swell + 0.16 * frame.pulse))
            )
        )

        let center = CGPoint(x: focus.midX, y: focus.midY)
        let base = min(focus.width, focus.height) * 0.5
        let scale = 0.62 + 0.5 * spread
        let radius = base * scale * (1 + 0.05 * frame.breath + reach * (0.24 * frame.swell + 0.26 * frame.pulse))
        let brightness = 0.74 + 0.08 * frame.breath + (0.2 + 0.3 * spread) * frame.pulse

        context.drawLayer { light in
            light.blendMode = .plusLighter

            // The glow's body: no edge, just light fading out.
            light.fill(
                disc(center, radius),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: palette.color(\.b, opacity: 0.5 * brightness), location: 0),
                        .init(color: palette.color(\.c, opacity: 0.28 * brightness), location: 0.5),
                        .init(color: .clear, location: 1),
                    ]),
                    center: center, startRadius: 0, endRadius: radius
                )
            )

            // Three soft lights orbiting inside it, mixing where they meet and
            // pushed outward by each pulse of the voice. The middle one is the app's accent.
            let lights: [(color: Color, speed: Double, phase: Double, reach: Double)] = [
                (palette.color(\.a), 1, 0, 0.3),
                (Color.accentColor, -0.8, 2.1, 0.26),
                (palette.color(\.b), 0.65, 4.2, 0.34),
            ]
            for item in lights {
                let angle = frame.spin * item.speed + item.phase
                let distance = radius * item.reach * (0.8 + 0.5 * frame.swell + 0.25 * frame.pulse)
                let lightCenter = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance * 0.85)
                let lightRadius = radius * (0.5 + 0.12 * frame.pulse)
                light.fill(
                    disc(lightCenter, lightRadius),
                    with: .radialGradient(
                        Gradient(colors: [item.color.opacity(0.5 * brightness), item.color.opacity(0)]),
                        center: lightCenter, startRadius: 0, endRadius: lightRadius
                    )
                )
            }

            drawRing(frame, in: &light, center: center, base: base)

            // Thinking: a soft beam turning slowly inside the glow, like something working.
            if frame.swirl > 0.01 {
                light.drawLayer { sweep in
                    sweep.opacity = 0.7 * frame.swirl
                    sweep.fill(
                        disc(center, radius),
                        with: .conicGradient(
                            Gradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: palette.color(\.a, opacity: 0.55), location: 0.12),
                                .init(color: .clear, location: 0.3),
                                .init(color: .clear, location: 0.5),
                                .init(color: palette.color(\.b, opacity: 0.45), location: 0.62),
                                .init(color: .clear, location: 0.8),
                            ]),
                            center: center,
                            angle: .radians(frame.spin * 1.4)
                        )
                    )
                    // Keep the beam to a soft band, fading at the middle and the edge.
                    sweep.blendMode = .destinationIn
                    sweep.fill(
                        disc(center, radius),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: .clear, location: 0.15),
                                .init(color: .black, location: 0.55),
                                .init(color: .clear, location: 1),
                            ]),
                            center: center, startRadius: 0, endRadius: radius
                        )
                    )
                }
            }
        }
    }

    /// The listening ring: open around the tight glow and swelling with the user's voice, then
    /// closed onto the glow and breathing slowly while Atlas works.
    private static func drawRing(_ frame: OrbFrame, in light: inout GraphicsContext, center: CGPoint, base: Double) {
        let form = frame.form
        guard form.ring > 0.01 else { return }
        let rest = 1 - form.ringOpen
        let closed = base * (0.66 + 0.03 * frame.breath)
        let open = base * (0.8 + 0.16 * frame.mic)
        let ringRadius = closed + (open - closed) * form.ringOpen
        let alpha = form.ring * (0.32 + 0.36 * frame.mic * form.ringOpen + 0.1 * frame.breath * rest)
        let color = frame.palette.color(\.a)
        let ring = disc(center, ringRadius)
        // A soft halo under a fine line, so the ring reads as light, not a stroke.
        light.stroke(ring, with: .color(color.opacity(0.22 * alpha)), lineWidth: 12)
        light.stroke(ring, with: .color(color.opacity(alpha)), lineWidth: 1.5)
    }

    private static func disc(_ center: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// Glow colors, kept as raw components so state changes can cross-fade per frame. The orb's own
/// light, drawn per frame in a Canvas, so it is not a design token (DESIGN.md § Motion).
private struct OrbPalette {
    /// The glow's heart, and the ring.
    var a: SIMD3<Double>
    /// Its body.
    var b: SIMD3<Double>
    /// Its outer reach, and the wash from below.
    var c: SIMD3<Double>

    // Prismatic takes on Hermes's Nous blue: the user is cool cyan all the way down, Atlas a warm
    // violet, so the wash (the largest lit area) says who has the turn.
    /// The user: cyan into azure, over a deep cyan wash.
    static let user = OrbPalette(a: [0.30, 0.90, 1.00], b: [0.16, 0.62, 1.00], c: [0.00, 0.50, 0.92])
    /// Atlas: lavender into violet, over a warm plum wash.
    static let atlas = OrbPalette(a: [0.70, 0.58, 1.00], b: [0.58, 0.34, 1.00], c: [0.54, 0.20, 0.80])
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
        color(self[keyPath: component], opacity: opacity)
    }

    func color(_ rgb: SIMD3<Double>, opacity: Double = 1) -> Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z, opacity: opacity) // design-drift: allow
    }
}
