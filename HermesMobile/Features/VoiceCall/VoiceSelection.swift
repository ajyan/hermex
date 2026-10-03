import AVFoundation

/// A synthesis voice reduced to what ranking needs, so the ranking is testable.
struct VoiceCandidate: Equatable {
    enum Quality: Int, Comparable {
        case standard, enhanced, premium
        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let identifier: String
    let language: String
    let quality: Quality
    let isPersonalVoice: Bool
}

enum VoiceSelection {
    /// The user's Personal Voice when authorized, else the highest-quality voice
    /// for `language` (a prefix such as "en"). Nil when nothing matches.
    static func best(from voices: [VoiceCandidate], personalVoiceAuthorized: Bool, language: String) -> VoiceCandidate? {
        let matching = voices.filter { $0.language.lowercased().hasPrefix(language.lowercased()) }
        if personalVoiceAuthorized, let personal = matching.first(where: \.isPersonalVoice) {
            return personal
        }
        return matching
            .filter { !$0.isPersonalVoice }
            .enumerated()
            .max { lhs, rhs in
                lhs.element.quality != rhs.element.quality
                    ? lhs.element.quality < rhs.element.quality
                    : lhs.offset > rhs.offset
            }?
            .element
    }

    /// The installed voice a call speaks with.
    static func installedVoice(language: String = "en") -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let candidates = voices.map { voice in
            VoiceCandidate(
                identifier: voice.identifier,
                language: voice.language,
                quality: voice.quality == .premium ? .premium : voice.quality == .enhanced ? .enhanced : .standard,
                isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice)
            )
        }
        let authorized = AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized
        guard let best = best(from: candidates, personalVoiceAuthorized: authorized, language: language) else { return nil }
        return AVSpeechSynthesisVoice(identifier: best.identifier)
    }
}
