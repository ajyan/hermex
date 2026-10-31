import AVFoundation
import Speech
import SwiftUI

/// The Mandarin practice card in steps, chosen from its step bar: Fix yesterday's slips, Recall the
/// phrasebook's due phrases, make each cue Yours (say its example, then two versions about his week,
/// checked), Talk (the question, a transition, a feeling and an everyday cue, and the answer), then
/// the takeaways that come back seconds after answering. `answer` is the deck's
/// own answer button (or his words once written).
struct DeckMandarinCard<Answer: View>: View {
    let card: DeckCard
    let palette: DeckPalette
    /// The question on display: the deck's, or his own from "Ask My Own Question".
    let asked: String?
    let practice: MandarinPractice
    @ViewBuilder let answer: () -> Answer

    @State private var speaker = MandarinSpeaker()
    /// Fixes and recall phrases whose answer is showing.
    @State private var revealed: Set<String> = []
    @State private var isCalling = false
    /// The cue whose versions he is saying, in the dictation sheet.
    @State private var makingYours: DeckPhrase?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepBar.padding(.trailing, 30)
            switch practice.step {
            case .fix: fixStep
            case .recall: recallStep
            case .yours: yoursStep
            case .talk: talkStep
            }
        }
        .onDisappear { speaker.stop() }
        .sheet(isPresented: $isCalling) { MandarinCallSheet(practice: practice, palette: palette) }
        .sheet(item: $makingYours) { cue in
            MandarinVersionsSheet(cue: cue, palette: palette) { text in
                Task { await practice.checkVersions(of: cue, text) }
            }
        }
    }

    // MARK: Step bar

    private var stepBar: some View {
        HStack(spacing: 6) {
            ForEach(practice.steps, id: \.self) { step in
                let isCurrent = practice.step == step
                let isDone = practice.isDone(step)
                Button { change { practice.step = step } } label: {
                    HStack(spacing: 4) {
                        if isDone { Image(systemName: "checkmark").font(AppFont.caption2(weight: .bold)) }
                        Text(verbatim: title(step))
                    }
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(isCurrent ? palette.onInk : palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isCurrent ? palette.ink : palette.colors.wash, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: title(step) + (isDone ? ", done" : "")))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private func title(_ step: MandarinPractice.Step) -> String {
        switch step {
        case .fix: "Fix"
        case .recall: "Recall \(card.recall.count)"
        case .yours: "Yours"
        case .talk: "Talk"
        }
    }

    // MARK: Fix

    @ViewBuilder
    private var fixStep: some View {
        let yesterday = card.yesterday
        if let fix = practice.currentFix {
            let key = "fix:\(fix.said)"
            heading("Say it the natural way",
                    detail: practice.fixes.count > 1 ? "\((practice.fixes.firstIndex(of: fix) ?? 0) + 1) of \(practice.fixes.count)" : nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(slip(in: yesterday?.said ?? fix.said, fix.said))
                    .font(AppFont.body())
                    .fixedSize(horizontal: false, vertical: true)
                if let en = fix.en {
                    Text(verbatim: "You meant: \(en)")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            if revealed.contains(key) {
                takeaway("Fix", fix.natural, pinyin: fix.naturalPinyin, note: fix.why)
                actions(primary: ("Next", "arrow.right", { change { practice.nextFix() } }))
            } else {
                actions(primary: ("Show me", "eye", { change { _ = revealed.insert(key) } }))
            }
        } else if practice.fixes.isEmpty, let yesterday {
            heading("Yesterday, said naturally", detail: nil)
            if let said = yesterday.said {
                Text(verbatim: said).font(AppFont.body()).foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            takeaway("Natural", yesterday.natural, pinyin: yesterday.naturalPinyin, note: nil)
            if let flow = yesterday.flow { flowTakeaway(flow) }
            if !practice.isDone(.fix) {
                actions(primary: ("Next", "arrow.right", { change { practice.nextFix() } }))
            }
        } else {
            heading("Yesterday's fixes", detail: nil)
            ForEach(practice.fixes, id: \.self) { fix in
                takeaway("Fix", fix.natural, pinyin: fix.naturalPinyin, note: [fix.said + " → " + fix.natural, fix.why]
                    .compactMap { $0 }.joined(separator: "\n"))
            }
            if let flow = yesterday?.flow { flowTakeaway(flow) }
        }
    }

    /// His sentence with the slip underlined in the card's ink.
    private func slip(in said: String, _ slip: String) -> AttributedString {
        var text = AttributedString(said)
        if let range = text.range(of: slip) {
            text[range].underlineStyle = .single
            text[range].foregroundColor = palette.ink
        }
        return text
    }

    // MARK: Recall

    @ViewBuilder
    private var recallStep: some View {
        if let phrase = practice.currentRecall {
            let key = "recall:\(phrase.hanzi)"
            heading(phrase.en ?? phrase.hanzi, detail: "Say it out loud, then check.")
            if revealed.contains(key) {
                takeaway(source(phrase), phrase.hanzi, pinyin: phrase.pinyin, note: phrase.en == nil ? nil : phrase.en)
                actions(primary: ("Got it", "checkmark", { Task { await practice.recall(phrase, got: true) } }),
                        secondary: ("Again", "arrow.counterclockwise", { Task { await practice.recall(phrase, got: false) } }),
                        busy: practice.isSavingRecall)
            } else {
                actions(primary: ("Show me", "eye", { change { _ = revealed.insert(key) } }))
            }
            if let error = practice.recallError {
                Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
            }
        } else {
            heading("All recalled", detail: "They come back on their own schedule.")
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(card.recall, id: \.hanzi) { phrase in
                let got = practice.record.recalled[phrase.hanzi]
                HStack(spacing: 10) {
                    Image(systemName: got == true ? "checkmark.circle.fill" : got == false ? "arrow.counterclockwise.circle" : "circle")
                        .foregroundStyle(got == nil ? Color.hxTextSecondary : palette.ink)
                        .accessibilityHidden(true)
                    Text(verbatim: got == nil ? (phrase.en ?? "…") : "\(phrase.en.map { "\($0) · " } ?? "")\(phrase.hanzi)")
                        .font(AppFont.footnote())
                        .foregroundStyle(got == nil ? Color.hxTextSecondary : Color.hxTextPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(verbatim: got == true ? "Got it" : got == false ? "Again" : "Not yet"))
            }
        }
    }

    private func source(_ phrase: DeckPhrase) -> String {
        switch phrase.source {
        case "gap": "Your word"
        case "fix": "Your fix"
        case "flow": "Transition"
        default: phrase.kindLabel ?? "Phrase"
        }
    }

    // MARK: Make it yours

    @ViewBuilder
    private var yoursStep: some View {
        let cues = practice.yoursCues
        if let cue = practice.currentCue, let example = cue.example {
            heading("Make it yours",
                    detail: cues.count > 1 ? "\((cues.firstIndex(of: cue) ?? 0) + 1) of \(cues.count)" : nil)
            takeaway([cue.kindLabel, cue.hanzi].compactMap { $0 }.joined(separator: " · "), example,
                     pinyin: cue.examplePinyin, note: cue.exampleEn)
            Text(verbatim: "Say it out loud. Then two of your own about this week, changing a word or two.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let checked = practice.record.versions[cue.hanzi] {
                versionsBlock(checked, cue: cue)
                actions(primary: ("Next", "arrow.right", { change { practice.nextCue() } }),
                        secondary: ("Say more", "mic", { speaker.stop(); makingYours = cue }))
            } else {
                actions(primary: ("Say yours", "mic", { speaker.stop(); makingYours = cue }),
                        secondary: ("Skip", "forward", { change { practice.nextCue() } }),
                        busy: practice.checkingCue == cue.hanzi)
            }
            if practice.checkingCue == cue.hanzi {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(verbatim: "Checking…").font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                }
            } else if let error = practice.versionsError {
                Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
            }
        } else {
            heading("All yours", detail: "Now use them in Talk.")
            ForEach(cues.filter { practice.record.versions[$0.hanzi] != nil }, id: \.hanzi) { cue in
                Text(verbatim: [cue.kindLabel, cue.hanzi].compactMap { $0 }.joined(separator: " · "))
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, 4)
                if let checked = practice.record.versions[cue.hanzi] { versionsBlock(checked, cue: cue) }
            }
        }
    }

    /// His versions: a fine one as he said it, one that needs it as the natural way and why.
    @ViewBuilder
    private func versionsBlock(_ checked: MandarinVersionsResponse, cue: DeckPhrase) -> some View {
        ForEach(checked.versions, id: \.self) { version in
            if let natural = version.natural {
                takeaway("Better", natural, pinyin: version.naturalPinyin,
                         note: [version.said + " → " + natural, version.why].compactMap { $0 }.joined(separator: "\n"))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark").font(AppFont.footnote(weight: .bold)).foregroundStyle(palette.ink)
                        .accessibilityHidden(true)
                    Text(verbatim: version.said).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(verbatim: "Natural"))
            }
        }
        if !checked.used {
            Text(verbatim: "These didn't use \(cue.hanzi). Say one that does.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
        }
    }

    // MARK: Talk and takeaways

    @ViewBuilder
    private var talkStep: some View {
        if let situation = card.title {
            Text(verbatim: situation)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let asked {
            let line = card.mandarinQuestion(asked: asked)
            takeaway("Question", line.hanzi, pinyin: line.pinyin, note: line.english)
        }
        if card.mandarinTellsAStory {
            Text(verbatim: "Tell it in three beats: what happened → how you felt → what's next")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let pattern = card.pattern {
            takeaway("Today's pattern", pattern.form ?? pattern.name, pinyin: nil,
                     note: [pattern.name, pattern.en].compactMap { $0 }.joined(separator: "\n"), play: false)
        }
        if !card.phrases.isEmpty {
            MandarinCueList(phrases: card.phrases, used: Set(practice.result?.used ?? []), palette: palette,
                            speaker: speaker)
        }
        answer()
        takeaways
        Button { speaker.stop(); isCalling = true } label: {
            Label { Text(verbatim: "Calling Mom or Dad?") } icon: { Image(systemName: "phone") }
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(Capsule().strokeBorder(palette.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Three things to say before the call, and what you couldn't say after it"))
    }

    @ViewBuilder
    private var takeaways: some View {
        switch practice.answering {
        case .waiting:
            HStack(spacing: 10) {
                ProgressView()
                Text(verbatim: "Getting feedback…").font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
            }
        case let .failed(message):
            retryLine(message)
        case .idle:
            if let result = practice.result {
                if let feedback = result.feedback {
                    feedbackBlocks(feedback)
                } else {
                    retryLine("Feedback comes with tomorrow's card.")
                }
            }
        }
    }

    @ViewBuilder
    private func feedbackBlocks(_ feedback: DeckMandarinFeedback) -> some View {
        Text(verbatim: "Takeaways")
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.top, 4)
        takeaway("Natural", feedback.natural, pinyin: feedback.naturalPinyin, note: nil)
        ForEach(feedback.gaps, id: \.self) { gap in
            takeaway("New word", gap.hanzi, pinyin: gap.pinyin,
                     note: [gap.en, gap.build].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
        }
        ForEach(feedback.fixes, id: \.self) { fix in
            takeaway("Fix", fix.natural, pinyin: fix.naturalPinyin,
                     note: [fix.said + " → " + fix.natural, fix.why].compactMap { $0 }.joined(separator: "\n"))
        }
        if let flow = feedback.flow {
            flowTakeaway(flow)
        } else if let pattern = feedback.pattern {
            takeaway("Pattern", pattern.pattern, pinyin: nil, note: pattern.en, play: false)
        }
    }

    /// The flow note: his two sentences joined, and the transition that joins them.
    private func flowTakeaway(_ flow: DeckMandarinFeedback.Flow) -> some View {
        let word = flow.transition + (flow.en.map { " (\($0))" } ?? "")
        return takeaway("Flow", flow.joined, pinyin: flow.joinedPinyin,
                        note: [word, flow.why].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
    }

    private func retryLine(_ message: String) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: message)
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { Task { await practice.retry() } } label: {
                Text(verbatim: "Try again").font(AppFont.footnote(weight: .semibold)).foregroundStyle(palette.ink)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Parts

    private func heading(_ text: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: text)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(verbatim: detail).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
            }
        }
    }

    private func takeaway(_ tag: String, _ text: String, pinyin: String?, note: String?, play: Bool = true) -> some View {
        MandarinTakeaway(tag: tag, text: text, pinyin: pinyin, note: note, palette: palette, speaker: play ? speaker : nil)
            .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
    }

    private typealias Action = (label: String, symbol: String, run: () -> Void)

    /// The step's buttons: one filled (the way forward), at most one outlined.
    private func actions(primary: Action, secondary: Action? = nil, busy: Bool = false) -> some View {
        HStack(spacing: 8) {
            if let secondary {
                Button(action: secondary.run) {
                    Label { Text(verbatim: secondary.label) } icon: { Image(systemName: secondary.symbol) }
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .overlay(Capsule().strokeBorder(palette.ink, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button(action: primary.run) {
                Label { Text(verbatim: primary.label) } icon: { Image(systemName: primary.symbol) }
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(palette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    private func change(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2), update)
    }
}

extension DeckCard {
    /// The Mandarin card's question line: the deck's pinyin and English only belong to its own question.
    func mandarinQuestion(asked: String) -> (hanzi: String, pinyin: String?, english: String?) {
        guard asked == question else { return (asked, nil, nil) }
        return (asked, questionPinyin, questionEn)
    }
}

/// One thing to keep: a tag (Fix, New word, Pattern…), the Mandarin, its pinyin, a one-line lesson,
/// and ▶ to hear it when there is a speaker.
struct MandarinTakeaway: View {
    let tag: String
    let text: String
    let pinyin: String?
    let note: String?
    let palette: DeckPalette
    let speaker: MandarinSpeaker?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: tag)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
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

/// The day's phrases as English cues, each labeled by kind: tap one to peek at the Mandarin, an example
/// from his life and a one-line note. A phrase he used in his answer gets a check. Shown on the card
/// and above the answer while he dictates.
struct MandarinCueList: View {
    let phrases: [DeckPhrase]
    let used: Set<String>
    let palette: DeckPalette
    /// Nil in the answer sheet, where playing would fight the microphone.
    let speaker: MandarinSpeaker?

    @State private var peeking: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "Work these in · tap to peek")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.bottom, 2)
            ForEach(phrases, id: \.hanzi) { phrase in
                let isUsed = used.contains(phrase.hanzi)
                let isPeeking = peeking.contains(phrase.hanzi) || phrase.en == nil
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: isUsed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isUsed ? palette.ink : Color.hxTextSecondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if let kind = phrase.kindLabel {
                            Text(verbatim: kind).font(AppFont.caption(weight: .semibold)).foregroundStyle(palette.ink)
                        }
                        if let en = phrase.en { Text(verbatim: en).font(AppFont.subheadline()) }
                        if isPeeking {
                            Text(verbatim: phrase.hanzi).font(AppFont.body(weight: .semibold))
                            if let pinyin = phrase.pinyin {
                                Text(verbatim: pinyin).font(AppFont.footnote()).foregroundStyle(palette.ink)
                            }
                            if let example = phrase.example {
                                Text(verbatim: example).font(AppFont.subheadline()).padding(.top, 4)
                                if let pinyin = phrase.examplePinyin {
                                    Text(verbatim: pinyin).font(AppFont.footnote()).foregroundStyle(palette.ink)
                                }
                                if let en = phrase.exampleEn {
                                    Text(verbatim: en).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                                }
                            }
                            if let note = phrase.note {
                                Text(verbatim: note).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if isPeeking, let speaker {
                        Button { speaker.toggle(phrase.hanzi) } label: {
                            Image(systemName: speaker.speaking == phrase.hanzi ? "stop.fill" : "play.fill")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(palette.ink)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        if peeking.contains(phrase.hanzi) { peeking.remove(phrase.hanzi) } else { peeking.insert(phrase.hanzi) }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: [phrase.kindLabel, phrase.en, isPeeking ? phrase.hanzi : nil,
                                                    isPeeking ? phrase.example : nil].compactMap { $0 }.joined(separator: ". ")))
                .accessibilityValue(Text(verbatim: isUsed ? "Used" : ""))
                .accessibilityHint(Text(verbatim: isPeeking ? "" : "Shows the Mandarin"))
                .accessibilityAddTraits(.isButton)
            }
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

/// Make it yours: the cue's example on top, his versions by zh-CN dictation (or typed) below. Done
/// sends them for checking; closing with nothing said sends nothing.
struct MandarinVersionsSheet: View {
    let cue: DeckPhrase
    let palette: DeckPalette
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var voiceInput = ComposerVoiceInputController(fixedLocale: MandarinDictation.locale)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: cue.example ?? cue.hanzi)
                        .font(AppFont.display(style: .title3, weight: .semibold))
                        .foregroundStyle(palette.ink)
                    if let en = cue.exampleEn {
                        Text(verbatim: en).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(verbatim: "Two sentences with \(cue.hanzi) about your week")
                                .font(AppFont.body())
                                .foregroundStyle(Color.hxTextSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(palette.paper.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if let message = MandarinDictation.isAvailable
                    ? voiceInput.errorMessage
                    : "To answer by voice, add Chinese (Simplified) dictation in Settings › General › Keyboard." {
                    Text(verbatim: message)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar {
                if MandarinDictation.isAvailable {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            _ = voiceInput.scheduleToggle(currentDraft: text) { text = $0 }
                        } label: {
                            Image(systemName: voiceInput.state == .idle ? "mic" : "stop.circle.fill")
                        }
                        .accessibilityLabel(Text(verbatim: voiceInput.state == .idle ? "Speak in Mandarin" : "Stop dictation"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        voiceInput.stopKeepingTranscript()
                        dismiss()
                    } label: { Text(verbatim: "Done") }
                }
            }
            .toolbarBackground(palette.paper, for: .navigationBar)
        }
        .tint(palette.ink)
        .onAppear { isFocused = true }
        .onDisappear {
            voiceInput.stopKeepingTranscript()
            onDone(text)
        }
        .presentationDragIndicator(.visible)
    }
}

/// The Mandarin card's dictation: on-device zh-CN only, so the answer arrives as characters.
enum MandarinDictation {
    static let locale = Locale(identifier: "zh-CN")

    /// Whether this phone has the on-device Mandarin model; without it the card hides its mic.
    static var isAvailable: Bool { SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true }
}
