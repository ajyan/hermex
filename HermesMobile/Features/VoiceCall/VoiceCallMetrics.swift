import Foundation

/// A call's latency numbers for the log: each turn's end of speech to the reply's first audible
/// word, each barge-in's speech to silence, and a one-line summary when the call ends. Times are
/// the controller's uptime clock, so tests drive them.
struct VoiceCallMetrics {
    /// One sent turn's marks, until its reply is heard.
    private struct Turn {
        /// When the user's turn ended (VAD end of turn, or the send for a tap or stalled transcript).
        let speechEnd: TimeInterval
        var accepted: TimeInterval?
        var firstText: TimeInterval?
        /// The reply's first spoken sentence; audio starting on it is the first audible word.
        var firstSentence: String?
        var tool: String?
    }

    private var turn: Turn?
    private var turns = 0
    private var audibleMS: [Int] = []
    private var bargeIns = 0
    private var spokenBargeInMS: [Int] = []
    /// Speech heard over Atlas that the talk-over guard kept from interrupting it.
    var echoIgnored = 0
    var listenerRestarts = 0

    /// A user turn was sent. The opening turn has no speech to time, so it passes nil and is not counted.
    mutating func turnSent(speechEnd: TimeInterval?) {
        turn = speechEnd.map { Turn(speechEnd: $0) }
        if speechEnd != nil { turns += 1 }
    }

    mutating func sendAccepted(at time: TimeInterval) {
        if turn?.accepted == nil { turn?.accepted = time }
    }

    mutating func replyText(at time: TimeInterval) {
        if turn?.firstText == nil { turn?.firstText = time }
    }

    mutating func replySentence(_ sentence: String) {
        if turn?.firstSentence == nil { turn?.firstSentence = sentence }
    }

    mutating func toolStarted(_ name: String) {
        if turn?.tool == nil { turn?.tool = name }
    }

    /// Audio started on `text`. When it carries the reply's first sentence, returns the turn's log
    /// line and its end-of-speech-to-audible milliseconds, once per turn.
    mutating func audioStarted(_ text: String, voice: SpeechVoice, at time: TimeInterval) -> (line: String, ms: Int)? {
        guard let turn, let first = turn.firstSentence, text.contains(first) else { return nil }
        self.turn = nil
        let ms = Self.ms(time - turn.speechEnd)
        audibleMS.append(ms)
        let splits = "send \(Self.span(turn.speechEnd, turn.accepted)), "
            + "first text \(Self.span(turn.accepted, turn.firstText)), tts \(Self.span(turn.firstText, time))"
        let line = String(format: "turn timing: speech_end→audible %.2fs", time - turn.speechEnd)
            + " (\(splits)) voice=\(voice.rawValue) tool=\(turn.tool ?? "none")"
        return (line, ms)
    }

    /// Atlas was cut off. `heard` is when the first words over the reply arrived and `onset` when the
    /// level meter heard that speech start (both nil for a tap); `detected` and `silent` bracket the
    /// speaker's stop. Returns the log line and the barge-in's milliseconds for the turn trace.
    mutating func bargeIn(
        _ trigger: String,
        heard: TimeInterval?,
        onset: TimeInterval?,
        detected: TimeInterval,
        silent: TimeInterval
    ) -> (line: String, ms: Int) {
        bargeIns += 1
        let stop = String(format: "%.2f", silent - detected)
        guard let heard else {
            return (String(format: "barge-in (\(trigger)): tap→silent %.2fs", silent - detected), Self.ms(silent - detected))
        }
        let ms = Self.ms(silent - heard)
        spokenBargeInMS.append(ms)
        let vad = onset.map { String(format: ", vad→silent %.2f", silent - $0) } ?? ""
        let line = String(format: "barge-in (\(trigger)): speech→silent %.2fs", silent - heard)
            + " (detect \(Self.span(heard, detected)), stop \(stop)\(vad))"
        return (line, ms)
    }

    /// One line for the end of the call.
    var summary: String {
        "call summary: turns \(turns), speech_end→audible \(Self.stats(audibleMS)), "
            + "barge-ins \(bargeIns) (spoken \(Self.stats(spokenBargeInMS))), "
            + "echo ignored \(echoIgnored), listener restarts \(listenerRestarts)"
    }

    /// "p50 2.10s max 3.40s n=3", or "n=0". The p50 of an even count is the lower middle sample.
    private static func stats(_ samples: [Int]) -> String {
        guard !samples.isEmpty else { return "n=0" }
        let sorted = samples.sorted()
        let p50 = Double(sorted[(sorted.count - 1) / 2]) / 1000
        let max = Double(sorted[sorted.count - 1]) / 1000
        return String(format: "p50 %.2fs max %.2fs n=%d", p50, max, sorted.count)
    }

    private static func span(_ start: TimeInterval?, _ end: TimeInterval?) -> String {
        guard let start, let end else { return "?" }
        return String(format: "%.2f", end - start)
    }

    private static func ms(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}
