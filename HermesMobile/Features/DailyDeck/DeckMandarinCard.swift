import AVFoundation
import Speech
import SwiftUI

/// The Mandarin card in three steps on its step bar: Tell (the question from his life, with the
/// mic ready), Hear it (his story retold naturally with its upgrades marked, played and said along),
/// and Tell again (with the retelling out of sight; the upgrades he used get a check). Everything he
/// says, he says on the card.
struct DeckMandarinCard: View {
    let card: DeckCard
    let palette: DeckPalette
    /// The question on display: the deck's, or his own from "Ask My Own Question".
    let asked: String?
    let practice: MandarinPractice
    /// His answer so far, and where a new one goes (kept with the deck's answers and sent for feedback).
    let answered: String?
    let onAnswer: (String) -> Void

    @State private var speaker = MandarinSpeaker()
    /// Back on the retelling after telling it again.
    @State private var reviewing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepBar.padding(.trailing, 30)
            switch practice.step {
            case .tell: tellStep
            case .hear: hearStep
            case .again: againStep
            }
        }
        .onDisappear { speaker.stop() }
    }

    // MARK: Step bar

    /// A named segment per step: done ones half ink, the current one full, the rest faint.
    private var stepBar: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(MandarinPractice.Step.allCases, id: \.self) { step in
                let isCurrent = practice.step == step
                let isDone = practice.isDone(step)
                Button { change { reviewing = false; practice.step = step } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule()
                            .fill(palette.ink.opacity(isCurrent ? 1 : isDone ? 0.5 : 0.15))
                            .frame(height: 4)
                        Text(verbatim: title(step))
                            .font(AppFont.footnote(weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? palette.ink : palette.colors.secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!practice.canOpen(step))
                .accessibilityLabel(Text(verbatim: title(step) + (isDone ? ", done" : "")))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }

    private func title(_ step: MandarinPractice.Step) -> String {
        switch step {
        case .tell: "Tell"
        case .hear: "Hear it"
        case .again: "Tell again"
        }
    }

    // MARK: The question

    /// Who asks, the Mandarin with pinyin over each character and ▶, then the line naming what he can tell.
    @ViewBuilder
    private var question: some View {
        let line = card.mandarinQuestion(asked: asked ?? card.question ?? "")
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(verbatim: card.mandarinScene) } icon: { Image(systemName: "character.bubble") }
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
            HStack(alignment: .top, spacing: 12) {
                MandarinRubyText(text: line.hanzi, ruby: line.ruby,
                                 font: AppFont.display(style: .title2, weight: .semibold),
                                 pinyinFont: AppFont.caption(weight: .medium), ink: palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                playButton(line.hanzi, size: 40)
            }
            if let hook = line.hook ?? line.english {
                Text(verbatim: hook).font(AppFont.footnote()).foregroundStyle(palette.colors.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(verbatim: "Play")) { speaker.toggle(line.hanzi) }
    }

    /// The question kept small above a step that isn't about it: who asks, the Mandarin, ▶.
    @ViewBuilder
    private var questionPinned: some View {
        let line = card.mandarinQuestion(asked: asked ?? card.question ?? "")
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.mandarinScene)
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(palette.ink)
                MandarinRubyText(text: line.hanzi, ruby: line.ruby, font: AppFont.subheadline(), ink: palette.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { speaker.toggle(line.hanzi) } label: {
                Image(systemName: speaker.speaking == line.hanzi ? "stop.fill" : "play.fill")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Play the question"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 10)
        .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
    }

    // MARK: Tell

    @ViewBuilder
    private var tellStep: some View {
        question
        switch practice.answering {
        case .waiting:
            telling("You said", answered ?? "")
            HStack(spacing: 8) {
                ProgressView().tint(palette.ink)
                Text(verbatim: "Retelling it…").font(AppFont.footnote()).foregroundStyle(palette.colors.secondaryInk)
            }
        case let .failed(message):
            telling("You said", answered ?? "")
            retryLine(message)
        case .idle:
            if let result = practice.result, result.feedback == nil {
                telling("You said", answered ?? "")
                retryLine("The retelling didn't come back.")
            } else {
                MandarinMic(prompt: "Tell it, as long as you like", palette: palette, confirms: true, editing: answered,
                            onListen: { speaker.stop() }) { text in
                    onAnswer(text)
                    return true
                }
            }
        }
    }

    // MARK: Hear it

    @ViewBuilder
    private var hearStep: some View {
        questionPinned
        telling("You said", practice.record.answeredText ?? answered ?? "")
        if let feedback = practice.feedback {
            retelling(feedback)
            actions(primary: ("Tell it again", "mic.fill", {
                speaker.stop()
                change { reviewing = false; practice.step = .again }
            }))
            .padding(.top, 4)
            Text(verbatim: "The retelling hides while you tell it.")
                .font(AppFont.footnote())
                .foregroundStyle(palette.colors.secondaryInk)
                .frame(maxWidth: .infinity)
        }
    }

    /// The retelling with its upgrades marked and ▶, the one instruction, then a row per upgrade.
    @ViewBuilder
    private func retelling(_ feedback: DeckMandarinFeedback) -> some View {
        MandarinTakeaway(tag: "Said naturally", text: feedback.natural, ruby: feedback.naturalRuby,
                         emphasis: feedback.upgrades.map(\.better), palette: palette, speaker: speaker)
            .transition(HXMotion.replaceTransition(reduceMotion: reduceMotion))
        Text(verbatim: "Play it and say it along once.")
            .font(AppFont.footnote())
            .foregroundStyle(palette.colors.secondaryInk)
        ForEach(feedback.upgrades, id: \.self) { upgrade in
            MandarinRow(tag: upgrade.fromBefore ? "From before" : "Upgrade", text: upgrade.better,
                        ruby: upgrade.betterRuby, note: Self.note(upgrade), palette: palette, speaker: speaker)
        }
    }

    /// An upgrade's note: his words → the better ones (or its English, for a phrase from before), then why.
    static func note(_ upgrade: DeckMandarinUpgrade) -> String {
        let first = upgrade.fromBefore ? upgrade.en : "\(upgrade.said) → \(upgrade.better)"
        return [first, upgrade.why].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
    }

    // MARK: Tell again

    @ViewBuilder
    private var againStep: some View {
        questionPinned
        if let again = practice.againText, !reviewing {
            telling("Second time", again)
            if let upgrades = practice.feedback?.upgrades, !upgrades.isEmpty {
                MandarinUsedChips(upgrades: upgrades, used: Set(practice.used), palette: palette)
            }
            Button { change { reviewing = true } } label: {
                MandarinPillLabel(text: "Back to the retelling", palette: palette)
            }
            .buttonStyle(.plain)
        } else if let feedback = practice.feedback, reviewing {
            retelling(feedback)
            Button { change { reviewing = false } } label: {
                MandarinPillLabel(text: "Done", palette: palette)
            }
            .buttonStyle(.plain)
        } else {
            MandarinMic(prompt: "Tell it again, without looking", palette: palette, isBusy: practice.answering == .waiting,
                        confirms: true, onListen: { speaker.stop() }) { text in
                await practice.tellAgain(text)
            }
            if case let .failed(message) = practice.answering { retryLine(message) }
        }
    }

    /// One telling of his answer: what he said, under its tag. Nothing when he hasn't said anything.
    @ViewBuilder
    private func telling(_ tag: String, _ text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: tag)
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.colors.secondaryInk)
                Text(verbatim: text)
                    .font(AppFont.body())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// A failed telling as one inline row: the warning mark, what happened, Try again.
    private func retryLine(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxWarning)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(AppFont.footnote())
                .foregroundStyle(palette.colors.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { Task { await practice.retry() } } label: {
                Text(verbatim: "Try again").font(AppFont.footnote(weight: .semibold)).foregroundStyle(palette.ink)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Parts

    private func playButton(_ text: String, size: CGFloat) -> some View {
        Button { speaker.toggle(text) } label: {
            Image(systemName: speaker.speaking == text ? "stop.fill" : "play.fill")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.onInk)
                .frame(width: size, height: size)
                .background(palette.ink, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private typealias Action = (label: String, symbol: String, run: () -> Void)

    /// The step's one filled button: the way forward.
    private func actions(primary: Action) -> some View {
        Button(action: primary.run) {
            Label { Text(verbatim: primary.label) } icon: { Image(systemName: primary.symbol) }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(palette.onInk)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(palette.ink, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A step, or the retelling, replacing what's on the card.
    private func change(_ update: () -> Void) {
        withAnimation(HXMotion.swap(reduceMotion: reduceMotion), update)
    }
}

extension DeckCard {
    /// The Mandarin card's question line. The deck's pinyin, English and hook belong only to its own
    /// question; one he asked himself shows plain.
    func mandarinQuestion(asked: String) -> (hanzi: String, ruby: [String]?, english: String?, hook: String?) {
        guard asked == self.question else { return (asked, nil, nil, nil) }
        return (asked, self.questionRuby, self.questionEn, self.hook)
    }

    /// Who the Mandarin card has him talk with, said to him; older cards name their scene.
    var mandarinScene: String {
        if let scene = self.scene { return scene }
        switch self.speaker {
        case "mom": return "Mom asks"
        case "dad": return "Dad asks"
        case "parents": return "Mom and Dad ask"
        case "baby": return "Talk to her"
        default: return "Today's question"
        }
    }
}

/// The retelling (or any long line to keep): a tag, the Mandarin with pinyin over each character and
/// its upgrades marked, and ▶ to hear it when there is a speaker.
struct MandarinTakeaway: View {
    let tag: String?
    let text: String
    let ruby: [String]?
    var emphasis: [String] = []
    let palette: DeckPalette
    let speaker: MandarinSpeaker?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let tag {
                    Text(verbatim: tag)
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
                MandarinRubyText(text: text, ruby: ruby, emphasis: emphasis, font: AppFont.body(),
                                 pinyinFont: AppFont.caption2(weight: .medium), ink: palette.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let speaker {
                Button { speaker.toggle(text) } label: {
                    Image(systemName: speaker.speaking == text ? "stop.fill" : "play.fill")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.onInk)
                        .frame(width: 36, height: 36)
                        .background(palette.ink, in: Circle())
                        .contentShape(.interaction, Rectangle().inset(by: -4))  // a 44 pt target
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .padding(14)
        .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [tag, text].compactMap { $0 }.joined(separator: ". ")))
        .accessibilityAction(named: Text(verbatim: "Play")) { speaker?.toggle(text) }
    }
}

/// One upgrade under the retelling: its tag, the better words with pinyin over them, a note, and ▶
/// beside it, with no box.
struct MandarinRow: View {
    let tag: String
    let text: String
    let ruby: [String]?
    let note: String?
    let palette: DeckPalette
    let speaker: MandarinSpeaker?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tag)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
                MandarinRubyText(text: text, ruby: ruby, font: AppFont.body(weight: .semibold), ink: palette.ink)
                if let note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(AppFont.footnote())
                        .foregroundStyle(palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let speaker {
                Button { speaker.toggle(text) } label: {
                    Image(systemName: speaker.speaking == text ? "stop.fill" : "play.fill")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(width: 32, height: 32)
                        .contentShape(.interaction, Rectangle().inset(by: -6))  // a 44 pt target
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [tag, text, note].compactMap { $0 }.joined(separator: ". ")))
        .accessibilityAction(named: Text(verbatim: "Play")) { speaker?.toggle(text) }
    }
}

/// The day's upgrades as chips after the second telling, checked when he said them.
struct MandarinUsedChips: View {
    let upgrades: [DeckMandarinUpgrade]
    let used: Set<String>
    let palette: DeckPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "You used")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(palette.ink)
            FlowRow(spacing: 6) {
                ForEach(upgrades, id: \.self) { upgrade in
                    let isUsed = used.contains(upgrade.better)
                    HXChip(paper: palette.colors, symbol: isUsed ? "checkmark" : nil, label: upgrade.better, lines: 2)
                        .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(verbatim: isUsed ? "Used" : "Not used"))
                }
            }
        }
    }
}

/// A secondary way on, as a pill in the card's wash: lighter than the 50 pt action row, so the
/// mic or the filled button stays the one primary.
struct MandarinPillLabel: View {
    let text: String
    let palette: DeckPalette

    var body: some View {
        Text(verbatim: text)
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(palette.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(palette.colors.wash, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.edge, lineWidth: 0.5))
    }
}

/// Speaking on the card: a big mic writes his Mandarin as he says it (zh-CN, on device), and stop hands
/// the words to `onFinish`, or, when `confirms`, first shows what it heard to edit, say again or check.
/// "Type instead" types. `onFinish` returns whether the words were taken, so a failed check keeps them
/// to send again.
struct MandarinMic: View {
    let prompt: String
    let palette: DeckPalette
    var isBusy = false
    /// Show what the dictation heard before sending it: for an answer that gets checked.
    var confirms = false
    /// What typing starts from when nothing is said yet: his earlier answer, to edit.
    var editing: String?
    /// A second way on beside "Type instead", such as Show me; it stays while listening.
    var alternative: (label: String, run: () -> Void)?
    /// Called as listening starts, so nothing on the card plays over the mic.
    var onListen: () -> Void = {}
    let onFinish: (String) async -> Bool

    @State private var text = ""
    /// What the dictation heard, waiting for Edit, Again or Check.
    @State private var heard: String?
    @State private var isTyping = !MandarinDictation.isAvailable
    @State private var voiceInput = ComposerVoiceInputController(fixedLocale: MandarinDictation.locale)
    @FocusState private var isFocused: Bool

    private var isListening: Bool { voiceInput.state != .idle }
    private var said: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let heard {
                heardView(heard)
            } else if isTyping {
                typing
            } else {
                speaking
            }
            if let message = voiceInput.errorMessage {
                Text(verbatim: message)
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.colors.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { voiceInput.stopKeepingTranscript() }
    }

    /// The big mic with what to say under it; his words appear above as he speaks.
    private var speaking: some View {
        VStack(spacing: 10) {
            if !text.isEmpty {
                Text(verbatim: text)
                    .font(AppFont.body())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { isListening ? finish() : listen() } label: {
                ZStack {
                    Circle().fill(palette.ink)
                    if isBusy {
                        ProgressView().tint(palette.onInk)
                    } else {
                        Image(systemName: isListening ? "stop.fill" : "mic.fill")
                            .font(AppFont.title2(weight: .semibold))
                            .foregroundStyle(palette.onInk)
                    }
                }
                .frame(width: 72, height: 72)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(Text(verbatim: isListening ? "Stop" : "Speak in Mandarin"))
            Text(verbatim: isBusy ? "Checking…" : isListening ? "Listening… tap stop when you're done" : prompt)
                .font(AppFont.body())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Side by side, stacked when large text won't fit them in a row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { otherWays }
                VStack(spacing: 8) { otherWays }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    /// The pills under the mic: Type instead, and the step's alternative when it has one.
    @ViewBuilder
    private var otherWays: some View {
        if MandarinDictation.isAvailable, !isListening, !isBusy {
            Button { startTyping(from: editing) } label: {
                MandarinPillLabel(text: "Type instead", palette: palette)
            }
            .buttonStyle(.plain)
        }
        if let alternative {
            Button(action: alternative.run) {
                MandarinPillLabel(text: alternative.label, palette: palette)
            }
            .buttonStyle(.plain)
        }
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(text: $text, axis: .vertical) { Text(verbatim: "Type in Mandarin") }
                .font(AppFont.body())
                .focused($isFocused)
                .padding(12)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            HStack(spacing: 12) {
                Text(verbatim: isBusy ? "Checking…" : prompt)
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.colors.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if MandarinDictation.isAvailable, !isBusy {
                    Button { isTyping = false; isFocused = false } label: {
                        Image(systemName: "mic")
                            .font(AppFont.body(weight: .medium))
                            .foregroundStyle(palette.ink)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "Speak instead"))
                }
                Button { send(said) } label: {
                    ZStack {
                        Circle().fill(palette.ink)
                        if isBusy {
                            ProgressView().tint(palette.onInk)
                        } else {
                            Image(systemName: "arrow.up").font(AppFont.title3(weight: .semibold)).foregroundStyle(palette.onInk)
                        }
                    }
                    .frame(width: 56, height: 56)
                }
                .buttonStyle(.plain)
                .disabled(isBusy || said.isEmpty)
                .opacity(said.isEmpty && !isBusy ? 0.4 : 1)
                .accessibilityLabel(Text(verbatim: "Check"))
            }
        }
    }

    /// What the dictation heard, to fix before it's checked: Edit types it, Again says it again.
    private func heardView(_ words: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "I heard")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
            Text(verbatim: words)
                .font(AppFont.body())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            Text(verbatim: "Fix a misheard word before it's checked.")
                .font(AppFont.footnote())
                .foregroundStyle(palette.colors.secondaryInk)
            HStack(spacing: 8) {
                choice("Edit", "pencil") { heard = nil; startTyping(from: words) }
                choice("Again", "mic") { heard = nil; text = ""; listen() }
                Button { send(words) } label: {
                    Group {
                        if isBusy {
                            ProgressView().tint(palette.onInk)
                        } else {
                            Label { Text(verbatim: "Check") } icon: { Image(systemName: "checkmark") }
                        }
                    }
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(palette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .disabled(isBusy)
        }
    }

    private func choice(_ label: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label { Text(verbatim: label) } icon: { Image(systemName: symbol) }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .background(palette.colors.wash, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.edge, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func listen() {
        onListen()
        _ = voiceInput.scheduleToggle(currentDraft: text) { text = $0 }
    }

    private func startTyping(from start: String?) {
        if text.isEmpty, let start { text = start }
        isTyping = true
        isFocused = true
    }

    /// Stop: what he said goes to "I heard" first when the mic confirms, else straight on.
    private func finish() {
        voiceInput.stopKeepingTranscript()
        let words = said
        guard !words.isEmpty else { return }
        if confirms { heard = words } else { send(words) }
    }

    private func send(_ words: String) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        isFocused = false
        Task {
            guard await onFinish(words) else { return }
            text = ""
            heard = nil
            isTyping = !MandarinDictation.isAvailable
        }
    }
}


/// Reads Mandarin aloud with the system's zh-CN voice, a little slower than normal for practice.
/// Tapping the playing line again stops it; tapping another switches to it.
@MainActor
@Observable
final class MandarinSpeaker {
    private(set) var speaking: String?

    @ObservationIgnored private let synthesizer: ChatSpeechSynthesizing
    @ObservationIgnored private let audioSession: ListenAudioSessionControlling
    @ObservationIgnored private var proxy: MandarinSpeakerDelegate?
    @ObservationIgnored private var current: ObjectIdentifier?

    /// `audioSession` is chat Listen's: playback on the speaker, left alone while dictation records.
    init(
        synthesizer: ChatSpeechSynthesizing = AVSpeechSynthesizer(),
        audioSession: ListenAudioSessionControlling? = nil
    ) {
        self.synthesizer = synthesizer
        self.audioSession = audioSession ?? ListenAudioSessionController()
        let proxy = MandarinSpeakerDelegate { [weak self] id in self?.utteranceEnded(id) }
        self.proxy = proxy
        synthesizer.delegate = proxy
    }

    /// An utterance finished on its own; only the one playing now clears the ▶ state.
    func utteranceEnded(_ id: ObjectIdentifier) {
        guard id == current else { return }
        current = nil
        speaking = nil
        audioSession.deactivate()
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
        audioSession.activate()
        synthesizer.speak(utterance)
    }

    func stop() {
        guard speaking != nil else { return }
        speaking = nil
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioSession.deactivate()
    }
}

private final class MandarinSpeakerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onDone: @MainActor (ObjectIdentifier) -> Void

    init(onDone: @escaping @MainActor (ObjectIdentifier) -> Void) { self.onDone = onDone }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        report(utterance)
    }

    /// An interruption cancels without a finish; clear the ▶ state the same way.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        report(utterance)
    }

    private func report(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [onDone] in onDone(id) }
    }
}


/// The Mandarin card's dictation: on-device zh-CN only, so the answer arrives as characters.
enum MandarinDictation {
    static let locale = Locale(identifier: "zh-CN")

    /// Whether this phone has the on-device Mandarin model; without it the card hides its mic.
    static var isAvailable: Bool { SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true }
}
