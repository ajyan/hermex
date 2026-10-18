import AVFoundation
import Speech
import SwiftUI

/// The Mandarin practice card's body: yesterday's feedback, the situation, three phrases to hear
/// and say, and the question to answer out loud. The answer field below it is the deck's own.
struct DeckMandarinCard: View {
    let card: DeckCard
    let palette: DeckPalette

    @State private var speaker = MandarinSpeaker()
    @State private var revealed: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let yesterday = card.yesterday {
                feedback(yesterday).padding(.bottom, 22)
            }
            if let situation = card.title {
                Text(verbatim: situation)
                    .font(AppFont.display(style: .title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 30)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(card.phrases, id: \.self) { phrase in
                    row(hanzi: phrase.hanzi, pinyin: phrase.pinyin, english: phrase.en, isReview: phrase.review)
                }
            }
            .padding(.top, 18)
            if let question = card.question {
                Text(verbatim: "Your turn")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, 26)
                row(hanzi: question, pinyin: card.questionPinyin, english: card.questionEn, isReview: false, isQuestion: true)
                    .padding(.top, 6)
            }
        }
        .onDisappear { speaker.stop() }
    }

    private func feedback(_ yesterday: DeckMandarinFeedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Yesterday")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
            if let said = yesterday.said {
                Text(verbatim: said)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: "More natural")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.top, 4)
            row(hanzi: yesterday.natural, pinyin: yesterday.naturalPinyin, english: nil, isReview: false)
            ForEach(Array(yesterday.notes.enumerated()), id: \.offset) { _, note in
                Label { Text(verbatim: note) } icon: { Image(systemName: "lightbulb") }
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
    }

    /// One line of Mandarin: pinyin over characters, ▶ to hear it, English on tap.
    private func row(hanzi: String, pinyin: String?, english: String?, isReview: Bool, isQuestion: Bool = false) -> some View {
        let shown = revealed.contains(hanzi)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let pinyin {
                    Text(verbatim: pinyin)
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(palette.ink)
                }
                Text(verbatim: hanzi)
                    .font(AppFont.display(style: isQuestion ? .title2 : .title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let english, shown {
                    Text(verbatim: english)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
                }
                if isReview {
                    HXChip(paper: palette.colors, symbol: "arrow.counterclockwise", label: "Review")
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard english != nil else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    if shown { revealed.remove(hanzi) } else { revealed.insert(hanzi) }
                }
            }
            Button { speaker.toggle(hanzi) } label: {
                Image(systemName: speaker.speaking == hanzi ? "stop.fill" : "play.fill")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(palette.onInk)
                    .frame(width: 44, height: 44)
                    .background(palette.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [english, hanzi].compactMap { $0 }.joined(separator: ". ")))
        .accessibilityAction(named: Text(verbatim: speaker.speaking == hanzi ? "Stop" : "Play")) { speaker.toggle(hanzi) }
    }
}

/// Reads Mandarin aloud with the system's zh-CN voice, a little slower than normal for practice.
/// Tapping the playing line again stops it; tapping another switches to it.
@MainActor
@Observable
final class MandarinSpeaker {
    private(set) var speaking: String?

    @ObservationIgnored private let synthesizer: ChatSpeechSynthesizing
    @ObservationIgnored private var proxy: MandarinSpeakerDelegate?
    @ObservationIgnored private var current: ObjectIdentifier?

    init(synthesizer: ChatSpeechSynthesizing = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        let proxy = MandarinSpeakerDelegate { [weak self] id in self?.utteranceEnded(id) }
        self.proxy = proxy
        synthesizer.delegate = proxy
    }

    /// An utterance finished on its own; only the one playing now clears the ▶ state.
    func utteranceEnded(_ id: ObjectIdentifier) {
        guard id == current else { return }
        current = nil
        speaking = nil
    }

    func toggle(_ text: String) {
        let wasPlaying = speaking == text
        stop()
        guard !wasPlaying else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: MandarinDictation.locale.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        speaking = text
        current = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stop() {
        guard speaking != nil else { return }
        speaking = nil
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private final class MandarinSpeakerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onDone: @MainActor (ObjectIdentifier) -> Void

    init(onDone: @escaping @MainActor (ObjectIdentifier) -> Void) { self.onDone = onDone }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [onDone] in onDone(id) }
    }
}

/// The Mandarin card's dictation: on-device zh-CN only, so the answer arrives as characters.
enum MandarinDictation {
    static let locale = Locale(identifier: "zh-CN")
}
