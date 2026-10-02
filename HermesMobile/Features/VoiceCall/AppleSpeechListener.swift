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

    func start() async throws {
        guard await Self.requestPermissions() else { throw VoiceCallStartError.permissionDenied }

        let recognizer: CallRecognizer
        if #available(iOS 26, *), SpeechTranscriber.isAvailable {
            recognizer = try await AnalyzerRecognizer.make(locale: Self.locale)
        } else {
            recognizer = try SFRecognizer(locale: Self.locale)
        }
        recognizer.onResult = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal { self.onFinal?(text) } else { self.onPartial?(text) }
        }
        self.recognizer = recognizer

        let input = engine.inputNode
        // Echo cancellation, so Atlas's own voice doesn't read as the user barging in.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        let meter = VoiceActivityMeter { [weak self] isSpeech, time in
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
            input.removeTap(onBus: 0)
            recognizer.finish()
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognizer?.finish()
        recognizer = nil
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

    static func make(locale: Locale) async throws -> AnalyzerRecognizer {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceCallStartError.recognitionUnavailable(language: locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceCallStartError.recognitionUnavailable(language: locale.identifier)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let recognizer = AnalyzerRecognizer(analyzer: analyzer, format: format, continuation: continuation)
        recognizer.resultsTask = Task { [weak recognizer] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    recognizer?.onResult?(text, result.isFinal)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        return recognizer
    }

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.format = format
        self.continuation = continuation
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

    init(locale: Locale) throws {
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
                    self.startSegment()
                }
            }
        }
    }

    func makeBufferSink(inputFormat: AVAudioFormat) -> (AVAudioPCMBuffer) -> Void {
        let box = requestBox
        return { buffer in box.append(buffer) }
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
/// published every 100 ms. Runs on the audio thread.
private final class VoiceActivityMeter: @unchecked Sendable {
    /// Speech must be this far above the noise floor.
    private static let marginDecibels: Float = 12
    /// Quieter than this is never speech.
    private static let absoluteFloorDecibels: Float = -55
    private static let window: TimeInterval = 0.1

    private let publish: (Bool, TimeInterval) -> Void
    private var noiseFloor: Float = -60
    private var windowStart: TimeInterval?
    private var speechBuffers = 0
    private var totalBuffers = 0

    init(publish: @escaping (Bool, TimeInterval) -> Void) {
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
