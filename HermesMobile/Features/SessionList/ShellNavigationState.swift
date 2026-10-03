import Foundation

/// The chat the shell's main stack is rooted on.
enum ShellRoot: Hashable {
    case newChat(PendingNewChatRoute)
    case session(SessionSummary)
}

/// Screens pushed over the chat root from the drawer or a route.
enum ShellPushDestination: Hashable {
    case projects
    case project(String)
    case tasks
    case kanban
    case settings(SettingsScrollAnchor?)
}

/// Navigation for the chat-first shell: one chat root, a push path over it, and
/// whether the drawer is open. Every launch and server switch starts on a new chat.
struct ShellNavigationState: Equatable {
    private(set) var root: ShellRoot = .newChat(PendingNewChatRoute())
    var path: [ShellPushDestination] = []
    var isDrawerOpen = false
    private(set) var rootRevision = 0
    /// The session a new-chat root created, once the server returns it. The root
    /// stays `.newChat` so its view (and any live stream) is never rebuilt.
    private var newChatSessionID: String?
    private var deepLinkedSessionLoadID: String?

    var selectedSessionID: String? {
        switch root {
        case .session(let session): Self.normalized(session.sessionId)
        case .newChat: newChatSessionID
        }
    }

    var isCreatingNewChat: Bool {
        guard case .newChat = root else { return false }
        return newChatSessionID == nil
    }

    mutating func select(_ session: SessionSummary) {
        setRoot(.session(session))
    }

    mutating func select(_ route: PendingNewChatRoute) {
        setRoot(.newChat(route))
    }

    mutating func push(_ destination: ShellPushDestination) {
        path.append(destination)
        isDrawerOpen = false
    }

    /// Replaces whatever is pushed with `destination` alone.
    mutating func showOnly(_ destination: ShellPushDestination) {
        path = [destination]
        isDrawerOpen = false
    }

    mutating func remember(_ session: SessionSummary) {
        guard case .newChat = root, let sessionID = Self.normalized(session.sessionId) else { return }
        newChatSessionID = sessionID
    }

    /// A removed (deleted or archived) current chat leaves the user on a fresh new chat.
    mutating func remove(sessionID: String?) {
        guard let sessionID = Self.normalized(sessionID), sessionID == selectedSessionID else { return }
        select(PendingNewChatRoute())
    }

    mutating func beginDeepLinkedSessionLoad(id: String?) -> String? {
        guard deepLinkedSessionLoadID == nil, let sessionID = Self.normalized(id) else { return nil }
        deepLinkedSessionLoadID = sessionID
        return sessionID
    }

    mutating func finishDeepLinkedSessionLoad(id: String?) {
        guard Self.normalized(id) == deepLinkedSessionLoadID else { return }
        deepLinkedSessionLoadID = nil
    }

    /// Opening the drawer is when its rows must catch up with what happened in the chat.
    static func drawerOpenRequestsRefresh(wasOpen: Bool, isOpen: Bool) -> Bool {
        !wasOpen && isOpen
    }

    private mutating func setRoot(_ newRoot: ShellRoot) {
        rootRevision += 1
        newChatSessionID = nil
        root = newRoot
        path = []
        isDrawerOpen = false
    }

    private static func normalized(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
