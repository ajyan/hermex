import SwiftUI

/// One personal goal: its paper hero (with the week strip that picks today or yesterday),
/// one-tap check-ins, daily checks, milestones, and a calendar of every day to the deadline.
/// Pushed as `.goal(slug)`.
struct GoalDetailView: View {
    @State private var viewModel: GoalDetailViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    init(slug: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        _viewModel = State(initialValue: GoalDetailViewModel(
            slug: slug, client: APIClientGoalsAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: navigationTitle))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
            // Back from the background, the server's today may have moved on.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await viewModel.load() } }
            }
    }

    /// The hero card carries the goal's title; the bar just says where you are.
    private var navigationTitle: String { "Goal" }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "Goal not found") } icon: { Image(systemName: "flag.checkered") }
            } description: {
                Text(verbatim: "It may have been closed or renamed.")
            }
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this goal", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let detail):
            let tint = GoalTint(GoalPaper.palette(for: detail.summary), scheme: colorScheme)
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    VStack(alignment: .leading, spacing: BrainStyle.m) {
                        GoalHeroCard(
                            goal: detail.summary,
                            why: detail.why,
                            selection: (detail.today, detail.yesterday, viewModel.day),
                            onSelect: { viewModel.day = $0 }
                        )
                        ForEach(detail.summary.flags.escalations, id: \.check) { escalation in
                            GoalNote(systemImage: "exclamationmark.triangle", tint: .hxWarning, text: escalation.say)
                        }
                        ForEach(detail.summary.flags.unlockReady, id: \.id) { unlock in
                            GoalNote(systemImage: "sparkles", tint: tint.fill, text: GoalDetailCopy.unlockOffer(unlock, in: detail.summary))
                        }
                    }
                    commitmentsSection(detail, tint: tint)
                    ForEach(detail.summary.dailyChecks) { check in
                        checkSection(check, tint: tint)
                    }
                    if !detail.milestones.isEmpty { milestonesSection(detail, tint: tint) }
                    consistencySection(detail, tint: tint)
                    planSection(detail)
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    // MARK: Check-ins

    private func commitmentsSection(_ d: GoalDetail, tint: GoalTint) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: viewModel.day == .today ? "Today" : "Yesterday")
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(d.summary.week.commitments.enumerated()), id: \.element.id) { offset, row in
                        if offset > 0 { PrepRowDivider() }
                        GoalCommitmentRow(
                            row: row,
                            day: viewModel.day,
                            tint: tint,
                            isPending: viewModel.pending.contains(row.id)
                        ) { status in
                            Task { await viewModel.checkIn(commitment: row.id, status: status) }
                        }
                    }
                }
            }
            if viewModel.day == .today, let missed = d.summary.week.commitments.first(where: { d.summary.flags.missTwice.contains($0.id) }) {
                Text(verbatim: "Missed \(GoalsCopy.shortName(missed.action).lowercased()) last night. Even the 2-min version counts.")
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxWarning)
            }
            if let error = viewModel.error {
                Text(verbatim: error).font(BrainStyle.meta).foregroundStyle(Color.hxDanger)
            }
        }
    }

    private func checkSection(_ check: GoalDailyCheck, tint: GoalTint) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: GoalDetailCopy.checkTitle(check.question))
            SectionCard {
                GoalChoiceRow(
                    options: check.options.map { ($0, $0.capitalized) },
                    selected: viewModel.day == .today ? check.today : check.yesterday,
                    tint: tint,
                    isDisabled: viewModel.pending.contains(check.id),
                    accessibilityPrefix: check.question
                ) { value in
                    Task { await viewModel.checkIn(check: check.id, value: value) }
                }
                .padding(.vertical, BrainStyle.xs)
            }
        }
    }

    // MARK: Milestones, consistency, plan

    private func milestonesSection(_ d: GoalDetail, tint: GoalTint) -> some View {
        let nextID = d.milestones.first { $0.done == nil }?.id
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Milestones")
            SectionCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(d.milestones.enumerated()), id: \.offset) { offset, m in
                        GoalMilestoneRow(
                            milestone: m,
                            today: d.today,
                            isNext: m.id == nextID,
                            isLast: offset == d.milestones.count - 1,
                            tint: tint
                        )
                    }
                }
            }
        }
    }

    private func consistencySection(_ d: GoalDetail, tint: GoalTint) -> some View {
        let shown = GoalCalendar.shownUp(heatmap: d.heatmap, today: d.today)
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Consistency")
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: GoalsCopy.streakTitle(d.streak.days)).brainText(.rowTitle)
                        Spacer(minLength: BrainStyle.s)
                        Text(verbatim: GoalDetailCopy.shownUpLine(shown)).brainText(.meta).monospacedDigit()
                    }
                    GoalCalendarGrid(
                        weeks: GoalCalendar.weeks(heatmap: d.heatmap, today: d.today, deadline: d.summary.deadline),
                        tint: tint
                    )
                }
                .padding(.vertical, BrainStyle.xs)
            }
        }
    }

    private func planSection(_ d: GoalDetail) -> some View {
        SectionCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    if !d.objective.isEmpty { Text(verbatim: d.objective).brainText(.rowSubtitle) }
                    ForEach(Array(d.doneWhen.enumerated()), id: \.offset) { _, item in
                        Label {
                            Text(verbatim: item.text).brainText(.rowSubtitle)
                        } icon: {
                            Image(systemName: item.checked ? "checkmark.square" : "square")
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                    }
                    if !d.obstacle.isEmpty { Text(verbatim: "Watch for: \(d.obstacle)").brainText(.meta) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, BrainStyle.s)
            } label: {
                Text(verbatim: "Plan").brainText(.rowTitle)
            }
            .tint(Color.hxTextSecondary)
            .padding(.vertical, BrainStyle.xs)
        }
    }
}

/// One commitment: short name and cue, with a check circle that marks Done on tap and
/// offers the 2-minute version, Skip and Missed on long press.
private struct GoalCommitmentRow: View {
    let row: GoalCommitmentProgress
    let day: GoalDay
    let tint: GoalTint
    let isPending: Bool
    let onSelect: (GoalStatus) -> Void

    var body: some View {
        let isDue = day == .today ? row.dueToday : row.dueYesterday
        let selected = day == .today ? row.today : row.yesterday
        HStack(spacing: BrainStyle.m) {
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: GoalsCopy.shortTitle(row.action)).brainText(.rowTitle)
                if !row.cue.isEmpty { Text(verbatim: row.cue).brainText(.rowSubtitle).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isDue || selected != nil ? 1 : 0.55)
            Menu {
                ForEach(GoalDetailCopy.statusOptions, id: \.value) { option in
                    let status = GoalStatus(rawValue: option.value) ?? .done
                    Button {
                        onSelect(status)
                    } label: {
                        Label(GoalDetailCopy.menuTitle(status, row: row), systemImage: GoalDetailCopy.symbol(status))
                    }
                    .disabled(status == .skip && GoalDetailCopy.skipDisabled(row, selected: selected))
                }
            } label: {
                GoalCheckCircle(status: selected, tint: tint, isPending: isPending)
            } primaryAction: {
                onSelect(.done)
            }
            .disabled(isPending)
            .accessibilityLabel(Text(verbatim: "\(GoalsCopy.shortTitle(row.action)), \(GoalDetailCopy.spoken(selected))"))
            .accessibilityHint(Text(verbatim: "Double-tap to mark done. Hold for more options."))
        }
        .padding(.vertical, BrainStyle.s)
        .frame(minHeight: BrainStyle.minTapTarget)
    }
}

/// The check circle: empty until checked in, then filled in the goal's tint (or amber for Missed).
private struct GoalCheckCircle: View {
    let status: GoalStatus?
    let tint: GoalTint
    let isPending: Bool
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    var body: some View {
        ZStack {
            switch status {
            case .some(.done), .some(.min):
                Circle().fill(status == .done ? tint.fill : tint.fill.opacity(0.55))
                Image(systemName: GoalDetailCopy.symbol(status!))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(tint.on)
            case .some(.skip):
                Circle().fill(Color.hxSeparator.opacity(0.7))
                Image(systemName: GoalDetailCopy.symbol(.skip)).font(.footnote.weight(.semibold)).foregroundStyle(Color.hxTextSecondary)
            case .some(.miss):
                Circle().strokeBorder(Color.hxWarning, lineWidth: 2)
                Image(systemName: GoalDetailCopy.symbol(.miss)).font(.footnote.weight(.bold)).foregroundStyle(Color.hxWarning)
            default:
                Circle().strokeBorder(tint.fill.opacity(0.7), lineWidth: 1.5)
            }
            if isPending { ProgressView().controlSize(.small) }
        }
        .frame(width: side, height: side)
        .frame(width: BrainStyle.minTapTarget, height: BrainStyle.minTapTarget)
        .contentShape(Rectangle())
    }
}

/// A row of capsule choices, the selected one filled with the goal's tint. Wraps to two
/// columns at accessibility text sizes.
private struct GoalChoiceRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let options: [(value: String, label: String)]
    let selected: String?
    let tint: GoalTint
    let isDisabled: Bool
    let accessibilityPrefix: String
    let onSelect: (String) -> Void

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : max(options.count, 1)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BrainStyle.s), count: columns),
                  spacing: BrainStyle.s) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selected
                Button { onSelect(option.value) } label: {
                    Text(verbatim: option.label)
                        .font(BrainStyle.rowSubtitle.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isSelected ? tint.on : Color.hxTextPrimary)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget - 8)
                        .background(isSelected ? tint.fill : Color.hxSeparator.opacity(0.45), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel(Text(verbatim: "\(accessibilityPrefix), \(option.label)"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// One milestone on a vertical line: filled when done, ringed when next, hollow later.
private struct GoalMilestoneRow: View {
    let milestone: GoalMilestone
    let today: String
    let isNext: Bool
    let isLast: Bool
    let tint: GoalTint

    var body: some View {
        HStack(alignment: .top, spacing: BrainStyle.m) {
            VStack(spacing: 0) {
                Circle()
                    .fill(milestone.done != nil || isNext ? tint.fill : Color.clear)
                    .overlay(Circle().strokeBorder(tint.fill.opacity(milestone.done != nil || isNext ? 1 : 0.4), lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .padding(.top, 5)
                if !isLast {
                    Rectangle().fill(tint.fill.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: milestone.title).brainText(.rowTitle)
                Text(verbatim: GoalDetailCopy.milestoneSubtitle(milestone, today: today)).brainText(.meta)
            }
            .padding(.bottom, isLast ? 0 : BrainStyle.m)
        }
        .padding(.vertical, BrainStyle.xs)
        .accessibilityElement(children: .combine)
    }
}

/// Every day from the goal's start to its deadline, Monday first, in the goal's tint.
private struct GoalCalendarGrid: View {
    let weeks: [[GoalCalendarDay?]]
    let tint: GoalTint

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, letter in
                Text(verbatim: letter).font(.caption2).foregroundStyle(Color.hxTextSecondary)
            }
            ForEach(Array(weeks.joined().enumerated()), id: \.offset) { _, day in
                if let day {
                    GoalCalendarCell(day: day, tint: tint)
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: GoalDetailCopy.calendarSummary(weeks)))
    }
}

private struct GoalCalendarCell: View {
    let day: GoalCalendarDay
    let tint: GoalTint

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let filled = !day.isFuture && (day.status != .none || day.isToday)
        ZStack {
            if day.isFuture {
                shape.strokeBorder(Color.hxSeparator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                shape.fill(GoalPaper.fill(day.status, ink: tint.fill))
            }
            if day.isToday { shape.strokeBorder(tint.fill, lineWidth: 2) }
            if day.isDeadline {
                Image(systemName: "flag.checkered").font(.caption2.weight(.semibold)).foregroundStyle(tint.fill)
            } else {
                Text(verbatim: "\(day.dayOfMonth)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(filled && day.status.isShown ? tint.on : Color.hxTextSecondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A one-line note under the hero: an escalation or an unlock offer.
private struct GoalNote: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        PrepNoteCard {
            Label { Text(verbatim: text).font(BrainStyle.rowSubtitle).foregroundStyle(Color.hxTextPrimary) } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
        }
    }
}

enum GoalDetailCopy {
    static let statusOptions: [(value: String, label: String)] = [
        ("done", "Done"), ("min", "2-min"), ("skip", "Skip"), ("miss", "Missed"),
    ]

    static func countLine(_ row: GoalCommitmentProgress) -> String {
        let shown = "\(row.done + row.min)/\(row.target)"
        guard row.skips > 0 else { return shown }
        let left = max(0, row.skips - row.skipped)
        return "\(shown) · \(left) skip\(left == 1 ? "" : "s") left"
    }

    /// Skip is off once the budget is spent, unless this day already holds the skip.
    static func skipDisabled(_ row: GoalCommitmentProgress, selected: GoalStatus?) -> Bool {
        selected != .skip && row.skipped >= row.skips
    }

    static func menuTitle(_ status: GoalStatus, row: GoalCommitmentProgress) -> String {
        switch status {
        case .done: return "Done"
        case .min: return row.minimum.isEmpty ? "2-minute version" : "2-minute version: \(row.minimum)"
        case .skip:
            let left = max(0, row.skips - row.skipped)
            return left == 1 ? "Skip (1 left)" : "Skip (\(left) left)"
        case .miss: return "Missed"
        case .none, .unknown: return ""
        }
    }

    static func symbol(_ status: GoalStatus) -> String {
        switch status {
        case .done: "checkmark"
        case .min: "timer"
        case .skip: "arrow.uturn.forward"
        case .miss: "xmark"
        case .none, .unknown: "circle"
        }
    }

    static func spoken(_ status: GoalStatus?) -> String {
        switch status {
        case .some(.done): "done"
        case .some(.min): "2-minute version"
        case .some(.skip): "skipped"
        case .some(.miss): "missed"
        default: "not checked in"
        }
    }

    /// "Foot today: better, same, or worse?" → "Foot today".
    static func checkTitle(_ question: String) -> String {
        let head = question.split(separator: ":").first.map(String.init) ?? question
        return head.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "?", with: "")
    }

    static func milestoneSubtitle(_ m: GoalMilestone, today: String) -> String {
        if m.done != nil { return "Done" }
        guard let due = m.due else { return "" }
        let relative = GoalsCopy.relativeDay(due, today: today)
        return relative.prefix(1).uppercased() + relative.dropFirst()
    }

    static func unlockOffer(_ unlock: GoalUnlock, in goal: GoalSummary) -> String {
        let after = goal.week.commitments.first { $0.id == unlock.after }?.action ?? unlock.after
        return "You held \(GoalsCopy.shortTitle(after).lowercased()) for a week. Ready to add \(unlock.action.lowercased())? Tell Atlas in chat."
    }

    static func shownUpLine(_ shown: (shown: Int, total: Int)) -> String {
        shown.total == 0 ? "Starts today" : "\(shown.shown) of \(shown.total) days"
    }

    static func calendarSummary(_ weeks: [[GoalCalendarDay?]]) -> String {
        let past = weeks.joined().compactMap { $0 }.filter { !$0.isFuture }
        let shown = past.filter { $0.status.isShown }.count
        let left = weeks.joined().compactMap { $0 }.filter(\.isFuture).count
        return "\(shown) of \(past.count) days shown up, \(left) days to go"
    }
}
