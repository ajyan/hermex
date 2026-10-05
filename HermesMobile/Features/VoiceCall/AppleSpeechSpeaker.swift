import AudioToolbox
import AVFoundation

/// Speaks call replies through `AVSpeechSynthesizer`, on the call's audio session.
@MainActor
final class AppleSpeechSpeaker: SpeechSpeaking {
    var onFinishedQueue: (() -> Void)?
    var isSpeaking: Bool { !pending.isEmpty }

    private let synthesizer: ChatSpeechSynthesizing
    private let voice: AVSpeechSynthesisVoice?
    private var pending: Set<ObjectIdentifier> = []
    private var delegateProxy: VoiceCallSynthesizerDelegate?
    private var cueTask: Task<Void, Never>?
    private let levels: VoiceCallAudioLevels?

    /// `levels` receives a beat per spoken word for the call visual.
    init(
        synthesizer: ChatSpeechSynthesizing = AVSpeechSynthesizer(),
        voice: AVSpeechSynthesisVoice? = VoiceSelection.installedVoice(),
        levels: VoiceCallAudioLevels? = nil
    ) {
        self.synthesizer = synthesizer
        self.voice = voice
        self.levels = levels
        let proxy = VoiceCallSynthesizerDelegate(
            onWord: { [levels] length in levels?.wordSpoken(length: length) }
        ) { [weak self] id, finished in
            self?.utteranceEnded(id, finished: finished)
        }
        delegateProxy = proxy
        synthesizer.delegate = proxy
    }

    func enqueue(_ sentence: String) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        pending.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    func stopNow() {
        pending.removeAll()
        levels?.voiceStopped()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func setThinkingCue(_ on: Bool) {
        cueTask?.cancel()
        cueTask = nil
        guard on else { return }
        cueTask = Task {
            while !Task.isCancelled {
                AudioServicesPlaySystemSound(Self.cueSound)
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// "Tink": short and soft.
    private static let cueSound: SystemSoundID = 1103

    private func utteranceEnded(_ id: ObjectIdentifier, finished: Bool) {
        guard pending.remove(id) != nil, finished, pending.isEmpty else { return }
        levels?.voiceStopped()
        onFinishedQueue?()
    }
}

private final class VoiceCallSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onWord: @Sendable (Int) -> Void
    private let onEnded: @MainActor (ObjectIdentifier, Bool) -> Void

    init(onWord: @escaping @Sendable (Int) -> Void, onEnded: @escaping @MainActor (ObjectIdentifier, Bool) -> Void) {
        self.onWord = onWord
        self.onEnded = onEnded
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        onWord(characterRange.length)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        report(utterance, finished: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        report(utterance, finished: false)
    }

    private func report(_ utterance: AVSpeechUtterance, finished: Bool) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [onEnded] in onEnded(id, finished) }
    }
}
