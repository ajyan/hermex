#if DEBUG
import SwiftUI

/// Debug-only call screen lab: loops a scripted conversation through the real
/// orb and captions in the call screen's layout, so turn changes can be
/// watched on a simulator without CallKit, a mic, or a server.
/// `xcrun simctl launch <udid> <bundle id> --voice-call-lab`
struct VoiceCallLab: View {
    private enum Phase: String {
        case listening = "Listening"
        case thinking = "Thinking"
        case speaking = "Speaking"
    }

    @State private var phase = Phase.listening
    @State private var sent: String?
    @State private var live = ""
    @State private var reply: String?
    @State private var levels = VoiceCallAudioLevels()
    @State private var orbSlot: CGRect = .zero

    private static let turns: [(user: String, atlas: String)] = [
        (
            "What's the weather like in Brooklyn today and should I bring an umbrella",
            "It's 64 degrees and cloudy in Brooklyn right now. Rain moves in around four this afternoon "
                + "and sticks around through the evening. So yes, bring an umbrella if you'll be out after work. "
                + "Tomorrow clears up and gets warmer, around 70. The weekend looks dry for your long run. "
                + "Saturday morning will be the coolest window, about 58 degrees at seven."
        ),
        ("What time is it", "It's 2:37 in the afternoon."),
        (
            "Explain how Tailscale works in detail",
            "Tailscale creates a mesh network of all your devices using WireGuard encryption. "
                + "Each device gets a stable virtual IP, and it punches direct encrypted tunnels between them, "
                + "no port forwarding needed. Tailscale's own control servers just coordinate who's allowed to "
                + "talk to whom; the actual data goes device to device. That's why your Mac mini is reachable "
                + "from your phone even when both are behind different NATs. When a direct path can't be found, "
                + "traffic falls back to an encrypted relay called DERP."
        ),
    ]

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.024, blue: 0.04).ignoresSafeArea()
            VoiceCallOrb(levels: levels, mood: mood, focus: orbSlot).ignoresSafeArea()
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text(verbatim: "Atlas").font(.headline.weight(.medium))
                    Text(verbatim: phase.rawValue).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 380, maxHeight: 380)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { orbSlot = $0 }
                    .overlay {
                        VoiceCallCaptions(sent: sent, live: live, reply: reply, isReplying: phase != .listening)
                            .padding(.horizontal, 12)
                    }
                Text(verbatim: " ").font(.footnote.weight(.medium)).padding(.top, 12)
                Spacer(minLength: 12)
                HStack {
                    ForEach(["Audio", "Mute", "End"], id: \.self) { title in
                        if title != "Audio" { Spacer() }
                        Circle().fill(title == "End" ? Color.red : Color.white.opacity(0.1))
                            .frame(width: 60, height: 60)
                            .frame(minWidth: 60)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .preferredColorScheme(.dark)
        .task { await run() }
    }

    private var mood: VoiceCallOrbMood {
        switch phase {
        case .listening: .listening
        case .thinking: .thinking
        case .speaking: .speaking
        }
    }

    private func run() async {
        while !Task.isCancelled {
            for turn in Self.turns {
                await play(turn.user, turn.atlas)
            }
        }
    }

    private func play(_ user: String, _ atlas: String) async {
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
        try? await Task.sleep(for: .seconds(2))
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
