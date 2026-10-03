import Foundation

enum VoiceApprovalDecision: Equatable {
    case approve
    case deny
}

/// Maps a spoken answer to an approval decision. Only an exact approve phrase
/// approves; anything else, including no answer (nil), denies.
enum VoiceApprovalMatcher {
    static let approvePhrases: Set<String> = ["approve", "approved", "yes approve", "approve it"]

    static func decide(_ finalTranscript: String?) -> VoiceApprovalDecision {
        guard let finalTranscript else { return .deny }
        let letters = finalTranscript.lowercased().unicodeScalars.map {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " "
        }
        let normalized = String(letters).split(separator: " ").joined(separator: " ")
        return approvePhrases.contains(normalized) ? .approve : .deny
    }
}
