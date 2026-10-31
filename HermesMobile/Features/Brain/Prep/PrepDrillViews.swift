import SwiftUI

// The drills inside `PrepRunView`. Each view is handed values and closures by the
// run view and owns only presentation state (a check's answer, a confirmation).

// MARK: - Problem card

/// The question being answered, pinned over the answer: a meta line and the question. A boss card
/// names the lesson it tests; a judgment card its stage and skill. Any other rep shows its title.
struct PrepProblemCard: View {
    let meta: String
    let title: String

    init(rep: PrepRep) {
        let item = rep.item
        switch rep.drill {
        case .boss:
            meta = PrepCopy.bossMeta(lessonTitle: item.title)
            title = item.summary
        case .judgment:
            meta = [PrepCopy.stageChip(item.stage) ?? "", item.skillTitle ?? item.title]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            title = item.summary
        default:
            meta = ""
            title = item.title
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            if !meta.isEmpty {
                Text(verbatim: meta).brainText(.meta)
            }
            Text(verbatim: title)
                .font(AppFont.display(style: .headline))
                .foregroundStyle(Color.hxTextPrimary)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .brainCardSurface()
        .transaction { $0.animation = nil }
    }
}

// MARK: - Choice (lesson checks and warm-ups)

/// The options as card rows; a tap answers straight away. Once graded, the chosen wrong
/// option shows a red cross and the correct one a green check.
struct PrepChoiceView: View {
    struct Grading {
        let chosenID: String?
        let correctID: String?
    }

    let title: String
    let options: [PrepOption]
    let grading: Grading?
    var isSubmitting = false
    var submitError: String?
    /// The option picked and not yet submitted: a tap selects, the run's pinned Submit sends it.
    var selectedID: String?
    let onChoose: (PrepOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: title)
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { offset, option in
                        if offset > 0 { PrepRowDivider() }
                        row(option)
                    }
                }
            }
            if let submitError {
                PrepSubmitError(message: submitError)
            }
        }
    }

    @ViewBuilder
    private func row(_ option: PrepOption) -> some View {
        if let grading {
            let isCorrect = PrepCopy.isSameChoice(option.id, grading.correctID)
            let isWrongPick = PrepCopy.isSameChoice(option.id, grading.chosenID) && !isCorrect
            HStack(spacing: BrainStyle.m) {
                optionTitle(option)
                if isCorrect {
                    Image(systemName: "checkmark").foregroundStyle(Color.hxSuccess)
                } else if isWrongPick {
                    Image(systemName: "xmark").foregroundStyle(Color.hxDanger)
                }
            }
            .font(BrainStyle.rowTitle.weight(.semibold))
            .frame(minHeight: BrainStyle.minTapTarget)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: option.title))
            .accessibilityValue(Text(verbatim: isCorrect
                ? (PrepCopy.isSameChoice(option.id, grading.chosenID) ? "Your answer, correct" : "Correct answer")
                : (isWrongPick ? "Your answer, wrong" : "")))
        } else {
            let isSelected = PrepCopy.isSameChoice(option.id, selectedID)
            Button { onChoose(option) } label: {
                HStack(spacing: BrainStyle.m) {
                    optionTitle(option)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.hxTextSecondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel(Text(verbatim: option.title))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func optionTitle(_ option: PrepOption) -> some View {
        Text(verbatim: option.title)
            .font(BrainStyle.rowTitle)
            .foregroundStyle(Color.hxTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, BrainStyle.s)
    }
}

// MARK: - Answer editor

/// A judgment or boss answer in a plain editor, capped at the server's limit. Submit lives in
/// the run view's pinned bar.
struct PrepAnswerEditor: View {
    @Binding var text: String
    let isSubmitting: Bool
    @ScaledMetric(relativeTo: .body) private var editorHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Your answer")
            TextEditor(text: $text)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: editorHeight)
                .padding(.horizontal, BrainStyle.m)
                .padding(.vertical, BrainStyle.s)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: "How would you solve this?")
                            .font(AppFont.body())
                            .foregroundStyle(Color.hxTextSecondary)
                            .padding(.horizontal, BrainStyle.m + 5)
                            .padding(.vertical, BrainStyle.s + 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .brainCardSurface()
                .disabled(isSubmitting)
                .accessibilityLabel(Text(verbatim: "Your answer"))
                .accessibilityHint(Text(verbatim: "How would you solve this?"))
            if PrepCopy.isAtApproachLimit(text) {
                Text(verbatim: "\(PrepCopy.approachMaxLength) characters max")
                    .brainText(.meta)
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
    }
}

// MARK: - Result

/// An answered judgment card: its grade, or that it waits for tonight's grading; then the feedback
/// with its first sentence in bold and the solution when the server sends one. Continue is pinned
/// by the run view.
struct PrepResultView: View {
    let rep: PrepRep
    let result: PrepAttemptResult

    var body: some View {
        if rep.drill == .judgment {
            if result.isUngraded {
                PrepNoteCard {
                    Text(verbatim: "Saved — Atlas will grade this tonight.")
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.hxTextPrimary)
                }
            } else {
                if let callout = PrepCopy.gapCallout(match: result.gapMatch, logged: result.logged) {
                    PrepGapCallout(text: callout, isKnownGap: !result.gapMatch.isEmpty)
                }
                if let grade = result.judgment {
                    PrepJudgmentGradeView(grade: grade, pointTexts: result.pointTexts)
                }
            }
        }

        let feedback = PrepCopy.feedbackParts(result.feedback)
        if !feedback.lead.isEmpty {
            PrepNoteCard {
                PrepLeadText(lead: feedback.lead, rest: feedback.rest)
            }
        }

        if let reference = result.referenceMD, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DisclosureGroup {
                MarkdownRenderer(content: reference)
                    .padding(.top, BrainStyle.s)
            } label: {
                Text(verbatim: "See the solution")
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(Color.hxTextPrimary)
            }
            .tint(Color.hxTextSecondary)
        }
    }
}

/// A judgment card's grade: the points made, quoted in the serif; the points missed and why;
/// then what a strong answer says. After a miss, the lesson's sections show as their own
/// cards: the repeat misses, the idea, the code, and a check whose answer unlocks Remember.
struct PrepJudgmentGradeView: View {
    let grade: PrepJudgmentGrade
    /// Each reference point's sentence by id; a point without one shows its id as a title.
    var pointTexts: [String: String] = [:]
    /// The user's answer in the lesson's "Check yourself" box; it stays on this screen only.
    @State private var checkAnswer = ""
    @State private var checkDone = false
    @FocusState private var checkFocused: Bool

    private func point(_ id: String) -> String { pointTexts[id] ?? PrepCopy.pointTitle(id) }

    var body: some View {
        if !grade.pointsHit.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "What landed")
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(grade.pointsHit.enumerated()), id: \.offset) { offset, hit in
                            if offset > 0 { PrepRowDivider() }
                            Label {
                                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                                    Text(verbatim: point(hit.pointID)).brainText(.meta)
                                    if !hit.quote.isEmpty {
                                        Text(verbatim: hit.quote)
                                            .brainText(.quote)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            } icon: {
                                Image(systemName: "checkmark").foregroundStyle(Color.hxSuccess)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, BrainStyle.s)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: "Hit: \(point(hit.pointID)). \(hit.quote)"))
                        }
                    }
                }
            }
        }
        if !grade.pointsMissed.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "What was missing")
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(grade.pointsMissed.enumerated()), id: \.offset) { offset, miss in
                            if offset > 0 { PrepRowDivider() }
                            BrainRow(title: point(miss.pointID),
                                     subtitle: miss.why.isEmpty ? nil : miss.why, subtitleLineLimit: 8,
                                     titleLineLimit: nil)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: "Missed: \(point(miss.pointID)). \(miss.why)"))
                        }
                    }
                }
            }
        }
        if !grade.strongAnswer.isEmpty {
            PrepNoteCard {
                HXSectionHeader(title: "What a strong answer says")
                Text(inlineMarkdown(grade.strongAnswer))
                    .brainText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let lesson = grade.lesson {
            PrepJudgmentLessonCards(lesson: lesson, checkAnswer: $checkAnswer,
                                    checkDone: $checkDone, checkFocused: $checkFocused)
        }
    }
}

/// The cards for a judgment miss's lesson, in the lesson's order: the repeat misses, the idea,
/// the code, the check, and Remember (locked behind the check's answer).
struct PrepJudgmentLessonCards: View {
    let lesson: PrepJudgmentLesson
    @Binding var checkAnswer: String
    @Binding var checkDone: Bool
    @FocusState.Binding var checkFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let repeatText = lesson.repeatText {
            SectionCard { BrainRow(title: repeatText, titleLineLimit: nil) }
        }
        if let repeats = lesson.repeats, !repeats.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Missed before")
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(repeats.enumerated()), id: \.offset) { offset, item in
                            if offset > 0 { PrepRowDivider() }
                            BrainRow(title: PrepCopy.pointTitle(item.concept),
                                     trailing: repeatLabel(item.misses),
                                     titleLineLimit: nil)
                        }
                    }
                }
            }
        }
        if !lesson.idea.isEmpty {
            PrepNoteCard {
                HXSectionHeader(title: "The idea")
                Text(PrepJudgmentLessonCards.attributed(body: lesson.idea))
                    .brainText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let code = lesson.code {
            PrepCodeCard {
                MarkdownRenderer(content: code)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, BrainStyle.xs)
            }
        }
        if let check = lesson.check {
            checkCard(check)
            if checkDone {
                rememberCard
            }
        } else {
            rememberCard
        }
    }

    /// "3rd miss", "2×": ordinals read better for small counts.
    private func repeatLabel(_ misses: Int) -> String {
        switch misses {
        case 2: "2nd miss"
        case 3: "3rd miss"
        case 4: "4th miss"
        default: "\(misses)×"
        }
    }

    private func checkCard(_ check: String) -> some View {
        SectionCard(title: "Check yourself") {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                Text(PrepJudgmentLessonCards.attributed(body: check))
                    .brainText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if checkDone {
                    PrepPrimaryButton(title: "Done") {
                        checkAnswer = ""
                        withAnimation(reduceMotion ? nil : .default) { checkDone = false }
                    }
                } else {
                    TextField(text: $checkAnswer, axis: .vertical) { Text(verbatim: "Answer with what you just learned") }
                        .lineLimit(1...4)
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextPrimary)
                        .focused($checkFocused)
                        .submitLabel(.done)
                        .onSubmit { done() }
                        .frame(minHeight: BrainStyle.minTapTarget, alignment: .topLeading)
                    PrepPrimaryButton(title: "Done", enabled: !checkAnswer.isEmpty) { done() }
                }
            }
        }
    }

    private var rememberCard: some View {
        SectionCard(title: "Remember") {
            VStack(spacing: 0) {
                ForEach(Array(lesson.remember.enumerated()), id: \.offset) { offset, item in
                    if offset > 0 { PrepRowDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
                        Text(verbatim: "•")
                            .font(BrainStyle.rowTitle)
                            .foregroundStyle(Color.hxTextSecondary)
                        Text(verbatim: item)
                            .brainText(.rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, BrainStyle.xs)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func done() {
        checkFocused = false
        withAnimation(reduceMotion ? nil : .default) { checkDone = true }
    }

    /// The lesson's text with inline bold and code intact; a parse failure shows the plain text.
    static func attributed(body: String) -> AttributedString {
        (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(body)
    }
}

/// The line under a graded judgment naming the gap its miss belongs to, or that it was logged.
struct PrepGapCallout: View {
    let text: String
    /// A miss on a gap already in the ledger, rather than one logged for the coach.
    let isKnownGap: Bool

    var body: some View {
        Label {
            Text(verbatim: text)
                .font(BrainStyle.rowTitle)
                .foregroundStyle(isKnownGap ? HermexPaper.knowledge.glow : Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isKnownGap ? "arrow.triangle.branch" : "tray.and.arrow.down")
                .foregroundStyle(isKnownGap ? HermexPaper.knowledge.glow : Color.hxTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .glowSurface(HermexPaper.knowledge, cornerRadius: HXRadius.md)
        .accessibilityElement(children: .combine)
    }
}

/// A cloze fact: one short typed answer, submitted from the keyboard or the pinned button.
struct PrepClozeView: View {
    @Binding var text: String
    let isSubmitting: Bool
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Your answer")
            TextField(text: $text) { Text(verbatim: "Type the term") }
                .font(AppFont.body())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(onSubmit)
                .disabled(isSubmitting)
                .padding(.horizontal, BrainStyle.m)
                .frame(minHeight: BrainStyle.minTapTarget)
                .brainCardSurface()
                .accessibilityLabel(Text(verbatim: "Your answer"))
        }
        .onAppear { focused = true }
    }
}

/// Retires a coach-written card after a confirmation; the coach writes a replacement for its gap.
struct PrepFlagCardButton: View {
    let isFlagged: Bool
    let error: String?
    let flag: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(spacing: BrainStyle.xs) {
            Button {
                confirming = true
            } label: {
                Label {
                    Text(verbatim: isFlagged ? "Card flagged" : "Flag this card")
                } icon: {
                    Image(systemName: isFlagged ? "flag.fill" : "flag")
                }
                .font(BrainStyle.rowTitle)
                .foregroundStyle(Color.hxTextSecondary)
                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isFlagged)
            .confirmationDialog(Text(verbatim: "Flag this card?"), isPresented: $confirming, titleVisibility: .visible) {
                Button(role: .destructive, action: flag) { Text(verbatim: "Flag and retire") }
            } message: {
                Text(verbatim: "Atlas wrote this card. Flagging retires it for good, and Atlas writes another for the same gap tonight.")
            }
            if let error {
                PrepSubmitError(message: error)
            }
        }
    }
}

// MARK: - Small pieces

/// The run's full-width primary action: a capsule in the course's paper, as the run's cards are
/// (`DESIGN.md`: a wash card's controls take its paper's tint), like the Daily Deck's File It.
struct PrepPrimaryButton: View {
    let title: String
    var enabled = true
    /// An answer is out for grading: the button keeps its tint, ignores taps, and shows
    /// `PrepGradingLabel` in place of the title.
    var isGrading = false
    let action: () -> Void

    private var paper: HermexPaper { .knowledge }
    private var isActive: Bool { enabled || isGrading }

    var body: some View {
        Button(action: action) {
            Group {
                if isGrading {
                    PrepGradingLabel()
                } else {
                    Text(verbatim: title)
                }
            }
            .font(AppFont.body(weight: .semibold))
            // Disabled: full-strength secondary text on a faint wash (glow text is never faded).
            .foregroundStyle(isActive ? paper.onGlow : Color.hxTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isActive ? paper.glow : paper.glow.opacity(0.15), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !isGrading)
        .allowsHitTesting(!isGrading)
    }
}

/// The wait while Atlas grades an answer: a breathing sparkle and the seconds since submit.
/// The symbol effect runs in the render server and the counter ticks once a second inside a
/// `TimelineView` scoped to this label, so nothing else re-renders. Under Reduce Motion the
/// sparkle holds still and the counter alone shows the wait is alive.
private struct PrepGradingLabel: View {
    @State private var startedAt = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: BrainStyle.s) {
                Image(systemName: "sparkles")
                    .symbolEffect(.breathe, isActive: !reduceMotion)
                Text(verbatim: "Grading")
                Text(verbatim: "\(seconds)s")
                    .monospacedDigit()
                    .opacity(0.7)
                    .contentTransition(.numericText(countsDown: false))
                    .animation(reduceMotion ? nil : .default, value: seconds)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Grading your answer"))
    }
}

/// An inline save failure under the primary action; never an alert.
struct PrepSubmitError: View {
    let message: String

    var body: some View {
        Text(verbatim: message)
            .font(BrainStyle.meta)
            .foregroundStyle(Color.hxDanger)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// A feedback or hint note on the card surface.
struct PrepNoteCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .brainCardSurface()
    }
}

/// A bold lead sentence followed by the rest, as one run of text.
struct PrepLeadText: View {
    let lead: String
    let rest: String

    var body: some View {
        Text(Self.attributed(lead: lead, rest: rest))
            .font(BrainStyle.rowTitle)
            .foregroundStyle(Color.hxTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(lead: String, rest: String) -> AttributedString {
        var bold = AttributedString(lead)
        bold.inlinePresentationIntent = .stronglyEmphasized
        return rest.isEmpty ? bold : bold + AttributedString(" " + rest)
    }
}

/// Monospaced lines on the code background, in the card shape.
struct PrepCodeCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, BrainStyle.m)
        .padding(.vertical, BrainStyle.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hxCodeBackground, in: BrainStyle.cardShape())
    }
}
