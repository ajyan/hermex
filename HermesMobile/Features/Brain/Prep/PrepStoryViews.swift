import SwiftUI

// The story rep's cards: the telling (the prompt, an m:ss clock, the transcript and a tap-to-talk
// mic), its graded result, and up to two follow-up probes. Like every run card they are `.prep`
// glow cards; the mic is a control, so it alone wears Nous blue. Only the sample telling is serif.

/// Tap to talk: on-device dictation into the answer, punctuated as it is heard and tidied on Stop,
/// with "Original" to put back the raw words. Capture stops when the answer is sent, the card goes
/// away, or the app leaves the foreground.
struct PrepStoryMicButton: View {
    @Binding var text: String
    let isSubmitting: Bool
    /// The first tap that starts listening, before any words arrive.
    var onStart: () -> Void = {}
    /// The card's main control: a filled Nous-blue capsule, because an interview answer is spoken.
    var prominent = true
    @State private var dictation = DictationModel()
    @Environment(\.dictationServer) private var server

    private var isListening: Bool { dictation.voiceInput.isListening }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            Button {
                if dictation.voiceInput.state == .idle { onStart() }
                dictation.server = server
                dictation.toggle($text)
            } label: {
                Label {
                    Text(verbatim: dictation.isTidying ? "Tidying…" : isListening ? "Listening · tap to stop" : "Tap to talk")
                } icon: {
                    if dictation.isTidying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isListening ? "stop.circle.fill" : "mic.fill")
                    }
                }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(prominent ? Color.hxOnAccent : Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: prominent ? 56 : BrainStyle.minTapTarget)
                .background(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.hxSurface), in: Capsule())
                .overlay(Capsule().strokeBorder(prominent ? Color.clear : Color.hxSeparator, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || dictation.isTidying || dictation.voiceInput.isRequestingPermission)
            .accessibilityLabel(Text(verbatim: dictation.isTidying ? "Tidying your words"
                : isListening ? "Stop dictation" : "Tap to talk"))
            .accessibilityHint(Text(verbatim: isListening ? "" : DictationCopy.micHint))
            if dictation.canUndoTidy {
                DictationOriginalButton(dictation: dictation)
            }
            if let message = dictation.voiceInput.errorMessage {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dictationLifecycle(dictation, text: text, isSubmitting: isSubmitting)
        .preference(key: PrepMicBusyKey.self, value: dictation.isBusy)
    }
}

/// True while any Prep mic is listening, transcribing or tidying. Submitting then would cancel the
/// dictation and send only what was typed, so the run screen holds Submit and Send until it settles.
struct PrepMicBusyKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The answer field shared by the telling and the probes.
private struct PrepStoryAnswerField: View {
    let placeholder: String
    @Binding var text: String
    let isSubmitting: Bool

    var body: some View {
        TextField(text: $text, axis: .vertical) { Text(verbatim: placeholder) }
            .font(AppFont.body())
            .lineLimit(3...14)
            .disabled(isSubmitting)
            .padding(BrainStyle.m)
            .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous)
                .strokeBorder(Color.hxSeparator, lineWidth: 0.5))
            .accessibilityLabel(Text(verbatim: "Your answer"))
    }
}

/// The story clock: elapsed m:ss, amber from 3:30, and "Over 4:00" past the limit. Text only, so it
/// ticks without animation.
private struct PrepStoryClock: View {
    let elapsedMS: Int

    var body: some View {
        let state = PrepCopy.storyClockState(elapsedMS)
        HStack(spacing: BrainStyle.xs) {
            if let text = state.text {
                Text(verbatim: text)
            }
            Text(verbatim: PrepCopy.storyClock(elapsedMS))
                .monospacedDigit()
        }
        .font(AppFont.body(weight: .semibold))
        .foregroundStyle(state == .normal ? Color.hxTextSecondary : Color.hxWarning)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ["Time", PrepCopy.storyClock(elapsedMS), state.text]
            .compactMap { $0 }.joined(separator: ", ")))
    }
}

/// Telling the story: the signal and the running clock (once started, from the first mic tap or word), the story to
/// tell and the interview prompt, its beats as cues (a label in the glow, a few words beside it), the mic as the
/// card's main control, then the transcript to correct. A story told on time last rep folds its cues to their labels
/// behind "Peek at the cues" (a hint), and the full script waits behind "Show script" once the cues are showing.
/// Submit is the run's pinned button.
struct PrepStoryTellCard: View {
    let prompt: String
    var title: String = ""
    var signal: String = ""
    var cues: [PrepStoryCue] = []
    var script: String = ""
    /// When the clock started; nil shows 0:00 without ticking. While submitting it stops ticking.
    let startedAt: Date?
    let elapsedMS: () -> Int
    @Binding var draft: String
    let isSubmitting: Bool
    let startClock: () -> Void
    /// Cues folded to their labels until peeked (`PrepRep.cuesHidden`).
    var cuesHidden = false
    var peeked = false
    var peek: () -> Void = {}
    @State private var showsScript = false
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 76
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        PrepRunCard {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: signal.isEmpty ? "Tell a story" : signal)
                    .font(BrainStyle.meta)
                    .foregroundStyle(HermexPaper.prep.glow)
                Spacer(minLength: BrainStyle.s)
                if startedAt != nil && !isSubmitting {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        PrepStoryClock(elapsedMS: elapsedMS())
                    }
                } else if startedAt != nil {
                    // Held at the moment the story was sent while it is graded; nothing shows before it starts.
                    PrepStoryClock(elapsedMS: elapsedMS())
                }
            }
            Text(verbatim: title.isEmpty ? prompt : title)
                .font(AppFont.display(style: .title3))
                .foregroundStyle(title.isEmpty ? Color.hxTextPrimary : HermexPaper.prep.glow)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !title.isEmpty {
                Text(verbatim: prompt)
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !cues.isEmpty && cuesHidden && !peeked {
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    Text(verbatim: cues.map(\.label).joined(separator: " · "))
                        .font(BrainStyle.meta.weight(.semibold))
                        .foregroundStyle(HermexPaper.prep.glow)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: peek) {
                        Text(verbatim: "Peek at the cues")
                            .font(BrainStyle.rowSubtitle)
                            .foregroundStyle(Color.accentColor)
                            .frame(minHeight: BrainStyle.minTapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(verbatim: "Shows each beat's cue. Counts as a hint."))
                }
            } else if !cues.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    ForEach(cues) { cue in
                        // At accessibility sizes the label sits over its cue, so the cue keeps the full width.
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: BrainStyle.m))
                        layout {
                            Text(verbatim: cue.label)
                                .font(AppFont.body(weight: .semibold))
                                .foregroundStyle(HermexPaper.prep.glow)
                                .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : labelWidth, alignment: .leading)
                            Text(verbatim: cue.cue)
                                .font(BrainStyle.rowTitle)
                                .foregroundStyle(Color.hxTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if showsScript && !script.isEmpty {
                Text(inlineMarkdown(script))
                    .brainText(.quote)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            PrepStoryMicButton(text: $draft, isSubmitting: isSubmitting, onStart: startClock)
            PrepStoryAnswerField(placeholder: "Your words appear here. Or type.", text: $draft, isSubmitting: isSubmitting)
            if !script.isEmpty && !(cuesHidden && !peeked) {
                Button {
                    showsScript.toggle()
                } label: {
                    Text(verbatim: showsScript ? "Hide script" : "Show script")
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A follow-up probe: the attack to answer, out loud or typed.
struct PrepProbeCard: View {
    let prompt: String
    let probe: PrepProbe
    let number: Int
    @Binding var draft: String
    let isSubmitting: Bool

    var body: some View {
        PrepRunCard {
            Text(verbatim: PrepCopy.probeLabel(number))
                .font(BrainStyle.meta)
                .foregroundStyle(HermexPaper.prep.glow)
            if !prompt.isEmpty {
                Text(verbatim: prompt)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: probe.attack)
                .font(AppFont.display(style: .title3))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            PrepStoryMicButton(text: $draft, isSubmitting: isSubmitting)
            PrepStoryAnswerField(placeholder: "Your words appear here. Or type.", text: $draft, isSubmitting: isSubmitting)
        }
    }
}

/// A graded telling: the score out of 5 and the time, the story's beats hit and missed (with "I had
/// that" on a miss), then the serif sample telling. An ungraded one says it was saved for tonight and shows no score.
struct PrepStoryResultView: View {
    let result: PrepAttemptResult
    /// The story the rep asked for, named here once the telling is in (the card asked the prompt alone).
    var title = ""
    /// Story titles by id, to name the story told on a wrong-story result.
    let titles: [String: String]
    /// The missed beat whose "I had that" is saving; every claim waits until it lands.
    var overridingPoint: String?
    let overrideMissed: (String) -> Void

    private var rows: [(id: String, hit: Bool)] {
        (result.judgment?.pointsHit.map { ($0.pointID, true) } ?? [])
            + (result.judgment?.pointsMissed.map { ($0.pointID, false) } ?? [])
    }

    private var sayIt: String {
        let text = result.sayItMD ?? result.strongAnswer
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        PrepRunCard {
            if !title.isEmpty {
                Text(verbatim: title)
                    .font(BrainStyle.meta)
                    .foregroundStyle(HermexPaper.prep.glow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: PrepCopy.storyHeadline(result))
                .font(AppFont.display(style: result.isUngraded ? .headline : .title3))
                .foregroundStyle(result.isUngraded ? Color.hxTextPrimary : HermexPaper.prep.glow)
                .accessibilityAddTraits(.isHeader)
            if !result.isUngraded {
                if let over = PrepCopy.storyClockState(result.elapsedMS ?? 0).text {
                    Text(verbatim: over)
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxWarning)
                }
                if let line = PrepCopy.wrongStoryLine(result, titles: titles) {
                    Text(verbatim: line)
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows, id: \.id) { row in
                    PrepKeyPointRow(result: result, id: row.id, hit: row.hit, canOverride: result.attemptID != nil,
                                    overridingPoint: overridingPoint, overrideMissed: overrideMissed)
                }
            }
        }
        if !result.isUngraded, !sayIt.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "How you'd say it")
                Text(inlineMarkdown(sayIt))
                    .brainText(.quote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                    .padding(.vertical, BrainStyle.cardVerticalPadding)
                    .hxCard()
            }
        }
    }
}

/// A probe's result: which probe it answered, then the recall result's key points. Ungraded, it
/// says it was saved for tonight instead.
struct PrepProbeResultView: View {
    let result: PrepAttemptResult
    let number: Int
    var overridingPoint: String?
    let overrideMissed: (String) -> Void

    var body: some View {
        Text(verbatim: PrepCopy.probeLabel(number))
            .font(BrainStyle.meta)
            .foregroundStyle(HermexPaper.prep.glow)
        if result.isUngraded {
            PrepRunCard {
                Text(verbatim: PrepCopy.storyUngraded)
                    .font(AppFont.display(style: .headline))
                    .foregroundStyle(Color.hxTextPrimary)
            }
        } else {
            PrepRecallResultView(result: result, canOverride: result.attemptID != nil,
                                 overridingPoint: overridingPoint, overrideMissed: overrideMissed)
        }
    }
}
