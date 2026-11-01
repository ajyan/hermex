#if DEBUG
import SwiftUI

/// Debug-only call screen lab: loops a scripted conversation through the real
/// starfield, captions, and status in the call screen's layout, so turn changes can be
/// watched on a simulator without CallKit, a mic, or a server.
/// `xcrun simctl launch <udid> <bundle id> --voice-call-lab`
/// holds one state instead with `--voice-call-lab-phase <phase>`, one of
/// idle, listening, thinking, tools, converge, speaking, interrupted, dropped, or ended.
/// `--voice-call-lab-perf` prints the starfield's frame times every 240 frames.
struct VoiceCallLab: View {
    private enum Phase: String, CaseIterable {
        case idle, listening, thinking, tools, converge, speaking, interrupted, dropped, ended

        var scene: VoiceCallScenePhase {
            switch self {
            case .idle, .dropped, .ended: .idle
            case .listening: .listen
            case .thinking: .think
            case .tools: .tools
            case .converge: .converge
            case .speaking: .speak
            case .interrupted: .interrupt
            }
        }

        var word: String {
            switch self {
            case .idle, .listening, .interrupted: "Listening"
            case .thinking, .tools: "Thinking"
            case .converge, .speaking: "Speaking"
            case .dropped: "Call dropped"
            case .ended: "Call ended"
            }
        }

        var hint: String? {
            switch self {
            case .idle: nil
            case .listening, .interrupted: "Tap to send"
            case .thinking, .tools: "Tap to cancel"
            case .converge, .speaking: "Tap to interrupt"
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
    @State private var replyStarts = 0
    @State private var sources: [VoiceCallSource] = []
    @State private var levels = VoiceCallAudioLevels()
    @State private var orbSlot: CGRect = .zero

    /// A sample turn's memories, one of each kind the call colors.
    private static let memories: [VoiceCallSource] = [
        VoiceCallSources.source(path: "journal/2026/10-October/2026-10-22.md"),
        VoiceCallSources.source(path: "wiki/running/taper-plan.md"),
        VoiceCallSources.person(named: "Mitch Anderson"),
        VoiceCallSources.source(path: "email_ingest/summaries/2026-10-06-marathon-fueling.md"),
        VoiceCallSources.source(path: "book_highlights/born-to-run.md"),
    ].compactMap { $0 }

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
            VoiceCallStarfield(
                levels: levels, phase: phase.scene, sources: sources, focus: orbSlot,
                interruptions: interruptions, replyStarts: replyStarts
            )
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
                            isReplying: [.thinking, .tools, .converge, .speaking].contains(phase)
                        )
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .padding(.horizontal, 12)
                    }
                    VoiceCallStatus(
                        word: phase.word, activity: activity,
                        sources: phase == .converge || phase == .speaking ? sources : [], hint: phase.hint
                    )
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
            if let held = Phase.held { await hold(held) } else { await run() }
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

    /// Holds one state for a screenshot. Memory phases first find their memories in a tool
    /// phase, as a call would, so the constellation is laid out; a held cut-off keeps cutting.
    private func hold(_ held: Phase) async {
        let turn = Self.turns[1]
        if [.tools, .converge, .speaking].contains(held) {
            phase = .tools
            sources = Self.memories
        }
        if held == .converge || held == .speaking {
            try? await Task.sleep(for: .seconds(3))
            replyStarts += 1
        }
        phase = held
        switch held {
        case .idle:
            break
        case .listening:
            live = "When did I last see"
            levels.setMic(0.7)
        case .thinking, .tools:
            sent = "What did I write about the taper, and did Mitch say anything about the race"
            activity = held == .thinking ? turn.tool : nil
        case .converge, .speaking:
            sent = "What did I write about the taper, and did Mitch say anything about the race"
            reply = "Your October 22nd entry says the taper is settling in, with sleep as the focus."
            while !Task.isCancelled {
                levels.setVoice(Float.random(in: 0.4...0.9))
                try? await Task.sleep(for: .milliseconds(200))
            }
        case .interrupted:
            live = "Wait, actually"
            while !Task.isCancelled {
                interruptions += 1
                levels.setMic(Float.random(in: 0.4...0.8))
                try? await Task.sleep(for: .seconds(0.6))
            }
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
        sources = []
        phase = .thinking
        try? await Task.sleep(for: .seconds(1))
        activity = tool
        if tool != nil {
            let found = Self.memories.shuffled()
            for count in 1...4 {
                try? await Task.sleep(for: .seconds(0.7))
                sources = Array(found.prefix(count))
                phase = .tools
            }
        }
        try? await Task.sleep(for: .seconds(1))
        activity = nil
        replyStarts += 1
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
