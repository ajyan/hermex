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
    case dailyDeck
    case brain
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
    /// True once the new-chat root has a first turn (typed or spoken on a call).
    private var newChatHasStarted = false
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

    /// The root is a new chat nothing has been said in yet, so starting
    /// another new chat would land right back here.
    var isOnEmptyNewChat: Bool {
        guard case .newChat = root else { return false }
        return !newChatHasStarted
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

    mutating func markNewChatStarted() {
        guard case .newChat = root else { return }
        newChatHasStarted = true
    }

    mutating func remember(_ session: SessionSummary) {
        guard case .newChat = root, let sessionID = Self.normalized(session.sessionId) else { return }
        newChatSessionID = sessionID
    }

    /// A removed (deleted or archived) current chat leaves the user on a fresh new
    /// chat. The drawer stays as it was, since that is usually where the removal happened.
    mutating func remove(sessionID: String?) {
        guard let sessionID = Self.normalized(sessionID), sessionID == selectedSessionID else { return }
        let wasDrawerOpen = isDrawerOpen
        select(PendingNewChatRoute())
        isDrawerOpen = wasDrawerOpen
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
        newChatHasStarted = false
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

/// Resolves the hardware-keyboard chat shortcuts (⌘1–⌘9, Next and Previous
/// Chat) against the ordinary chat rows in on-screen order.
enum ChatShortcutNavigation {
    /// The chat at a 1-based list position, or nil when the list is shorter.
    static func chat(atPosition position: Int, in chats: [SessionSummary]) -> SessionSummary? {
        chats.indices.contains(position - 1) ? chats[position - 1] : nil
    }

    /// The chat `offset` rows from the selection, wrapping at the ends. Without
    /// a selection in the list, next starts at the first chat and previous at
    /// the last.
    static func adjacentChat(
        offset: Int,
        from selectedSessionID: String?,
        in chats: [SessionSummary]
    ) -> SessionSummary? {
        guard !chats.isEmpty else { return nil }
        guard let selectedSessionID,
              let selectedIndex = chats.firstIndex(where: { $0.sessionId == selectedSessionID })
        else {
            return offset > 0 ? chats.first : chats.last
        }

        let count = chats.count
        return chats[((selectedIndex + offset) % count + count) % count]
    }
}

/// Device-local last-seen server timestamps for session rows. The server URL
/// scopes equal session IDs on different configured servers independently.
struct SessionUnreadStore {
    var defaults: UserDefaults = .standard

    private func key(for server: URL) -> String {
        "session-inbox-seen." + server.absoluteString
    }

    func load(for server: URL) -> [String: Double] {
        defaults.dictionary(forKey: key(for: server)) as? [String: Double] ?? [:]
    }

    func save(_ seen: [String: Double], for server: URL) {
        defaults.set(seen, forKey: key(for: server))
    }

    func remove(for server: URL) {
        defaults.removeObject(forKey: key(for: server))
    }
}
