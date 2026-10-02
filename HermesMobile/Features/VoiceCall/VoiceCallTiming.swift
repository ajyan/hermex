import Foundation

/// Tunable thresholds for a voice call. Device tuning changes these, nothing else.
enum VoiceCallTiming {
    /// Silence that ends a turn once enough speech has been heard.
    static let endOfTurnSilence: TimeInterval = 0.8
    /// Speech needed before silence can end a turn; shorter blips are ignored.
    static let minimumTurnSpeech: TimeInterval = 0.3
    /// A turn is forced to end this long after it started, so a stuck mic can't hang the call.
    static let monologueCap: TimeInterval = 30
    /// Words, not in what Atlas is saying, that must be heard before talking over Atlas interrupts it.
    static let bargeInNovelWords = 2
    /// After a turn ends, how long to wait for the recognizer's final text before sending the partial.
    static let finalTranscriptWait: TimeInterval = 1.0
    /// Wait without a reply token before the thinking cue plays.
    static let thinkingCueDelay: TimeInterval = 1.5
    /// How long to listen for an approval answer before denying.
    static let approvalListenTimeout: TimeInterval = 8
    /// How long the system call may take to connect its audio before the call gives up.
    static let connectTimeout: TimeInterval = 10
    /// How long to wait for a dropped stream to come back before ending the call.
    static let reconnectGiveUp: TimeInterval = 30
}
