import Foundation

/// What the call's starfield is showing. `base` reads it from the call's state; `converge` and
/// `interrupt` are short beats the starfield plays itself, timed from the moment Atlas's reply
/// starts or the user cuts it off.
enum VoiceCallScenePhase: Int, CaseIterable, Equatable {
    /// At rest, before the user first speaks.
    case idle
    /// The user has the turn: cooler, shimmering with the mic.
    case listen
    /// Atlas works with nothing found yet: the stars leave as a flock.
    case think
    /// Atlas found memories: each lights as a node and part of the flock streams to it.
    case tools
    /// The reply is starting: the flock flies home into this turn's constellation.
    case converge
    /// Atlas talks: warmer, swelling with its voice, the memories glowing inside.
    case speak
    /// The user cut Atlas off: an instant snap toward listening.
    case interrupt

    /// How long the flock takes to land before Atlas's reply shows as speaking.
    static let convergeSeconds: TimeInterval = 1.2
    /// How long a cut-off holds its snap before settling into listening.
    static let interruptSeconds: TimeInterval = 0.7

    /// The phase the call's state asks for. `heardUser` is false until the user first speaks,
    /// so a fresh call rests; once Atlas has found a memory, thinking shows it.
    static func base(state: VoiceCallState, heardUser: Bool, sourceCount: Int) -> VoiceCallScenePhase {
        switch state {
        case .idle, .connecting, .listening: heardUser ? .listen : .idle
        case .thinking: sourceCount > 0 ? .tools : .think
        case .speaking: .speak
        // A pending approval keeps the calm thinking flock; the overlay asks the question.
        case .awaitingApproval: .think
        case .reconnecting, .ended: .idle
        }
    }

    /// `base` with the timed beats laid over it: a cut-off wins, and a reply's first
    /// `convergeSeconds` are the landing.
    static func resolved(
        base: VoiceCallScenePhase,
        now: TimeInterval,
        convergeUntil: TimeInterval,
        interruptUntil: TimeInterval
    ) -> VoiceCallScenePhase {
        if now < interruptUntil { return .interrupt }
        if base == .speak, now < convergeUntil { return .converge }
        return base
    }
}

/// What the call screen remembers across a turn for the starfield: whether the user has spoken
/// yet, the memories this turn found, and a count of replies starting (each plays the landing).
/// Memories reset when a new turn is sent and only grow while Atlas's run streams, so the last
/// run's leftovers never leak into the next turn.
struct VoiceCallSceneTracker: Equatable {
    private(set) var heardUser = false
    private(set) var sources: [VoiceCallSource] = []
    /// Counts replies starting (thinking to speaking); the starfield lands on each new count.
    private(set) var replyStarts = 0
    /// How many memories the latest reply started with, for VoiceOver's "Found 3 notes".
    private(set) var sourcesAtReply = 0

    mutating func stateChanged(from old: VoiceCallState, to new: VoiceCallState) {
        switch (old, new) {
        case (.idle, .thinking), (.connecting, .thinking), (.listening, .thinking):
            // A new turn went out.
            heardUser = true
            sources = []
            sourcesAtReply = 0
        case (.thinking, .speaking):
            replyStarts += 1
            sourcesAtReply = sources.count
        default:
            break
        }
    }

    /// The user's words so far; the first ones wake the starfield from rest.
    mutating func heard(_ partial: String) {
        if !partial.isEmpty { heardUser = true }
    }

    /// Adds what the running reply has found, keeping earlier finds first.
    mutating func absorb(_ found: [VoiceCallSource], isStreaming: Bool) {
        guard isStreaming, !found.isEmpty else { return }
        let next = VoiceCallSources.merged(sources, found)
        if next != sources { sources = next }
    }

    /// VoiceOver's count of what a reply drew on, or nil when it found nothing.
    var foundAnnouncement: String? {
        switch sourcesAtReply {
        case 0: nil
        case 1: String(localized: "Found 1 note")
        default: String(localized: "Found \(sourcesAtReply) notes")
        }
    }
}
