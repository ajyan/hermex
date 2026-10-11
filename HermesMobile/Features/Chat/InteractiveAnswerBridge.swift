import SwiftUI

/// A validated message from an interactive answer's `atlas` bridge. Tools are
/// agent-written code, so every message is checked here before the app acts:
/// anything malformed, out of bounds, or not https decodes to nil and is ignored.
enum InteractiveAnswerBridgeMessage: Equatable {
    case ask(String)
    case open(URL)
    case resize(CGFloat)
    case scriptError(String)
    case loadError

    static let maxAskLength = 4000
    private static let maxHeight: Double = 20_000
    private static let maxErrorLength = 500

    /// Decodes a `WKScriptMessage.body`.
    static func decode(_ body: Any) -> InteractiveAnswerBridgeMessage? {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        switch type {
        case "ask":
            guard let raw = dict["text"] as? String else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= maxAskLength else { return nil }
            return .ask(text)
        case "open":
            guard let raw = dict["url"] as? String,
                  let url = URL(string: raw),
                  url.scheme?.lowercased() == "https",
                  url.host()?.isEmpty == false
            else { return nil }
            return .open(url)
        case "resize":
            guard let height = (dict["height"] as? NSNumber)?.doubleValue,
                  height.isFinite, height >= 0, height <= maxHeight
            else { return nil }
            return .resize(CGFloat(height))
        case "scriptError":
            let message = (dict["message"] as? String) ?? ""
            return .scriptError(String(message.prefix(maxErrorLength)))
        case "loadError":
            return .loadError
        default:
            return nil
        }
    }
}

/// How an "Ask Atlas" question lands in the composer: it fills an empty draft,
/// or follows a draft already started as a new paragraph. It never sends.
enum InteractiveAnswerDraftMerge {
    static func merged(draft: String, ask: String) -> String {
        let existing = draft.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return existing.isEmpty ? ask : existing + "\n\n" + ask
    }
}

/// The screen's handler for "Ask Atlas" taps in interactive answers. A
/// reference, like `ChatDisclosureToggleAction`, so rebuilding the handler on
/// every pass does not invalidate the cards that read it.
final class InteractiveAnswerAskAction {
    var handler: (String) -> Void = { _ in }

    func callAsFunction(_ text: String) { handler(text) }
}

private struct InteractiveAnswerAskKey: EnvironmentKey {
    static let defaultValue = InteractiveAnswerAskAction()
}

private struct InteractiveAnswersEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InteractiveAnswerUnclosedBodyKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var interactiveAnswerAsk: InteractiveAnswerAskAction {
        get { self[InteractiveAnswerAskKey.self] }
        set { self[InteractiveAnswerAskKey.self] = newValue }
    }

    /// Whether `atlas-ui` blocks render as cards. Only screens with a composer
    /// (`interactiveAnswerAsk(perform:)`) turn it on; elsewhere they stay code.
    var interactiveAnswersEnabled: Bool {
        get { self[InteractiveAnswersEnabledKey.self] }
        set { self[InteractiveAnswersEnabledKey.self] = newValue }
    }

    /// The body of an `atlas-ui` block the reply never closed, set by `MarkdownRenderer`.
    var interactiveAnswerUnclosedBody: String? {
        get { self[InteractiveAnswerUnclosedBodyKey.self] }
        set { self[InteractiveAnswerUnclosedBodyKey.self] = newValue }
    }
}

extension View {
    /// Renders interactive answers below this view as cards and routes their
    /// "Ask Atlas" taps into `handler`, which should fill the composer and never send.
    func interactiveAnswerAsk(perform handler: @escaping (String) -> Void) -> some View {
        modifier(InteractiveAnswerAskModifier(handler: handler))
    }
}

private struct InteractiveAnswerAskModifier: ViewModifier {
    let handler: (String) -> Void
    @State private var action = InteractiveAnswerAskAction()

    func body(content: Content) -> some View {
        action.handler = handler
        return content
            .environment(\.interactiveAnswerAsk, action)
            .environment(\.interactiveAnswersEnabled, true)
    }
}
