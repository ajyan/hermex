import SwiftUI

// The tutor dialogue after a question rep (spec 2026-10-19 Track A, slice 2): the question on a run card, then
// chat bubbles, the user's on `hxSurface` at the trailing edge and the tutor's on the knowledge wash at the
// leading edge. "Show me" (a link, so Nous blue) ends it at any point; the reply bar's mic is the only other
// control. While the tutor thinks, its bubble shows the grading sparkle, still under Reduce Motion.

/// The dialogue: the question, the first answer, each follow-up and reply, and the turn streaming in.
struct PrepTutorDialogueView: View {
    let prompt: String
    let kicker: String
    /// "Follow-up 1 of 3" over the conversation, once the tutor has asked one.
    let followup: String?
    let firstAnswer: String
    let state: PrepDialogueState?
    /// The tutor's turn so far while it streams ("" before its first words), else nil.
    let streaming: String?
    /// A reply out for grading, shown at once so the screen never looks like it dropped it.
    let pendingReply: String?
    let error: String?
    let retry: () -> Void

    var body: some View {
        PrepRunCard {
            Text(verbatim: kicker)
                .font(BrainStyle.meta)
                .foregroundStyle(HermexPaper.knowledge.glow)
            Text(verbatim: prompt)
                .font(AppFont.display(style: .headline))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        VStack(alignment: .leading, spacing: BrainStyle.m) {
            if let followup {
                Text(verbatim: followup)
                    .font(BrainStyle.meta)
                    .foregroundStyle(HermexPaper.knowledge.glow)
            }
            if !firstAnswer.isEmpty {
                PrepBubble(text: firstAnswer, isTutor: false)
            }
            ForEach(Array((state?.turns ?? []).enumerated()), id: \.offset) { _, turn in
                PrepBubble(text: turn.text, isTutor: turn.isTutor)
            }
            if let pendingReply {
                PrepBubble(text: pendingReply, isTutor: false)
            }
            if let streaming {
                if streaming.isEmpty {
                    PrepThinkingBubble()
                } else {
                    PrepBubble(text: streaming, isTutor: true)
                }
            }
            if let error {
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    PrepSubmitError(message: error)
                    Button(action: retry) {
                        Text(verbatim: "Try again")
                            .font(BrainStyle.rowTitle)
                            .foregroundStyle(Color.accentColor)
                            .frame(minHeight: BrainStyle.minTapTarget)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One message: the tutor's on the knowledge wash, leading; the user's on `hxSurface`, trailing.
private struct PrepBubble: View {
    let text: String
    let isTutor: Bool

    var body: some View {
        HStack {
            if !isTutor { Spacer(minLength: BrainStyle.xl) }
            if isTutor {
                label.glowSurface(.knowledge, cornerRadius: HXRadius.lg)
            } else {
                label
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous)
                        .strokeBorder(Color.hxSeparator, lineWidth: 0.5))
            }
            if isTutor { Spacer(minLength: BrainStyle.xl) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(isTutor ? "Tutor" : "You"): \(text)"))
    }

    private var label: some View {
        Text(verbatim: text)
            .font(AppFont.body())
            .foregroundStyle(Color.hxTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, BrainStyle.m)
            .padding(.vertical, BrainStyle.s)
    }
}

/// The tutor's bubble before its first words: the grading sparkle, breathing unless Reduce Motion is on.
private struct PrepThinkingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            Label {
                Text(verbatim: "Thinking")
            } icon: {
                Image(systemName: "sparkles").symbolEffect(.breathe, isActive: !reduceMotion)
            }
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(HermexPaper.knowledge.glow)
            .padding(.horizontal, BrainStyle.m)
            .padding(.vertical, BrainStyle.s)
            .glowSurface(.knowledge, cornerRadius: HXRadius.lg)
            Spacer(minLength: BrainStyle.xl)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "The tutor is thinking"))
    }
}

/// The pinned reply bar: the answer field, the mic, Send, and "Show me".
struct PrepTutorReplyBar: View {
    @Binding var draft: String
    let canReply: Bool
    let canSend: Bool
    let isBusy: Bool
    let send: () -> Void
    let showMe: () -> Void

    var body: some View {
        VStack(spacing: BrainStyle.s) {
            if canReply {
                TextField(text: $draft, axis: .vertical) { Text(verbatim: "Answer out loud or type…") }
                    .font(AppFont.body())
                    .lineLimit(1...6)
                    .disabled(isBusy)
                    .padding(BrainStyle.m)
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous)
                        .strokeBorder(Color.hxSeparator, lineWidth: 0.5))
                    .accessibilityLabel(Text(verbatim: "Your reply"))
                PrepStoryMicButton(text: $draft, isSubmitting: isBusy, prominent: false)  // Send leads this bar
                PrepPrimaryButton(title: "Send", enabled: canSend, isGrading: isBusy, action: send)
            }
            Button(action: showMe) {
                Text(verbatim: "Show me")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
            }
            .buttonStyle(.plain)
            .disabled(isBusy && !canReply)
            .accessibilityHint(Text(verbatim: "Ends the follow-ups and shows the result"))
        }
    }
}
