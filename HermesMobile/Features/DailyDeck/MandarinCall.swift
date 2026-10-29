import Foundation

/// The Daily Deck's Mandarin call with Mom or Dad. It runs through the Prep voice-mock path (profile
/// switch, a chat already in a call, the brief as its opening turn), under a `mandarin:<date>` call
/// id, which routes the call's end back to the deck and keeps it out of the Prep grader.
enum MandarinCall {
    static let profile = "mandarin"
    private static let prefix = "mandarin:"

    static func id(date: String) -> String { prefix + date }

    /// The card's date for a Mandarin call id; nil for any other id.
    static func date(fromCallID id: String?) -> String? {
        guard let id, id.hasPrefix(prefix) else { return nil }
        let date = String(id.dropFirst(prefix.count))
        return date.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) == nil ? nil : date
    }

    static func language(forCallID id: String?) -> VoiceCallLanguage {
        date(fromCallID: id) == nil ? .english : .mandarin
    }
}

/// What the shell does when a Mandarin call ends, in order: switch back to the previous profile,
/// keep the call's session and answer waits on the day's card (only when the parent answered, so a
/// call hung up before that leaves the card on Call with nothing to review), then,
/// if the call's chat is still on screen, replace it with a fresh chat and show the deck, where the
/// card asks for the review.
@MainActor
struct MandarinCallFinisher {
    var leave: @MainActor () async -> Void
    var record: @MainActor (_ date: String, _ sessionID: String, _ waitMS: [Int]) -> Void
    /// False once the call's chat is no longer the shell's root (the user went elsewhere).
    var isStillOnCallChat: @MainActor () -> Bool
    var showDeck: @MainActor () -> Void

    func finish(_ end: MockCallEnd, date: String) async {
        await leave()
        if let grade = end.grade { record(date, grade.sessionID, end.waitMS) }
        guard isStillOnCallChat() else { return }
        showDeck()
    }
}
