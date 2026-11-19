import SwiftUI

// Baki's coaching on the live workout: the offers above the lifts (the body check and his
// adjustments, in the rough-night banner's style), the cue inside the open lift's card, and what
// the card asks after each set. Rows are `Equatable` on their data and act through the view
// model, like the rest of the workout screen.

// MARK: - Offers

/// An offer above the lifts: a symbol and headline in the training glow, a line under it, and its
/// controls. The rough-night and morning-hinge offers, the body check and Baki's adjustments.
struct WorkoutOfferBanner<Actions: View>: View {
    let symbol: String
    let title: String
    var question: String?
    @ViewBuilder let actions: Actions

    private var paper: HermexPaper { .training }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(paper.glow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(AppFont.display(style: .headline, weight: .semibold))
                        .foregroundStyle(paper.glow)
                        .accessibilityAddTraits(.isHeader)
                    if let question, !question.isEmpty {
                        Text(verbatim: question)
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glowSurface(paper, cornerRadius: HXRadius.lg, opaque: true)
    }
}

/// An offer's two answers: side by side when they fit, stacked at large text sizes.
struct WorkoutOfferButtons: View {
    let primary: String
    let secondary: String
    var primaryEnabled = true
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(spacing: 8) { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: onPrimary) { Text(verbatim: primary).bodyTapHeight() }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
            .disabled(!primaryEnabled)
        Button(action: onSecondary) { Text(verbatim: secondary).bodyTapHeight() }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
    }
}

/// An offer once it is taken: what changed, in the training glow, and the way back ("Undo",
/// "Change", "Put them back"). A long line puts its button underneath.
struct WorkoutUndoLine: View {
    let text: String
    var action: String? = "Undo"
    let perform: () -> Void

    private var paper: HermexPaper { .training }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                line.lineLimit(1)
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .leading, spacing: 0) {
                line.fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                button
                if action == nil { Color.clear.frame(height: 12) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14)
        .glowSurface(paper, cornerRadius: HXRadius.md)
    }

    private var line: some View {
        Text(verbatim: text)
            .font(AppFont.subheadline())
            .foregroundStyle(paper.glow)
    }

    @ViewBuilder
    private var button: some View {
        if let action {
            Button(action: perform) {
                Text(verbatim: action)
                    .font(AppFont.subheadline(weight: .semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: "\(action): \(text)"))
        }
    }
}

/// "How's your body today?", the first thing on a fresh workout. All good clears it; Something's
/// sore opens the area and the 0 to 10 score in place. Once answered it is one line: what he
/// said, the lifts that are out, and Change or Put them back.
struct WorkoutBodyCheckBanner: View {
    let viewModel: WorkoutViewModel
    @State private var isSore = false
    @State private var area: BodyArea?
    @State private var score: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if viewModel.coach.bodyCheckBanner == .asking {
            WorkoutOfferBanner(symbol: "figure.stand", title: "How's your body today?") {
                if isSore {
                    sorePicker
                } else {
                    WorkoutOfferButtons(
                        primary: "All good", secondary: "Something's sore",
                        onPrimary: allGood,
                        onSecondary: { withAnimation(HXMotion.disclosure(reduceMotion: reduceMotion)) { isSore = true } })
                }
            }
        } else if let line = viewModel.bodyCheckLine {
            let action = viewModel.bodyCheckAction
            WorkoutUndoLine(text: line, action: action?.label) {
                if let action { perform(action) }
            }
        }
    }

    private var sorePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One row when the three fit; else the two short ones over the long one; else a column.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { areaChoices }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        areaChoice(.lowerBack)
                        areaChoice(.shoulders)
                    }
                    areaChoice(.shoulderBlades)
                }
                VStack(spacing: 6) { areaChoices }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "How bad? 0 is none, 10 is the worst")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                BodyPainStepper(score: score) { score = BodyPainScore.stepped(score, by: $0) }
            }
            WorkoutOfferButtons(primary: "Done", secondary: "All good", primaryEnabled: area != nil && score != nil,
                                onPrimary: done, onSecondary: allGood)
        }
    }

    @ViewBuilder
    private var areaChoices: some View {
        ForEach(BodyArea.allCases, id: \.self) { areaChoice($0) }
    }

    private func areaChoice(_ choice: BodyArea) -> some View {
        Button { area = choice } label: { Text(verbatim: choice.title).lineLimit(1).bodyTapHeight() }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: area == choice ? .primary : .secondary))
            .accessibilityAddTraits(area == choice ? .isSelected : [])
    }

    private func allGood() {
        isSore = false
        area = nil
        score = nil
        viewModel.answerBodyCheck(area: nil, score: 0)
    }

    /// Done needs an area and a score, and is off until he has given both.
    private func done() {
        guard let area, let score else { return }
        viewModel.answerBodyCheck(area: area, score: score)
    }

    private func perform(_ action: WorkoutBodyCheckAction) {
        switch action {
        case .change:
            // The picker opens on what he said before.
            if let check = viewModel.session?.bodyCheck {
                area = check.bodyArea
                score = check.score
                isSore = true
            }
            viewModel.changeBodyCheck()
        case .putBack:
            viewModel.putBackBodyCheckLifts()
        }
    }
}

/// One of Baki's adjustments: his question with its two answers, then the `done` line with Undo.
struct WorkoutAdjustmentBanner: View, Equatable {
    let row: WorkoutAdjustmentRow
    let viewModel: WorkoutViewModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    var body: some View {
        let adjustment = row.adjustment
        switch row.state {
        case .asking:
            WorkoutOfferBanner(symbol: "person.fill", title: adjustment.title, question: adjustment.question) {
                WorkoutOfferButtons(
                    primary: adjustment.use.isEmpty ? "Use" : adjustment.use,
                    secondary: adjustment.keep.isEmpty ? "Not now" : adjustment.keep,
                    onPrimary: { viewModel.useAdjustment(adjustment.id) },
                    onSecondary: { viewModel.keepAdjustment(adjustment.id) })
            }
        case .done(let canUndo):
            WorkoutUndoLine(text: adjustment.done.isEmpty ? adjustment.title : adjustment.done,
                            action: canUndo ? "Undo" : nil) {
                viewModel.undoAdjustment(adjustment.id)
            }
        }
    }
}

// MARK: - The cue

/// The link to a lift's Form page: "Form" and a chevron in the training glow, 44 pt tall.
struct WorkoutFormLink: View {
    let liftName: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Text(verbatim: "Form")
                Image(systemName: "chevron.right")
                    .font(AppFont.caption2(weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(HermexPaper.training.glow)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "Form for \(liftName)"))
        .accessibilityHint(Text(verbatim: "Opens the setup, cues and what goes wrong"))
    }
}

/// Baki's cue in the open lift's card, between its scheme and its sets: who is speaking and the
/// focus pips, the cue, his plan (or how many to leave in the tank), and the link to the Form
/// page, beside the slot the lift's diagram will fill. A retired cue leaves only the link.
struct WorkoutCueBlock: View {
    let lift: BodyExercise
    let openForm: () -> Void

    private var paper: HermexPaper { .training }

    var body: some View {
        if let coach = lift.coach {
            if coach.retired {
                WorkoutFormLink(liftName: lift.name, open: openForm)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    BakiRule()
                    HStack(alignment: .center, spacing: 10) {
                        words(coach).frame(maxWidth: .infinity, alignment: .leading)
                        CueDiagramSlot(liftID: lift.id)
                    }
                    .padding(.top, 10)
                    BakiRule()
                }
            }
        }
    }

    private func words(_ coach: BodyCoach) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                BodyCoachKicker(text: WorkoutCoach.cueKicker(coach))
                Spacer(minLength: 8)
                BodyFocusPips(checks: coach.checks)
            }
            if !coach.cue.isEmpty {
                Text(verbatim: coach.cue)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = WorkoutCoach.cueLine(coach) {
                Text(verbatim: line)
                    .font(AppFont.footnote())
                    .foregroundStyle(paper.glow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WorkoutFormLink(liftName: lift.name, open: openForm)
        }
    }
}

/// The cues in an open superset's card: one compact line a lift, "Face pull: Pull the rope to your
/// eyes", each with its own Form link.
struct WorkoutPairCues: View {
    let lifts: [BodyExercise]
    let openForm: (String) -> Void

    var body: some View {
        let coached = lifts.filter { $0.coach != nil }
        if !coached.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                BakiRule()
                ForEach(coached) { lift in
                    HStack(alignment: .center, spacing: 10) {
                        Text(verbatim: WorkoutCoach.pairedCue(lift))
                            .font(AppFont.footnote(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        WorkoutFormLink(liftName: lift.name) { openForm(lift.id) }
                    }
                }
                BakiRule()
            }
        }
    }
}

// MARK: - After a set

/// The open card's foot after a set: how many more the set he just ticked had in it (0, 1, 2 or
/// 3+, never needed to go on), the next set, and after the last set the coach's focus question
/// and a line on the sets that hit their targets.
struct WorkoutEffortRow: View, Equatable {
    let after: WorkoutAfterSet
    let exercise: Int
    let viewModel: WorkoutViewModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.after == rhs.after && lhs.exercise == rhs.exercise }

    private static let choices: [(value: Int, label: String, spoken: String)] = [
        (0, "0", "None left"), (1, "1", "One left"), (2, "2", "Two left"), (3, "3+", "Three or more left"),
    ]

    private var paper: HermexPaper { .training }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BakiRule()
            if let name = after.name {
                Text(verbatim: name)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(paper.glow)
            }
            if let question = after.question {
                title(question)
                HStack(spacing: 8) {
                    ForEach(Self.choices, id: \.value) { choice in
                        Button { viewModel.setRepsLeft(choice.value) } label: {
                            Text(verbatim: choice.label).monospacedDigit().bodyTapHeight()
                        }
                        .buttonStyle(ChatDecisionButtonStyle(emphasis: after.answer == choice.value ? .primary : .secondary))
                        .accessibilityLabel(Text(verbatim: choice.spoken))
                        .accessibilityAddTraits(after.answer == choice.value ? .isSelected : [])
                    }
                }
                if let next = after.next {
                    Text(verbatim: next)
                        .font(AppFont.footnote())
                        .foregroundStyle(.hxSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let ask = after.focusAsk {
                title(ask)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { focusChoices }
                    VStack(spacing: 8) { focusChoices }
                }
            }
            if let praise = after.praise {
                Text(verbatim: praise)
                    .font(AppFont.footnote())
                    .foregroundStyle(paper.glow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }

    private func title(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppFont.subheadline(weight: .semibold))
            .foregroundStyle(Color.hxTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var focusChoices: some View {
        ForEach(BodyFocusAnswer.allCases, id: \.self) { answer in
            Button { viewModel.setFocusCheck(answer, exercise: exercise) } label: {
                Text(verbatim: answer.label).bodyTapHeight()
            }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: after.focusAnswer == answer ? .primary : .secondary))
            .accessibilityAddTraits(after.focusAnswer == answer ? .isSelected : [])
        }
    }
}
