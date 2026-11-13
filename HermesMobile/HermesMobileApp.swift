import SwiftUI
import SwiftData

struct HermexSceneActions {
    let canCreateNewChat: Bool
    let createNewChat: () -> Void
    let searchSessions: () -> Void
    /// Opens the chat at a 1-based position in the visible list.
    let openChat: (_ position: Int) -> Void
    /// Opens the chat `offset` rows from the selected one, wrapping at the ends.
    let openAdjacentChat: (_ offset: Int) -> Void
    /// True while the drawer covers the chat, so Esc closes it instead of
    /// stopping the chat's response.
    var isDrawerOpen = false
    /// Archives the open chat, with the drawer row's rules (`SessionRowActionPolicy`).
    var canArchiveChat = false
    var archiveChat: () -> Void = {}
}

/// The open chat's keyboard commands, published by `ChatView`.
struct ChatKeyboardActions {
    let isStreaming: Bool
    let isCancellingStream: Bool
    let stopResponse: () -> Void

    var canStopResponse: Bool { isStreaming && !isCancellingStream }

    /// Esc stops only a chat on screen: with the drawer open it closes the drawer.
    func canStopWithEscape(isDrawerOpen: Bool) -> Bool {
        canStopResponse && !isDrawerOpen
    }
}

private struct ChatKeyboardActionsKey: FocusedValueKey {
    typealias Value = ChatKeyboardActions
}

private struct HermexSceneActionsKey: FocusedValueKey {
    typealias Value = HermexSceneActions
}

extension FocusedValues {
    var hermexSceneActions: HermexSceneActions? {
        get { self[HermexSceneActionsKey.self] }
        set { self[HermexSceneActionsKey.self] = newValue }
    }

    var chatKeyboardActions: ChatKeyboardActions? {
        get { self[ChatKeyboardActionsKey.self] }
        set { self[ChatKeyboardActionsKey.self] = newValue }
    }
}

struct HermexCommands: Commands {
    @FocusedValue(\.hermexSceneActions) private var focusedActions
    @FocusedValue(\.chatKeyboardActions) private var focusedChatActions

    /// Every command is off while the app lock is up (#885). Read live, so a stale
    /// menu can't act either.
    @MainActor private var actions: HermexSceneActions? {
        AppLock.shared.isLocked ? nil : focusedActions
    }

    @MainActor private var chatActions: ChatKeyboardActions? {
        AppLock.shared.isLocked ? nil : focusedChatActions
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") {
                actions?.createNewChat()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions?.canCreateNewChat != true)
        }

        CommandGroup(after: .newItem) {
            Button("Search Sessions") {
                actions?.searchSessions()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(actions == nil)

            Divider()

            Button("Stop Response") {
                chatActions?.stopResponse()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(chatActions?.canStopResponse != true)

            Button("Stop Response") {
                chatActions?.stopResponse()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(chatActions?.canStopWithEscape(isDrawerOpen: actions?.isDrawerOpen ?? false) != true)

            Button("Archive Chat") {
                actions?.archiveChat()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(actions?.canArchiveChat != true)
        }

        // View menu, beside Toggle Sidebar. ⌘⇧] and ⌘⇧[ back up ⌃Tab in case
        // iPadOS or a focused text view takes it first. Out-of-range positions
        // do nothing rather than grey out: counting rows here would filter and
        // sort every session on each update.
        CommandGroup(after: .sidebar) {
            Group {
                Button("Next Chat") { actions?.openAdjacentChat(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Chat") { actions?.openAdjacentChat(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("Next Chat") { actions?.openAdjacentChat(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Chat") { actions?.openAdjacentChat(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(1...9, id: \.self) { position in
                    Button("Go to Chat \(position)") { actions?.openChat(position) }
                        .keyboardShortcut(KeyEquivalent(Character(String(position))), modifiers: .command)
                }
            }
            .disabled(actions == nil)
        }
    }
}

@main
struct HermesMobileApp: App {
    // APNs hands device tokens to a UIKit delegate and nowhere else.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @State private var authManager = AuthManager()
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue

    init() {
        // Record installation age even before a server has been configured.
        _ = RatingPromptState.shared
        NetworkPathMonitor.shared.start()
        GoalsWidgetSync.install()
        MealsWidgetSync.install()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--voice-call-lab") {
                VoiceCallLab()
            } else if ProcessInfo.processInfo.arguments.contains("--filing-receipt-lab") {
                FilingReceiptLab()
            } else {
                ContentView(authManager: authManager)
                    .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
                    // Signs in from `HERMEX_DEV_*` launch environment variables
                    // (`scripts/sim-login`); a no-op when they are absent.
                    .task(id: authManager.state) { await DevAutoLogin.run(authManager: authManager) }
                    .overlay(alignment: .topLeading) {
                        // `--hitch-meter`: frame-hitch readout for profiling (#870).
                        if HitchMeter.isEnabled {
                            HitchMeterOverlay()
                        }
                    }
            }
            #else
            ContentView(authManager: authManager)
                .preferredColorScheme(AppTheme.storedValue(appThemeRawValue).colorScheme)
            #endif
        }
        .modelContainer(for: [CachedSession.self, CachedMessage.self, CachedBrainEntry.self])
        .commands {
            HermexCommands()
            SidebarCommands()
        }
    }
}
