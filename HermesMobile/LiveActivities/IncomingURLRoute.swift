import Foundation

/// What an incoming URL (`onOpenURL`, App Intents, notification and Live Activity
/// taps, the share extension) asks the app to open. `ContentView.handleOpenURL`
/// switches on this and owns every side effect; the order of the checks below is
/// the precedence. Main-app only: it names `WebuiPushDestination` and `BotDestination`.
enum IncomingURLRoute: Equatable {
    case webuiPush(WebuiPushDestination)
    case newChatVoice
    /// A daily-brief link; `date` and `kind` are set together when it names a review.
    case dailyBrief(date: String?, kind: String?)
    /// The Goals widget's tap: open Goals on the active webui server.
    case goals
    case newCall
    /// A malformed link with no profile carries nil and falls back to a plain new chat.
    case newChatInProfile(profileName: String?)
    case newChat
    case bot(BotDestination)
    case session(id: String)
    case shareOpen
    case ignore

    init(_ url: URL) {
        if let destination = WebuiPushDestination(url: url) {
            self = .webuiPush(destination)
        } else if HermesDeepLink.isNewChatVoiceURL(url) {
            self = .newChatVoice
        } else if HermesDeepLink.isDailyBriefURL(url) {
            let deck = HermesDeepLink.dailyBriefDeck(from: url)
            self = .dailyBrief(date: deck?.date, kind: deck?.kind)
        } else if HermesDeepLink.isGoalsURL(url) {
            self = .goals
        } else if HermesDeepLink.isNewCallURL(url) {
            self = .newCall
        } else if HermesDeepLink.isNewChatInProfileURL(url) {
            self = .newChatInProfile(profileName: HermesDeepLink.profileName(fromNewChatInProfile: url))
        } else if HermesDeepLink.isNewChatURL(url) {
            self = .newChat
        } else if let destination = HermesDeepLink.botDestination(from: url) {
            self = .bot(destination)
        } else if let sessionID = HermesDeepLink.sessionID(from: url) {
            self = .session(id: sessionID)
        } else if HermesShareDraft.isShareOpenURL(url) {
            self = .shareOpen
        } else {
            self = .ignore
        }
    }
}
