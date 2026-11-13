import AVFoundation
import Speech
import SwiftUI

/// The Mandarin card as one conversation, moved through by its named step bar: it opens on the family
/// member's question and the phrases for the answer (Warm up), asks each from its English and shows it
/// (Got it / Again), takes the answer (what the dictation heard is shown to fix before it's checked),
/// then the feedback and telling it again with it out of sight. Everything he says, he says on the card.
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
    /// Warm-up phrases whose Mandarin is showing, and what he said for each before seeing it.
    @State private var revealed: Set<String> = []
    @State private var attempts: [String: String] = [:]
    /// Telling it again, with the feedback out of sight.
    @State private var retelling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepBar.padding(.trailing, 30)
            switch practice.step {
            case .warmUp: if let item = practice.currentWarmUp { warmUpStep(item) } else { opening }
            case .answer: answerStep
            case .again: againStep
            }
        }
        .onDisappear { speaker.stop() }
        .onChange(of: practice.againText) { _, _ in retelling = false }  // a retried second telling landed
    }

    // MARK: Step bar

    /// A named segment per step: done ones half ink, the current one full, the rest faint. Tell it
    /// again opens once the answer has feedback.
    private var stepBar: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(practice.steps, id: \.self) { step in
                let isCurrent = practice.step == step
                let isDone = practice.isDone(step)
                Button { change { practice.step = step } } label: {
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
                .disabled(step == .again && !practice.isDone(.answer))
                .accessibilityLabel(Text(verbatim: title(step) + (isDone ? ", done" : "")))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }

    private func title(_ step: MandarinPractice.Step) -> String {
        switch step {
        case .warmUp: "Warm up"
        case .answer: "Answer"
        case .again: "Tell it again"
        }
    }

    // MARK: The question

    /// The question in full: who asks about what, the Mandarin with ▶, its pinyin and English.
    @ViewBuilder
    private var question: some View {
        let line = card.mandarinQuestion(asked: asked ?? card.question ?? "")
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(verbatim: card.scene ?? "Today's question") } icon: { Image(systemName: "character.bubble") }
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
            HStack(alignment: .top, spacing: 12) {
                Text(verbatim: line.hanzi)
                    .font(AppFont.display(style: .title2, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                playButton(line.hanzi, size: 40)
            }
            if let pinyin = line.pinyin {
                Text(verbatim: pinyin).font(AppFont.subheadline(weight: .medium)).foregroundStyle(palette.ink)
            }
            if let english = line.english {
                Text(verbatim: english).font(AppFont.footnote()).foregroundStyle(palette.colors.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(verbatim: "Play")) { speaker.toggle(line.hanzi) }
    }

    /// The question kept small above a step that isn't about it: who asks, the Mandarin, ▶.
    @ViewBuilder
    private var questionPinned: some View {
        let hanzi = asked ?? card.question ?? ""
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.scene ?? "Today's question")
                    .font(AppFont.caption(weight: .medium))
                    .foregroundStyle(palette.ink)
                Text(verbatim: hanzi).font(AppFont.subheadline()).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { speaker.toggle(hanzi) } label: {
                Image(systemName: speaker.speaking == hanzi ? "stop.fill" : "play.fill")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Play the question"))
        }
        .padding(.leading, 12)
        .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
    }

    // MARK: Warm up

    /// Before the warm-up: the question, the phrases for the answer, and the way in (or straight to answering).
    private var opening: some View {
        VStack(alignment: .leading, spacing: 0) {
            question
            Rectangle().fill(palette.edge).frame(height: 0.5).padding(.vertical, 20)
            Text(verbatim: "Warm up · \(practice.warmUp.count) \(practice.warmUp.count == 1 ? "phrase" : "phrases") for your answer")
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            ForEach(practice.warmUp) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.en).font(AppFont.body())
                    Text(verbatim: item.listNote).font(AppFont.footnote()).foregroundStyle(palette.colors.secondaryInk)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(palette.edge).frame(height: 0.5) }
                .accessibilityElement(children: .combine)
            }
            actions(primary: ("Warm up", "mic.fill", { change { practice.startWarmUp() } }))
                .padding(.top, 20)
            Button { change { practice.step = .answer } } label: {
                MandarinPillLabel(text: "Skip to answer", palette: palette)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    /// One phrase: its English to say, then the Mandarin beside what he said, and Got it or Again.
    @ViewBuilder
    private func warmUpStep(_ item: MandarinWarmUp) -> some View {
        let isRevealed = revealed.contains(item.hanzi)
        questionPinned
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: "How would you say")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                Spacer()
                Text(verbatim: "\((practice.warmUp.firstIndex(of: item) ?? 0) + 1) of \(practice.warmUp.count)")
                    .font(AppFont.caption())
                    .foregroundStyle(palette.colors.secondaryInk)
            }
            Text(verbatim: "“\(item.en)”")
                .font(AppFont.display(style: .title2, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        if isRevealed {
            if let tried = attempts[item.hanzi] {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "You said").font(AppFont.footnote(weight: .semibold)).foregroundStyle(palette.colors.secondaryInk)
                    HStack(spacing: 6) {
                        Text(verbatim: tried).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
                        if MandarinWarmUp.said(tried, item.hanzi) {
                            Image(systemName: "checkmark").font(AppFont.footnote(weight: .bold)).foregroundStyle(palette.ink)
                                .accessibilityLabel(Text(verbatim: "Right"))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            } else if let said = item.said {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Yesterday you said").font(AppFont.footnote(weight: .semibold)).foregroundStyle(palette.colors.secondaryInk)
                    Text(verbatim: said).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            MandarinTakeaway(tag: nil, text: item.hanzi, pinyin: item.pinyin,
                             note: [item.example, item.exampleEn ?? item.note].compactMap { $0 }.joined(separator: "\n"),
                             palette: palette, speaker: speaker)
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
            if let error = practice.recallError {
                Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(palette.colors.secondaryInk)
            }
            actions(primary: ("Got it", "checkmark", { Task { await practice.warm(item, got: true) } }),
                    secondary: ("Again", "arrow.counterclockwise", { Task { await practice.warm(item, got: false) } }),
                    busy: practice.isSavingRecall)
        } else {
            MandarinMic(prompt: "Say it in Mandarin", palette: palette,
                        alternative: ("Show me", { change { _ = revealed.insert(item.hanzi) } }),
                        onListen: { speaker.stop() }) { text in
                attempts[item.hanzi] = text
                change { _ = revealed.insert(item.hanzi) }
                return true
            }
            .id(item.hanzi)
        }
    }

    // MARK: Answer

    @ViewBuilder
    private var answerStep: some View {
        question
        if !card.phrases.isEmpty {
            MandarinCueChips(phrases: card.phrases, used: Set(practice.usedCues), palette: palette, speaker: speaker)
        }
        switch practice.answering {
        case .waiting:
            telling("You said", answered ?? "")
            HStack(spacing: 8) {
                ProgressView().tint(palette.ink)
                Text(verbatim: "Checking…").font(AppFont.footnote()).foregroundStyle(palette.colors.secondaryInk)
            }
        case let .failed(message):
            telling("You said", answered ?? "")
            retryLine(message)
        case .idle:
            if let result = practice.result, result.feedback == nil {
                telling("You said", answered ?? "")
                retryLine("Feedback comes with tomorrow's card.")
            } else {
                MandarinMic(prompt: talkPrompt, palette: palette, confirms: true, editing: answered,
                            onListen: { speaker.stop() }) { text in
                    onAnswer(text)
                    return true
                }
            }
        }
    }

    private var talkPrompt: String {
        card.mandarinTellsAStory ? "What happened → how you felt → what's next" : "Answer out loud"
    }

    // MARK: Tell it again

    @ViewBuilder
    private var againStep: some View {
        questionPinned
        if retelling {
            MandarinMic(prompt: "Tell it again, a little longer", palette: palette, isBusy: practice.answering == .waiting,
                        confirms: true, onListen: { speaker.stop() }) { text in
                let told = await practice.tellAgain(text)
                if told { change { retelling = false } }
                return told
            }
            if case let .failed(message) = practice.answering { retryLine(message) }
            Button { change { retelling = false } } label: {
                MandarinPillLabel(text: "Back to the feedback", palette: palette)
            }
            .buttonStyle(.plain)
            .disabled(practice.answering == .waiting)
        } else {
            if let again = practice.againText {
                telling("First time", answered ?? "")
                telling("Second time", again)
            } else {
                telling("You said", answered ?? "")
            }
            if let feedback = (practice.againText == nil ? practice.result : practice.againResult)?.feedback {
                feedbackBlocks(feedback)
            } else if case let .failed(message) = practice.answering {
                retryLine(message)
            }
            if !card.phrases.isEmpty {
                MandarinCueChips(phrases: card.phrases, used: Set(practice.usedCues), palette: palette, speaker: speaker)
            }
            VStack(spacing: 8) {
                actions(primary: ("Tell it again", "mic.fill", {
                    speaker.stop()
                    change { retelling = true }
                }))
                Text(verbatim: "The feedback hides while you tell it.")
                    .font(AppFont.footnote())
                    .foregroundStyle(palette.colors.secondaryInk)
            }
            .padding(.top, 4)
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

    /// The natural version, any new words, and one thing to try: the first fix, else the flow note.
    @ViewBuilder
    private func feedbackBlocks(_ feedback: DeckMandarinFeedback) -> some View {
        MandarinTakeaway(tag: "Said naturally", text: feedback.natural, pinyin: feedback.naturalPinyin, note: nil,
                         palette: palette, speaker: speaker)
            .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        ForEach(feedback.gaps, id: \.self) { gap in
            row("New word", gap.hanzi, pinyin: gap.pinyin,
                note: [gap.en, gap.build].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
        }
        if let fix = feedback.fixes.first {
            row("One thing to try", fix.natural, pinyin: fix.naturalPinyin,
                note: [fix.said + " → " + fix.natural, fix.why].compactMap { $0 }.joined(separator: "\n"))
        } else if let flow = feedback.flow {
            let word = flow.transition + (flow.en.map { " (\($0))" } ?? "")
            row("One thing to try", flow.joined, pinyin: flow.joinedPinyin,
                note: [word, flow.why].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
        }
    }

    private func retryLine(_ message: String) -> some View {
        HStack(spacing: 12) {
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

    private func row(_ tag: String, _ text: String, pinyin: String?, note: String?) -> some View {
        MandarinRow(tag: tag, text: text, pinyin: pinyin, note: note, palette: palette, speaker: speaker)
            .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
    }

    private typealias Action = (label: String, symbol: String, run: () -> Void)

    /// The step's buttons: one filled (the way forward), at most one in the paper's wash.
    private func actions(primary: Action, secondary: Action? = nil, busy: Bool = false) -> some View {
        HStack(spacing: 8) {
            if let secondary {
                Button(action: secondary.run) {
                    Label { Text(verbatim: secondary.label) } icon: { Image(systemName: secondary.symbol) }
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(palette.colors.wash, in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.edge, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            Button(action: primary.run) {
                Label { Text(verbatim: primary.label) } icon: { Image(systemName: primary.symbol) }
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(palette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    private func change(_ update: () -> Void) {
        withAnimation(HXMotion.quickState(reduceMotion: reduceMotion), update)
    }
}

extension MandarinWarmUp {
    /// Whether what he said has the phrase in it, ignoring punctuation and spaces the dictation adds.
    static func said(_ text: String, _ hanzi: String) -> Bool {
        let bare: (String) -> String = { $0.filter { !$0.isPunctuation && !$0.isWhitespace } }
        let phrase = bare(hanzi)
        return !phrase.isEmpty && bare(text).contains(phrase)
    }
}

extension DeckCard {
    /// The Mandarin card's question line: the deck's pinyin and English only belong to its own question.
    func mandarinQuestion(asked: String) -> (hanzi: String, pinyin: String?, english: String?) {
        guard asked == self.question else { return (asked, nil, nil) }
        return (asked, self.questionPinyin, self.questionEn)
    }
}

/// One thing to keep: a tag (Fix, New word, Pattern…), the Mandarin, its pinyin, a one-line lesson,
/// and ▶ to hear it when there is a speaker.
struct MandarinTakeaway: View {
    let tag: String?
    let text: String
    let pinyin: String?
    let note: String?
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
                Text(verbatim: text)
                    .font(AppFont.display(style: .title3, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let pinyin {
                    Text(verbatim: pinyin).font(AppFont.subheadline(weight: .medium)).foregroundStyle(palette.ink)
                }
                if let note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
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
        .accessibilityLabel(Text(verbatim: [tag, text, note].compactMap { $0 }.joined(separator: ". ")))
        .accessibilityAction(named: Text(verbatim: "Play")) { speaker?.toggle(text) }
    }
}

/// A lighter takeaway for the ones under the main one: the same tag, Mandarin, pinyin and note, with
/// ▶ beside it and no box.
struct MandarinRow: View {
    let tag: String
    let text: String
    let pinyin: String?
    let note: String?
    let palette: DeckPalette
    let speaker: MandarinSpeaker?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tag)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(verbatim: text)
                    .font(AppFont.body(weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let pinyin {
                    Text(verbatim: pinyin).font(AppFont.footnote(weight: .medium)).foregroundStyle(palette.ink)
                }
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

/// The day's cues as chips in his English, checked once used in the answer. Tapping one peeks at its
/// Mandarin, example and note underneath; tapping it again closes it.
struct MandarinCueChips: View {
    let phrases: [DeckPhrase]
    let used: Set<String>
    let palette: DeckPalette
    let speaker: MandarinSpeaker

    @State private var peeking: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Work these in")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(palette.ink)
            FlowRow(spacing: 6) {
                ForEach(phrases, id: \.hanzi) { phrase in
                    let isUsed = used.contains(phrase.hanzi)
                    let isOpen = peeking == phrase.hanzi
                    Button {
                        withAnimation(HXMotion.disclosure(reduceMotion: reduceMotion)) { peeking = isOpen ? nil : phrase.hanzi }
                    } label: {
                        HStack(spacing: 4) {
                            if isUsed { Image(systemName: "checkmark").font(AppFont.caption2(weight: .bold)) }
                            Text(verbatim: phrase.en ?? phrase.hanzi)
                        }
                        .font(AppFont.subheadline(weight: .medium))
                        .foregroundStyle(isOpen ? palette.onInk : palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(isOpen ? palette.ink : palette.colors.wash, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: [phrase.kindLabel, phrase.en].compactMap { $0 }.joined(separator: ". ")))
                    .accessibilityValue(Text(verbatim: isUsed ? "Used" : ""))
                    .accessibilityHint(Text(verbatim: isOpen ? "Hides the Mandarin" : "Shows the Mandarin"))
                }
            }
            if let phrase = phrases.first(where: { $0.hanzi == peeking }) {
                MandarinRow(tag: phrase.kindLabel ?? "Phrase", text: phrase.hanzi, pinyin: phrase.pinyin,
                            note: [phrase.example, phrase.exampleEn, phrase.note].compactMap { $0 }.joined(separator: "\n"),
                            palette: palette, speaker: speaker)
                    .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
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
