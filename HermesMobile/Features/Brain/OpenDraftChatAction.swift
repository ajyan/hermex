import SwiftUI

/// Starts a new chat with its composer filled in, from a screen pushed on the shell's stack
/// (a Week ahead card's Edit in chat). A reference, like `OpenBrainRouteAction`: the shell keeps
/// one instance and refreshes `handler`, so readers never see a new value.
final class OpenDraftChatAction {
    var handler: ((String) -> Void)?

    /// True when a shell is listening; without one, the button that uses it hides.
    var isAvailable: Bool { handler != nil }

    func callAsFunction(_ draft: String) { handler?(draft) }
}

struct OpenDraftChatKey: EnvironmentKey {
    static let defaultValue = OpenDraftChatAction()
}

extension EnvironmentValues {
    var openDraftChat: OpenDraftChatAction {
        get { self[OpenDraftChatKey.self] }
        set { self[OpenDraftChatKey.self] = newValue }
    }
}

/// Pushes one of the shell's screens (a goal, Meals, Body) from a screen that doesn't own navigation: a Daily
/// Brief card opening the module it is about. A reference, like `OpenDraftChatAction`.
final class OpenShellScreenAction {
    var handler: ((ShellPushDestination) -> Void)?

    /// True when a shell is listening; without one, the button that uses it hides.
    var isAvailable: Bool { handler != nil }

    func callAsFunction(_ destination: ShellPushDestination) { handler?(destination) }
}

struct OpenShellScreenKey: EnvironmentKey {
    static let defaultValue = OpenShellScreenAction()
}

extension EnvironmentValues {
    var openShellScreen: OpenShellScreenAction {
        get { self[OpenShellScreenKey.self] }
        set { self[OpenShellScreenKey.self] = newValue }
    }
}
