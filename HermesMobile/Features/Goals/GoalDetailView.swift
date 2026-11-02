import SwiftUI

/// One personal goal: its paper hero, one-tap check-ins for today or yesterday, daily checks,
/// milestones, and a calendar of its days so far with a countdown to the deadline.
/// Pushed as `.goal(slug)`.
struct GoalDetailView: View {
    @State private var viewModel: GoalDetailViewModel
    /// The finished goal's record: the celebration sheet, then this screen, show it.
    @State private var record: GoalRecordViewModel?
    @State private var celebrating = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    private let client: GoalsDataClient
    private let onAPIError: (Error) -> Void
    /// After a check-in, finish or reopen lands: the widget refreshes for this server.
    private let onChange: @MainActor () -> Void

    init(slug: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientGoalsAdapter(apiClient: APIClient(baseURL: server))
        let onChange: @MainActor () -> Void = { GoalsWidgetSync.refreshAfterChange(server: server) }
        self.client = client
        self.onAPIError = onAPIError
        self.onChange = onChange
        _viewModel = State(initialValue: GoalDetailViewModel(
            slug: slug, client: client, onAPIError: onAPIError, onChange: onChange))
    }

    var body: some View {
        Group {
            if let record {
                GoalRecordContent(viewModel: record) { detail in
                    self.record = nil
                    viewModel.reopened(detail)
                }
            } else {
                content
            }
        }
        .hxNavigationTitle(record == nil ? viewModel.navigationTitle : "Finished", subtitle: record?.subtitle)
        .background(Color.hxCanvas.ignoresSafeArea())
        .task { if record == nil { await viewModel.load() } }
        // Back from the background, the server's today may have moved on.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, record == nil { Task { await viewModel.load() } }
        }
        .onChange(of: viewModel.finished) { _, finished in
            guard let finished, record == nil else { return }
            record = GoalRecordViewModel(slug: viewModel.slug, record: finished, client: client,
                                         onAPIError: onAPIError, onChange: onChange)
            celebrating = true
        }
        .sheet(isPresented: $celebrating) {
            if let record {
                GoalCelebrationView(viewModel: record) { celebrating = false }
            }
        }
    }

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
                    if let error = viewModel.error, viewModel.errorRow == nil {
                        GoalErrorLine(text: error)
                    }
                    if viewModel.asksToFinish {
                        GoalFinishPrompt(
                            goalTitle: detail.summary.title,
                            milestone: detail.milestones.last?.title ?? "",
                            paper: tint.paper,
                            isFinishing: viewModel.isFinishing,
                            onFinish: { Task { await viewModel.finish() } },
                            onNotYet: { viewModel.finishDeferred = true }
                        )
                    }
                    VStack(alignment: .leading, spacing: BrainStyle.m) {
                        GoalHeroCard(
                            goal: detail.summary,
                            why: detail.why,
                            today: detail.today,
                            checkIn: GoalHeroCheckIn(
                                today: detail.today, yesterday: detail.yesterday,
                                isPending: { viewModel.isPending(.commitment($0.id)) },
                                checkIn: { row, day, status in
                                    Task { await viewModel.checkIn(commitment: row.id, status: status, day: day) }
                                },
                                // Items count from their row below, where Add note and Undo follow.
                                addOne: nil
                            )
                        )
                        // Never miss twice is said once: the chip on the hero's commitment, and what
                        // to do about it on its Today row. An escalation is a chip in the goal's paper.
                        ForEach(detail.summary.flags.escalations, id: \.check) { escalation in
                            HXChip(paper: tint.paper, symbol: "exclamationmark.circle", label: escalation.say, lines: 2)
                        }
                        ForEach(detail.summary.flags.unlockReady, id: \.id) { unlock in
                            GoalNote(systemImage: "sparkles", tint: tint.fill, text: GoalDetailCopy.unlockOffer(unlock, in: detail.summary))
                        }
                    }
                    commitmentsSection(detail, tint: tint)
                    ForEach(detail.summary.dailyChecks) { check in
                        checkSection(check, tint: tint)
                    }
                    if !detail.milestones.isEmpty {
                        GoalMilestonesSection(milestones: detail.milestones, today: detail.today, tint: tint)
                    }
                    GoalConsistencySection(calendar: viewModel.calendar, countdown: viewModel.countdown, tint: tint)
                    if GoalDetailCopy.hasPlan(detail) { planSection(detail) }
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
            if viewModel.canCheckInYesterday {
                BrainSectionHeader(title: "Check in")
                Picker(selection: Binding(get: { viewModel.day }, set: { viewModel.day = $0 })) {
                    Text(verbatim: "Today").tag(GoalDay.today)
                    Text(verbatim: "Yesterday").tag(GoalDay.yesterday)
                } label: {
                    Text(verbatim: "Check in for")
                }
                .pickerStyle(.segmented)
            } else {
                BrainSectionHeader(title: viewModel.day == .today ? "Today" : "Yesterday")
            }
            // The plan's obstacle, where it helps: right above the day's check-ins.
            if let watchFor = GoalDetailCopy.watchFor(d.obstacle) {
                Text(verbatim: watchFor).brainText(.meta).fixedSize(horizontal: false, vertical: true)
            }
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(d.summary.week.commitments.enumerated()), id: \.element.id) { offset, row in
                        if offset > 0 { PrepRowDivider() }
                        // The hero already wears the at-risk chip; the row says what to do today.
                        if row.isItem {
                            GoalItemRow(
                                row: row,
                                tint: tint,
                                isPending: viewModel.isPending(.commitment(row.id)),
                                recentDate: viewModel.recentItems.date(for: .commitment(row.id)),
                                actions: viewModel.itemActions(row.id)
                            )
                        } else {
                            GoalCommitmentRow(
                                row: row,
                                day: viewModel.day,
                                date: viewModel.day == .today ? d.today : d.yesterday,
                                tint: tint,
                                isPending: viewModel.isPending(.commitment(row.id))
                            ) { status in
                                Task { await viewModel.checkIn(commitment: row.id, status: status) }
                            }
                        }
                        if let line = GoalDetailCopy.missTwiceAction(row, in: d.summary, day: viewModel.day) {
                            Label {
                                Text(verbatim: line)
                            } icon: {
                                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                            }
                            .font(BrainStyle.meta)
                            .foregroundStyle(tint.fill)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, BrainStyle.s)
                        }
                    }
                }
            }
            if let sourceErrors = GoalDetailCopy.sourceErrors(d.summary.sourceErrors) {
                Text(verbatim: sourceErrors)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
            }
            if let error = viewModel.error, case .commitment? = viewModel.errorRow {
                GoalErrorLine(text: error)
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
                    isDisabled: viewModel.isPending(.check(check.id)),
                    accessibilityPrefix: check.question
                ) { value in
                    Task { await viewModel.checkIn(check: check.id, value: value) }
                }
                .padding(.vertical, BrainStyle.xs)
            }
            if let error = viewModel.error, viewModel.errorRow == .check(check.id) {
                GoalErrorLine(text: error)
            }
        }
    }

    // MARK: Plan

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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, BrainStyle.s)
            } label: {
                Text(verbatim: "Plan")
                    .font(AppFont.display(style: .body))
                    .foregroundStyle(Color.hxTextPrimary)
            }
            .tint(Color.hxTextSecondary)
            .padding(.vertical, BrainStyle.xs)
        }
    }
}

/// A failed save or refresh, said where it happened.
private struct GoalErrorLine: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(BrainStyle.meta).foregroundStyle(Color.hxDanger)
    }
}

/// The milestones on their line. Its own view, so a check-in elsewhere on the screen leaves it be.
private struct GoalMilestonesSection: View {
    let milestones: [GoalMilestone]
    let today: String
    let tint: GoalTint

    var body: some View {
        let nextID = milestones.first { $0.done == nil }?.id
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Milestones")
            SectionCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(milestones.enumerated()), id: \.element.id) { offset, m in
                        GoalMilestoneRow(
                            milestone: m,
                            today: today,
                            isNext: m.id == nextID,
                            isLast: offset == milestones.count - 1,
                            tint: tint
                        )
                    }
                }
            }
        }
    }
}

/// The check circle: empty until checked in, then filled in the goal's tint; Missed is a neutral
/// ring with its xmark.
struct GoalCheckCircle: View {
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
                    .font(AppFont.footnote(weight: .bold))
                    .foregroundStyle(tint.on)
            case .some(.skip):
                Circle().fill(Color.hxSeparator.opacity(0.7))
                Image(systemName: GoalDetailCopy.symbol(.skip)).font(AppFont.footnote(weight: .semibold)).foregroundStyle(Color.hxTextSecondary)
            case .some(.miss):
                // A miss is a fact, not an alarm: neutral ink and its mark, never amber.
                Circle().strokeBorder(Color.hxSeparator, lineWidth: 2)
                Image(systemName: GoalDetailCopy.symbol(.miss)).font(AppFont.footnote(weight: .bold)).foregroundStyle(Color.hxTextSecondary)
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
struct GoalChoiceRow: View {
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
                  spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selected
                // Tapping the selected answer again clears it.
                Button { onSelect(isSelected ? GoalCheckValue.clear : option.value) } label: {
                    Text(verbatim: option.label)
                        .font(BrainStyle.rowSubtitle.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isSelected ? tint.on : Color.hxTextPrimary)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget - 8)
                        .background(isSelected ? tint.fill : Color.hxSeparator.opacity(0.45), in: Capsule())
                        .frame(minHeight: BrainStyle.minTapTarget)
                        .contentShape(Rectangle())
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

/// A one-line note under the hero: an unlock offer (and, on the Daily Brief's goal card, the
/// never-miss-twice nudge).
struct GoalNote: View {
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

    /// "Watch for: Late bedtime…" over the Today check-ins; nil when the plan names no obstacle.
    static func watchFor(_ obstacle: String) -> String? {
        let text = obstacle.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : "Watch for: \(text)"
    }

    /// The Plan disclosure has something left once the obstacle moved up to Today.
    static func hasPlan(_ detail: GoalDetail) -> Bool {
        !detail.objective.isEmpty || !detail.doneWhen.isEmpty
    }

    /// The commitments the server flags as never-miss-twice, in the week's order.
    static func missTwiceRows(_ goal: GoalSummary) -> [GoalCommitmentProgress] {
        goal.week.commitments.filter { goal.flags.missTwice.contains($0.id) }
    }

    /// What to do about a never-miss-twice flag, under its row on the detail's Today list (the
    /// hero's chip already says it's at risk): nil for an unflagged row, or when checking in for
    /// yesterday.
    static func missTwiceAction(_ row: GoalCommitmentProgress, in goal: GoalSummary, day: GoalDay) -> String? {
        guard day == .today, goal.flags.missTwice.contains(row.id) else { return nil }
        return row.isItem ? "One today counts." : "Missed yesterday. Even the 2-min version counts."
    }

    /// The nudge before a second miss in a row: a day commitment missed yesterday, or an item
    /// commitment short of its target two weeks running. The Daily Brief's goal card says it whole.
    static func missTwice(_ row: GoalCommitmentProgress) -> String {
        let name = GoalsCopy.shortName(row.action).lowercased()
        return row.isItem
            ? "Short on \(name) two weeks running. One today counts."
            : "Missed \(name) yesterday. Even the 2-min version counts."
    }

    /// The server's `source_errors` ("prep.days: attempts file not found"), one line each:
    /// "Couldn't count Prep: attempts file not found". Nil when every source counted.
    static func sourceErrors(_ errors: [String]) -> String? {
        guard !errors.isEmpty else { return nil }
        return errors.map { error in
            guard let colon = error.range(of: ": ") else { return "Couldn't count \(error)" }
            let source = String(error[..<colon.lowerBound])
            let reason = String(error[colon.upperBound...])
            return "Couldn't count \(source == "prep.days" ? "Prep" : source): \(reason)"
        }.joined(separator: "\n")
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
        case .none, .clear, .unknown: return ""
        }
    }

    static func symbol(_ status: GoalStatus) -> String {
        switch status {
        case .done: "checkmark"
        case .min: "timer"
        case .skip: "arrow.uturn.forward"
        case .miss: "xmark"
        case .clear: "arrow.uturn.backward"
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

    /// This goal's own consistency over its days so far: "Showed up 16 of 18 days".
    static func shownUpLine(_ shown: (shown: Int, total: Int)) -> String {
        shown.total == 0 ? "Starts today" : "Showed up \(shown.shown) of \(shown.total) days"
    }

    private static let deadlineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d"
        return f
    }()

    /// Under the calendar, the days still ahead: "118 days to Sun Feb 28"; nil without a deadline.
    static func countdown(today: String, deadline: String?) -> String? {
        guard let deadline, let date = GoalCalendar.date(deadline),
              let n = GoalCalendar.days(from: today, to: deadline) else { return nil }
        let day = deadlineFormatter.string(from: date)
        switch n {
        case 0: return "Due today, \(day)"
        case 1: return "1 day to \(day)"
        case let n where n > 1: return "\(n) days to \(day)"
        case -1: return "1 day past \(day)"
        default: return "\(-n) days past \(day)"
        }
    }

    /// The detail calendar for VoiceOver: "Showed up 16 of 18 days. 118 days to Sun Feb 28".
    static func consistencySummary(shown: Int, total: Int, countdown: String?) -> String {
        [shownUpLine((shown, total)), countdown].compactMap { $0 }.joined(separator: ". ")
    }

    static func calendarSummary(_ weeks: [[GoalCalendarDay?]]) -> String {
        let past = weeks.joined().compactMap { $0 }.filter { !$0.isFuture }
        let shown = past.filter { $0.status.isShown }.count
        let left = weeks.joined().compactMap { $0 }.filter(\.isFuture).count
        return "\(shown) of \(past.count) days shown up, \(left) days to go"
    }
}
