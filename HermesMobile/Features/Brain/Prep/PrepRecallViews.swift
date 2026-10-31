import SwiftUI

// The recall-first run's cards (spec 2026-10-14 prep-recall §7): every card in a run is a `.knowledge`
// glow card, the primary buttons are Nous blue, missed key points are `hxWarning` with ◌, hits
// are `hxSuccess` with ✓, and only sample answers are serif.

/// A run card: an `HXCard` in the Prep paper's wash, which floats its controls in the paper's tint.
struct PrepRunCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HXCard(.wash(.knowledge), spacing: BrainStyle.m) { content }
    }
}

/// The question with an answer field (tap to talk, or type), and "I don't know, show me".
/// Submit is the run's pinned button.
struct PrepRecallCard: View {
    let prompt: String
    let label: String
    @Binding var draft: String
    let isSubmitting: Bool
    let dontKnow: () -> Void
    @FocusState private var typing: Bool

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
            TextField(text: $draft, axis: .vertical) { Text(verbatim: "Answer out loud or type…") }
                .font(AppFont.body())
                .lineLimit(3...10)
                .focused($typing)
                .disabled(isSubmitting)
                .padding(BrainStyle.m)
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous)
                    .strokeBorder(Color.hxSeparator, lineWidth: 0.5))
                .accessibilityLabel(Text(verbatim: "Your answer"))
            PrepStoryMicButton(text: $draft, isSubmitting: isSubmitting)
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
/// Motion), "I had that" on misses. After a question rep the headline
/// counts the tutor's follow-ups, each miss says why, and the worked answer for this question waits behind a tap;
/// "Go deeper in Atlas" opens a chat about it, which never changes the score.
struct PrepRecallResultView: View {
    let result: PrepAttemptResult
    let xp: Int?
    /// Starts a new Atlas chat with these words in the composer; nil hides the button.
    var goDeeper: ((String) -> Void)?
    /// False after "I don't know": there are no points to claim back.
    var canOverride = true
    /// The point whose claim is saving; every "I had that" waits until it lands.
    var overridingPoint: String?
    let overrideMissed: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    @State private var showsWorked = false

    private var hits: [String] { result.judgment?.pointsHit.map(\.pointID) ?? [] }
    private var misses: [String] { result.judgment?.pointsMissed.map(\.pointID) ?? [] }
    private var rows: [(id: String, hit: Bool)] { hits.map { ($0, true) } + misses.map { ($0, false) } }
    /// A pool question's rep, which carries the dialogue and a worked answer.
    private var isQuestion: Bool { result.dialogue != nil }

    var body: some View {
        PrepRunCard {
            if result.isUngraded {
                Text(verbatim: "Saved — Atlas will grade this tonight.")
                    .font(AppFont.display(style: .headline))
                    .foregroundStyle(Color.hxTextPrimary)
            } else {
                Text(verbatim: PrepCopy.endHeadline(hit: hits.count, total: rows.count,
                                                    followups: result.dialogue?.followups))
                    .font(AppFont.display(style: .title3))
                    .foregroundStyle(HermexPaper.knowledge.glow)
                    .accessibilityAddTraits(.isHeader)
                if isQuestion {
                    Text(verbatim: "What you reasoned through")
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextSecondary)
                }
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
        if isQuestion && !result.strongAnswer.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsWorked.toggle() }
                } label: {
                    HStack {
                        Text(verbatim: "Worked answer for this question")
                            .font(BrainStyle.rowTitle)
                            .foregroundStyle(Color.hxTextPrimary)
                        Spacer(minLength: BrainStyle.s)
                        Image(systemName: showsWorked ? "chevron.up" : "chevron.down")
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                    .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hxCard()
                .accessibilityAddTraits(showsWorked ? .isSelected : [])
                .accessibilityHint(Text(verbatim: showsWorked ? "Hides the worked answer" : "Shows a worked answer"))
                if showsWorked {
                    Text(inlineMarkdown(result.strongAnswer))
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                        .padding(.vertical, BrainStyle.cardVerticalPadding)
                        .hxCard()
                        .transition(.opacity)
                }
            }
        }
        if let goDeeper, let seed = result.deeperMD {
            Button { goDeeper(seed) } label: {
                Label {
                    Text(verbatim: "Go deeper in Atlas")
                } icon: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: "Starts a chat with Atlas about this question. It doesn't change your score."))
        }
    }

    private func pointRow(_ id: String, hit: Bool) -> some View {
        PrepKeyPointRow(result: result, id: id, hit: hit, canOverride: canOverride,
                        overridingPoint: overridingPoint, overrideMissed: overrideMissed, showsWhy: isQuestion)
    }
}

/// One key point of a graded answer: ✓ when hit, ◌ with "I had that" when missed, until the answer has
/// used its one "I had that" (the server allows one per answer).
struct PrepKeyPointRow: View {
    let result: PrepAttemptResult
    let id: String
    let hit: Bool
    var canOverride = true
    var overridingPoint: String?
    let overrideMissed: (String) -> Void
    /// Under a miss, the grader's one line on what was missing.
    var showsWhy = false

    private var why: String? {
        guard showsWhy, !hit else { return nil }
        let line = result.judgment?.pointsMissed.first { $0.pointID == id }?.why ?? ""
        return line.isEmpty ? nil : line
    }

    /// "I had that" shows on a miss the caller allows, while the answer hasn't used its one.
    static func offersOverride(hit: Bool, canOverride: Bool, result: PrepAttemptResult) -> Bool {
        !hit && canOverride && result.overridden.isEmpty
    }

    var body: some View {
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
                if let why {
                    Text(verbatim: why)
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result.overridden.contains(id) {
                    Text(verbatim: "You had this").font(BrainStyle.meta).foregroundStyle(Color.hxTextSecondary)
                }
                if Self.offersOverride(hit: hit, canOverride: canOverride, result: result) {
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
