import SwiftUI

// The recall-first run's cards (spec 2026-10-14 prep-recall §7): every card in a run is a `.knowledge`
// glow card, the mic and primary buttons are Nous blue, missed key points are `hxWarning` with ◌, hits
// are `hxSuccess` with ✓, and only sample answers are serif.

/// A run card: an `HXCard` in the Prep paper's wash, which floats its controls in the paper's tint.
struct PrepRunCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HXCard(.wash(.knowledge), spacing: BrainStyle.m) { content }
    }
}

/// Guess / Fairly sure / Certain, picked before a recall is graded.
struct PrepConfidenceChips: View {
    @Binding var selection: PrepConfidence?

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            Text(verbatim: "How sure are you?")
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextSecondary)
            HStack(spacing: BrainStyle.s) {
                ForEach(PrepConfidence.allCases, id: \.self) { level in
                    let on = selection == level
                    Button {
                        selection = level
                    } label: {
                        Text(verbatim: PrepCopy.confidenceLabel(level))
                            .font(AppFont.body(weight: on ? .semibold : nil))
                            .foregroundStyle(on ? HermexPaper.knowledge.onGlow : Color.hxTextPrimary)
                            .padding(.horizontal, BrainStyle.m)
                            .frame(minHeight: BrainStyle.minTapTarget)
                            .background(on ? HermexPaper.knowledge.glow : Color.hxSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(on ? Color.clear : Color.hxSeparator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}

/// The recall prompt with tap-to-talk dictation into an editable answer, the confidence chips, and
/// "I don't know, show me". Submit is the run's pinned button.
struct PrepRecallCard: View {
    let prompt: String
    let label: String
    @Binding var draft: String
    @Binding var confidence: PrepConfidence?
    let isSubmitting: Bool
    let voiceInput: ComposerVoiceInputController
    let toggleVoice: () -> Void
    let dontKnow: () -> Void
    @FocusState private var typing: Bool
    @ScaledMetric(relativeTo: .title) private var mic: CGFloat = 76

    var body: some View {
        PrepRunCard {
            Text(verbatim: label)
                .font(BrainStyle.meta)
                .foregroundStyle(HermexPaper.knowledge.glow)
            Text(verbatim: prompt)
                .font(AppFont.display(style: .title3))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: BrainStyle.s) {
                let transcribing = voiceInput.state == .transcribing
                Button(action: toggleVoice) {
                    Image(systemName: voiceInput.isListening ? "stop.fill" : "mic.fill")
                        .font(.system(size: mic * 0.36, weight: .semibold))
                        .foregroundStyle(Color.hxOnAccent)
                        .frame(width: mic, height: mic)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || transcribing)
                .accessibilityLabel(Text(verbatim: voiceInput.isListening ? "Stop dictating" : "Answer out loud"))
                Text(verbatim: transcribing ? "Transcribing…"
                     : voiceInput.isListening ? "Listening… tap to stop" : "Tap to answer out loud")
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
                if let error = voiceInput.errorMessage {
                    Text(verbatim: error).font(BrainStyle.meta).foregroundStyle(Color.hxWarning)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, BrainStyle.s)
            TextField(text: $draft, axis: .vertical) { Text(verbatim: "Or type your answer") }
                .font(AppFont.body())
                .lineLimit(3...10)
                .focused($typing)
                .disabled(isSubmitting)
                .padding(BrainStyle.m)
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous)
                    .strokeBorder(Color.hxSeparator, lineWidth: 0.5))
                .accessibilityLabel(Text(verbatim: "Your answer"))
            PrepConfidenceChips(selection: $confidence)
        }
        Button(action: dontKnow) {
            Text(verbatim: "I don't know, show me")
                .font(BrainStyle.rowTitle)
                .foregroundStyle(Color.hxTextSecondary)
                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }
}

/// A graded recall: "3 of 4 key points", each point revealed in turn (all at once under Reduce
/// Motion), "I had that" on misses, the surprise banner on a confident miss, then the serif sample answer.
struct PrepRecallResultView: View {
    let result: PrepAttemptResult
    let xp: Int?
    /// False after "I don't know": there are no points to claim back.
    var canOverride = true
    /// The point whose claim is saving; every "I had that" waits until it lands.
    var overridingPoint: String?
    let overrideMissed: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    private var hits: [String] { result.judgment?.pointsHit.map(\.pointID) ?? [] }
    private var misses: [String] { result.judgment?.pointsMissed.map(\.pointID) ?? [] }
    private var rows: [(id: String, hit: Bool)] { hits.map { ($0, true) } + misses.map { ($0, false) } }

    var body: some View {
        if result.surprise {
            Label {
                Text(verbatim: "Surprise one. You were sure, and this is the kind that sticks now.")
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(Color.hxWarning)
            }
            .padding(BrainStyle.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.hxWarning.opacity(0.14), in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        }
        PrepRunCard {
            if result.isUngraded {
                Text(verbatim: "Saved — Atlas will grade this tonight.")
                    .font(AppFont.display(style: .headline))
                    .foregroundStyle(Color.hxTextPrimary)
            } else {
                Text(verbatim: PrepCopy.keyPointsLine(hit: hits.count, total: rows.count))
                    .font(AppFont.display(style: .title3))
                    .foregroundStyle(HermexPaper.knowledge.glow)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                    if offset < shown {
                        pointRow(row.id, hit: row.hit)
                            .transition(.opacity)
                    }
                }
            }
            if let xp {
                PrepXPTick(xp: xp)
            }
        }
        .task(id: result.verdict + rows.map(\.id).joined()) {
            if reduceMotion {
                shown = rows.count
                return
            }
            while shown < rows.count {
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeOut(duration: 0.2)) { shown += 1 }
            }
        }
        if !result.strongAnswer.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "How you'd say it")
                Text(verbatim: result.strongAnswer)
                    .brainText(.quote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                    .padding(.vertical, BrainStyle.cardVerticalPadding)
                    .hxCard()
            }
        }
    }

    @ViewBuilder
    private func pointRow(_ id: String, hit: Bool) -> some View {
        let text = result.pointTexts[id] ?? PrepCopy.pointTitle(id)
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
            Image(systemName: hit ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(hit ? Color.hxSuccess : Color.hxWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: text)
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if result.overridden.contains(id) {
                    Text(verbatim: "You had this").font(BrainStyle.meta).foregroundStyle(Color.hxTextSecondary)
                }
                if !hit && canOverride {
                    Button { overrideMissed(id) } label: {
                        Text(verbatim: overridingPoint == id ? "Saving…" : "I had that ›")
                            .font(BrainStyle.meta).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(overridingPoint != nil)
                    .frame(minHeight: 32)
                    .accessibilityLabel(Text(verbatim: "I had that: \(text)"))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(hit ? "Hit" : "Missed"): \(text)"))
    }
}
