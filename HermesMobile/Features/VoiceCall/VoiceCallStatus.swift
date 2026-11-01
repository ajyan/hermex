import AVKit
import SwiftUI

/// What Atlas is doing in a tool call, in plain words for the call screen. Never the raw tool
/// name: "terminal" or "web_search" means nothing mid-conversation.
struct VoiceCallToolActivity: Equatable {
    /// The call's kind, which picks the chip's paper (`HermexPaper.forTool`), as in chat.
    let kind: ToolCallSummaryFormatter.Kind
    let label: String
    let symbol: String

    static func of(_ call: ToolCall) -> VoiceCallToolActivity {
        let kind = ToolCallSummaryFormatter.kind(forToolNamed: call.name)
        let command = kind == .shell ? shellCommand(in: call.args) : nil
        if let command, let person = personLookedUp(in: command) {
            return VoiceCallToolActivity(kind: kind, label: String(localized: "Looking up \(person)"), symbol: "person")
        }
        switch kind {
        case .read, .list, .search:
            return .checkingNotes(kind)
        case .shell where command.map(isNotesCommand) == true:
            return .checkingNotes(kind)
        case .write:
            return VoiceCallToolActivity(kind: kind, label: String(localized: "Saving to your notes"), symbol: "square.and.pencil")
        case .web:
            return VoiceCallToolActivity(kind: kind, label: String(localized: "Searching the web"), symbol: "globe")
        case .memory:
            return VoiceCallToolActivity(kind: kind, label: String(localized: "Remembering"), symbol: "brain")
        case .shell, .skill, .delegate, .unknown:
            return VoiceCallToolActivity(kind: kind, label: String(localized: "Working"), symbol: "gearshape")
        }
    }

    private static func checkingNotes(_ kind: ToolCallSummaryFormatter.Kind) -> VoiceCallToolActivity {
        VoiceCallToolActivity(kind: kind, label: String(localized: "Checking your notes"), symbol: "doc.text.magnifyingglass")
    }

    /// The shell command a terminal call ran, unwrapped from its `bash -lc` shell.
    static func shellCommand(in args: [String: JSONValue]?) -> String? {
        for key in ["command", "cmd"] {
            if case .string(let command)? = args?[key], !command.isEmpty {
                return ToolCallSummaryFormatter.unwrappingShellWrapper(command)
            }
        }
        return nil
    }

    /// The vault's CLI: `brain …`, or `crm …` run directly.
    private static func isNotesCommand(_ command: String) -> Bool {
        command.contains(/(^|[\s;&|(\/])(brain|crm)\s/)
    }

    /// The person a `crm show <name>` reads, as a name ("Jane Doe" from `jane-doe`).
    static func personLookedUp(in command: String) -> String? {
        let pattern = /\bcrm\s+show\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))/
        guard let match = command.firstMatch(of: pattern) else { return nil }
        guard let raw = match.output.1 ?? match.output.2 ?? match.output.3 else { return nil }
        var name = String(raw)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasSuffix(".md") { name = String(name.dropLast(3)) }
        let words = name.split { $0 == "-" || $0 == "_" || $0 == " " }
        guard !words.isEmpty else { return nil }
        // A slug reads as a name; a name typed with capitals keeps them.
        let isSlug = name == name.lowercased()
        return words.map { isSlug ? $0.prefix(1).uppercased() + $0.dropFirst() : String($0) }.joined(separator: " ")
    }
}

/// Under the cloud: whose turn it is in large type, what Atlas is doing in a tool chip (or, while
/// it answers, the memories it drew on), and what a tap on the cloud does. The chip's and hint's
/// lines are always reserved, so the cloud never shifts.
struct VoiceCallStatus: View {
    let word: String
    let activity: VoiceCallToolActivity?
    /// The turn's memories, each in its paper; shown when no tool is running.
    var sources: [VoiceCallSource] = []
    let hint: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Text(verbatim: word)
                .font(AppFont.display(style: .title2, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)

            ZStack {
                chip
                    .opacity(activity == nil ? 0 : 1)
                    .accessibilityHidden(activity == nil)
                if activity == nil, !sources.isEmpty {
                    sourceChips
                }
            }

            Text(verbatim: hint ?? " ")
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(Color.hxTextSecondary)
                .opacity(hint == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .multilineTextAlignment(.center)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .animation(HXMotion.quickState(reduceMotion: reduceMotion), value: activity)
        .animation(HXMotion.quickState(reduceMotion: reduceMotion), value: hint)
        .animation(HXMotion.quickState(reduceMotion: reduceMotion), value: sources)
    }

    /// One line of memory chips: as many as fit, the rest behind `+N`.
    private var sourceChips: some View {
        ViewThatFits(in: .horizontal) {
            sourceRow(3)
            sourceRow(2)
            sourceRow(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Sources"))
    }

    /// The first `shown` memories; a lone chip may truncate instead of overflowing.
    private func sourceRow(_ shown: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(sources.prefix(shown)) { source in
                HXChip(paper: source.kind.paper, symbol: source.kind.symbol, label: source.label)
                    .fixedSize(horizontal: shown > 1, vertical: false)
            }
            if sources.count > shown {
                HXChip(paper: .tool, label: "+\(sources.count - shown)")
                    .fixedSize()
                    .accessibilityLabel(String(localized: "\(sources.count - shown) more"))
            }
        }
    }

    private var chip: some View {
        let shown = activity ?? VoiceCallToolActivity(kind: .unknown, label: " ", symbol: "gearshape")
        return HXChip(paper: .forTool(shown.kind), symbol: shown.symbol, label: shown.label) {
            Image(systemName: "ellipsis")
                .font(AppFont.caption2(weight: .bold))
                .accessibilityHidden(true)
        }
    }
}

/// Replaces the call controls when the call dropped: why, in one line, and the two ways on.
struct VoiceCallFailurePanel: View {
    let reason: String
    let onReconnect: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(verbatim: reason)
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Side by side, or stacked with Reconnect first when large text won't fit both.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    back
                    reconnect
                }
                VStack(spacing: 10) {
                    reconnect
                    back
                }
            }
            .font(AppFont.body(weight: .semibold))
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(.horizontal, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var back: some View {
        Button(action: onBack) {
            Text("Back to chat").lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(Color.hxTextPrimary)
    }

    private var reconnect: some View {
        Button(action: onReconnect) {
            Text("Reconnect").lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
    }
}

/// One round call button with its caption underneath, Phone-app style.
struct CallControl<Content: View>: View {
    let title: LocalizedStringKey
    var isOn = false
    var tint: Color?
    @ViewBuilder let content: Content

    /// The title is for VoiceOver; the round buttons speak for themselves on screen.
    var body: some View {
        button
            .accessibilityLabel(title)
            .frame(minWidth: 60)
    }

    /// Solid when it carries meaning (End, or a control that's on), glass otherwise.
    @ViewBuilder
    private var button: some View {
        let face = content
            .font(AppFont.title3())
            .foregroundStyle(isOn ? Color.black : Color.white)
            .frame(width: 60, height: 60)
        if let solid = tint ?? (isOn ? Color.white : nil) {
            face.background(solid, in: Circle())
        } else {
            face.adaptiveGlass(fallbackMaterial: .ultraThinMaterial, in: Circle())
        }
    }
}

/// The system audio route menu (speaker, receiver, AirPods) for the call.
struct CallAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
