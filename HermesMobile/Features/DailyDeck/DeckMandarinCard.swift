import AVFoundation
import Speech
import SwiftUI

/// The Mandarin practice card in steps, moved through by its segment bar: Fix yesterday's slips, Recall
/// the phrasebook's due phrases, make each cue Yours (say its example, then two versions about his
/// week, checked), Talk (the question, a transition, a feeling and an everyday cue, and the answer),
/// then the takeaways that come back seconds after answering, and telling it again without them. Everything he says, he says on the card.
struct DeckMandarinCard: View {
    let card: DeckCard
    let palette: DeckPalette
    /// The question on display: the deck's, or his own from "Ask My Own Question".
    let asked: String?
    let practice: MandarinPractice
    /// His Talk answer so far, and where a new one goes (kept with the deck's answers and sent for feedback).
    let answered: String?
    let onAnswer: (String) -> Void

    @State private var speaker = MandarinSpeaker()
    /// Fixes and recall phrases whose answer is showing.
    @State private var revealed: Set<String> = []
    /// What he said for each fix before seeing it, to set beside the natural way.
    @State private var attempts: [String: String] = [:]
    /// Talk: telling it again, with the feedback out of sight.
    @State private var retelling = false
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
        .onChange(of: practice.againText) { _, _ in retelling = false }  // a retried second telling landed
    }

    // MARK: Step bar

    /// One thin segment per step: done ones solid, the current one darkest, the rest faint.
    private var stepBar: some View {
        HStack(spacing: 4) {
            ForEach(practice.steps, id: \.self) { step in
                let isCurrent = practice.step == step
                let isDone = practice.isDone(step)
                Button { change { practice.step = step } } label: {
                    Capsule()
                        .fill(palette.ink.opacity(isCurrent ? 1 : isDone ? 0.5 : 0.15))
                        .frame(height: 4)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: title(step) + (isDone ? ", done" : "")))
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }

    private func title(_ step: MandarinPractice.Step) -> String {
        switch step {
        case .fix: "Fix"
        case .recall: "Recall"
        case .yours: "Make it yours"
        case .talk: "Talk"
        }
    }

    // MARK: Fix

    @ViewBuilder
    private var fixStep: some View {
        let yesterday = card.yesterday
        if let fix = practice.currentFix {
            let key = "fix:\(fix.said)"
            let isRevealed = revealed.contains(key)
            askHeading(fix.en.map { "“\($0)”" } ?? "Say it the natural way", pips: practice.fixes.count,
                       at: practice.fixes.firstIndex(of: fix) ?? 0,
                       showMe: isRevealed ? nil : { change { _ = revealed.insert(key) } })
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Yesterday you said")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                Text(slip(in: yesterday?.said ?? fix.said, fix.said))
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if isRevealed {
                attempt(key)
                takeaway("Natural", fix.natural, pinyin: fix.naturalPinyin, note: fix.why)
                actions(primary: ("Next", "arrow.right", { change { practice.nextFix() } }))
            } else {
                tryMic(key, prompt: "Say it in Mandarin")
            }
        } else if practice.fixes.isEmpty, let yesterday {
            heading("Yesterday, said naturally", detail: nil)
            if let said = yesterday.said {
                Text(verbatim: said).font(AppFont.body()).foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            takeaway("Natural", yesterday.natural, pinyin: yesterday.naturalPinyin, note: nil)
            if let flow = yesterday.flow { flowRow(flow) }
            if !practice.isDone(.fix) {
                actions(primary: ("Next", "arrow.right", { change { practice.nextFix() } }))
            }
        } else {
            heading("Yesterday's fixes", detail: nil)
            ForEach(practice.fixes, id: \.self) { fix in
                row("Fix", fix.natural, pinyin: fix.naturalPinyin, note: [fix.said + " → " + fix.natural, fix.why]
                    .compactMap { $0 }.joined(separator: "\n"))
            }
            if let flow = yesterday?.flow { flowRow(flow) }
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

    /// One due phrase from his English: say it, see it, then use it in a sentence of his own (checked
    /// like Make it yours), and Got it or Again. The finished list comes back as a review.
    @ViewBuilder
    private var recallStep: some View {
        if let phrase = practice.currentRecall {
            let key = "recall:\(phrase.hanzi)"
            let isRevealed = revealed.contains(key)
            askHeading(phrase.en.map { "“\($0)”" } ?? phrase.hanzi, pips: card.recall.count,
                       at: card.recall.firstIndex(of: phrase) ?? 0,
                       showMe: isRevealed ? nil : { change { _ = revealed.insert(key) } })
            if isRevealed {
                attempt(key)
                takeaway(source(phrase), phrase.hanzi, pinyin: phrase.pinyin, note: nil)
                if let checked = practice.record.versions[phrase.hanzi] { versionsBlock(checked) }
                MandarinMic(prompt: sentencePrompt(practice.record.versions[phrase.hanzi], phrase: phrase),
                            palette: palette, isBusy: practice.checkingCue == phrase.hanzi,
                            onListen: { speaker.stop() }) { text in
                    await practice.checkVersions(of: phrase, text)
                }
                .id("sentence:\(phrase.hanzi)")
                if let error = practice.versionsError {
                    Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                }
                actions(primary: ("Got it", "checkmark", { Task { await practice.recall(phrase, got: true) } }),
                        secondary: ("Again", "arrow.counterclockwise", { Task { await practice.recall(phrase, got: false) } }),
                        busy: practice.isSavingRecall || practice.checkingCue != nil)
            } else {
                tryMic(key, prompt: "Say it in Mandarin")
            }
            if let error = practice.recallError {
                Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
            }
        } else {
            heading("All recalled", detail: "They come back on their own schedule.")
            ForEach(card.recall, id: \.hanzi) { phrase in
                let got = practice.record.recalled[phrase.hanzi]
                row(got == false ? "Again tomorrow" : phrase.en ?? source(phrase), phrase.hanzi, pinyin: phrase.pinyin, note: nil)
                if let checked = practice.record.versions[phrase.hanzi] { versionsBlock(checked) }
            }
        }
    }

    /// What the sentence mic asks for: one with the phrase, another, or one that really uses it.
    private func sentencePrompt(_ checked: MandarinVersionsResponse?, phrase: DeckPhrase) -> String {
        guard let checked else { return "Now use it in a sentence about your week" }
        if !checked.used { return "Try one with \(phrase.hanzi)" }
        return "Another, or Got it"
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
            let checked = practice.record.versions[cue.hanzi]
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                headingRow("Make it yours", pips: cues.count, at: cues.firstIndex(of: cue) ?? 0)
                Button { change { practice.nextCue() } } label: {
                    Text(verbatim: checked == nil ? "Skip" : "Next")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(practice.checkingCue != nil)
            }
            takeaway(cue.kindLabel ?? "Phrase", cue.hanzi, pinyin: cue.pinyin, note: cue.en)
            row("Example", example, pinyin: cue.examplePinyin, note: cue.exampleEn)
            if let checked { versionsBlock(checked) }
            MandarinMic(prompt: yoursPrompt(checked, cue: cue), palette: palette,
                        isBusy: practice.checkingCue == cue.hanzi, onListen: { speaker.stop() }) { text in
                let ok = await practice.checkVersions(of: cue, text)
                if ok, practice.record.versions[cue.hanzi]?.isClean == true { moveOn(from: cue) }
                return ok
            }
            .id(cue.hanzi)
            if let error = practice.versionsError {
                Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
            }
        } else {
            heading("All yours", detail: "Now use them in Talk.")
            ForEach(cues.filter { practice.record.versions[$0.hanzi] != nil }, id: \.hanzi) { cue in
                Text(verbatim: [cue.kindLabel, cue.hanzi].compactMap { $0 }.joined(separator: " · "))
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, 4)
                if let checked = practice.record.versions[cue.hanzi] { versionsBlock(checked) }
            }
        }
    }

    /// What the mic asks for next: the example and two of his own, one more, or one that uses the cue.
    private func yoursPrompt(_ checked: MandarinVersionsResponse?, cue: DeckPhrase) -> String {
        guard let checked else { return "Say the example, then two of your own with \(cue.hanzi)" }
        if !checked.used { return "Now one with \(cue.hanzi)" }
        if checked.versions.count < 2 { return "One more with \(cue.hanzi)" }
        return "Another with \(cue.hanzi), or Next"
    }

    /// Two clean versions: a beat to see the checks, then the next cue (unless he has already moved).
    private func moveOn(from cue: DeckPhrase) {
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard practice.currentCue == cue else { return }
            change { practice.nextCue() }
        }
    }

    /// His versions: a fine one as he said it with a check, one that needs it as the natural way and why.
    @ViewBuilder
    private func versionsBlock(_ checked: MandarinVersionsResponse) -> some View {
        ForEach(checked.versions, id: \.self) { version in
            if let natural = version.natural {
                row("Better", natural, pinyin: version.naturalPinyin,
                    note: [version.said + " → " + natural, version.why].compactMap { $0 }.joined(separator: "\n"))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark").font(AppFont.footnote(weight: .bold)).foregroundStyle(palette.ink)
                        .accessibilityHidden(true)
                    Text(verbatim: version.said).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(verbatim: "Natural"))
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
            }
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
        if let pattern = card.pattern {
            takeaway("Today's pattern", pattern.form ?? pattern.name, pinyin: nil,
                     note: [pattern.name, pattern.en].compactMap { $0 }.joined(separator: "\n"), play: false)
        }
        if !card.phrases.isEmpty {
            MandarinCueChips(phrases: card.phrases, used: Set(practice.usedCues), palette: palette, speaker: speaker)
        }
        if retelling {
            MandarinMic(prompt: "Tell it again, a little longer", palette: palette,
                        isBusy: practice.answering == .waiting, onListen: { speaker.stop() }) { text in
                let told = await practice.tellAgain(text)
                if told { change { retelling = false } }
                return told
            }
            if case let .failed(message) = practice.answering { retryLine(message) }
            Button { change { retelling = false } } label: {
                Text(verbatim: "Back to the feedback")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(practice.answering == .waiting)
        } else if let again = practice.againText {
            telling("First time", answered ?? "")
            telling("Second time", again)
            takeaways(for: practice.againResult)
            tellAgainButton
        } else {
            telling("You said", answered ?? "")
            if practice.result?.feedback == nil {
                MandarinMic(prompt: talkPrompt, palette: palette, isBusy: practice.answering == .waiting,
                            editing: answered, onListen: { speaker.stop() }) { text in
                    onAnswer(text)
                    return true
                }
            }
            takeaways(for: practice.result)
            if practice.result?.feedback != nil, practice.answering == .idle { tellAgainButton }
        }
    }

    private var talkPrompt: String {
        if answered?.isEmpty == false { return "Say it again" }
        return card.mandarinTellsAStory ? "What happened → how you felt → what's next" : "Answer out loud"
    }

    /// One telling of his answer: what he said, under its tag. Nothing when he hasn't said anything.
    @ViewBuilder
    private func telling(_ tag: String, _ text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: tag)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(verbatim: text)
                    .font(AppFont.body())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// After the feedback: tell the same story again with it out of sight.
    private var tellAgainButton: some View {
        actions(primary: ("Tell it again", "arrow.counterclockwise", {
            speaker.stop()
            change { retelling = true }
        }))
    }

    @ViewBuilder
    private func takeaways(for result: MandarinAnswerResponse?) -> some View {
        switch practice.answering {
        case .waiting:
            EmptyView()
        case let .failed(message):
            retryLine(message)
        case .idle:
            if let result {
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
        takeaway("Said naturally", feedback.natural, pinyin: feedback.naturalPinyin, note: nil)
        ForEach(feedback.gaps, id: \.self) { gap in
            row("New word", gap.hanzi, pinyin: gap.pinyin,
                note: [gap.en, gap.build].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
        }
        ForEach(feedback.fixes, id: \.self) { fix in
            row("Fix", fix.natural, pinyin: fix.naturalPinyin,
                note: [fix.said + " → " + fix.natural, fix.why].compactMap { $0 }.joined(separator: "\n"))
        }
        if let flow = feedback.flow {
            flowRow(flow)
        } else if let pattern = feedback.pattern {
            row("Pattern", pattern.pattern, pinyin: nil, note: pattern.en, play: false)
        }
    }

    /// The flow note: his two sentences joined, and the transition that joins them.
    private func flowRow(_ flow: DeckMandarinFeedback.Flow) -> some View {
        let word = flow.transition + (flow.en.map { " (\($0))" } ?? "")
        return row("Flow", flow.joined, pinyin: flow.joinedPinyin,
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

    /// "How would you say" over his English as the heading, with pips and, until it shows, Show me.
    private func askHeading(_ text: String, pips count: Int, at index: Int, showMe: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "How would you say")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
                headingRow(text, pips: count, at: index)
            }
            if let showMe {
                Button(action: showMe) {
                    Text(verbatim: "Show me")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The mic for a first try: what he says is kept beside the answer it then shows.
    private func tryMic(_ key: String, prompt: String) -> some View {
        MandarinMic(prompt: prompt, palette: palette, onListen: { speaker.stop() }) { text in
            attempts[key] = text
            change { _ = revealed.insert(key) }
            return true
        }
        .id(key)
    }

    /// His first try, once the answer shows.
    @ViewBuilder
    private func attempt(_ key: String) -> some View {
        if let tried = attempts[key] {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "You tried")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(verbatim: tried).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

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

    /// A heading with a pip per item (the current one filled) when there is more than one.
    private func headingRow(_ text: String, pips count: Int, at index: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            heading(text, detail: nil)
            if count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { pip in
                        Circle()
                            .fill(palette.ink.opacity(pip <= index ? 1 : 0.2))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "\(index + 1) of \(count)"))
            }
            Spacer(minLength: 0)
        }
    }

    private func takeaway(_ tag: String, _ text: String, pinyin: String?, note: String?, play: Bool = true) -> some View {
        MandarinTakeaway(tag: tag, text: text, pinyin: pinyin, note: note, palette: palette, speaker: play ? speaker : nil)
            .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
    }

    private func row(_ tag: String, _ text: String, pinyin: String?, note: String?, play: Bool = true) -> some View {
        MandarinRow(tag: tag, text: text, pinyin: pinyin, note: note, palette: palette, speaker: play ? speaker : nil)
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
                        .foregroundStyle(Color.hxTextSecondary)
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
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { peeking = isOpen ? nil : phrase.hanzi }
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

/// Speaking on the card: a big mic writes his Mandarin as he says it (zh-CN, on device), and stop hands
/// the words to `onFinish`. The keyboard button types instead. `onFinish` returns whether the words were
/// taken, so a failed check keeps them to send again.
struct MandarinMic: View {
    let prompt: String
    let palette: DeckPalette
    var isBusy = false
    /// What typing starts from when nothing is said yet: his earlier answer, to edit.
    var editing: String?
    /// Called as listening starts, so nothing on the card plays over the mic.
    var onListen: () -> Void = {}
    let onFinish: (String) async -> Bool

    @State private var text = ""
    @State private var isTyping = !MandarinDictation.isAvailable
    @State private var voiceInput = ComposerVoiceInputController(fixedLocale: MandarinDictation.locale)
    @FocusState private var isFocused: Bool

    private var isListening: Bool { voiceInput.state != .idle }
    private var said: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isTyping {
                TextField(text: $text, axis: .vertical) { Text(verbatim: "Type in Mandarin") }
                    .font(AppFont.body())
                    .focused($isFocused)
                    .padding(12)
                    .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            } else if !text.isEmpty {
                Text(verbatim: text)
                    .font(AppFont.body())
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(verbatim: status)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if MandarinDictation.isAvailable, !isListening, !isBusy {
                    Button { toggleTyping() } label: {
                        Image(systemName: isTyping ? "mic" : "keyboard")
                            .font(AppFont.body(weight: .medium))
                            .foregroundStyle(palette.ink)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: isTyping ? "Speak instead" : "Type instead"))
                }
                mainButton
            }
            if let message = voiceInput.errorMessage {
                Text(verbatim: message)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { voiceInput.stopKeepingTranscript() }
    }

    private var status: String {
        if isBusy { return "Checking…" }
        if isListening { return "Listening… tap stop when you're done" }
        return prompt
    }

    @ViewBuilder
    private var mainButton: some View {
        let symbol = isListening ? "stop.fill" : isTyping ? "arrow.up" : "mic.fill"
        Button { isListening ? finish() : isTyping ? finish() : listen() } label: {
            ZStack {
                Circle().fill(palette.ink)
                if isBusy {
                    ProgressView().tint(palette.onInk)
                } else {
                    Image(systemName: symbol)
                        .font(AppFont.title3(weight: .semibold))
                        .foregroundStyle(palette.onInk)
                }
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .disabled(isBusy || (isTyping && said.isEmpty))
        .opacity(isTyping && said.isEmpty && !isBusy ? 0.4 : 1)
        .accessibilityLabel(Text(verbatim: isListening ? "Stop and check" : isTyping ? "Check" : "Speak in Mandarin"))
    }

    private func listen() {
        onListen()
        _ = voiceInput.scheduleToggle(currentDraft: text) { text = $0 }
    }

    private func toggleTyping() {
        isTyping.toggle()
        if isTyping, text.isEmpty, let editing { text = editing }
        isFocused = isTyping
    }

    private func finish() {
        voiceInput.stopKeepingTranscript()
        let words = said
        guard !words.isEmpty else { return }
        isFocused = false
        Task {
            guard await onFinish(words) else { return }
            text = ""
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
