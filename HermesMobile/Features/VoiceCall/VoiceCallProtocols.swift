import Foundation

/// Mic capture and on-device recognition. Callbacks arrive on the main actor;
/// voice activity is published at most ~10 Hz with times on the
/// `ProcessInfo.systemUptime` clock.
@MainActor
protocol SpeechListening: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onVoiceActivity: ((Bool, TimeInterval) -> Void)? { get set }
    /// The mic stopped or changed under a running listener (a route change, an
    /// interruption ending): stop and start it again. Carries the reason, for the log.
    var onNeedsRestart: ((String) -> Void)? { get set }
    func start() async throws
    func stop()
    /// The user has paused: finalize what has been heard so far, so its final
    /// result arrives now rather than when the recognizer decides.
    func endTurn()
}

/// Which voice played a stretch of speech, for the call's timing log.
enum SpeechVoice: String {
    case server, device
}

/// Speaks queued sentences in order. `onFinishedQueue` fires when the queue
/// drains naturally, never after `stopNow()`.
@MainActor
protocol SpeechSpeaking: AnyObject {
    var onFinishedQueue: (() -> Void)? { get set }
    /// Fires as audio for queued text starts playing, with that text (several sentences when
    /// the server voice fetched them as one clip) and the voice playing it.
    var onAudioStarted: ((String, SpeechVoice) -> Void)? { get set }
    var isSpeaking: Bool { get }
    /// Reply text audibly played since the last `resetHeardText()`: each sentence queued with
    /// `isReply` that finished, then the words heard so far of the one playing. Other lines
    /// (hold-on lines, read-backs) never count, and `stopNow()` drops only the one playing.
    /// The call resets it as each reply begins and reads it as the user cuts in.
    var heardText: String { get }
    /// Queues `sentence`; `isReply` marks it as reply text, which counts toward `heardText`.
    func enqueue(_ sentence: String, isReply: Bool)
    func resetHeardText()
    func stopNow()
    /// A single soft cue that Atlas is working on a reply; `false` marks the wait over.
    func setThinkingCue(_ on: Bool)
}

extension SpeechSpeaking {
    func enqueue(_ sentence: String) { enqueue(sentence, isReply: false) }
}

/// The chat a call drives: the open session's `ChatViewModel`.
@MainActor
protocol VoiceCallChatDriving: AnyObject {
    /// True once the server sealed the session for compression: it refuses every later send.
    var isCompressionRotated: Bool { get }
    func sendVoiceMessage(_ text: String) async -> Bool
    func cancelActiveStream() async -> Bool
    func respondToApproval(_ choice: ApprovalChoice) async -> Bool
    /// The call's system audio is up (or gone). While it is up the app keeps running in
    /// the background, so the chat keeps its stream when a background task expires.
    func voiceCallDidChange(isActive: Bool)
    /// Set by the call: during it, the chat attached a turn the server started by itself
    /// (a background dig coming back), with its stream id.
    var onServerStartedReply: ((String) -> Void)? { get set }
    /// The call's timing of the current turn, in milliseconds, for its turn trace: from the end
    /// of the user's speech to the reply's first audible word, or from speech over the reply to silence.
    func noteVoiceTiming(speechEndToAudibleMS: Int?, bargeInMS: Int?)
}

/// CallKit: the system call that keeps audio alive in the background and
/// carries Lock Screen, Dynamic Island, and AirPods controls.
@MainActor
protocol CallSystemBridging: AnyObject {
    var onEnded: (() -> Void)? { get set }
    var onMuteChanged: ((Bool) -> Void)? { get set }
    var onHoldChanged: ((Bool) -> Void)? { get set }
    /// Returns once the call is connected and its audio session is active.
    func startCall() async throws
    func endCall()
    /// Asks the system to mute; the result comes back through `onMuteChanged`.
    func setMuted(_ muted: Bool)
}

enum VoiceCallStartError: Error, Equatable {
    case permissionDenied
    case recognitionUnavailable(language: String)
    /// The system call never connected its audio.
    case callDidNotConnect
}
