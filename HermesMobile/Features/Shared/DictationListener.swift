import AVFoundation
import Speech
import UIKit

// The mic behind a text box's dictation. On iOS 26 it is `SpeechAnalyzer` with `DictationTranscriber`,
// biased toward the server's names and words, and it keeps the audio so the server can transcribe each
// passage again with a larger model. Below iOS 26, or when that can't start, it is the chat composer's
// on-device recognizer, with no vocabulary and no audio.

enum DictationListenerEvent: Equatable {
    /// The words of the stretch of speech still being heard; each one replaces the last.
    case volatile(String)
    /// Words that will not change, to add after the settled words so far.
    case settled(String)
    /// The mic stopped by itself: an interruption, or an error to show.
    case ended(error: String?)
}

enum DictationListenerError: LocalizedError {
    case permissionDenied
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow the microphone and speech recognition for Hermex in Settings to dictate."
        case .unavailable: "Dictation isn't available on this iPhone right now."
        case .failed(let message): message
        }
    }
}

@MainActor
protocol DictationListening: AnyObject {
    /// Names the recognizer in the server's dictation log.
    var engineName: String { get }
    var onEvent: ((DictationListenerEvent) -> Void)? { get set }
    /// Starts the mic. `vocabulary` loads the names and words to expect; listening doesn't wait for it.
    func start(vocabulary: @escaping () async -> [String]) async throws
    /// Stops the mic and returns once the last words have settled.
    func stop() async
    /// Stops the mic now and drops what hasn't settled.
    func cancel()
    /// The audio since the last take as a WAV file: through the last settled words, or through now.
    /// Nil when this recognizer keeps no audio or there is too little to send.
    func takeAudio(throughNow: Bool) -> Data?
    /// The live words so far are already in the box as the user's own: leave them out from here on.
    func skipLiveWords()
}

/// Leaves out the first words of the stretch being heard, once the box took them over as an edit.
struct DictationWordSkip {
    private var count = 0

    mutating func skip(_ shown: String) {
        count += shown.split(whereSeparator: \.isWhitespace).count
    }

    func strip(_ text: String) -> String {
        guard count > 0 else { return text }
        return text.split(whereSeparator: \.isWhitespace).dropFirst(count).joined(separator: " ")
    }

    /// The stretch ended: the next one starts whole.
    mutating func reset() { count = 0 }
}

/// The mic's audio as 16-bit mono samples, written on the audio thread and taken in passages.
final class DictationAudioStore: @unchecked Sendable {
    let sampleRate: Double
    private let lock = NSLock()
    private var samples: [Int16] = []
    /// How many samples were taken or dropped before `samples[0]`.
    private var taken = 0

    /// Passages shorter than this aren't worth a second transcription.
    static let minimumSeconds = 0.4
    /// A stretch nobody takes (no server) is dropped past this, so a long dictation can't fill memory.
    static let maximumSeconds = 180.0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Samples heard so far, taken ones included.
    var total: Int {
        lock.withLock { taken + samples.count }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var chunk = [Int16](repeating: 0, count: frames)
        if let ints = buffer.int16ChannelData {
            chunk.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: ints[0], count: frames) }
        } else if let floats = buffer.floatChannelData {
            for index in 0..<frames {
                chunk[index] = Int16(max(-1, min(1, floats[0][index])) * Float(Int16.max))
            }
        } else {
            return
        }
        append(chunk)
    }

    func append(_ chunk: [Int16]) {
        lock.withLock {
            samples.append(contentsOf: chunk)
            let overflow = samples.count - Int(Self.maximumSeconds * sampleRate)
            if overflow > 0 {
                samples.removeFirst(overflow)
                taken += overflow
            }
        }
    }

    /// The samples up to `end` (counted from the start of listening; nil is everything) as a WAV file.
    func take(through end: Int?) -> Data? {
        let passage: [Int16] = lock.withLock {
            let count = min(samples.count, max(0, (end ?? .max) - taken))
            guard Double(count) >= Self.minimumSeconds * sampleRate else { return [] }
            let passage = Array(samples.prefix(count))
            samples.removeFirst(count)
            taken += count
            return passage
        }
        return passage.isEmpty ? nil : Self.wav(passage, sampleRate: sampleRate)
    }

    static func wav(_ samples: [Int16], sampleRate: Double) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(bytes)
        samples.withUnsafeBufferPointer { pointer in
            pointer.withMemoryRebound(to: UInt8.self) { data.append(contentsOf: $0) }
        }
        return data
    }
}

enum DictationListenerFactory {
    /// The best recognizer this iPhone has.
    @MainActor
    static func live() -> any DictationListening {
        #if DEBUG
        if let script = ProcessInfo.processInfo.environment["HERMEX_DICTATION_SCRIPT"], !script.isEmpty {
            return ScriptedDictationListener(script: script)
        }
        #endif
        if #available(iOS 26, *) { return AnalyzerDictationListener() }
        return LegacyDictationListener()
    }
}

#if DEBUG
/// Speaks a fixed script, a word every 0.4 s and a sentence settling at each period, so the simulator
/// (which has no usable mic) can show how dictation and the keyboard share a box. Set
/// `HERMEX_DICTATION_SCRIPT` in the launch environment.
@MainActor
final class ScriptedDictationListener: DictationListening {
    let engineName = "scripted"
    var onEvent: ((DictationListenerEvent) -> Void)?
    private var words: [Substring]
    private var open: [Substring] = []
    private var skip = DictationWordSkip()
    private var task: Task<Void, Never>?

    init(script: String) {
        words = script.split(separator: " ")
    }

    func start(vocabulary: @escaping () async -> [String]) async throws {
        task = Task { [weak self] in
            while let self, !Task.isCancelled, !self.words.isEmpty {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self.open.append(self.words.removeFirst())
                let heard = self.skip.strip(self.open.joined(separator: " "))
                if self.open.last?.hasSuffix(".") == true {
                    self.open = []
                    self.skip.reset()
                    self.onEvent?(.settled(heard))
                } else {
                    self.onEvent?(.volatile(heard))
                }
            }
        }
    }

    func stop() async {
        task?.cancel()
        let rest = skip.strip(open.joined(separator: " "))
        open = []
        if !rest.isEmpty { onEvent?(.settled(rest)) }
    }

    func cancel() { task?.cancel() }
    func takeAudio(throughNow: Bool) -> Data? { nil }
    func skipLiveWords() { skip.skip(skip.strip(open.joined(separator: " "))) }
}
#endif

@available(iOS 26, *)
@MainActor
final class AnalyzerDictationListener: DictationListening {
    let engineName = "analyzer"
    var onEvent: ((DictationListenerEvent) -> Void)?

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var store: DictationAudioStore?
    /// The sample the settled words reach.
    private var settledThrough = 0
    /// The end of the audio a final result already covered.
    private var finalizedThrough = CMTime.zero
    private var skip = DictationWordSkip()
    private var lastVolatile = ""
    private let lease = ComposerDictationLease.live()
    private var interruptionObserver: NSObjectProtocol?
    private var isRunning = false

    /// How long Stop waits for the last words before taking them as heard.
    static let settleDeadline: Duration = .seconds(3)

    func start(vocabulary: @escaping () async -> [String]) async throws {
        let terms = Task { await vocabulary() }
        guard await Self.requestPermissions() else { throw DictationListenerError.permissionDenied }
        let locale = await Self.supportedLocale()
        guard let locale else { throw DictationListenerError.unavailable }
        // DictationTranscriber, not SpeechTranscriber: only it honors the contextual strings.
        let transcriber = DictationTranscriber(
            locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults], attributeOptions: []
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationListenerError.unavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.continuation = continuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(result, sampleRate: format.sampleRate)
                }
            } catch {
                self?.ended(error: error.localizedDescription)
            }
        }
        try await analyzer.start(inputSequence: stream)
        Task {
            let terms = await terms.value
            guard !terms.isEmpty else { return }
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try? await analyzer.setContext(context)
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            ComposerVoiceAudioSessionConfiguration.category,
            mode: ComposerVoiceAudioSessionConfiguration.mode,
            options: ComposerVoiceAudioSessionConfiguration.options
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        try ComposerVoiceInputPreflight.validate(recordingFormat: inputFormat)
        let store = DictationAudioStore(sampleRate: format.sampleRate)
        let converter = AVAudioConverter(from: inputFormat, to: format)
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
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
            store.append(output)
            continuation.yield(AnalyzerInput(buffer: output))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            teardown()
            throw error
        }
        self.engine = engine
        self.store = store
        isRunning = true
        lease.acquire()
        ComposerAudioCaptureState.shared.setCapturing(true)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
            MainActor.assumeIsolated {
                if began { self?.ended(error: nil) }
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        stopCapture()
        let analyzer = analyzer
        let results = resultsTask
        // The last words settle once the analyzer has read the audio it was given.
        let settle = Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await results?.value
        }
        let deadline = Task {
            try? await Task.sleep(for: Self.settleDeadline)
            results?.cancel()
        }
        await settle.value
        deadline.cancel()
        if !lastVolatile.isEmpty {
            // The deadline passed with words still open: keep them as heard.
            let rest = lastVolatile
            lastVolatile = ""
            onEvent?(.settled(rest))
        }
        settledThrough = store?.total ?? settledThrough
        teardown()
    }

    func cancel() {
        guard isRunning || analyzer != nil else { return }
        stopCapture()
        resultsTask?.cancel()
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        teardown()
    }

    func takeAudio(throughNow: Bool) -> Data? {
        store?.take(through: throughNow ? nil : settledThrough)
    }

    func skipLiveWords() {
        skip.skip(lastVolatile)
        lastVolatile = ""
    }

    private func handle(_ result: DictationTranscriber.Result, sampleRate: Double) {
        let heard = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            finalizedThrough = CMTimeMaximum(finalizedThrough, result.range.end)
            let seconds = finalizedThrough.seconds
            if seconds.isFinite { settledThrough = max(settledThrough, Int(seconds * sampleRate)) }
            let text = skip.strip(heard)
            skip.reset()
            lastVolatile = ""
            if !text.isEmpty { onEvent?(.settled(text)) }
        } else {
            // A volatile result for audio a final already covered would repeat its words.
            guard result.range.end > finalizedThrough else { return }
            lastVolatile = skip.strip(heard)
            onEvent?(.volatile(lastVolatile))
        }
    }

    private func ended(error: String?) {
        guard isRunning else { return }
        onEvent?(.ended(error: error))
    }

    private func stopCapture() {
        isRunning = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        continuation?.finish()
        continuation = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        lease.release()
        ComposerAudioCaptureState.shared.setCapturing(false)
    }

    private func teardown() {
        analyzer = nil
        resultsTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func supportedLocale() async -> Locale? {
        if let current = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) { return current }
        return await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
    }

    private static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// The chat composer's on-device recognizer as a dictation mic: no vocabulary, no audio.
@MainActor
final class LegacyDictationListener: DictationListening {
    let engineName = "legacy"
    var onEvent: ((DictationListenerEvent) -> Void)?

    private let input: ComposerVoiceInputController
    private var committed = ""
    private var lastVolatile = ""
    private var skip = DictationWordSkip()
    private var isRunning = false

    init(input: ComposerVoiceInputController? = nil) {
        self.input = input ?? ComposerVoiceInputController(punctuates: true)
    }

    func start(vocabulary: @escaping () async -> [String]) async throws {
        committed = ""
        lastVolatile = ""
        skip.reset()
        input.onCommittedTranscript = { [weak self] in self?.committedChanged($0) }
        input.onStateChange = { [weak self] in self?.stateChanged() }
        await input.toggle(currentDraft: "") { [weak self] in self?.drafted($0) }
        guard input.state != .idle else {
            throw input.errorMessage.map(DictationListenerError.failed) ?? DictationListenerError.unavailable
        }
        isRunning = true
    }

    func stop() async {
        isRunning = false
        input.stopKeepingTranscript()
    }

    func cancel() {
        isRunning = false
        input.stopBeforeSubmittingDraft()
    }

    func takeAudio(throughNow: Bool) -> Data? { nil }

    func skipLiveWords() {
        skip.skip(lastVolatile)
        lastVolatile = ""
    }

    /// The recognizer's whole draft: the finished segments, then the open one.
    private func drafted(_ draft: String) {
        guard draft.hasPrefix(committed) else { return }
        lastVolatile = skip.strip(String(draft.dropFirst(committed.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        onEvent?(.volatile(lastVolatile))
    }

    private func committedChanged(_ all: String) {
        guard all.hasPrefix(committed) else { return }
        let added = skip.strip(String(all.dropFirst(committed.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        committed = all
        skip.reset()
        lastVolatile = ""
        if !added.isEmpty { onEvent?(.settled(added)) }
    }

    private func stateChanged() {
        guard isRunning, input.state == .idle else { return }
        isRunning = false
        onEvent?(.ended(error: input.errorMessage))
    }
}

/// The focused field behind the box being dictated into: where its cursor is, so speech lands there,
/// and a way to change its words without disturbing the keyboard.
@MainActor
protocol DictationCursor {
    /// The cursor's character offset when the focused field holds exactly `text`; nil otherwise.
    func position(in text: String) -> Int?
    /// Makes `edit` in the focused field when it holds `old`, turning it into `new`, and leaves the
    /// cursor at `cursor`. The caller still writes `new` to the box's binding.
    func write(_ edit: DictationDocument.Edit, from old: String, to new: String, cursor: Int)
}

/// The focused UIKit text input behind a SwiftUI field. Dictation edits it through `UITextInput`, as
/// the keyboard does: a field whose text is only replaced through its binding loses its cursor and
/// leaves the keyboard's autocorrection holding the old words.
struct FocusedFieldCursor: DictationCursor {
    func position(in text: String) -> Int? {
        guard let input = Self.focusedInput(showing: text), let range = input.selectedTextRange else { return nil }
        let utf16 = input.offset(from: input.beginningOfDocument, to: range.end)
        guard let index = String.Index(utf16Offset: utf16, in: text).samePosition(in: text) else { return nil }
        return text.distance(from: text.startIndex, to: index)
    }

    func write(_ edit: DictationDocument.Edit, from old: String, to new: String, cursor: Int) {
        guard let input = Self.focusedInput(showing: old),
              let start = Self.position(edit.at, in: old, of: input),
              let end = Self.position(edit.at + edit.removed, in: old, of: input),
              let range = input.textRange(from: start, to: end) else { return }
        let from = new.index(new.startIndex, offsetBy: edit.at)
        let replacement = String(new[from..<new.index(from, offsetBy: edit.inserted)])
        input.replace(range, withText: replacement)
        guard let caret = Self.position(cursor, in: new, of: input) else { return }
        input.selectedTextRange = input.textRange(from: caret, to: caret)
    }

    private static func position(_ offset: Int, in text: String, of input: UITextInput) -> UITextPosition? {
        let index = text.index(text.startIndex, offsetBy: min(max(offset, 0), text.count))
        return input.position(from: input.beginningOfDocument, offset: index.utf16Offset(in: text))
    }

    private static func focusedInput(showing text: String) -> UITextInput? {
        UIResponder.hxFocused = nil
        UIApplication.shared.sendAction(#selector(UIResponder.hxReportFocus(_:)), to: nil, from: nil, for: nil)
        guard let input = UIResponder.hxFocused as? UITextInput,
              let whole = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument),
              input.text(in: whole) == text else { return nil }
        return input
    }
}

private extension UIResponder {
    static weak var hxFocused: UIResponder?

    @objc func hxReportFocus(_ sender: Any?) {
        UIResponder.hxFocused = self
    }
}
