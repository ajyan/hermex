import AudioToolbox
import AVFoundation

/// Speaks call replies through `AVSpeechSynthesizer`, on the call's audio session.
@MainActor
final class AppleSpeechSpeaker: SpeechSpeaking {
    var onFinishedQueue: (() -> Void)?
    var onAudioStarted: ((String, SpeechVoice) -> Void)?
    var isSpeaking: Bool { !pending.isEmpty }
    var heardText: String {
        (heardReplies + [speakingNow?.prefix ?? ""]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private let synthesizer: ChatSpeechSynthesizing
    private let voice: AVSpeechSynthesisVoice?
    private var pending: Set<ObjectIdentifier> = []
    private var delegateProxy: VoiceCallSynthesizerDelegate?
    private let levels: VoiceCallAudioLevels?
    private let log: (String) -> Void
    /// When each pending utterance was queued and what it says, so the log shows how long audio took to start.
    private var enqueued: [ObjectIdentifier: (at: TimeInterval, text: String, isReply: Bool)] = [:]
    /// Reply utterances that finished, and the reply utterance playing with the text before its current word.
    private var heardReplies: [String] = []
    private var speakingNow: (id: ObjectIdentifier, prefix: String)?

    /// `levels` receives a beat per spoken word for the call visual.
    init(
        synthesizer: ChatSpeechSynthesizing = AVSpeechSynthesizer(),
        voice: AVSpeechSynthesisVoice? = VoiceSelection.installedVoice(),
        levels: VoiceCallAudioLevels? = nil,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.synthesizer = synthesizer
        self.voice = voice
        self.levels = levels
        self.log = log
        log("speaker voice: \(voice?.identifier ?? "system default") quality=\(voice?.quality.rawValue ?? 0)")
        let proxy = VoiceCallSynthesizerDelegate(
            // The word is heard once it clears the output path (a Bluetooth headset adds ~0.2 s).
            onWord: { [levels] length in
                let heardAt = ProcessInfo.processInfo.systemUptime + AVAudioSession.sharedInstance().outputLatency
                levels?.wordSpoken(length: length, at: heardAt)
            },
            onStarted: { [weak self] id in self?.utteranceStarted(id) },
            onReached: { [weak self] id, prefix in self?.utteranceReached(id, prefix: prefix) }
        ) { [weak self] id, finished in
            self?.utteranceEnded(id, finished: finished)
        }
        delegateProxy = proxy
        synthesizer.delegate = proxy
    }

    func enqueue(_ sentence: String, isReply: Bool) {
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        pending.insert(ObjectIdentifier(utterance))
        enqueued[ObjectIdentifier(utterance)] = (ProcessInfo.processInfo.systemUptime, sentence, isReply)
        synthesizer.speak(utterance)
    }

    func resetHeardText() {
        heardReplies = []
        speakingNow = nil
    }

    func stopNow() {
        pending.removeAll()
        enqueued.removeAll()
        speakingNow = nil
        levels?.voiceStopped()
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Plays the cue once as it turns on. It never repeats: a tick every second or so reads as
    /// anxious, and the call's hold-on lines cover a long wait.
    func setThinkingCue(_ on: Bool) {
        guard on else { return }
        AudioServicesPlaySystemSound(Self.cueSound)
    }

    /// "Tink": short and soft.
    private static let cueSound: SystemSoundID = 1103

    private func utteranceStarted(_ id: ObjectIdentifier) {
        guard let queued = enqueued[id] else { return }
        log(String(format: "speaker audio started %.2fs after enqueue", ProcessInfo.processInfo.systemUptime - queued.at))
        onAudioStarted?(queued.text, .device)
    }

    private func utteranceReached(_ id: ObjectIdentifier, prefix: String) {
        guard enqueued[id]?.isReply == true else { return }
        speakingNow = (id, prefix)
    }

    private func utteranceEnded(_ id: ObjectIdentifier, finished: Bool) {
        if speakingNow?.id == id { speakingNow = nil }
        if finished, let queued = enqueued[id], queued.isReply { heardReplies.append(queued.text) }
        enqueued[id] = nil
        guard pending.remove(id) != nil, finished, pending.isEmpty else { return }
        levels?.voiceStopped()
        onFinishedQueue?()
    }
}

private final class VoiceCallSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onWord: @Sendable (Int) -> Void
    private let onStarted: @MainActor (ObjectIdentifier) -> Void
    /// An utterance reached a word, with its text before that word (what has been said of it).
    private let onReached: @MainActor (ObjectIdentifier, String) -> Void
    private let onEnded: @MainActor (ObjectIdentifier, Bool) -> Void

    init(
        onWord: @escaping @Sendable (Int) -> Void,
        onStarted: @escaping @MainActor (ObjectIdentifier) -> Void,
        onReached: @escaping @MainActor (ObjectIdentifier, String) -> Void,
        onEnded: @escaping @MainActor (ObjectIdentifier, Bool) -> Void
    ) {
        self.onWord = onWord
        self.onStarted = onStarted
        self.onReached = onReached
        self.onEnded = onEnded
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [onStarted] in onStarted(id) }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        onWord(characterRange.length)
        let id = ObjectIdentifier(utterance)
        let prefix = (utterance.speechString as NSString).substring(to: characterRange.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor [onReached] in onReached(id, prefix) }
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
