import AVFoundation

/// Speaks call replies with the server's neural voice (`POST /api/tts`), one
/// fetch at a time: the first sentence alone so it starts fast, then whatever
/// has queued while it played. The server allows one TTS request per client
/// every 2 s, which batching keeps under. If the server voice fails, the rest
/// of the call falls back to `fallback`, which also plays the thinking cue.
@MainActor
final class ServerSpeechSpeaker: NSObject, SpeechSpeaking, AVAudioPlayerDelegate {
    var onFinishedQueue: (() -> Void)?
    var isSpeaking: Bool { !queued.isEmpty || fetchTask != nil || !clips.isEmpty || player != nil || fallback.isSpeaking }

    /// Mirrors the server's per-client TTS rate limit (`_TtsRateLimiter`, 2 s).
    static let serverRequestSpacing: TimeInterval = 2.05

    private let synthesize: (String) async throws -> Data
    private let fallback: SpeechSpeaking
    private let levels: VoiceCallAudioLevels?
    private let log: (String) -> Void
    private let requestSpacing: TimeInterval

    private var queued: [String] = []
    private var clips: [Data] = []
    private var fetchTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var meterTask: Task<Void, Never>?
    private var lastRequestAt = -TimeInterval.infinity
    /// Set once the server voice has failed; later sentences go to `fallback`.
    private var usesFallback = false

    init(
        synthesize: @escaping (String) async throws -> Data,
        fallback: SpeechSpeaking,
        levels: VoiceCallAudioLevels? = nil,
        requestSpacing: TimeInterval = ServerSpeechSpeaker.serverRequestSpacing,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.requestSpacing = requestSpacing
        self.synthesize = synthesize
        self.fallback = fallback
        self.levels = levels
        self.log = log
        super.init()
        fallback.onFinishedQueue = { [weak self] in self?.finishIfDrained() }
    }

    func enqueue(_ sentence: String) {
        queued.append(sentence)
        pump()
    }

    func stopNow() {
        fetchTask?.cancel()
        fetchTask = nil
        queued = []
        clips = []
        player?.stop()
        player = nil
        stopMeter()
        fallback.stopNow()
        levels?.voiceStopped()
    }

    func setThinkingCue(_ on: Bool) {
        fallback.setThinkingCue(on)
    }

    // MARK: - Fetching

    private func pump() {
        guard fetchTask == nil, !queued.isEmpty else { return }
        if usesFallback {
            // Wait for server audio already fetched, so the voices never overlap.
            guard player == nil, clips.isEmpty else { return }
            queued.forEach(fallback.enqueue)
            queued = []
            return
        }
        let text = queued.joined(separator: " ")
        let count = queued.count
        queued = []
        fetchTask = Task { [weak self] in await self?.fetch(text, sentences: count) }
    }

    private func fetch(_ text: String, sentences: Int) async {
        let wait = lastRequestAt + requestSpacing - ProcessInfo.processInfo.systemUptime
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard !Task.isCancelled else { return }
        lastRequestAt = ProcessInfo.processInfo.systemUptime
        let started = lastRequestAt
        do {
            let data = try await synthesize(text)
            guard !Task.isCancelled else { return }
            log(String(format: "tts fetched %d sentence(s), %d chars in %.2fs",
                       sentences, text.count, ProcessInfo.processInfo.systemUptime - started))
            clips.append(data)
        } catch is CancellationError {
            return
        } catch APIError.http(statusCode: 429, _) {
            guard !Task.isCancelled else { return }
            log("tts rate limited; retrying")
            queued.insert(text, at: 0)
        } catch {
            guard !Task.isCancelled else { return }
            log("tts failed (\(error)); using the on-device voice")
            usesFallback = true
            queued.insert(text, at: 0)
        }
        fetchTask = nil
        playNextIfIdle()
        pump()
        finishIfDrained()
    }

    // MARK: - Playback

    private func playNextIfIdle() {
        guard player == nil, !clips.isEmpty else { return }
        let data = clips.removeFirst()
        guard let player = try? AVAudioPlayer(data: data) else {
            log("tts audio undecodable; skipping clip")
            playNextIfIdle()
            return
        }
        player.delegate = self
        player.isMeteringEnabled = levels != nil
        guard player.play() else {
            log("tts playback failed to start")
            playNextIfIdle()
            return
        }
        self.player = player
        startMeter()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.clipFinished(id) }
    }

    private func clipFinished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        stopMeter()
        playNextIfIdle()
        pump()
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard !isSpeaking else { return }
        levels?.voiceStopped()
        onFinishedQueue?()
    }

    /// Drives the orb from the clip's measured loudness, about 30 times a second.
    private func startMeter() {
        guard let levels else { return }
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let player = self?.player else { return }
                player.updateMeters()
                // -45 dB and quieter reads as silence; -10 dB as full scale.
                levels.setVoice((player.averagePower(forChannel: 0) + 45) / 35)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
        levels?.setVoice(0)
    }
}
