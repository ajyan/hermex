import AVFoundation
import Speech
import SwiftUI

/// The Mandarin practice card in four steps, chosen from its step bar: Recall the phrasebook's due
/// phrases, Prep (chunks said aloud, then a first telling of the day's story), the Call with Mom or
/// Dad (or "Type it instead": the question, today's pattern, the phrases to work in, the answer and
/// its takeaways), then After: Try again on two moments, the call's takeaways and its fluency.
/// `answer` is the deck's own answer button (or his words once written).
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
    /// What the Mandarin dictation sheet is for: the first telling, or saying a moment again.
    @State private var speaking: MandarinSpeakTarget?
    @Environment(\.openMockCall) private var openMockCall
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepBar.padding(.trailing, 30)
            switch practice.step {
            case .recall: recallStep
            case .prep: prepStep
            case .call: callStep
            case .after: afterStep
            }
        }
        .onDisappear { speaker.stop() }
        .task { await practice.reviewIfNeeded() }
        .sheet(isPresented: $isCalling) { MandarinCallSheet(practice: practice, palette: palette) }
        .sheet(item: $speaking) { target in speakSheet(target) }
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
        case .recall: "Recall \(card.recall.count)"
        case .prep: "Prep"
        case .call: "Call"
        case .after: "After"
        }
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
        default: "Phrase"
        }
    }

    // MARK: Prep

    @ViewBuilder
    private var prepStep: some View {
        heading("Say each one out loud, twice", detail: "Then tell today's story once.")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(card.chunks, id: \.hanzi) { chunk in chunkRow(chunk) }
        }
        if !card.beats.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Today's story")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
                ForEach(card.beats, id: \.self) { beat in
                    Text(verbatim: "· " + beat)
                        .font(AppFont.footnote())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if let telling = practice.record.telling {
            takeaway("First telling", telling, pinyin: nil, note: nil, play: false)
        }
        actions(primary: (practice.record.telling == nil ? "Tell it once" : "Tell it again", "mic",
                          { speaker.stop(); speaking = .telling }))
    }

    private func chunkRow(_ chunk: DeckChunk) -> some View {
        let said = practice.record.saidChunks.contains(chunk.hanzi)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: chunk.hanzi).font(AppFont.display(style: .title3, weight: .semibold))
                if let pinyin = chunk.pinyin {
                    Text(verbatim: pinyin).font(AppFont.footnote(weight: .medium)).foregroundStyle(palette.ink)
                }
                if let en = chunk.en {
                    Text(verbatim: en).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Button { speaker.toggle(chunk.hanzi) } label: {
                Image(systemName: speaker.speaking == chunk.hanzi ? "stop.fill" : "play.fill")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Play \(chunk.hanzi)"))
            Button { change { practice.markSaid(chunk.hanzi) } } label: {
                HXChip(paper: palette.colors, symbol: said ? "checkmark" : nil, label: "Said it")
            }
            .buttonStyle(.plain)
            .disabled(said)
            .accessibilityValue(Text(verbatim: said ? "Done" : ""))
        }
        .padding(.vertical, 8)
    }

    // MARK: Call

    @ViewBuilder
    private var callStep: some View {
        if practice.record.isTyping {
            talkStep
        } else {
            if let situation = card.title {
                Text(verbatim: situation)
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let asked {
                let line = card.mandarinQuestion(asked: asked)
                takeaway("\(practice.speakerName) asks", line.hanzi, pinyin: line.pinyin, note: line.english)
            }
            if openMockCall.isAvailable {
                actions(primary: ("Call \(practice.speakerName)", "phone.fill", {
                            speaker.stop()
                            Task { await practice.startCall(open: openMockCall) }
                        }),
                        secondary: ("Type it instead", "keyboard", { change { practice.typeInstead() } }),
                        busy: practice.isStartingCall)
            } else {
                actions(primary: ("Type it instead", "keyboard", { change { practice.typeInstead() } }))
            }
            if let error = practice.startCallError {
                Text(verbatim: error)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: After

    @ViewBuilder
    private var afterStep: some View {
        switch practice.reviewing {
        case .waiting:
            HStack(spacing: 10) {
                ProgressView()
                Text(verbatim: "Reviewing your call…").font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
            }
        case let .failed(message):
            HStack(spacing: 12) {
                Text(verbatim: message).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                Spacer(minLength: 0)
                Button { Task { await practice.reviewIfNeeded() } } label: {
                    Text(verbatim: "Retry").font(AppFont.footnote(weight: .semibold)).foregroundStyle(palette.ink)
                }
                .buttonStyle(.plain)
            }
        case .idle:
            if let review = practice.record.review { reviewBlocks(review) }
        }
    }

    @ViewBuilder
    private func reviewBlocks(_ review: MandarinCallReview) -> some View {
        if !review.moments.isEmpty {
            heading("Try again", detail: "Say it again your way, then see the natural way.")
            ForEach(Array(review.moments.enumerated()), id: \.offset) { index, moment in
                momentRow(index, moment)
            }
        }
        Text(verbatim: "Takeaways")
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.top, 4)
        ForEach(review.naturalTurns, id: \.self) { turn in
            takeaway("Natural", turn.natural, pinyin: turn.naturalPinyin, note: "You said: " + turn.said)
        }
        if !review.chunksUsed.isEmpty || !review.chunksMissed.isEmpty {
            Text(verbatim: (review.chunksUsed.map { "✓ " + $0 } + review.chunksMissed.map { "○ " + $0 }).joined(separator: "  "))
                .font(AppFont.footnote())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: "Used " + review.chunksUsed.joined(separator: ", ")
                                         + ". Missed " + review.chunksMissed.joined(separator: ", ")))
        }
        ForEach([MandarinFluencyLine.text(review.fluency),
                 MandarinFluencyLine.telling(review.telling, call: review.fluency),
                 MandarinFluencyLine.lastWeek(practice.progress)].compactMap { $0 }, id: \.self) { line in
            Text(verbatim: line)
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func momentRow(_ index: Int, _ moment: MandarinCallReview.Moment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: moment.said)
                .font(AppFont.body())
                .fixedSize(horizontal: false, vertical: true)
            if let again = practice.record.retries[index] {
                Text(verbatim: "Again: " + again)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if practice.record.revealed.contains(index) {
            takeaway("Natural", moment.natural, pinyin: moment.naturalPinyin,
                     note: [moment.en, moment.why].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n"))
        } else {
            actions(primary: ("Show the natural way", "eye", { change { practice.reveal(index) } }),
                    secondary: ("Say it again", "mic", { speaker.stop(); speaking = .retry(index) }))
        }
    }

    // MARK: Dictation

    @ViewBuilder
    private func speakSheet(_ target: MandarinSpeakTarget) -> some View {
        switch target {
        case .telling:
            MandarinSpeakSheet(prompt: "Tell today's story in Mandarin", detail: card.beats.map { "· " + $0 }.joined(separator: "\n"),
                               initial: practice.record.telling ?? "", palette: palette) { text in
                Task { await practice.tell(text) }
            }
        case .retry(let index):
            let moments = practice.record.review?.moments ?? []
            let moment = moments.indices.contains(index) ? moments[index] : nil
            MandarinSpeakSheet(prompt: moment?.en ?? "Say it again", detail: moment?.said,
                               initial: practice.record.retries[index] ?? "", palette: palette) { text in
                practice.retry(index, text: text)
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
            MandarinCueList(phrases: card.phrases, used: Set(practice.result?.used ?? []), palette: palette,
                            speaker: speaker)
        }
        answer()
        if practice.record.isTyping, openMockCall.isAvailable {
            Button { change { practice.callInstead() } } label: {
                Text(verbatim: "Call \(practice.speakerName) instead")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
            }
            .buttonStyle(.plain)
        }
        takeaways
        if let progress = practice.progress, let line = MandarinProgressLine.text(progress) {
            Text(verbatim: line)
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        familyCallButton
    }

    /// The real call with his parents: three things to say before, and what he couldn't say after.
    private var familyCallButton: some View {
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
                    feedbackBlocks(feedback, used: result.used)
                } else {
                    retryLine("Feedback comes with tomorrow's card.")
                }
            }
        }
    }

    @ViewBuilder
    private func feedbackBlocks(_ feedback: DeckMandarinFeedback, used: [String]) -> some View {
        Text(verbatim: "Takeaways")
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.top, 4)
        let cues = card.phrases.count
        takeaway("Natural", feedback.natural, pinyin: feedback.naturalPinyin,
                 note: cues == 0 ? nil : "Used \(used.count) of \(cues) phrases" + (used.isEmpty ? "" : ": " + used.joined(separator: " ")))
        ForEach(feedback.gaps, id: \.self) { gap in
            takeaway("New word", gap.hanzi, pinyin: gap.pinyin,
                     note: [gap.en, gap.build].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
        }
        ForEach(feedback.fixes, id: \.self) { fix in
            takeaway("Fix", fix.natural, pinyin: fix.naturalPinyin,
                     note: [fix.said + " → " + fix.natural, fix.why].compactMap { $0 }.joined(separator: "\n"))
        }
        if let pattern = feedback.pattern {
            takeaway("Pattern", pattern.pattern, pinyin: nil, note: pattern.en, play: false)
        }
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

/// What the card's Mandarin dictation sheet is for.
enum MandarinSpeakTarget: Identifiable, Hashable {
    case telling
    case retry(Int)

    var id: String {
        switch self {
        case .telling: "telling"
        case .retry(let index): "retry:\(index)"
        }
    }
}

/// Speaking Mandarin into the card: the prompt on the card's paper, on-device zh-CN dictation (or
/// typing), and Done hands back the words.
struct MandarinSpeakSheet: View {
    let prompt: String
    let detail: String?
    let initial: String
    let palette: DeckPalette
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var voiceInput = ComposerVoiceInputController(fixedLocale: MandarinDictation.locale)

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: prompt)
                    .font(AppFont.display(style: .title3, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextEditor(text: $text)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(verbatim: "Say it out loud in Mandarin, or type")
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
                    : "To speak, add Chinese (Simplified) dictation in Settings › General › Keyboard." {
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
                        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !words.isEmpty { onDone(words) }
                        dismiss()
                    } label: { Text(verbatim: "Done") }
                }
            }
            .toolbarBackground(palette.paper, for: .navigationBar)
        }
        .tint(palette.ink)
        .onAppear {
            text = initial
            isFocused = true
        }
        .onDisappear { voiceInput.stopKeepingTranscript() }
        .presentationDragIndicator(.visible)
    }
}

/// The Mandarin call's fluency lines: "Wait 1.4 s · English 3 · Restarts 1 · 14 characters a turn",
/// last week's the same way, and the first telling against the call.
enum MandarinFluencyLine {
    static func text(_ fluency: MandarinFluency?) -> String? {
        guard let fluency else { return nil }
        let parts = [fluency.waitMsP50.map { "Wait \(seconds($0)) s" },
                     fluency.english.map { "English \(number($0))" },
                     fluency.restarts.map { "Restarts \(number($0))" },
                     fluency.charsPerTurn.map { "\(Int($0.rounded())) characters a turn" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func lastWeek(_ progress: DeckMandarinProgress?) -> String? {
        guard let line = text(progress?.callBefore) else { return nil }
        return "Last week: " + (line.hasPrefix("Wait") ? "w" + line.dropFirst() : line)
    }

    static func telling(_ telling: MandarinFluency?, call: MandarinFluency?) -> String? {
        guard let before = telling?.english, let after = call?.english else { return nil }
        return "First telling: English \(number(before)) → on the call \(number(after))"
    }

    private static func seconds(_ ms: Double) -> String { String(format: "%.1f", ms / 1000) }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
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

/// The day's phrases as English cues: tap one to peek at the Mandarin. A phrase he used in his
/// answer gets a check. Shown on the card and above the answer while he dictates.
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
                        if let en = phrase.en { Text(verbatim: en).font(AppFont.subheadline()) }
                        if isPeeking {
                            Text(verbatim: phrase.hanzi).font(AppFont.body(weight: .semibold))
                            if let pinyin = phrase.pinyin {
                                Text(verbatim: pinyin).font(AppFont.footnote()).foregroundStyle(palette.ink)
                            }
                        }
                    }
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
                .accessibilityLabel(Text(verbatim: [phrase.en, isPeeking ? phrase.hanzi : nil].compactMap { $0 }.joined(separator: ". ")))
                .accessibilityValue(Text(verbatim: isUsed ? "Used" : ""))
                .accessibilityHint(Text(verbatim: isPeeking ? "" : "Shows the Mandarin"))
                .accessibilityAddTraits(.isButton)
            }
        }
    }
}

/// The progress line: "36 phrases · 6 used this week · English per answer 2.8 → 1.2".
enum MandarinProgressLine {
    static func text(_ progress: DeckMandarinProgress) -> String? {
        var parts: [String] = []
        if let phrases = progress.phrases { parts.append(phrases == 1 ? "1 phrase" : "\(phrases) phrases") }
        if let used = progress.usedWeek { parts.append("\(used) used this week") }
        if let now = progress.englishNow {
            parts.append("English per answer " + (progress.englishBefore.map { "\(number($0)) → " } ?? "") + number(now))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
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
