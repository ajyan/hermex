import Foundation

enum TurnEvent: Equatable {
    case speechStarted
    case endOfTurn
}

/// Decides when the user has finished a turn from voice-activity samples.
/// Time comes only from the caller, so it is deterministic under test.
struct TurnDetector {
    private var turnStart: TimeInterval?
    private var runStart: TimeInterval?
    private var silenceStart: TimeInterval?
    private var spoken: TimeInterval = 0

    mutating func observe(isSpeech: Bool, at time: TimeInterval) -> TurnEvent? {
        var started = false
        if isSpeech {
            silenceStart = nil
            if runStart == nil { runStart = time }
            if turnStart == nil {
                turnStart = time
                started = true
            }
        } else if let start = runStart {
            spoken += time - start
            runStart = nil
            silenceStart = time
        }

        if let turnStart, time - turnStart >= VoiceCallTiming.monologueCap {
            reset()
            return .endOfTurn
        }
        if started { return .speechStarted }
        if let silenceStart, time - silenceStart >= VoiceCallTiming.endOfTurnSilence - 0.0001 {
            let heardEnough = spoken >= VoiceCallTiming.minimumTurnSpeech - 0.0001
            reset()
            return heardEnough ? .endOfTurn : nil
        }
        return nil
    }

    mutating func reset() {
        turnStart = nil
        runStart = nil
        silenceStart = nil
        spoken = 0
    }
}
