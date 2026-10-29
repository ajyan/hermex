import AVFoundation
import Speech
import SwiftUI

/// The Mandarin practice card. Before a call: whose turn it is, Call (or type instead), the week's
/// calls as day circles, and pips for the phrases the call will bring back. After: the words he
/// reached for, one line said better, what to work on, and the day's pattern with Practice it.
struct DeckMandarinCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let practice: MandarinPractice

    @State private var speaker = MandarinSpeaker()
    @State private var isPracticing = false
    @State private var phrasebook: MandarinPhrasebookModel?
    @Environment(\.openMockCall) private var openMockCall

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch practice.state {
            case .call: callState
            case .after: afterState
            }
            phrasebookLink
        }
        .onDisappear { speaker.stop() }
        .task { await practice.reviewIfNeeded() }
        .sheet(isPresented: $isPracticing) { MandarinPatternPractice(practice: practice, palette: palette) }
        .sheet(item: $phrasebook) { model in MandarinPhrasebookView(model: model, palette: palette) }
    }

    // MARK: Before the call

    @ViewBuilder
    private var callState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: MandarinCardCopy.turn(card.speaker))
                .font(AppFont.display(style: .title3, weight: .semibold))
                .foregroundStyle(palette.ink)
            Text(verbatim: MandarinCardCopy.asks(card.speaker))
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
        }
        if openMockCall.isAvailable {
            VStack(spacing: 10) {
                primaryButton(MandarinCardCopy.call(card.speaker), symbol: "phone.fill", busy: practice.isStartingCall) {
                    speaker.stop()
                    Task { await practice.startCall(open: openMockCall, typed: false) }
                }
                Button {
                    speaker.stop()
                    Task { await practice.startCall(open: openMockCall, typed: true) }
                } label: {
                    Text(verbatim: MandarinCardCopy.type(card.speaker))
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.plain)
                .disabled(practice.isStartingCall)
            }
        }
        if let error = practice.startCallError {
            Text(verbatim: error)
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        weekRow
        let pips = MandarinCardCopy.pips(due: card.mandarinDue)
        if pips > 0 {
            HStack {
                Text(verbatim: "Words coming back").font(AppFont.caption()).foregroundStyle(palette.ink)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    ForEach(0..<pips, id: \.self) { _ in Circle().fill(palette.ink).frame(width: 8, height: 8) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: pips == 1 ? "1 word coming back" : "\(pips) words coming back"))
        }
    }

    private static let weekdays = ["M", "T", "W", "T", "F", "S", "S"]
    private static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private var weekRow: some View {
        let days = MandarinWeekCircles.filled(week: card.mandarinWeek, date: practice.date, after: practice.state == .after)
        let today = MandarinWeekCircles.dayIndex(date: practice.date)
        return HStack {
            Text(verbatim: "This week").font(AppFont.caption()).foregroundStyle(palette.ink)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { index in
                    Text(verbatim: Self.weekdays[index])
                        .font(AppFont.caption2(weight: .semibold))
                        .foregroundStyle(days[index] ? palette.onInk : palette.ink)
                        .frame(width: 20, height: 20)
                        .background(days[index] ? palette.ink : Color.clear, in: Circle())
                        .overlay(Circle().strokeBorder(palette.ink, lineWidth: index == today ? 1.5 : 0.5))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "This week: " + {
            let called = days.indices.filter { days[$0] }.map { Self.weekdayNames[$0] }
            return called.isEmpty ? "no calls yet" : "called " + called.joined(separator: ", ")
        }()))
    }

    // MARK: After the call

    @ViewBuilder
    private var afterState: some View {
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
        if openMockCall.isAvailable, practice.reviewing != .waiting {
            secondaryButton("Call again", symbol: "phone") {
                speaker.stop()
                Task { await practice.startCall(open: openMockCall, typed: false) }
            }
            .disabled(practice.isStartingCall)
        }
    }

    @ViewBuilder
    private func reviewBlocks(_ review: MandarinCallReview) -> some View {
        if !review.reached.isEmpty {
            sectionTitle("Words you reached for")
            ForEach(Array(review.reached.enumerated()), id: \.offset) { _, word in
                MandarinTakeaway(tag: word.en ?? "", text: word.hanzi, pinyin: word.pinyin,
                                 note: word.said.map { "You said: " + $0 }, palette: palette, speaker: speaker)
            }
        }
        if let better = review.better {
            sectionTitle("Said better")
            MandarinTakeaway(tag: "Natural", text: better.natural, pinyin: better.naturalPinyin,
                             note: "You said: " + better.said, palette: palette, speaker: speaker)
        }
        if let focus = review.focus {
            sectionTitle("What to work on")
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: focus.advice)
                    .font(AppFont.body())
                    .fixedSize(horizontal: false, vertical: true)
                if let next = focus.next, !next.isEmpty {
                    Text(verbatim: "Next call: " + next)
                        .font(AppFont.footnote(weight: .medium))
                        .foregroundStyle(palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        if let pattern = review.pattern { patternBlock(pattern) }
    }

    @ViewBuilder
    private func patternBlock(_ pattern: MandarinPattern) -> some View {
        sectionTitle("Today's pattern")
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: pattern.name).font(AppFont.display(style: .title2, weight: .semibold)).foregroundStyle(palette.ink)
            if let use = pattern.use, !use.isEmpty {
                Text(verbatim: use).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: pattern.form)
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(palette.ink)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
        if let rebuilt = pattern.rebuilt, !rebuilt.isEmpty {
            MandarinTakeaway(tag: "With the pattern", text: rebuilt, pinyin: pattern.rebuiltPinyin,
                             note: pattern.said.map { "You said: " + $0 }, palette: palette, speaker: speaker)
        }
        ForEach(pattern.examples, id: \.self) { example in
            MandarinTakeaway(tag: "Example", text: example.hanzi, pinyin: example.pinyin, note: example.en,
                             palette: palette, speaker: speaker)
        }
        if !pattern.prompts.isEmpty {
            if practice.isPracticeDone {
                Label { Text(verbatim: "Practiced") } icon: { Image(systemName: "checkmark") }
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
            } else {
                primaryButton("Practice it", symbol: "mic.fill") { speaker.stop(); isPracticing = true }
            }
        }
    }

    // MARK: Parts

    private var phrasebookLink: some View {
        Button { speaker.stop(); phrasebook = practice.phrasebookModel() } label: {
            Label { Text(verbatim: "Phrasebook") } icon: { Image(systemName: "book.closed") }
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func primaryButton(_ label: String, symbol: String, busy: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label { Text(verbatim: label) } icon: { Image(systemName: symbol) }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(palette.onInk)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(palette.ink, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    private func secondaryButton(_ label: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label { Text(verbatim: label) } icon: { Image(systemName: symbol) }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, minHeight: 46)
                .overlay(Capsule().strokeBorder(palette.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
