import SwiftUI

// The pieces of a lift on the workout screen (board 2C). The open lift is a `training` glow card
// drawn as several List rows (header, one row per set, the effort question, the footer) so each
// set can swipe to delete; `WorkoutCardPiece` (WorkoutView.swift) draws its slice of the card behind each row. Rows
// are `Equatable` on their data and act through the view model, so a tap redraws only its row.

/// The words and numbers the workout composes from a lift.
enum WorkoutCopy {
    /// "150", "42.5s", "BW", "Band", "Cable"; nil for a weighted lift with no weight yet.
    static func shortWeight(unit: String, weight: Double?) -> String? {
        switch unit {
        case "bw": "BW"
        case "band": "Band"
        case "cable": "Cable"
        case "lb_each": weight.map { "\(BodyFormat.number($0))s" }
        default: weight.map(BodyFormat.number)
        }
    }

    static func isWeighted(_ lift: BodyExercise) -> Bool {
        lift.unit == "lb" || lift.unit == "lb_each"
    }

    /// One set's count: "8", "10 s", "40 yd"; "—" when unset.
    static func count(_ value: Int?, _ measure: BodyMeasure) -> String {
        guard let value else { return "—" }
        switch measure {
        case .reps: return "\(value)"
        case .hold: return "\(value) s"
        case .distance: return "\(value) yd"
        }
    }

    /// "4 × 6–8", "3 × 10 s a side", "4 sets · Goal 8·7·6·6".
    static func scheme(_ lift: BodyExercise) -> String {
        let sets = lift.workSets.count
        if let goal = lift.goalReps, !goal.isEmpty { return "\(sets) sets · " + BodyHomeCopy.goalLabel(goal) }
        let side = lift.perSide ? " a side" : ""
        if let hold = lift.target.holdS { return "\(sets) × \(hold) s\(side)" }
        if let yards = lift.target.distanceYd { return "\(sets) × \(yards) yd\(side)" }
        if let lo = lift.target.reps?.first, let hi = lift.target.reps?.last {
            return "\(sets) × \(lo == hi ? "\(lo)" : "\(lo)–\(hi)")\(side)"
        }
        return sets == 1 ? "1 set" : "\(sets) sets"
    }

    /// An upcoming lift folded: "4 × 6–8 · 150".
    static func planLine(_ lift: BodyExercise) -> String {
        [scheme(lift), shortWeight(unit: lift.unit, weight: lift.workSets.first?.weight)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The open lift's line: "4 × 6–8 · last time 145 × 8 8 8 8".
    static func targetLine(_ lift: BodyExercise) -> String {
        guard BodyMeasure(lift) == .reps else { return scheme(lift) }
        let reps = lift.last.compactMap(\.reps)
        guard !reps.isEmpty else { return scheme(lift) }
        let weights = Set(lift.last.compactMap(\.weight))
        var last = reps.map(String.init).joined(separator: " ")
        if isWeighted(lift), weights.count == 1, let weight = shortWeight(unit: lift.unit, weight: weights.first) {
            last = "\(weight) × \(last)"
        }
        return "\(scheme(lift)) · last time \(last)"
    }

    /// A set's last time: "145 × 8", "BW × 12", "10 s", "50 · 40 yd"; "—" when there's none.
    static func lastTime(_ lift: BodyExercise, workIndex: Int?) -> String {
        guard let workIndex, lift.last.indices.contains(workIndex) else { return "—" }
        let last = lift.last[workIndex]
        let measure = BodyMeasure(lift)
        let weight = shortWeight(unit: lift.unit, weight: last.weight)
        let count = measure.count(last).map { self.count($0, measure) }
        // Only a weight he can change is worth repeating; "BW", "Band" and "Cable" would just echo the plan.
        let parts: [String?] = [isWeighted(lift) ? weight : nil, count]
        let text = parts.compactMap { $0 }.joined(separator: measure == .reps ? " × " : " · ")
        return text.isEmpty ? "—" : text
    }

    /// "↑ 5 lb today: every set hit 8 last time."; "a dumbbell" for dumbbell lifts.
    static func upNote(_ lift: BodyExercise) -> String? {
        guard lift.up, let from = lift.upFrom, let to = lift.workSets.first?.weight, to > from else { return nil }
        let each = lift.unit == "lb_each" ? " a dumbbell" : ""
        let why = lift.target.reps?.last.map { ": every set hit \($0) last time." } ?? "."
        return "↑ \(BodyFormat.number(to - from)) lb\(each) today\(why)"
    }

    /// A done lift folded: its reps, "8 8 8 7", or "3 sets" for holds and carries.
    static func doneSummary(_ lift: BodyExercise) -> String {
        let done = lift.workSets.filter(\.done)
        guard BodyMeasure(lift) == .reps else { return done.count == 1 ? "1 set" : "\(done.count) sets" }
        return done.map { $0.reps.map(String.init) ?? "—" }.joined(separator: " ")
    }

    static func weightHeader(_ lift: BodyExercise) -> String {
        switch lift.unit {
        case "lb": "lb"
        case "lb_each": "lb ea"
        default: ""
        }
    }

    static func countHeader(_ measure: BodyMeasure) -> String {
        switch measure {
        case .reps: "Reps"
        case .hold: "Hold"
        case .distance: "Yards"
        }
    }

    static func sectionTitle(_ section: BodySection) -> String {
        switch section {
        case .warmup: "Warm-up"
        case .main: "Main"
        case .superset: "Superset"
        case .optional: "Optional"
        case .finisher: "Finisher"
        }
    }

    /// "W" for a warm-up set, else the work set's number.
    static func tag(_ lift: BodyExercise, set s: Int) -> String {
        guard lift.sets.indices.contains(s), lift.sets[s].kind == .work else { return "W" }
        return "\(workIndex(lift, set: s).map { $0 + 1 } ?? 1)"
    }

    /// The set's place among the lift's work sets, or nil for a warm-up set.
    static func workIndex(_ lift: BodyExercise, set s: Int) -> Int? {
        guard lift.sets.indices.contains(s), lift.sets[s].kind == .work else { return nil }
        return lift.sets[..<s].filter { $0.kind == .work }.count
    }

    /// "Rough night: 5h 40m, rated 2", leaving out what Garmin didn't send.
    static func sleepTitle(_ offer: BodySleepOffer) -> String {
        var parts: [String] = []
        if let hours = offer.hours {
            let minutes = Int((hours * 60).rounded())
            parts.append("\(minutes / 60)h \(String(format: "%02d", minutes % 60))m")
        }
        if let quality = offer.quality { parts.append("rated \(quality)") }
        return parts.isEmpty ? "Rough night" : "Rough night: " + parts.joined(separator: ", ")
    }

    /// "You woke 40 min ago."; "under an hour" when the server didn't say.
    static func hingeTitle(minutes: Int?) -> String {
        guard let minutes else { return "You woke under an hour ago." }
        return "You woke \(minutes) min ago."
    }

    /// "Move RDLs to the end?"; other hinge lifts by name.
    static func hingeQuestion(_ names: [String]) -> String {
        let rdl = !names.isEmpty && names.allSatisfy { $0.localizedCaseInsensitiveContains("Romanian deadlift") }
        return "Move \(rdl ? "RDLs" : ListFormatter.localizedString(byJoining: names)) to the end?"
    }

    /// A number typed into a set's box: "137.5", or "137,5" from a comma keyboard; nil when the box
    /// is empty or doesn't read as a number at or above zero.
    static func typedNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// The phase subtitle: "Build", "Re-entry · Deload".
    static func phaseLabel(_ phase: String?, deload: Bool) -> String? {
        let label: String? = switch phase {
        case "recover": "Recover"
        case "reentry": "Re-entry"
        case "build", "before": "Build"
        case "newborn": "Newborn mode"
        default: nil
        }
        guard deload else { return label }
        return [label, "Deload"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Folded lift

/// A lift that isn't open: a check and its reps when done, its prescription when still to come.
struct WorkoutFoldedRow: View, Equatable {
    let lift: BodyExercise
    let index: Int
    let viewModel: WorkoutViewModel

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lift == rhs.lift && lhs.index == rhs.index
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        let done = WorkoutViewModel.isComplete(lift)
        let detail = done ? WorkoutCopy.doneSummary(lift) : WorkoutCopy.planLine(lift)
        Button { viewModel.open(exercise: index) } label: {
            HStack(spacing: 10) {
                ZStack {
                    if done {
                        Circle().fill(paper.glow)
                        Image(systemName: "checkmark")
                            .font(AppFont.caption2(weight: .heavy))
                            .foregroundStyle(paper.onGlow)
                    } else {
                        Circle().strokeBorder(Color.hxTextSecondary.opacity(0.6), lineWidth: 1.5)
                    }
                }
                .frame(width: 22, height: 22)
                Text(verbatim: lift.name)
                    .font(AppFont.subheadline())
                    .foregroundStyle(done ? Color.hxTextSecondary : Color.hxTextPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(verbatim: detail)
                    .font(AppFont.footnote())
                    .monospacedDigit()
                    .foregroundStyle(Color.hxTextSecondary)
                    .lineLimit(1)
                if !done, lift.up {
                    Text(verbatim: "↑")
                        .font(AppFont.subheadline(weight: .bold))
                        .foregroundStyle(paper.glow)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hxCard(cornerRadius: HXRadius.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: done
            ? "\(lift.name), done, \(detail)"
            : "\(lift.name), \(detail)\(lift.up ? ", going up" : "")"))
        .accessibilityHint(Text(verbatim: "Opens this lift"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Open lift

/// The set columns' widths, growing with Dynamic Type so the pills keep their numbers readable.
struct WorkoutColumns: DynamicProperty {
    @ScaledMetric(relativeTo: .body) var tag = WorkoutLayout.tagWidth
    @ScaledMetric(relativeTo: .body) var weight = WorkoutLayout.weightWidth
    @ScaledMetric(relativeTo: .body) var count = WorkoutLayout.countWidth
    @ScaledMetric(relativeTo: .body) var check = WorkoutLayout.checkSize
}

/// The open card's top: the name, the target and last time, why it went up, and the column labels.
struct WorkoutCardHeader: View, Equatable {
    let lift: BodyExercise
    private var columns = WorkoutColumns()

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.lift == rhs.lift }

    private var paper: HermexPaper { .training }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: lift.name)
                    .font(AppFont.display(style: .title2, weight: .bold))
                    .foregroundStyle(paper.glow)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: WorkoutCopy.targetLine(lift))
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                if let note = WorkoutCopy.upNote(lift) {
                    Text(verbatim: note)
                        .font(AppFont.footnote())
                        .foregroundStyle(paper.glow)
                }
                if let note = lift.note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: WorkoutLayout.columnSpacing) {
                Text(verbatim: "Set").frame(width: columns.tag, alignment: .leading)
                Text(verbatim: "Last time").frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: WorkoutCopy.weightHeader(lift)).frame(width: columns.weight)
                Text(verbatim: WorkoutCopy.countHeader(BodyMeasure(lift))).frame(width: columns.count)
                Color.clear.frame(width: columns.check, height: 1)
            }
            .font(AppFont.caption2(weight: .bold))
            .foregroundStyle(paper.glow)
            .lineLimit(1)
            .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }
}

/// An open superset's top: the lifts' names, each one's target and last time, and the column labels.
struct WorkoutPairHeader: View, Equatable {
    let lifts: [BodyExercise]
    private var columns = WorkoutColumns()

    init(lifts: [BodyExercise]) { self.lifts = lifts }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.lifts == rhs.lifts }

    private var paper: HermexPaper { .training }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: lifts.map(\.name).joined(separator: " + "))
                    .font(AppFont.display(style: .title2, weight: .bold))
                    .foregroundStyle(paper.glow)
                    .accessibilityAddTraits(.isHeader)
                ForEach(lifts) { lift in
                    (Text(verbatim: lift.name).fontWeight(.semibold) + Text(verbatim: " · \(WorkoutCopy.targetLine(lift))"))
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextPrimary)
                }
                Text(verbatim: "One set of each, then the next round.")
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: WorkoutLayout.columnSpacing) {
                Text(verbatim: "Set").frame(width: columns.tag, alignment: .leading)
                Text(verbatim: "Lift · last time").frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: lifts.lazy.map(WorkoutCopy.weightHeader).first { !$0.isEmpty } ?? "")
                    .frame(width: columns.weight)
                Text(verbatim: WorkoutCopy.countHeader(lifts.first.map(BodyMeasure.init) ?? .reps))
                    .frame(width: columns.count)
                Color.clear.frame(width: columns.check, height: 1)
            }
            .font(AppFont.caption2(weight: .bold))
            .foregroundStyle(paper.glow)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityHidden(true)
        }
        .padding(.bottom, 4)
    }
}

/// One set: its tag, last time, the weight and count boxes, and the 44 pt check. The row is
/// identified by the set's `uid`, so deleting a set takes its row with it. A box is a number he
/// types straight into: tapping it empties it over the old number, and the new one commits when
/// he leaves the box or ticks the set; leaving it empty keeps the old number. In a superset card
/// `named` puts the lift's name over its last time, so the interleaved rows say whose they are.
struct WorkoutSetRow: View, Equatable {
    let lift: BodyExercise
    let exercise: Int
    let index: Int
    let viewModel: WorkoutViewModel
    var named = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.exercise == rhs.exercise && lhs.index == rhs.index && lhs.row == rhs.row && lhs.named == rhs.named
            && lhs.tag == rhs.tag && lhs.lastTime == rhs.lastTime && lhs.lift.unit == rhs.lift.unit
            && lhs.lift.target == rhs.lift.target && lhs.lift.name == rhs.lift.name
    }

    private enum Field: Hashable { case weight, count }
    @FocusState private var focus: Field?
    /// What he has typed into the focused box so far.
    @State private var draft = ""
    private var columns = WorkoutColumns()

    init(lift: BodyExercise, exercise: Int, index: Int, viewModel: WorkoutViewModel, named: Bool = false) {
        self.lift = lift
        self.exercise = exercise
        self.index = index
        self.viewModel = viewModel
        self.named = named
    }

    private var paper: HermexPaper { .training }
    private var row: BodySet { lift.sets[index] }
    private var tag: String { WorkoutCopy.tag(lift, set: index) }
    private var lastTime: String { WorkoutCopy.lastTime(lift, workIndex: WorkoutCopy.workIndex(lift, set: index)) }
    private var measure: BodyMeasure { BodyMeasure(lift) }
    private var isWarm: Bool { row.kind == .warm }
    private var setName: String {
        if isWarm { return named ? "\(lift.name) warm-up set" : "Warm-up set" }
        return named ? "\(lift.name) set \(tag)" : "Set \(tag)"
    }

    var body: some View {
        HStack(spacing: WorkoutLayout.columnSpacing) {
            HStack(spacing: WorkoutLayout.columnSpacing) {
                Text(verbatim: tag)
                    .font(AppFont.subheadline(weight: .bold))
                    .foregroundStyle(isWarm ? Color.hxTextSecondary : paper.glow)
                    .frame(width: columns.tag, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    if named {
                        Text(verbatim: lift.name)
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                    }
                    Text(verbatim: lastTime)
                        .font(named ? AppFont.caption() : AppFont.subheadline())
                        .monospacedDigit()
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(setName), last time \(lastTime)"))
            if WorkoutCopy.isWeighted(lift) { weightBox } else { weightLabel }
            countBox
            check
        }
        .frame(minHeight: 48)
        .opacity(row.done ? 0.75 : 1)
        .onChange(of: focus) { old, _ in
            if let old { commit(old) }
            draft = ""
        }
    }

    private var weightText: String {
        WorkoutCopy.shortWeight(unit: lift.unit, weight: row.weight)
            .map { lift.unit == "lb_each" ? String($0.dropLast()) : $0 } ?? "—"
    }

    private var countText: String {
        WorkoutCopy.count(measure.count(row), measure).replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// Bodyweight, band and cable lifts have nothing to change: plain text where the box would be, so
    /// it doesn't look tappable.
    private var weightLabel: some View {
        Text(verbatim: weightText)
            .font(AppFont.subheadline())
            .foregroundStyle(Color.hxTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: columns.weight)
            .accessibilityLabel(Text(verbatim: "\(setName), \(BodyFormat.weightLabel(unit: lift.unit, weight: nil))"))
    }

    private var weightBox: some View {
        numberBox(.weight, shown: weightText, width: columns.weight,
                  label: "\(setName) weight, pounds\(lift.unit == "lb_each" ? " a dumbbell" : "")")
    }

    private var countBox: some View {
        numberBox(.count, shown: countText, width: columns.count,
                  label: "\(setName) \(WorkoutCopy.countHeader(measure).lowercased())")
    }

    private var check: some View {
        Button {
            // A number still being typed belongs to this set: land it before the tick.
            if let focus { commit(focus) }
            focus = nil
            viewModel.toggle(exercise: exercise, set: index)
        } label: {
            Image(systemName: "checkmark")
                .font(AppFont.headline(weight: .bold))
                .foregroundStyle(row.done ? paper.onGlow : Color.hxTextSecondary)
                .frame(width: columns.check, height: columns.check)
                .background(row.done ? paper.glow : Color.clear,
                            in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
                    .strokeBorder(row.done ? paper.glow : Color.hxTextSecondary.opacity(0.6), lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: row.done) { old, new in !old && new }
        .accessibilityLabel(Text(verbatim: row.done ? "\(setName) done" : "Mark \(setName.lowercased()) done"))
    }

    /// A 44 pt tall number box, as wide as its column, typed into in place. The set's number shows
    /// until he types, dimmed while the box has focus; the focused box wears the Nous-blue edge.
    private func numberBox(_ field: Field, shown: String, width: CGFloat, label: String) -> some View {
        let isFocused = focus == field
        let shape = RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
        let text = Binding(get: { focus == field ? draft : "" }, set: { if focus == field { draft = $0 } })
        return ZStack {
            if !isFocused || draft.isEmpty {
                Text(verbatim: shown)
                    .foregroundStyle(isFocused ? Color.hxTextSecondary : Color.hxTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextField(text: text) { Text(verbatim: label) }
                .keyboardType(field == .weight ? .decimalPad : .numberPad)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.hxTextPrimary)
                .focused($focus, equals: field)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityValue(Text(verbatim: shown))
        }
        .font(AppFont.body(weight: .semibold))
        .monospacedDigit()
        .padding(.horizontal, 4)
        .frame(width: width)
        .frame(minHeight: 44)
        .background(Color.hxCanvas, in: shape)
        .overlay(shape.strokeBorder(isFocused ? Color.accentColor : Color.hxSeparator, lineWidth: isFocused ? 1.5 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture { focus = field }
    }

    /// Lands what was typed into `field`. An empty or unreadable box changes nothing.
    private func commit(_ field: Field) {
        guard let value = WorkoutCopy.typedNumber(draft) else { return }
        switch field {
        case .weight:
            if value != row.weight { viewModel.setWeight(value, exercise: exercise, set: index) }
        case .count:
            let count = Int(value.rounded())
            if count != measure.count(row) { viewModel.setReps(count, exercise: exercise, set: index) }
        }
    }
}
