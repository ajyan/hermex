import AVFoundation
import Speech

/// Mic capture and on-device English recognition for a call: `SpeechAnalyzer`
/// on iOS 26+, on-device `SFSpeechRecognizer` below. Start it after the call's
/// audio session is active.
@MainActor
final class AppleSpeechListener: SpeechListening {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onVoiceActivity: ((Bool, TimeInterval) -> Void)?

    static let locale = Locale(identifier: "en-US")

    private let engine = AVAudioEngine()
    private var recognizer: CallRecognizer?
    private let levels: VoiceCallAudioLevels?
    private let log: (String) -> Void
    private var sessionObservers: [NSObjectProtocol] = []

    /// `levels` receives mic loudness for the call visual.
    init(levels: VoiceCallAudioLevels? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.levels = levels
        self.log = log
    }

    func start() async throws {
        var phase = ProcessInfo.processInfo.systemUptime
        func elapsed() -> String {
            let now = ProcessInfo.processInfo.systemUptime
            defer { phase = now }
            return String(format: "%.2fs", now - phase)
        }
        guard await Self.requestPermissions() else {
            log("listener: permission denied")
            throw VoiceCallStartError.permissionDenied
        }
        log("listener: permissions \(elapsed())")

        let recognizer: CallRecognizer
        do {
            if #available(iOS 26, *), SpeechTranscriber.isAvailable {
                recognizer = try await AnalyzerRecognizer.make(locale: Self.locale, log: log)
                log("listener: SpeechAnalyzer ready \(elapsed())")
            } else {
                recognizer = try SFRecognizer(locale: Self.locale, log: log)
                log("listener: SFSpeechRecognizer ready \(elapsed())")
            }
        } catch {
            log("listener: recognizer failed after \(elapsed()): \(error)")
            throw error
        }
        recognizer.onResult = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal { self.onFinal?(text) } else { self.onPartial?(text) }
        }
        self.recognizer = recognizer

        let input = engine.inputNode
        // Echo cancellation, so Atlas's own voice doesn't read as the user barging in.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            log("listener: voice processing (echo cancellation) failed: \(error)")
        }
        let format = input.outputFormat(forBus: 0)
        log("listener: input \(format.sampleRate) Hz, \(format.channelCount) ch; setup \(elapsed())")
        let meter = VoiceActivityMeter(levels: levels) { [weak self] isSpeech, time in
            Task { @MainActor in self?.onVoiceActivity?(isSpeech, time) }
        }
        let sink = recognizer.makeBufferSink(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink(buffer)
            meter.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log("listener: engine start failed: \(error)")
            input.removeTap(onBus: 0)
            recognizer.finish()
            throw error
        }
        log("listener: engine running \(elapsed())")
        observeAudioSession()
    }

    /// Logs the audio-session events that can silently stop the mic mid-call.
    private func observeAudioSession() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let log = log
        sessionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                log("audio session interruption: \(type == .began ? "began" : type == .ended ? "ended" : "unknown")")
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                log("audio route change: reason=\(reason)")
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
                log("audio media services were reset")
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                log("audio engine configuration change; running=\(self?.engine.isRunning ?? false)")
            },
        ]
    }

    func endTurn() {
        recognizer?.endTurn()
    }

    func stop() {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognizer?.finish()
        recognizer = nil
        levels?.setMic(0)
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// A recognition backend: takes mic buffers on the audio thread, reports text on the main actor.
@MainActor
private protocol CallRecognizer: AnyObject {
    var onResult: ((String, Bool) -> Void)? { get set }
    /// Returns the closure the audio tap calls with each buffer.
    func makeBufferSink(inputFormat: AVAudioFormat) -> (AVAudioPCMBuffer) -> Void
    /// Finalizes the audio heard so far.
    func endTurn()
    func finish()
}

@available(iOS 26, *)
@MainActor
private final class AnalyzerRecognizer: CallRecognizer {
    var onResult: ((String, Bool) -> Void)?

    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var log: (String) -> Void = { _ in }
    /// The end of the audio already covered by a final result.
    private var finalizedThrough = CMTime.zero

    static func make(locale: Locale, log: @escaping (String) -> Void) async throws -> AnalyzerRecognizer {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceCallStartError.recognitionUnavailable(language: locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log("listener: downloading speech assets")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceCallStartError.recognitionUnavailable(language: locale.identifier)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let recognizer = AnalyzerRecognizer(analyzer: analyzer, format: format, continuation: continuation)
        recognizer.log = log
        recognizer.resultsTask = Task { [weak recognizer] in
            do {
                for try await result in transcriber.results {
                    recognizer?.handle(result)
                }
                log("listener: transcriber results ended")
            } catch {
                log("listener: transcriber failed: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        return recognizer
    }

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.format = format
        self.continuation = continuation
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            finalizedThrough = CMTimeMaximum(finalizedThrough, result.range.end)
        } else if result.range.end <= finalizedThrough {
            // A volatile result for audio a final already covered would repeat its words.
            log("listener: dropped stale volatile \"\(text)\"")
            return
        }
        onResult?(text, result.isFinal)
    }

    func endTurn() {
        let analyzer = analyzer
        let log = log
        Task {
            do {
                try await analyzer.finalize(through: nil)
            } catch {
                log("listener: finalize failed: \(error)")
            }
        }
    }

    func makeBufferSink(inputFormat: AVAudioFormat) -> (AVAudioPCMBuffer) -> Void {
        let format = format
        let continuation = continuation
        let converter = AVAudioConverter(from: inputFormat, to: format)
        return { buffer in
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var consumed = false
            converter.convert(to: output, error: nil) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    func finish() {
        continuation.finish()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// iOS 18–25 fallback. Each pause ends a segment (the result carries metadata),
/// which is reported as final and starts a fresh request.
@MainActor
private final class SFRecognizer: CallRecognizer {
    var onResult: ((String, Bool) -> Void)?

    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let requestBox = RequestBox()
    private let log: (String) -> Void

    init(locale: Locale, log: @escaping (String) -> Void) throws {
        self.log = log
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw VoiceCallStartError.recognitionUnavailable(language: locale.identifier)
        }
        self.recognizer = recognizer
        startSegment()
    }

    private func startSegment() {
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        requestBox.set(request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let segmentDone = result?.isFinal == true || result?.speechRecognitionMetadata != nil
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if segmentDone {
                    self.onResult?(text, true)
                    self.request?.endAudio()
                    self.startSegment()
                } else if !text.isEmpty {
                    self.onResult?(text, false)
                } else if failed, self.request === request {
                    self.log("listener: recognition task failed: \(error.map { String(describing: $0) } ?? "")")
                    self.startSegment()
                }
            }
        }
    }

    func makeBufferSink(inputFormat: AVAudioFormat) -> (AVAudioPCMBuffer) -> Void {
        let box = requestBox
        return { buffer in box.append(buffer) }
    }

    /// Ending the request's audio makes it deliver its final result, which starts the next segment.
    func endTurn() {
        request?.endAudio()
    }

    func finish() {
        request?.endAudio()
        task?.cancel()
        requestBox.set(nil)
    }

    /// The current request, shared with the audio thread.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?

        func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
            lock.withLock { self.request = request }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock { request }?.append(buffer)
        }
    }
}

/// Voice activity from buffer loudness against an adaptive noise floor,
/// published every 100 ms, plus per-buffer loudness for the call visual.
/// Runs on the audio thread.
private final class VoiceActivityMeter: @unchecked Sendable {
    /// Speech must be this far above the noise floor.
    private static let marginDecibels: Float = 9
    /// Quieter than this is never speech.
    private static let absoluteFloorDecibels: Float = -58
    private static let window: TimeInterval = 0.1

    /// Loudness this far above the noise floor reads as full scale on the visual.
    private static let visualRangeDecibels: Float = 30

    private let levels: VoiceCallAudioLevels?
    private let publish: (Bool, TimeInterval) -> Void
    private var noiseFloor: Float = -70
    private var windowStart: TimeInterval?
    private var speechBuffers = 0
    private var totalBuffers = 0

    init(levels: VoiceCallAudioLevels?, publish: @escaping (Bool, TimeInterval) -> Void) {
        self.levels = levels
        self.publish = publish
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let level = 20 * log10(max(rms, 1e-7))

        // The floor drops at once and rises slowly, so speech doesn't become the floor.
        noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * 0.002
        let isSpeech = level > max(noiseFloor + Self.marginDecibels, Self.absoluteFloorDecibels)
        let audible = level - max(noiseFloor + Self.marginDecibels * 0.5, Self.absoluteFloorDecibels)
        levels?.setMic(audible / Self.visualRangeDecibels)

        let now = ProcessInfo.processInfo.systemUptime
        let start = windowStart ?? now
        windowStart = start
        totalBuffers += 1
        if isSpeech { speechBuffers += 1 }
        guard now - start >= Self.window else { return }
        publish(speechBuffers * 2 >= totalBuffers, now)
        windowStart = now
        speechBuffers = 0
        totalBuffers = 0
    }
}
