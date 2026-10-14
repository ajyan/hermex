import SwiftUI

// The drills inside `PrepRunView`. Each view is handed values and closures by the
// run view and owns only presentation state (a timer start, an example toggle).

// MARK: - Problem card

/// The problem being drilled, pinned over the drill: meta, title, a two-line
/// summary and a More/Less toggle that reveals the full summary and example. A primer shows the skill and its worked example instead.
struct PrepProblemCard: View {
    let meta: String
    let title: String
    let summary: String
    let example: String
    /// Reset per rep: the run view keys each rep with `.id(rep.index)`.
    @State private var expanded = false
    @State private var detailHeight: CGFloat = 0

    /// The most height the expanded card may take; the rest scrolls inside it.
    let maxHeight: CGFloat
    /// Room for the meta line, title and More button inside `maxHeight`.
    @ScaledMetric(relativeTo: .body) private var chrome: CGFloat = 110

    private var canExpand: Bool { PrepCode.canExpand(summary: summary, example: example) }

    init(rep: PrepRep, maxHeight: CGFloat = .infinity) {
        self.maxHeight = maxHeight
        let item = rep.item
        if rep.drill == .fact || rep.drill == .judgment {
            meta = [PrepCopy.stageChip(item.stage) ?? "", item.skillTitle ?? item.title]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            title = item.summary
            summary = ""
            example = ""
        } else if rep.drill == .primer {
            meta = "Primer"
            title = item.skillTitle.flatMap { $0.isEmpty ? nil : $0 } ?? item.title
            summary = "Worked example: \(item.title)"
            example = ""
        } else {
            meta = [item.skillTitle ?? "", item.difficulty].filter { !$0.isEmpty }.joined(separator: " · ")
            title = item.title
            summary = item.summary
            example = item.example
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
            if expanded {
                // Natural height, capped; scrolls only when the content is taller. The
                // height is measured on a hidden copy outside the scroll, so it can't be circular.
                Group {
                    if detailHeight > 0 {
                        ScrollView { detail }
                            .scrollBounceBehavior(.basedOnSize)
                            .frame(height: PrepCode.expandedHeight(
                                natural: detailHeight, cap: max(maxHeight - chrome, 80)))
                    } else {
                        detail.fixedSize(horizontal: false, vertical: true)
                    }
                }
                .background(alignment: .top) {
                    detail
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailHeight = $0 }
                        .accessibilityHidden(true)
                }
            } else if !summary.isEmpty {
                Text(verbatim: summary)
                    .brainText(.rowSubtitle)
                    .lineLimit(2)
                    .accessibilityLabel(Text(verbatim: summary))
            }
            if canExpand {
                Button {
                    // Instant: no crossfade between the compact and expanded text.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { expanded.toggle() }
                } label: {
                    Text(verbatim: expanded ? "Less" : "More")
                        .font(BrainStyle.rowSubtitle.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: BrainStyle.minTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(verbatim: expanded ? "Expanded" : "Collapsed"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.top, BrainStyle.cardVerticalPadding)
        .padding(.bottom, canExpand ? 0 : BrainStyle.cardVerticalPadding)
        .brainCardSurface()
        .transaction { $0.animation = nil }
    }

    /// The full summary and the example, shown when expanded.
    private var detail: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .brainText(.rowSubtitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !example.isEmpty {
                Text(verbatim: example)
                    .font(AppFont.mono(style: .footnote))
                    .foregroundStyle(Color.hxTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Choice (complexity, trace, spot-the-bug fixes)

/// The options as card rows. A tap answers straight away, or, with `selectedID`
/// bound, only marks the option in the accent for a later submit. Once graded, the
/// chosen wrong option shows a red cross and the correct one a green check.
struct PrepChoiceView: View {
    struct Grading {
        let chosenID: String?
        let correctID: String?
    }

    let title: String
    let options: [PrepOption]
    let grading: Grading?
    /// Options holding code (trace outputs, fixes) are set in the monospaced face.
    var monospaced = false
    var selectedID: String?
    var isSubmitting = false
    var submitError: String?
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
            let isSelected = selectedID == option.id
            Button { onChoose(option) } label: {
                HStack(spacing: BrainStyle.m) {
                    optionTitle(option)
                    if isSelected {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
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
            .font(monospaced ? AppFont.mono(style: .body) : BrainStyle.rowTitle)
            .foregroundStyle(Color.hxTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, BrainStyle.s)
    }
}

// MARK: - Approach

/// An approach rep: the answer in a plain editor, a 90-second clock in the toolbar,
/// and the hint ladder. Submit lives in the run view's pinned bar.
struct PrepApproachView: View {
    @Binding var text: String
    let hints: [String]
    let hintsShown: Int
    let isSubmitting: Bool
    let showHint: () -> Void
    /// When the rep appeared, from the view model, so the clock matches the timed answer.
    let shownAt: Date
    /// The section title: "Your approach" on DSA reps, "Your answer" on judgment cards.
    var prompt = "Your approach"
    @ScaledMetric(relativeTo: .body) private var editorHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: prompt)
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
                .accessibilityLabel(Text(verbatim: prompt))
                .accessibilityHint(Text(verbatim: "How would you solve this?"))
            if PrepCopy.isAtApproachLimit(text) {
                Text(verbatim: "\(PrepCopy.approachMaxLength) characters max")
                    .brainText(.meta)
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TimelineView(.periodic(from: shownAt, by: 1)) { context in
                    let clock = PrepCopy.approachClock(elapsed: context.date.timeIntervalSince(shownAt))
                    Text(verbatim: clock.text)
                        .brainText(.meta)
                        .foregroundStyle(clock.isOver ? Color.hxDanger.opacity(0.8) : Color.hxTextSecondary)
                        .monospacedDigit()
                        .accessibilityLabel(Text(verbatim: clock.isOver ? "Over time" : "Time left"))
                        .accessibilityValue(Text(verbatim: clock.text))
                }
                .transaction { $0.animation = nil }
            }
        }

        PrepHintLadder(hints: hints, shown: hintsShown, showHint: showHint)
    }
}

/// Hints revealed one at a time, each numbered, then "Show a hint" while any remain.
struct PrepHintLadder: View {
    let hints: [String]
    let shown: Int
    let showHint: () -> Void

    var body: some View {
        if shown > 0 {
            PrepNoteCard {
                ForEach(0..<min(shown, hints.count), id: \.self) { index in
                    PrepLeadText(lead: "Hint \(index + 1) of \(hints.count).", rest: hints[index])
                }
            }
        }
        if shown < hints.count {
            Button(action: showHint) {
                Text(verbatim: "Show a hint")
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(Color.hxTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Spot the bug

/// A spot-the-bug rep: tap the line with the bug, then pick its fix. The run view's
/// pinned Submit enables once both are chosen.
struct PrepSpotBugView: View {
    let code: [String]
    let fixes: [String]
    let selectedLine: Int?
    let selectedFix: String?
    let isSubmitting: Bool
    let selectLine: (Int) -> Void
    let selectFix: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Tap the line with the bug")
            PrepNumberedCode(code: code, tint: { $0 == selectedLine ? Color.accentColor.opacity(0.18) : nil },
                             selectedLine: selectedLine, isDisabled: isSubmitting, onTap: selectLine)
        }
        if selectedLine != nil {
            PrepChoiceView(
                title: "Fix",
                options: fixes.map { PrepOption(id: $0, title: $0) },
                grading: nil,
                monospaced: true,
                selectedID: selectedFix,
                isSubmitting: isSubmitting
            ) { selectFix($0.id) }
        }
    }
}

/// Code lines numbered from 1, each optionally tinted; tappable when `onTap` is set.
struct PrepNumberedCode: View {
    let code: [String]
    let tint: (Int) -> Color?
    var selectedLine: Int?
    var isDisabled = false
    var onTap: ((Int) -> Void)?
    @ScaledMetric(relativeTo: .footnote) private var gutter: CGFloat = 20

    var body: some View {
        PrepCodeCard {
            ForEach(Array(code.enumerated()), id: \.offset) { index, line in
                if let onTap {
                    Button { onTap(index) } label: { numbered(index, line) }
                        .buttonStyle(.plain)
                        .disabled(isDisabled)
                        .accessibilityLabel(Text(verbatim: PrepCopy.codeLineLabel(index: index, code: line)))
                        .accessibilityAddTraits(selectedLine == index ? .isSelected : [])
                } else {
                    numbered(index, line)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: PrepCopy.codeLineLabel(index: index, code: line)))
                }
            }
        }
    }

    private func numbered(_ index: Int, _ line: String) -> some View {
        HStack(spacing: BrainStyle.s) {
            Text(verbatim: "\(index + 1)")
                .font(AppFont.mono(style: .caption))
                .foregroundStyle(Color.hxTextSecondary)
                .frame(minWidth: gutter, alignment: .trailing)
            PrepCodeLine(code: line)
        }
        .padding(.horizontal, BrainStyle.xs)
        .background(tint(index) ?? .clear, in: RoundedRectangle(cornerRadius: BrainStyle.thumbnailCorner, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: - Trace

/// A trace rep: the code, its input, then the possible outputs; a tap answers.
struct PrepTraceView: View {
    let item: PrepItemExcerpt
    let isSubmitting: Bool
    let submitError: String?
    let onChoose: (PrepOption) -> Void

    var body: some View {
        PrepTraceCode(item: item)
        PrepChoiceView(
            title: "What does it return?",
            options: item.options,
            grading: nil,
            monospaced: true,
            isSubmitting: isSubmitting,
            submitError: submitError,
            onChoose: onChoose
        )
    }
}

/// The traced code and its input, shared by the rep and its result.
struct PrepTraceCode: View {
    let item: PrepItemExcerpt

    var body: some View {
        if !item.code.isEmpty {
            PrepNumberedCode(code: item.code, tint: { _ in nil })
        }
        if !item.input.isEmpty {
            Text(verbatim: "Input: \(item.input)")
                .font(AppFont.mono(style: .footnote))
                .foregroundStyle(Color.hxTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Primer

/// A new skill's primer: its signals, template, invariant and complexity, then
/// the worked example. "Got it" records it as seen.
struct PrepPrimerView: View {
    let item: PrepItemExcerpt

    var body: some View {
        if let primer = item.primer {
            if !primer.signals.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    BrainSectionHeader(title: "Signals")
                    PrepFlowLayout(spacing: BrainStyle.s) {
                        ForEach(Array(primer.signals.enumerated()), id: \.offset) { _, signal in
                            BrainTagChip(tag: signal)
                        }
                    }
                }
            }
            if !primer.template.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    BrainSectionHeader(title: "Template")
                    PrepCodeCard {
                        Text(verbatim: primer.template)
                            .font(AppFont.mono(style: .footnote))
                            .foregroundStyle(Color.hxTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, BrainStyle.s)
                    }
                }
            }
            if !primer.invariant.isEmpty || !primer.complexity.isEmpty {
                SectionCard {
                    VStack(spacing: 0) {
                        if !primer.invariant.isEmpty {
                            BrainRow(title: "Invariant", subtitle: primer.invariant, subtitleLineLimit: 8)
                        }
                        if !primer.invariant.isEmpty, !primer.complexity.isEmpty {
                            PrepRowDivider()
                        }
                        if !primer.complexity.isEmpty {
                            BrainRow(title: "Complexity", subtitle: primer.complexity, subtitleLineLimit: 4)
                        }
                    }
                }
            }
        }
        if let reference = item.referenceMD, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Worked example")
                Text(verbatim: item.title)
                    .brainText(.rowTitle)
                    .fontWeight(.semibold)
                MarkdownRenderer(content: reference)
            }
        }
    }
}

// MARK: - Result

/// An answered rep: the graded options, the approach grade, or the bug revealed;
/// then the feedback with its first sentence in bold, the solution and video when
/// the server sends them. Continue is pinned by the run view.
struct PrepResultView: View {
    let rep: PrepRep
    let result: PrepAttemptResult
    let chosenID: String?
    /// The line tapped on a spot-the-bug rep, 0-based.
    var chosenLine: Int?
    /// The text typed on a cloze fact, shown beside the answer.
    var typedAnswer = ""

    var body: some View {
        switch rep.drill {
        case .complexity:
            PrepChoiceView(title: "Time complexity?", options: rep.item.options,
                           grading: .init(chosenID: chosenID, correctID: correctChoice)) { _ in }
        case .trace:
            PrepTraceCode(item: rep.item)
            PrepChoiceView(title: "What does it return?", options: rep.item.options,
                           grading: .init(chosenID: chosenID, correctID: correctChoice), monospaced: true) { _ in }
        case .approach:
            if result.isUngraded {
                PrepNoteCard {
                    Text(verbatim: "Saved — Atlas will grade this tonight.")
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.hxTextPrimary)
                }
            } else if let grade = result.grade {
                PrepApproachGradeView(grade: grade)
            }
        case .spotBug:
            spotBugReveal
        case .fact:
            if rep.item.format == "cloze" {
                PrepNoteCard {
                    PrepLeadText(lead: result.verdict == "pass" ? "Right." : "Not quite.",
                                 rest: "You wrote \u{201C}\(typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}. "
                                     + "The answer is \(correctChoice ?? "").")
                }
            } else {
                PrepChoiceView(title: "Your answer", options: rep.item.options,
                               grading: .init(chosenID: chosenID, correctID: correctChoice)) { _ in }
            }
        case .judgment:
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
        case .primer, .unknown:
            EmptyView()
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

        if let video = (result.links["video"] ?? rep.item.links["video"]).flatMap(URL.init(string:)) {
            Link(destination: video) {
                Label { Text(verbatim: "Watch NeetCode") } icon: { Image(systemName: "play.rectangle") }
                    .font(BrainStyle.rowTitle)
                    .frame(minHeight: BrainStyle.minTapTarget)
            }
        }
    }

    /// The code with the bug's line in green (and a wrong pick in red), then the fix.
    /// The server's feedback names the line, so the header doesn't repeat it.
    @ViewBuilder
    private var spotBugReveal: some View {
        let bug = correctBugFix
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "The code")
            PrepNumberedCode(code: rep.item.code, tint: { index in
                if index == bug?.line { return Color.hxSuccess.opacity(0.18) }
                if index == chosenLine { return Color.hxDanger.opacity(0.15) }
                return nil
            })
        }
        if let bug, !bug.fix.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Fix")
                PrepCodeCard {
                    PrepCodeLine(code: bug.fix)
                }
            }
        }
    }

    private var correctChoice: String? {
        if case let .choice(id)? = result.correct { return id }
        return nil
    }

    private var correctBugFix: (line: Int, fix: String)? {
        if case let .bugFix(line, fix)? = result.correct { return (line, fix) }
        return nil
    }
}

/// The grader's read of an approach: what landed, quoted in the serif; what was
/// missing and why; then what a strong answer says.
struct PrepApproachGradeView: View {
    let grade: PrepOpenGrade

    var body: some View {
        if !grade.skillsHit.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "What landed")
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(grade.skillsHit.enumerated()), id: \.offset) { offset, hit in
                            if offset > 0 { PrepRowDivider() }
                            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                                Text(verbatim: PrepCopy.rubricTitle(hit.skill)).brainText(.meta)
                                Text(verbatim: hit.quote)
                                    .brainText(.quote)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, BrainStyle.s)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        if !grade.skillsMissed.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "What was missing")
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(grade.skillsMissed.enumerated()), id: \.offset) { offset, miss in
                            if offset > 0 { PrepRowDivider() }
                            BrainRow(title: PrepCopy.rubricTitle(miss.skill),
                                     subtitle: miss.why.isEmpty ? nil : miss.why, subtitleLineLimit: 8,
                                     titleLineLimit: nil)
                        }
                    }
                }
            }
        }
        if !grade.strongAnswer.isEmpty {
            PrepNoteCard {
                HXSectionHeader(title: "What a strong answer says")
                Text(verbatim: grade.strongAnswer)
                    .brainText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A judgment card's grade: the points made, quoted in the serif; the points missed and why;
/// then what a strong answer says.
struct PrepJudgmentGradeView: View {
    let grade: PrepJudgmentGrade
    /// Each reference point's sentence by id; a point without one shows its id as a title.
    var pointTexts: [String: String] = [:]

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
                Text(verbatim: grade.strongAnswer)
                    .brainText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                .foregroundStyle(isKnownGap ? HermexPaper.request.glow : Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isKnownGap ? "arrow.triangle.branch" : "tray.and.arrow.down")
                .foregroundStyle(isKnownGap ? HermexPaper.request.glow : Color.hxTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .glowSurface(HermexPaper.request, cornerRadius: HXRadius.md)
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

/// The run's full-width primary action.
struct PrepPrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(AppFont.body(weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!enabled)
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

/// One line of code with a hanging indent: its leading spaces become padding and
/// wrapped continuation lines sit one step further in. No truncation, at least a
/// tap target tall.
struct PrepCodeLine: View {
    let code: String
    /// The width of one monospaced space at the footnote size, scaled with Dynamic Type.
    @ScaledMetric(relativeTo: .footnote) private var step: CGFloat = 7.8

    var body: some View {
        let parts = PrepCode.split(code)
        PrepHangingLayout(hang: step, indent: CGFloat(parts.indent) * step) {
            ForEach(Array(PrepCode.words(parts.text).enumerated()), id: \.offset) { _, word in
                Text(verbatim: word)
                    .font(AppFont.mono(style: .footnote))
                    .foregroundStyle(Color.hxTextPrimary)
                    .layoutValue(key: PrepTrailingSpace.self, value: word.hasSuffix(" ") ? step : 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: code))
    }
}

/// Splits a code line for rendering with a hanging indent.
enum PrepCode {
    /// The expanded detail's height: its natural height, never above the cap.
    static func expandedHeight(natural: CGFloat, cap: CGFloat) -> CGFloat {
        min(natural, cap)
    }

    /// More/Less only appears when there is something to reveal: an example or a summary
    /// longer than the two compact lines.
    static func canExpand(summary: String, example: String) -> Bool {
        !example.isEmpty || summary.count > 140
    }

    /// The leading indent in points, never more than half the width so deep nesting
    /// can't starve the text.
    static func clampedIndent(_ points: CGFloat, width: CGFloat) -> CGFloat {
        min(points, width * 0.5)
    }

    /// The leading whitespace as a space count (a tab is 4) and the rest of the line.
    static func split(_ line: String) -> (indent: Int, text: String) {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return (indent, String(rest))
    }

    /// The text cut after each space, so each piece carries its trailing space.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Lays words out left to right, wrapping at the proposed width; continuation lines
/// start `hang` in. A word wider than the room left goes on its own line and wraps itself.
struct PrepHangingLayout: Layout {
    var hang: CGFloat
    /// The unclamped leading indent, in points.
    var indent: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = arrange(width: width, subviews: subviews)
        // An unbounded proposal gets the content width, never infinity.
        return CGSize(width: width.isFinite ? width : result.size.width, height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = result.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width fullWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let lead = fullWidth.isFinite ? PrepCode.clampedIndent(indent, width: fullWidth) : indent
        let width = fullWidth - lead
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        var lineStart: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            // Fit is judged without the trailing space, which may hang past the edge.
            let trailing = Self.trailingSpace(subview)
            if x > lineStart, x + size.width - trailing > width + 0.5 {
                y += lineHeight
                lineStart = hang
                x = lineStart
                lineHeight = 0
            }
            if x + size.width - trailing > width + 0.5 {
                size = subview.sizeThatFits(ProposedViewSize(width: max(width - x, 1), height: nil))
            }
            frames.append(CGRect(x: x + lead, y: y, width: size.width, height: size.height))
            x += size.width
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x + lead)
        }
        return (frames, CGSize(width: maxX, height: y + lineHeight))
    }

    /// The width of a word's trailing space, from the layout value set by `PrepCodeLine`.
    private static func trailingSpace(_ subview: LayoutSubview) -> CGFloat {
        subview[PrepTrailingSpace.self]
    }
}

private struct PrepTrailingSpace: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Wraps its children onto as many lines as the proposed width needs, leading aligned.
struct PrepFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let result = arrange(width: width, subviews: subviews)
        // An unbounded proposal gets the content width, never infinity.
        return CGSize(width: width.isFinite ? width : result.size.width, height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
