import SwiftUI

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
    /// The Brain home, from the drawer.
    case brain
    /// Any screen inside the Brain, pushed from the home or another Brain screen.
    case brainRoute(BrainRoute)
    /// Goals home, from the drawer.
    case goals
    /// One personal goal, by slug.
    case goal(String)
    /// A finished goal's record, by slug.
    case finishedGoal(String)
    /// Every finished goal, by year.
    case finishedGoals
    /// Money: net worth and the market card, from the drawer.
    case money
    /// The in-app feedback inbox, from the drawer.
    case feedback
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

    /// The root is an untouched new chat that carries nothing (no draft, attachments, profile,
    /// project or call) and nothing is pushed over it, so swapping it for a fresh one loses nothing.
    var isOnBareNewChat: Bool {
        guard isOnEmptyNewChat, path.isEmpty, case .newChat(let route) = root else { return false }
        return route.carriesNothing
    }

    /// The root is a voice mock's chat, whose call may still be live.
    var isOnMockChat: Bool {
        guard case .newChat(let route) = root else { return false }
        return route.mockID != nil
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

    /// The Brain home, in place of the Brain screens on top of the path: back to the nearest
    /// home in that run of screens, or, for a page opened from outside the Brain (a chat link,
    /// a Daily Brief card), the run swapped for the home so Back still leads where it began.
    mutating func showBrainHome() {
        var start = path.endIndex
        while start > path.startIndex, path[start - 1].isBrain { start -= 1 }
        if let home = path[start...].lastIndex(of: .brain) {
            path.removeSubrange(path.index(after: home)...)
        } else {
            path.removeSubrange(start...)
            path.append(.brain)
        }
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

/// Keeps the shell's chat streaming while a screen is pushed over it, so a reply
/// still arrives (and alerts) while the user is in the Deck, the Brain or Goals.
/// The shell keeps `isCovered` in step with its push path; a covered chat that
/// disappears hands over its suspension here instead of running it, and the shell
/// runs it when that chat goes away for good (a new root, or the shell closing).
@MainActor
final class CoveredChatStream {
    /// A screen is pushed over the chat root.
    var isCovered = false
    private var suspendHeldChat: (@MainActor () -> Void)?

    /// Called by a covered chat as it disappears: `suspend` runs if it never comes back.
    func hold(suspend: @escaping @MainActor () -> Void) {
        suspendHeldChat = suspend
    }

    /// Called by the chat when it is back on screen.
    func release() {
        suspendHeldChat = nil
    }

    /// The held chat is gone for good: suspend its stream now.
    func suspendHeld() {
        let suspend = suspendHeldChat
        suspendHeldChat = nil
        suspend?()
    }
}

private struct CoveredChatStreamKey: EnvironmentKey {
    static let defaultValue: CoveredChatStream? = nil
}

extension EnvironmentValues {
    /// The shell's covered-chat holder; nil outside the shell, where a chat that
    /// disappears always suspends its stream.
    var coveredChatStream: CoveredChatStream? {
        get { self[CoveredChatStreamKey.self] }
        set { self[CoveredChatStreamKey.self] = newValue }
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

// MARK: - Zoom transitions

extension ShellPushDestination {
    /// The Brain home or any screen inside the Brain.
    var isBrain: Bool {
        switch self {
        case .brain, .brainRoute: true
        case .projects, .project, .tasks, .kanban, .dailyDeck, .goals, .goal, .finishedGoal, .finishedGoals, .money,
             .feedback, .settings: false
        }
    }

    /// Whether this screen opens with a zoom out of the card or chip that pushed it. Screens
    /// the drawer opens slide in as usual; a zoom screen pushed with no source on screen
    /// (an inline link) falls back to the system's zoom from the middle of the screen.
    var zoomsFromSource: Bool {
        switch self {
        case .goal, .finishedGoal, .brainRoute: true
        case .projects, .project, .tasks, .kanban, .dailyDeck, .brain, .goals, .finishedGoals, .money, .feedback,
             .settings: false
        }
    }
}

private struct ShellZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// The namespace the shell's stack matches zoom sources in; nil outside the stack.
    var shellZoomNamespace: Namespace.ID? {
        get { self[ShellZoomNamespaceKey.self] }
        set { self[ShellZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks this card or chip as where `destination` opens from: pushing it zooms out of
    /// this view, and going back shrinks the screen into it. A card passes its `cornerRadius`;
    /// a chip passes none, because the zoom's clip takes the radius literally (no clamping to a
    /// capsule) and an oversized one clips the chip away entirely. Does nothing outside the
    /// shell's stack.
    func zoomSource(for destination: ShellPushDestination, cornerRadius: CGFloat? = nil) -> some View {
        modifier(ZoomSourceModifier(destination: destination, cornerRadius: cornerRadius))
    }

    /// Opens a pushed screen with a zoom out of its source, for destinations that have one.
    func zoomDestination(_ destination: ShellPushDestination, in namespace: Namespace.ID) -> some View {
        modifier(ZoomDestinationModifier(destination: destination, namespace: namespace))
    }
}

private struct ZoomSourceModifier: ViewModifier {
    let destination: ShellPushDestination
    let cornerRadius: CGFloat?
    @Environment(\.shellZoomNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace, let cornerRadius {
            content.matchedTransitionSource(id: destination, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else if let namespace {
            content.matchedTransitionSource(id: destination, in: namespace)
        } else {
            content
        }
    }
}

private struct ZoomDestinationModifier: ViewModifier {
    let destination: ShellPushDestination
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if destination.zoomsFromSource {
            content.navigationTransition(.zoom(sourceID: destination, in: namespace))
        } else {
            content
        }
    }
}
