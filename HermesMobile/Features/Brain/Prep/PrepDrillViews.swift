import SwiftUI

// The drills inside `PrepRunView`. Each view is handed values and closures by the
// run view and owns only presentation state (a timer start, an example toggle).

// MARK: - Problem card

/// The problem being drilled, pinned over the drill: meta, title, summary and a
/// "Show example" toggle. A primer shows the skill and its worked example instead.
struct PrepProblemCard: View {
    let meta: String
    let title: String
    let summary: String
    let example: String
    @State private var showsExample = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(rep: PrepRep) {
        let item = rep.item
        if rep.drill == .primer {
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
                .font(AppFont.headline())
                .foregroundStyle(Color.hxTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .brainText(.rowSubtitle)
                    // Pinned, so it must never fill the screen at accessibility sizes.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : nil)
            }
            if showsExample {
                Text(verbatim: example)
                    .font(AppFont.mono(style: .footnote))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : nil)
            }
            if !example.isEmpty {
                Button {
                    showsExample.toggle()
                } label: {
                    Text(verbatim: showsExample ? "Hide example" : "Show example")
                        .font(BrainStyle.rowSubtitle.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: BrainStyle.minTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.top, BrainStyle.cardVerticalPadding)
        .padding(.bottom, example.isEmpty ? BrainStyle.cardVerticalPadding : 0)
        .brainCardSurface()
    }
}

// MARK: - Choice (pattern_id, complexity)

/// The options as card rows. While answering, a pattern rep shows a 30-second
/// countdown (system-driven text, no repainting of ours). Once graded, the chosen
/// wrong option shows a red cross and the correct one a green check.
struct PrepChoiceView: View {
    struct Grading {
        let chosenID: String?
        let correctID: String?
    }

    let rep: PrepRep
    let grading: Grading?
    var isSubmitting = false
    var submitError: String?
    let onChoose: (PrepOption) -> Void
    @State private var shownAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HStack(alignment: .firstTextBaseline) {
                BrainSectionHeader(title: rep.drill == .patternID ? "Which pattern?" : "Time complexity?")
                if rep.drill == .patternID, grading == nil {
                    let window = shownAt...shownAt.addingTimeInterval(30)
                    Text(timerInterval: window, countsDown: true)
                        .brainText(.sectionCaption)
                        .monospacedDigit()
                        .fixedSize()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(verbatim: "Time left"))
                        .accessibilityValue(Text(timerInterval: window, countsDown: true))
                }
            }
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(rep.item.options.enumerated()), id: \.offset) { offset, option in
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
            let isCorrect = option.id == grading.correctID
            let isWrongPick = option.id == grading.chosenID && !isCorrect
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
                ? (option.id == grading.chosenID ? "Your answer, correct" : "Correct answer")
                : (isWrongPick ? "Your answer, wrong" : "")))
        } else {
            Button { onChoose(option) } label: {
                optionTitle(option)
                    .frame(minHeight: BrainStyle.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        }
    }

    private func optionTitle(_ option: PrepOption) -> some View {
        Text(verbatim: option.title)
            .brainText(.rowTitle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, BrainStyle.s)
    }
}

// MARK: - Parsons

/// Tap-to-place Parsons: the placed solution on top, the remaining lines below,
/// hints on request, and Check order once enough lines are placed.
struct PrepParsonsView: View {
    let hints: [String]
    let board: ParsonsBoard
    let hintsShown: Int
    let isSubmitting: Bool
    let submitError: String?
    let place: (Int) -> Void
    let unplace: (Int) -> Void
    let showHint: () -> Void
    let check: () -> Void

    private var target: Int { PrepCopy.parsonsTarget(poolCount: board.pool.count) }

    var body: some View {
        Text(verbatim: "Order the lines. One doesn't belong.")
            .brainText(.rowSubtitle)

        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Your solution", trailing: "\(board.placedIndices.count) / \(target)")
            PrepCodeCard {
                if board.placedIndices.isEmpty {
                    Text(verbatim: "Tap a line below to start")
                        .brainText(.rowSubtitle)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                } else {
                    ForEach(Array(board.placedIndices.enumerated()), id: \.element) { position, poolIndex in
                        let code = board.pool[poolIndex]
                        Button { unplace(position) } label: { PrepCodeLine(code: code) }
                            .buttonStyle(.plain)
                            .disabled(isSubmitting)
                            .accessibilityLabel(Text(verbatim: PrepCopy.parsonsPlacedLabel(position: position + 1, code: code)))
                    }
                }
            }
        }

        if !board.remaining.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Lines")
                PrepCodeCard {
                    ForEach(board.remaining, id: \.self) { poolIndex in
                        let code = board.pool[poolIndex]
                        Button { place(poolIndex) } label: { PrepCodeLine(code: code) }
                            .buttonStyle(.plain)
                            .disabled(isSubmitting)
                            .accessibilityLabel(Text(verbatim: PrepCopy.parsonsLineLabel(code)))
                    }
                }
            }
        }

        if hintsShown > 0 {
            PrepNoteCard {
                ForEach(0..<min(hintsShown, hints.count), id: \.self) { index in
                    PrepLeadText(lead: "Hint \(index + 1) of \(hints.count).", rest: hints[index])
                }
            }
        }

        VStack(spacing: BrainStyle.s) {
            PrepPrimaryButton(title: "Check order", enabled: board.isFull(target: target) && !isSubmitting, action: check)
            if let submitError {
                PrepSubmitError(message: submitError)
            }
            if hintsShown < hints.count {
                Button(action: showHint) {
                    Text(verbatim: "Show a hint")
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Primer

/// A new skill's primer: its signals, template, invariant and complexity, then
/// the worked example. "Got it" records it as seen.
struct PrepPrimerView: View {
    let item: PrepItemExcerpt
    let isSubmitting: Bool
    let submitError: String?
    let onAcknowledge: () -> Void

    var body: some View {
        if let primer = item.primer {
            if !primer.signals.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    BrainSectionHeader(title: "Signals")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BrainStyle.s) {
                            ForEach(Array(primer.signals.enumerated()), id: \.offset) { _, signal in
                                BrainTagChip(tag: signal)
                            }
                        }
                    }
                    .scrollClipDisabled()
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
        VStack(spacing: BrainStyle.s) {
            PrepPrimaryButton(title: "Got it", enabled: !isSubmitting, action: onAcknowledge)
            if let submitError {
                PrepSubmitError(message: submitError)
            }
        }
    }
}

// MARK: - Result

/// A graded rep: the graded options or the submitted lines, the feedback with its
/// first sentence in bold, the solution and video when the server sends them, and
/// Continue.
struct PrepResultView: View {
    let rep: PrepRep
    let result: PrepAttemptResult
    let chosenID: String?
    let placedLines: [String]
    let onContinue: () -> Void

    var body: some View {
        switch rep.drill {
        case .patternID, .complexity:
            PrepChoiceView(rep: rep, grading: .init(chosenID: chosenID, correctID: correctChoice)) { _ in }
        case .parsons where !placedLines.isEmpty:
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Your solution")
                PrepCodeCard {
                    ForEach(Array(placedLines.enumerated()), id: \.offset) { _, line in
                        PrepCodeLine(code: line)
                    }
                }
            }
        default:
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

        PrepPrimaryButton(title: "Continue", action: onContinue)
    }

    private var correctChoice: String? {
        if case let .choice(id)? = result.correct { return id }
        return nil
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

/// One line of code, indentation kept, at least a tap target tall.
struct PrepCodeLine: View {
    let code: String

    var body: some View {
        Text(verbatim: code)
            .font(AppFont.mono(style: .footnote))
            .foregroundStyle(Color.hxTextPrimary)
            .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
            .contentShape(Rectangle())
    }
}
