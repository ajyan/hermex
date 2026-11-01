import SwiftUI

/// Prep's landing screen, ordered by the goal: whether you're interview-ready (the mastery bar as four pips),
/// today's run (its one action), the weak spots (open gaps and missed lessons), practice out loud (the voice
/// mock ladders, a due one marked, and the story bank), then the course, folded to the unit being taught.
/// Pushed as `.brainRoute(.prep(.home))`; owns no `NavigationStack`.
struct PrepHomeView: View {
    @State private var viewModel: PrepHomeViewModel
    /// The voice mock ladders, loaded beside home; their section hides until they load.
    @State private var mockViewModel: PrepMockViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientPrepAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: PrepHomeViewModel(client: client, onAPIError: onAPIError))
        // Quiet: a server without mocks just has no section, and home reports its own failures.
        _mockViewModel = State(initialValue: PrepMockViewModel(client: client))
    }

    var body: some View {
        content
            .hxNavigationTitle("Interview prep")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { FeedbackMoreMenu() } }
            .feedbackContext(FeedbackContext(feature: "Prep", screen: "Home"))
            .background(Color.hxCanvas.ignoresSafeArea())
            // Every appear refreshes quietly, so a finished run or graded mock shows on the way back.
            .task { await load() }
    }

    private func load() async {
        async let mocks: Void = mockViewModel.load()
        await viewModel.load()
        await mocks
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            PrepFailedView(title: "Couldn't load Prep", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let home):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    if !home.readiness.isEmpty {
                        PrepReadinessRow(checks: home.readiness)
                    }
                    PrepTodayCard(run: home.run, streakDays: home.streak.days, today: viewModel.course?.today)
                    if viewModel.gaps != nil || viewModel.course != nil {
                        PrepWeakSpotsSection(gaps: viewModel.gaps ?? [], missed: PrepWeakSpotsSection.missed(in: viewModel.course))
                    }
                    mockSection
                    storiesSection
                    if let course = viewModel.course {
                        PrepUnitPath(course: course, catchingUp: home.run.catchingUp)
                    }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await load() }
        }
    }

    // MARK: Practice out loud

    @ViewBuilder
    private var mockSection: some View {
        if let mocks = mockViewModel.mocks {
            PrepMockSection(mocks: mocks, due: mocks.weeklyDue())
        }
    }

    // MARK: Stories

    @ViewBuilder
    private var storiesSection: some View {
        if let stories = viewModel.stories, !stories.stories.isEmpty || !stories.candidates.isEmpty || !stories.dismissed.isEmpty {
            PrepStorySection(
                list: stories, inFlight: viewModel.candidatesInFlight, errors: viewModel.candidateErrors,
                onAct: { candidate, action in
                    Task { await viewModel.act(on: candidate, action: action) }
                })
        }
    }
}

/// Today's run action as a small accent capsule: Start or Resume push the run;
/// Done is shown disabled once nothing is left today.
struct PrepRunButton: View {
    let action: PrepCopy.RunAction
    /// The readiness card's primary: full width, like Start call. Otherwise a compact capsule.
    var fullWidth = false
    /// Filled when it is the screen's main action; outlined when a due mock leads and the run follows.
    var prominent = true

    var body: some View {
        let title = fullWidth ? PrepCopy.runActionLongTitle(action) : PrepCopy.runActionTitle(action)
        if action == .done {
            label(title, enabled: false)
                .accessibilityLabel(Text(verbatim: "Today's run is done"))
        } else {
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.run))) {
                label(title, enabled: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: fullWidth ? title : "\(title) today's run"))
        }
    }

    private func label(_ title: String, enabled: Bool) -> some View {
        let filled = enabled && prominent
        return Text(verbatim: title)
            .font((fullWidth ? AppFont.body(weight: .semibold) : BrainStyle.rowSubtitle.weight(.semibold)))
            .foregroundStyle(filled ? Color.hxOnAccent : enabled ? Color.accentColor : Color.hxTextSecondary)
            .lineLimit(fullWidth ? 2 : 1)
            .fixedSize(horizontal: !fullWidth, vertical: true)
            .padding(.horizontal, BrainStyle.l)
            .padding(.vertical, BrainStyle.s)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: BrainStyle.minTapTarget)
            .background(filled ? Color.accentColor : enabled ? Color.clear : Color.hxSeparator.opacity(0.6), in: Capsule())
            .overlay { if enabled && !prominent { Capsule().strokeBorder(Color.accentColor, lineWidth: 1) } }
            .contentShape(Capsule())
    }
}

// MARK: - Shared Prep pieces

/// The hairline between rows inside a `SectionCard`.
struct PrepRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.hxSeparator)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// The "no Prep here" state: a stock server answers the tutor API with 404.
struct PrepUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: "No Prep on this server") } icon: { Image(systemName: "target") }
        } description: {
            Text(verbatim: "This server doesn't serve interview prep. It needs the tutor API from your hermes-webui fork.")
        }
    }
}

/// A load failure with a retry.
struct PrepFailedView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: title) } icon: { Image(systemName: "exclamationmark.triangle") }
        } description: {
            Text(verbatim: message)
        } actions: {
            Button(action: retry) { Text(verbatim: "Try again") }
        }
    }
}

// MARK: - Gaps

/// The weak spots on Prep home: open or improving gaps (a filled amber dot, or an amber ring while improving),
/// then learned lessons whose last recall missed (each one "Try it now" away), the first three shown with
/// "See all N" for the rest, and a "Closed this week" count.
struct PrepWeakSpotsSection: View {
    let gaps: [PrepGapSummary]
    let missed: [PrepLessonNode]
    @State private var showsAll = false
    private static let shown = 3

    /// The course's learned lessons whose latest recall wasn't a pass, in path order.
    static func missed(in course: PrepCourse?) -> [PrepLessonNode] {
        (course?.units ?? []).flatMap(\.lessons).filter { $0.state == .shaky }
    }

    private enum Spot: Identifiable {
        case gap(PrepGapSummary)
        case lesson(PrepLessonNode)
        var id: String {
            switch self {
            case .gap(let gap): "gap-\(gap.id)"
            case .lesson(let lesson): "lesson-\(lesson.id)"
            }
        }
    }

    private var spots: [Spot] {
        gaps.filter { $0.status == .open || $0.status == .improving }.map(Spot.gap) + missed.map(Spot.lesson)
    }
    private var closed: Int { gaps.filter { $0.status == .closed }.count }

    var body: some View {
        let spots = spots
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Weak spots", trailing: PrepCopy.weakSpotsHeader(
                gaps: gaps.filter { $0.status == .open || $0.status == .improving }.count, missed: missed.count))
            SectionCard {
                VStack(spacing: 0) {
                    if spots.isEmpty {
                        BrainRow(title: "Nothing open",
                                 subtitle: "A gap opens when the same point is missed across answers.")
                    }
                    ForEach(Array(spots.prefix(showsAll ? spots.count : Self.shown).enumerated()), id: \.element.id) { offset, spot in
                        if offset > 0 { PrepRowDivider() }
                        row(spot)
                    }
                    if spots.count > Self.shown {
                        PrepRowDivider()
                        PrepShowAllButton(showsAll: $showsAll, count: spots.count)
                    }
                    if closed > 0 {
                        PrepRowDivider()
                        BrainRow(title: "Gaps closed this week", trailing: "\(closed)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ spot: Spot) -> some View {
        switch spot {
        case .gap(let gap):
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.gap(gap.id)))) {
                BrainRow(leading: { PrepGapStatusDot(status: gap.status) }, title: gap.label,
                         trailing: PrepCopy.gapRowDetail(gap))
            }
            .buttonStyle(.plain)
        case .lesson(let lesson):
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.lessonRun(lesson.id)))) {
                BrainRow(leading: { PrepMissedLessonMark() }, title: lesson.title, subtitle: "Missed last recall",
                         trailing: "Try it now", trailingTint: Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: "Asks one question on this lesson now"))
        }
    }
}

/// A lesson whose last recall missed: an amber dashed ring, beside the gaps' amber dots.
private struct PrepMissedLessonMark: View {
    var body: some View {
        Circle()
            .strokeBorder(Color.hxWarning, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

/// A gap's status as a small mark: open a filled amber dot (it needs care, it didn't fail), improving an
/// amber ring, closed a gray dot. The shape tells open from improving as well as the fill.
struct PrepGapStatusDot: View {
    let status: PrepGapStatus

    var body: some View {
        Group {
            switch status {
            case .open: Circle().fill(Color.hxWarning)
            case .improving: Circle().strokeBorder(Color.hxWarning, lineWidth: 1.5)
            default: Circle().fill(Color.hxTextSecondary)
            }
        }
        .frame(width: 9, height: 9)
            .accessibilityLabel(Text(verbatim: status == .open ? "Open" : status == .improving ? "Improving" : "Closed"))
    }
}

/// One gap: what it is, the answers that showed it (quoted in the serif), and the cards that
/// target it. Pushed as `.brainRoute(.prep(.gap(id)))`; owns no `NavigationStack`.
struct PrepGapView: View {
    @State private var viewModel: PrepGapViewModel

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        _viewModel = State(initialValue: PrepGapViewModel(
            id: id, client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle(title)
            .feedbackContext(FeedbackContext(feature: "Prep", screen: "Gap"))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    private var title: String {
        if case .loaded(let gap) = viewModel.state, !gap.label.isEmpty { return gap.label }
        return "Gap"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this gap", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let gap):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    header(gap)
                    if gap.practice > 0 {
                        PrepPracticeLink(title: "Practice this gap",
                                         detail: PrepCopy.practiceDetail(gap.practice),
                                         route: .gapRun(gap.id))
                    }
                    if !gap.evidence.isEmpty { evidence(gap.evidence) }
                    if !gap.cards.isEmpty { cards(gap.cards) }
                    Text(verbatim: "A gap closes after you make its point on 3 different cards across 2 or more days.")
                        .brainText(.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func header(_ gap: PrepGapDetail) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HStack(spacing: BrainStyle.s) {
                HXChip(paper: .prep, label: statusWord(gap)) { EmptyView() }
                if let stage = PrepCopy.stageChip(gap.stage) {
                    HXChip(paper: .plain, label: stage) { EmptyView() }
                }
            }
            if !gap.summary.isEmpty {
                Text(verbatim: gap.summary)
                    .brainText(.rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusWord(_ gap: PrepGapDetail) -> String {
        switch gap.status {
        case .open: "Open · seen \(gap.misses)×"
        case .improving: "Improving · \(gap.hitsTowardClose) of 3 hits"
        case .closed: "Closed"
        case .unknown: "Gap"
        }
    }

    private func evidence(_ rows: [PrepGapEvidence]) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Your answers", count: rows.count)
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                        if offset > 0 { PrepRowDivider() }
                        VStack(alignment: .leading, spacing: BrainStyle.xs) {
                            Text(verbatim: [row.date.isEmpty ? "" : BrainStyle.displayDate(row.date), row.itemTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                                .brainText(.meta)
                                .lineLimit(2)
                            Text(verbatim: "\u{201C}\(row.quote)\u{201D}")
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

    private func cards(_ rows: [PrepGapCard]) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Cards that target it", count: rows.count)
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, card in
                        if offset > 0 { PrepRowDivider() }
                        BrainRow(
                            title: card.title,
                            subtitle: card.due.map { "Due \($0)" },
                            badge: card.isCoachWritten ? "Atlas" : nil
                        )
                    }
                }
            }
        }
    }
}

/// "See all 14" / "Show fewer" under a list cut to its first few rows.
struct PrepShowAllButton: View {
    @Binding var showsAll: Bool
    let count: Int

    var body: some View {
        Button {
            showsAll.toggle()
        } label: {
            Text(verbatim: showsAll ? "Show fewer" : "See all \(count)")
                .font(BrainStyle.rowSubtitle)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A full-width Nous-blue capsule that pushes a short practice run, with what it asks underneath:
/// "Practice this gap" on a gap, "Try it now" on a lesson.
struct PrepPracticeLink: View {
    let title: String
    let detail: String?
    let route: PrepRoute

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(route))) {
                Text(verbatim: title)
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(Color.hxOnAccent)
                    .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                    .background(Color.accentColor, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if let detail {
                Text(verbatim: detail)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
