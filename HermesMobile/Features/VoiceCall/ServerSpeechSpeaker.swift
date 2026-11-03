import AVFoundation

/// Speaks call replies with the server's neural voice (`POST /api/tts`), one
/// fetch at a time: the first sentence alone so it starts fast, then whatever
/// has queued while it played. The server allows one TTS request per client
/// every 2 s, which batching keeps under. A fetch that fails is spoken by
/// `fallback` (which also plays the thinking cue) and the next one tries the
/// server again; after `maxConsecutiveFailures` in a row the rest of the call
/// uses `fallback`.
@MainActor
final class ServerSpeechSpeaker: NSObject, SpeechSpeaking, AVAudioPlayerDelegate {
    var onFinishedQueue: (() -> Void)?
    var onAudioStarted: ((String, SpeechVoice) -> Void)?
    var isSpeaking: Bool { !queued.isEmpty || fetchTask != nil || !clips.isEmpty || player != nil || fallback.isSpeaking }
    /// Finished reply lines, then the playing clip's reply words in proportion to its progress,
    /// then what the on-device voice has said since it last drained.
    var heardText: String {
        var parts = heard
        if let player, player.duration > 0 {
            parts.append(Self.replyWords(of: playing, through: player.currentTime / player.duration))
        }
        parts.append(fallback.heardText)
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Mirrors the server's per-client TTS rate limit (`_TtsRateLimiter`, 2 s).
    static let serverRequestSpacing: TimeInterval = 2.05
    static let maxConsecutiveFailures = 3

    private let synthesize: (String) async throws -> Data
    private let fallback: SpeechSpeaking
    private let levels: VoiceCallAudioLevels?
    private let log: (String) -> Void
    private let requestSpacing: TimeInterval
    private let makePlayer: (Data) throws -> AVAudioPlayer

    /// A queued sentence, and whether it is reply text (`SpeechSpeaking.heardText`).
    private struct Line {
        let text: String
        let isReply: Bool
    }

    /// Speech in order: fetched server audio, or a line the server voice failed on.
    private enum Clip {
        case audio(Data, lines: [Line])
        case onDevice(Line)
    }

    private var queued: [Line] = []
    private var clips: [Clip] = []
    private var fetchTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    /// The lines `player` is playing, and the reply lines whose audio finished.
    private var playing: [Line] = []
    private var heard: [String] = []
    private var meterTask: Task<Void, Never>?
    private var lastRequestAt = -TimeInterval.infinity
    /// Server-voice failures in a row; at `maxConsecutiveFailures` later sentences go to `fallback`.
    private var consecutiveFailures = 0
    private var usesFallback: Bool { consecutiveFailures >= Self.maxConsecutiveFailures }

    init(
        synthesize: @escaping (String) async throws -> Data,
        fallback: SpeechSpeaking,
        levels: VoiceCallAudioLevels? = nil,
        requestSpacing: TimeInterval = ServerSpeechSpeaker.serverRequestSpacing,
        makePlayer: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.requestSpacing = requestSpacing
        self.makePlayer = makePlayer
        self.synthesize = synthesize
        self.fallback = fallback
        self.levels = levels
        self.log = log
        super.init()
        fallback.onFinishedQueue = { [weak self] in self?.fallbackFinished() }
        fallback.onAudioStarted = { [weak self] text, voice in self?.onAudioStarted?(text, voice) }
    }

    func enqueue(_ sentence: String, isReply: Bool) {
        queued.append(Line(text: sentence, isReply: isReply))
        pump()
    }

    func resetHeardText() {
        heard = []
        fallback.resetHeardText()
    }

    func stopNow() {
        fetchTask?.cancel()
        fetchTask = nil
        queued = []
        clips = []
        player?.stop()
        player = nil
        playing = []
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
            // After server audio already fetched, so the voices never overlap.
            clips.append(contentsOf: queued.map(Clip.onDevice))
            queued = []
            playNextIfIdle()
            return
        }
        let lines = queued
        queued = []
        fetchTask = Task { [weak self] in await self?.fetch(lines) }
    }

    private func fetch(_ lines: [Line]) async {
        let text = lines.map(\.text).joined(separator: " ")
        let wait = lastRequestAt + requestSpacing - ProcessInfo.processInfo.systemUptime
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard !Task.isCancelled else { return }
        lastRequestAt = ProcessInfo.processInfo.systemUptime
        let started = lastRequestAt
        do {
            let data = try await synthesize(text)
            guard !Task.isCancelled else { return }
            log(String(format: "tts fetched %d sentence(s), %d chars in %.2fs",
                       lines.count, text.count, ProcessInfo.processInfo.systemUptime - started))
            consecutiveFailures = 0
            clips.append(.audio(data, lines: lines))
        } catch is CancellationError {
            return
        } catch APIError.http(statusCode: 429, _) {
            guard !Task.isCancelled else { return }
            log("tts rate limited; retrying")
            queued.insert(contentsOf: lines, at: 0)
        } catch {
            guard !Task.isCancelled else { return }
            consecutiveFailures += 1
            log("tts failed (\(error)); " + (usesFallback
                ? "using the on-device voice for the rest of the call"
                : "using the on-device voice for this sentence"))
            clips.append(contentsOf: lines.map(Clip.onDevice))
        }
        fetchTask = nil
        playNextIfIdle()
        pump()
        finishIfDrained()
    }

    // MARK: - Playback

    private func playNextIfIdle() {
        guard player == nil, let next = clips.first else { return }
        let data: Data
        let lines: [Line]
        switch next {
        case .onDevice(let line):
            clips.removeFirst()
            fallback.enqueue(line.text, isReply: line.isReply)
            playNextIfIdle()
            return
        case .audio(let audio, let clipLines):
            // After the on-device voice finishes, so the voices never overlap.
            guard !fallback.isSpeaking else { return }
            clips.removeFirst()
            data = audio
            lines = clipLines
        }
        guard let player = try? makePlayer(data) else {
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
        playing = lines
        startMeter()
        onAudioStarted?(lines.map(\.text).joined(separator: " "), .server)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.clipFinished(id) }
    }

    private func clipFinished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        heard += playing.filter(\.isReply).map(\.text)
        playing = []
        stopMeter()
        playNextIfIdle()
        pump()
        finishIfDrained()
    }

    private func fallbackFinished() {
        // The on-device voice is quiet until the next server clip; its words join the finished lines.
        heard.append(fallback.heardText)
        fallback.resetHeardText()
        playNextIfIdle()
        pump()
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard !isSpeaking else { return }
        levels?.voiceStopped()
        onFinishedQueue?()
    }

    /// The reply words of `lines` heard `fraction` of the way through their clip, counting words
    /// as evenly spaced in time.
    private static func replyWords(of lines: [Line], through fraction: Double) -> String {
        let words = lines.flatMap { line in
            line.text.split(whereSeparator: \.isWhitespace).map { (word: $0, isReply: line.isReply) }
        }
        let count = Int((Double(words.count) * min(max(fraction, 0), 1)).rounded())
        return words.prefix(count).filter(\.isReply).map(\.word).joined(separator: " ")
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
