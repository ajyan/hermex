import Foundation

/// Mic capture and on-device recognition. Callbacks arrive on the main actor;
/// voice activity is published at most ~10 Hz with times on the
/// `ProcessInfo.systemUptime` clock.
@MainActor
protocol SpeechListening: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onVoiceActivity: ((Bool, TimeInterval) -> Void)? { get set }
    func start() async throws
    func stop()
}

/// Speaks queued sentences in order. `onFinishedQueue` fires when the queue
/// drains naturally, never after `stopNow()`.
@MainActor
protocol SpeechSpeaking: AnyObject {
    var onFinishedQueue: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    func enqueue(_ sentence: String)
    func stopNow()
    /// A soft repeating cue while Atlas is thinking.
    func setThinkingCue(_ on: Bool)
}

/// The chat a call drives: the open session's `ChatViewModel`.
@MainActor
protocol VoiceCallChatDriving: AnyObject {
    func sendVoiceMessage(_ text: String) async -> Bool
    func cancelActiveStream() async -> Bool
    func respondToApproval(_ choice: ApprovalChoice) async -> Bool
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
