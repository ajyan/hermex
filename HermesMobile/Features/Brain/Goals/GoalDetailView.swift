import SwiftUI

/// One personal goal: why it matters, this week's commitments with one-tap check-ins for
/// today or yesterday, daily checks, milestones, and the consistency heatmap.
/// Pushed as `.brainRoute(.goals(.detail(slug)))`.
struct GoalDetailView: View {
    @State private var viewModel: GoalDetailViewModel
    @Environment(\.scenePhase) private var scenePhase

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

    private var navigationTitle: String {
        if case .loaded(let d) = viewModel.state { return d.summary.title }
        return "Goal"
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
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    header(detail)
                    ForEach(detail.summary.flags.escalations, id: \.check) { escalation in
                        PrepNoteCard {
                            Label { Text(verbatim: escalation.say) } icon: {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.hxWarning)
                            }
                            .font(BrainStyle.rowTitle)
                        }
                    }
                    ForEach(detail.summary.flags.unlockReady, id: \.id) { unlock in
                        PrepNoteCard {
                            Text(verbatim: GoalDetailCopy.unlockOffer(unlock, in: detail.summary))
                                .font(BrainStyle.rowSubtitle)
                                .foregroundStyle(Color.hxTextPrimary)
                        }
                    }
                    weekSection(detail)
                    if !detail.summary.dailyChecks.isEmpty { checksSection(detail) }
                    if !detail.milestones.isEmpty { milestonesSection(detail) }
                    consistencySection(detail)
                    planSection(detail)
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    // MARK: Header

    private func header(_ d: GoalDetail) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Text(verbatim: d.summary.title).brainText(.readerTitle)
            if !d.summary.identity.isEmpty {
                Text(verbatim: d.summary.identity.prefix(1).uppercased() + d.summary.identity.dropFirst())
                    .brainText(.quote)
            }
            if !d.why.isEmpty { Text(verbatim: d.why).brainText(.rowSubtitle) }
            if let days = d.summary.daysLeft, let deadline = d.summary.deadline {
                Text(verbatim: "\(days) days · \(deadline)").brainText(.meta).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: This week

    private func weekSection(_ d: GoalDetail) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "This week")
            Picker(selection: $viewModel.day) {
                Text(verbatim: "Yesterday").tag(GoalDay.yesterday)
                Text(verbatim: "Today").tag(GoalDay.today)
            } label: {
                Text(verbatim: "Check in for")
            }
            .pickerStyle(.segmented)
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(d.summary.week.commitments.enumerated()), id: \.element.id) { offset, row in
                        if offset > 0 { PrepRowDivider() }
                        GoalCommitmentRow(
                            row: row,
                            day: viewModel.day,
                            missTwice: d.summary.flags.missTwice.contains(row.id),
                            isPending: viewModel.pending.contains(row.id)
                        ) { status in
                            Task { await viewModel.checkIn(commitment: row.id, status: status) }
                        }
                    }
                }
            }
            if let error = viewModel.error {
                Text(verbatim: error).font(BrainStyle.meta).foregroundStyle(Color.hxDanger)
            }
        }
    }

    private func checksSection(_ d: GoalDetail) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Daily checks")
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(d.summary.dailyChecks.enumerated()), id: \.element.id) { offset, check in
                        if offset > 0 { PrepRowDivider() }
                        VStack(alignment: .leading, spacing: BrainStyle.s) {
                            Text(verbatim: check.question).brainText(.rowTitle)
                            let selected = viewModel.day == .today ? check.today : check.yesterday
                            GoalChoiceRow(
                                options: check.options.map { ($0, $0.capitalized) },
                                selected: selected,
                                isDisabled: viewModel.pending.contains(check.id),
                                accessibilityPrefix: check.question
                            ) { value in
                                Task { await viewModel.checkIn(check: check.id, value: value) }
                            }
                        }
                        .padding(.vertical, BrainStyle.s)
                    }
                }
            }
        }
    }

    // MARK: Milestones, consistency, plan

    private func milestonesSection(_ d: GoalDetail) -> some View {
        let nextID = d.milestones.first { $0.done == nil }?.id
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Milestones")
            SectionCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(d.milestones.enumerated()), id: \.element.id) { offset, m in
                        if offset > 0 { PrepRowDivider() }
                        BrainRow(
                            leading: {
                                Image(systemName: m.done != nil ? "checkmark.circle.fill" : (m.id == nextID ? "circle.inset.filled" : "circle"))
                                    .foregroundStyle(m.done != nil ? Color.hxSuccess : Color.hxTextSecondary)
                                    .accessibilityHidden(true)
                            },
                            title: m.title,
                            subtitle: m.done != nil ? "Done" : m.due.map { GoalsCopy.relativeDay($0, today: d.today).capitalizingFirst }
                        )
                    }
                }
            }
        }
    }

    private func consistencySection(_ d: GoalDetail) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Consistency")
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    Text(verbatim: GoalDetailCopy.consistencyLine(d.consistency)).brainText(.rowTitle)
                    GoalHeatmapView(days: d.heatmap)
                }
                .padding(.vertical, BrainStyle.s)
            }
        }
    }

    private func planSection(_ d: GoalDetail) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                if !d.objective.isEmpty { Text(verbatim: d.objective).brainText(.rowSubtitle) }
                ForEach(d.doneWhen, id: \.text) { item in
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
            Text(verbatim: "Plan").brainText(.sectionCaption).fontWeight(.semibold)
        }
    }
}

/// One commitment: name, this week's count, cue and 2-minute version, then the four
/// status buttons for the selected day.
private struct GoalCommitmentRow: View {
    let row: GoalCommitmentProgress
    let day: GoalDay
    let missTwice: Bool
    let isPending: Bool
    let onSelect: (GoalStatus) -> Void

    var body: some View {
        let isDue = day == .today ? row.dueToday : row.dueYesterday
        let selected = day == .today ? row.today : row.yesterday
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: row.action).brainText(.rowTitle)
                Text(verbatim: GoalDetailCopy.countLine(row)).brainText(.meta).monospacedDigit()
                if !row.cue.isEmpty { Text(verbatim: row.cue).brainText(.rowSubtitle) }
                if !row.minimum.isEmpty { Text(verbatim: "2-min: \(row.minimum)").brainText(.meta) }
            }
            .accessibilityElement(children: .combine)
            .opacity(isDue ? 1 : 0.6)
            GoalChoiceRow(
                options: GoalDetailCopy.statusOptions,
                selected: selected?.rawValue,
                disabledValues: GoalDetailCopy.skipDisabled(row, selected: selected) ? ["skip"] : [],
                isDisabled: isPending,
                accessibilityPrefix: row.action
            ) { value in
                onSelect(GoalStatus(rawValue: value) ?? .done)
            }
            if missTwice, day == .today {
                Text(verbatim: "Missed yesterday — even the 2-min version counts today.")
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxWarning)
            }
        }
        .padding(.vertical, BrainStyle.s)
    }
}

/// A row of capsule buttons; the selected one is filled with the accent.
private struct GoalChoiceRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let options: [(value: String, label: String)]
    let selected: String?
    var disabledValues: Set<String> = []
    let isDisabled: Bool
    let accessibilityPrefix: String
    let onSelect: (String) -> Void

    var body: some View {
        // Four capsules don't fit one row at accessibility sizes; two rows of two do.
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : max(options.count, 1)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BrainStyle.s), count: columns),
                  spacing: BrainStyle.s) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selected
                let isOff = isDisabled || (disabledValues.contains(option.value) && !isSelected)
                Button { onSelect(option.value) } label: {
                    Text(verbatim: option.label)
                        .font(BrainStyle.rowSubtitle.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isSelected ? Color.hxOnAccent : Color.hxTextPrimary)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget - 8)
                        .background(isSelected ? Color.accentColor : Color.hxSeparator.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isOff)
                .opacity(isOff && !isSelected ? 0.5 : 1)
                .accessibilityLabel(Text(verbatim: "\(accessibilityPrefix), \(option.label)"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// Every day since the goal began, as week columns of seven squares (Monday on top).
private struct GoalHeatmapView: View {
    let days: [GoalHeatDay]
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 10

    var body: some View {
        let columns = GoalDetailCopy.heatmapColumns(days)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(week[i].map(Self.color) ?? Color.clear)
                                .frame(width: side, height: side)
                        }
                    }
                }
            }
        }
        .defaultScrollAnchor(.trailing)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: GoalDetailCopy.heatmapSummary(days)))
    }

    private static func color(_ status: GoalStatus) -> Color {
        switch status {
        case .done: Color.hxSuccess
        case .min: Color.hxSuccess.opacity(0.5)
        case .skip: Color.hxTextSecondary.opacity(0.35)
        case .miss: Color.hxDanger.opacity(0.45)
        case .none, .unknown: Color.hxSeparator
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

    static func consistencyLine(_ c: GoalConsistency) -> String {
        c.weeks == 0 ? "First week in progress" : "\(c.weeksHit) of \(c.weeks) weeks hit"
    }

    static func unlockOffer(_ unlock: GoalUnlock, in goal: GoalSummary) -> String {
        let after = goal.week.commitments.first { $0.id == unlock.after }?.action ?? unlock.after
        return "You held \(after.lowercased()) for a week. Ready to add \(unlock.action.lowercased())? Tell Atlas in chat."
    }

    /// Week columns of seven optional days, Monday first, padded before the first day.
    static func heatmapColumns(_ days: [GoalHeatDay]) -> [[GoalStatus?]] {
        guard let first = days.first, let start = GoalsCopy.isoDay(first.date) else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let lead = (cal.component(.weekday, from: start) + 5) % 7  // Monday = 0
        var cells: [GoalStatus?] = Array(repeating: nil, count: lead) + days.map { $0.status }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    static func heatmapSummary(_ days: [GoalHeatDay]) -> String {
        let shown = days.filter { $0.status.isShown }.count
        return "\(shown) days shown up of \(days.count)"
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
