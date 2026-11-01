import Foundation

/// Live loudness for the call's starfield. The mic side is written from the audio
/// thread; Atlas's side comes from the synthesizer's word callbacks or, for a
/// voice played from audio, its measured loudness. The starfield reads both every frame.
/// Deliberately not observable: only the starfield's Canvas redraws, never the call screen around it.
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
