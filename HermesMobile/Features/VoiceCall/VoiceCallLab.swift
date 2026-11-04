#if DEBUG
import SwiftUI

/// Debug-only call screen lab: loops a whole scripted call through the real starfield,
/// captions, and status in the call screen's layout, so every state can be watched on a
/// simulator without CallKit, a mic, or a server: rest, a turn with no memories, a turn that
/// finds three, a follow-up that reuses one and is cut off, muted, reconnecting, dropped, ended.
/// The state's name shows in the corner.
/// `xcrun simctl launch <udid> <bundle id> --voice-call-lab`
/// holds one state instead with `--voice-call-lab-phase <phase>`, one of idle, listening,
/// thinking, tools, converge, speaking, interrupted, muted, reconnecting, dropped, or ended.
/// `--voice-call-lab-perf` prints the starfield's frame times every 240 frames.
struct VoiceCallLab: View {
    private enum Phase: String, CaseIterable {
        case idle, listening, thinking, tools, converge, speaking, interrupted, muted, reconnecting, dropped, ended

        var scene: VoiceCallScenePhase {
            switch self {
            case .idle, .reconnecting, .dropped, .ended: .idle
            case .listening, .muted: .listen
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
            case .muted: "Muted"
            case .reconnecting: "Reconnecting"
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
            case .muted, .reconnecting, .dropped, .ended: nil
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
    @State private var heard = ""
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
                interruptions: interruptions, replyStarts: replyStarts,
                dimmed: phase == .muted || phase == .reconnecting
            )
            .ignoresSafeArea()
            Text(verbatim: "LAB · \(phase.rawValue)")
                .font(AppFont.caption2(weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .monospaced()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 20)
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
                    }
                    VoiceCallStatus(
                        word: phase.word, activity: activity,
                        sources: [.tools, .converge, .speaking].contains(phase) ? sources : [], hint: phase.hint
                    )
                    VoiceCallCaptions(
                        sent: sent, live: live, reply: reply, heard: heard,
                        isSpeaking: phase == .speaking,
                        isReplying: [.thinking, .tools, .converge, .speaking].contains(phase)
                    )
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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

    /// The call buttons as the call draws them, without their actions.
    private var controls: some View {
        HStack(alignment: .top) {
            CallControl(title: "Audio") { Image(systemName: "airplayaudio") }
            Spacer()
            CallControl(title: phase == .muted ? "Unmute" : "Mute", isOn: phase == .muted) {
                Image(systemName: phase == .muted ? "mic.slash.fill" : "mic.fill")
            }
            Spacer()
            CallControl(title: "End", tint: .hxDanger) { Image(systemName: "phone.down.fill") }
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
            let said = "Your October 22nd entry says the taper is settling in, with sleep as the focus."
            reply = said
            while !Task.isCancelled {
                await speak(said)
                try? await Task.sleep(for: .seconds(1))
            }
        case .interrupted:
            live = "Wait, actually"
            while !Task.isCancelled {
                interruptions += 1
                levels.setMic(Float.random(in: 0.4...0.8))
                try? await Task.sleep(for: .seconds(0.6))
            }
        case .muted, .reconnecting, .dropped, .ended:
            sent = turn.user
            reply = turn.atlas
        }
    }

    /// One whole call, over and over: rest, a turn with no memories, a turn that finds three,
    /// a follow-up that reuses the journal day (it lights where it was) and is cut off, then
    /// muted, reconnecting, dropped, and ended.
    private func run() async {
        let journal = Self.memories[0], wiki = Self.memories[1], mitch = Self.memories[2], article = Self.memories[3]
        while !Task.isCancelled {
            sent = nil
            reply = nil
            live = ""
            sources = []
            phase = .idle
            try? await Task.sleep(for: .seconds(2.5))
            let weather = Self.turns[0]
            await play(weather.user, weather.atlas, tool: weather.tool, found: [])
            await play(
                "What did I write about the taper, and did Mitch say anything about the race",
                "Your October 22nd entry says the taper is settling in, with sleep as the focus. "
                    + "Mitch told you to keep Thursday easy and save your legs for the race.",
                tool: Self.lookup, found: [journal, wiki, mitch]
            )
            await play(
                "And what should I eat the night before",
                "Your journal from the 22nd says pasta worked well before the half. The fueling article "
                    + "suggests rice or potatoes, lightly salted, and nothing new the night before.",
                tool: Self.lookup, found: [journal, article], cutOffAfter: 12
            )
            phase = .interrupted
            interruptions += 1
            live = "Wait, actually"
            try? await Task.sleep(for: .seconds(VoiceCallScenePhase.interruptSeconds))
            phase = .listening
            try? await Task.sleep(for: .seconds(1.5))
            live = ""
            phase = .muted
            try? await Task.sleep(for: .seconds(3))
            phase = .reconnecting
            try? await Task.sleep(for: .seconds(3))
            phase = .dropped
            try? await Task.sleep(for: .seconds(3.5))
            phase = .ended
            try? await Task.sleep(for: .seconds(2.5))
        }
    }

    /// One turn: the user's words, thinking (finding `found` one at a time under `tool`), and
    /// Atlas's reply, cut off after `cutOffAfter` words if given.
    private func play(
        _ user: String, _ atlas: String, tool: VoiceCallToolActivity?, found: [VoiceCallSource], cutOffAfter: Int? = nil
    ) async {
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
        try? await Task.sleep(for: .seconds(1.5))
        for count in found.indices {
            sources = Array(found.prefix(count + 1))
            phase = .tools
            try? await Task.sleep(for: .seconds(0.7))
        }
        try? await Task.sleep(for: .seconds(1))
        activity = nil
        replyStarts += 1
        phase = .speaking
        reply = atlas
        await speak(atlas, stopAfter: cutOffAfter)
        if cutOffAfter == nil {
            try? await Task.sleep(for: .seconds(1.5))
        }
        levels.voiceStopped()
    }

    /// Says `text` a word at a time like the server voice: a loud attack and a dip per word,
    /// longer pauses after a sentence, with `heard` following along.
    private func speak(_ text: String, stopAfter limit: Int? = nil) async {
        heard = ""
        for words in Self.prefixes(of: text).prefix(limit ?? .max) {
            levels.setVoice(Float.random(in: 0.55...0.9))
            try? await Task.sleep(for: .milliseconds(140))
            levels.setVoice(Float.random(in: 0.08...0.2))
            heard = words
            let pause = words.last.map { ".,?!".contains($0) } == true ? 260 : 90
            try? await Task.sleep(for: .milliseconds(pause))
        }
        levels.setVoice(0)
    }

    private static func prefixes(of text: String) -> [String] {
        let words = text.split(separator: " ")
        return words.indices.map { words[...$0].joined(separator: " ") }
    }
}
#endif
