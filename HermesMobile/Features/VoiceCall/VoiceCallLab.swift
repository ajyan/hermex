#if DEBUG
import SwiftUI

/// Debug-only call screen lab: loops a scripted conversation through the real
/// orb, captions, and status in the call screen's layout, so turn changes can be
/// watched on a simulator without CallKit, a mic, or a server.
/// `xcrun simctl launch <udid> <bundle id> --voice-call-lab`
/// holds one state instead with `--voice-call-lab-phase <phase>`, one of
/// listening, thinking, speaking, interrupted, dropped, or ended.
struct VoiceCallLab: View {
    private enum Phase: String, CaseIterable {
        case listening, thinking, speaking, interrupted, dropped, ended

        var mood: VoiceCallOrbMood {
            switch self {
            case .listening, .interrupted: .listening
            case .thinking: .thinking
            case .speaking: .speaking
            case .dropped, .ended: .quiet
            }
        }

        var word: String {
            switch self {
            case .listening, .interrupted: "Listening"
            case .thinking: "Thinking"
            case .speaking: "Speaking"
            case .dropped: "Call dropped"
            case .ended: "Call ended"
            }
        }

        var hint: String? {
            switch self {
            case .listening, .interrupted: "Tap to send"
            case .thinking: "Tap to cancel"
            case .speaking: "Tap to interrupt"
            case .dropped, .ended: nil
            }
        }

        /// The phase named after `--voice-call-lab-phase`, if any.
        static var held: Phase? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "--voice-call-lab-phase"), flag + 1 < arguments.count else {
                return nil
            }
            return Phase(rawValue: arguments[flag + 1])
        }
    }

    @State private var phase = Phase.listening
    @State private var sent: String?
    @State private var live = ""
    @State private var reply: String?
    @State private var activity: VoiceCallToolActivity?
    @State private var interruptions = 0
    @State private var levels = VoiceCallAudioLevels()
    @State private var orbSlot: CGRect = .zero

    private static let lookup = VoiceCallToolActivity.of(
        ToolCall(name: "terminal", preview: nil, args: ["command": .string("brain crm show jane-doe")])
    )

    private static let turns: [(user: String, atlas: String, tool: VoiceCallToolActivity?)] = [
        (
            "What's the weather like in Brooklyn today and should I bring an umbrella",
            "It's 64 degrees and cloudy in Brooklyn right now. Rain moves in around four this afternoon "
                + "and sticks around through the evening. So yes, bring an umbrella if you'll be out after work. "
                + "Tomorrow clears up and gets warmer, around 70. The weekend looks dry for your long run. "
                + "Saturday morning will be the coolest window, about 58 degrees at seven.",
            VoiceCallToolActivity.of(ToolCall(name: "web_search", preview: nil, args: nil))
        ),
        ("When did I last see Jane", "You had coffee with Jane two weeks ago, on the 17th.", lookup),
        (
            "Explain how Tailscale works in detail",
            "Tailscale creates a mesh network of all your devices using WireGuard encryption. "
                + "Each device gets a stable virtual IP, and it punches direct encrypted tunnels between them, "
                + "no port forwarding needed. Tailscale's own control servers just coordinate who's allowed to "
                + "talk to whom; the actual data goes device to device.",
            nil
        ),
    ]

    var body: some View {
        ZStack {
            Color.hxCanvas.ignoresSafeArea()
            VoiceCallOrb(levels: levels, mood: phase.mood, focus: orbSlot, interruptions: interruptions)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(verbatim: "Atlas")
                        .font(AppFont.headline(weight: .medium))
                        .foregroundStyle(Color.hxTextPrimary)
                    Text(verbatim: phase == .dropped || phase == .ended ? " " : "0:42")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .monospacedDigit()
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                Spacer(minLength: 12)
                VStack(spacing: 16) {
                    ZStack {
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 380, maxHeight: 380)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { orbSlot = $0 }
                        VoiceCallCaptions(
                            sent: sent, live: live, reply: reply,
                            isReplying: phase == .thinking || phase == .speaking
                        )
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .padding(.horizontal, 12)
                    }
                    VoiceCallStatus(word: phase.word, activity: activity, hint: phase.hint)
                }
                Spacer(minLength: 12)
                if phase == .dropped {
                    VoiceCallFailurePanel(reason: "Lost the connection to Atlas.", onReconnect: {}, onBack: {})
                } else {
                    controls
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .preferredColorScheme(.dark)
        .task {
            if let held = Phase.held { hold(held) } else { await run() }
        }
    }

    /// Stand-ins for the call buttons: their size and place, not their behavior.
    private var controls: some View {
        HStack {
            ForEach(["Audio", "Mute", "End"], id: \.self) { title in
                if title != "Audio" { Spacer() }
                Circle()
                    .fill(title == "End" ? Color.hxDanger : Color.hxTextPrimary.opacity(0.1))
                    .frame(width: 60, height: 60)
                    .frame(minWidth: 60)
            }
        }
        .padding(.horizontal, 8)
    }

    /// Sets one still state for a screenshot.
    private func hold(_ held: Phase) {
        let turn = Self.turns[1]
        phase = held
        switch held {
        case .listening:
            live = "When did I last see"
            levels.setMic(0.7)
        case .thinking:
            sent = turn.user
            activity = turn.tool
        case .speaking:
            sent = Self.turns[0].user
            reply = String(Self.turns[0].atlas.prefix(150))
            levels.setVoice(0.7)
        case .interrupted:
            interruptions = 1
            live = "Wait, actually"
            levels.setMic(0.6)
        case .dropped, .ended:
            sent = turn.user
            reply = turn.atlas
        }
    }

    private func run() async {
        while !Task.isCancelled {
            for turn in Self.turns {
                await play(turn.user, turn.atlas, tool: turn.tool)
            }
        }
    }

    private func play(_ user: String, _ atlas: String, tool: VoiceCallToolActivity?) async {
        phase = .listening
        try? await Task.sleep(for: .seconds(1.5))
        for word in Self.prefixes(of: user) {
            // The call drops the last exchange once the user's words are recognized.
            sent = nil
            reply = nil
            live = word
            levels.setMic(Float.random(in: 0.3...0.9))
            try? await Task.sleep(for: .milliseconds(280))
        }
        levels.setMic(0)
        try? await Task.sleep(for: .seconds(1))
        sent = user
        live = ""
        phase = .thinking
        try? await Task.sleep(for: .seconds(1))
        activity = tool
        try? await Task.sleep(for: .seconds(1.5))
        activity = nil
        phase = .speaking
        for words in Self.prefixes(of: atlas) {
            reply = words
            levels.setVoice(Float.random(in: 0.35...0.85))
            try? await Task.sleep(for: .milliseconds(220))
        }
        try? await Task.sleep(for: .seconds(1.5))
        levels.voiceStopped()
    }

    private static func prefixes(of text: String) -> [String] {
        let words = text.split(separator: " ")
        return words.indices.map { words[...$0].joined(separator: " ") }
    }
}
#endif
