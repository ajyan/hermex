import Foundation

/// Tunable thresholds for a voice call. Device tuning changes these, nothing else.
enum VoiceCallTiming {
    /// Silence that ends a turn once enough speech has been heard.
    static let endOfTurnSilence: TimeInterval = 0.8
    /// Speech needed before silence can end a turn; shorter blips are ignored.
    static let minimumTurnSpeech: TimeInterval = 0.3
    /// With no voice activity, a transcript that stops changing this long is a finished turn.
    /// Covers a quiet speaker the level meter never calls speech.
    static let transcriptStallEnd: TimeInterval = 1.5
    /// Listening this long with no words recognized hangs up a forgotten call. Shorter
    /// silences are thinking time: the call never prompts, since noise starts false turns.
    static let silentHangUp: TimeInterval = 300
    /// After a run ends with no reply text yet, how long to wait for it before going back to listening.
    static let noReplyTextGrace: TimeInterval = 3
    /// A turn is forced to end this long after it started, so a stuck mic can't hang the call.
    static let monologueCap: TimeInterval = 30
    /// Words, not in what Atlas is saying, that must be heard before talking over Atlas interrupts it.
    /// A backchannel ("yeah", "mm") needs one more, so agreeing doesn't cut Atlas off.
    static let bargeInNovelWords = 1
    /// New words heard while Atlas is still working on a reply that make them part of the
    /// turn just sent: the run is cancelled and the turn reopened with them.
    static let continuationNovelWords = 2
    /// Speech that starts this soon after a turn is sent is the user still talking (a pause
    /// ended the turn early); speech that starts later while Atlas works is the room.
    static let continuationWindow: TimeInterval = 3
    /// A final transcript that nothing has followed for this long is a finished turn,
    /// even while the level meter still hears noise.
    static let finalTranscriptSettle: TimeInterval = 1.0
    /// After a turn ends, how long to wait for the recognizer's final text before sending the partial.
    static let finalTranscriptWait: TimeInterval = 1.0
    /// Wait without a reply token before the thinking cue plays.
    static let thinkingCueDelay: TimeInterval = 1.5
    /// Wait without reply text before saying "One moment", so a long think isn't dead air.
    static let holdOnDelay: TimeInterval = 8
    /// After that, how often "Still working on it" repeats while nothing has been said.
    static let stillWorkingInterval: TimeInterval = 15
    /// A transcript ending mid-thought ("tell me a fact about") waits this long after its
    /// last change before it is sent, in case the user is still choosing the next word.
    static let midThoughtWait: TimeInterval = 1.5
    /// After "wait" takes back a turn, how long it waits for more words before sending it as it was.
    static let waitForMore: TimeInterval = 8
    /// Words recognized this soon after Atlas starts replying were said before any of its
    /// audio played (synthesis alone takes longer), so they can't be talking over it.
    static let talkOverGrace: TimeInterval = 1.0
    /// How long to listen for an approval answer before denying.
    static let approvalListenTimeout: TimeInterval = 8
    /// How long the system call may take to connect its audio before the call gives up.
    static let connectTimeout: TimeInterval = 10
    /// How long to wait for a dropped stream to come back before ending the call.
    static let reconnectGiveUp: TimeInterval = 30
}

enum VoiceCallSettings {
    /// Speak call replies with the server's OpenAI-compatible voice instead of the on-device one.
    static let usesServerVoiceKey = "voiceCall.usesServerVoice"
}
