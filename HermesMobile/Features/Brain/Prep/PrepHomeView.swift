import SwiftUI

/// Prep's landing screen: today's ring card, then interview practice (the voice mock ladders and the
/// story bank), then the course's unit path and the gaps. Pushed as `.brainRoute(.prep(.home))`;
/// owns no `NavigationStack`.
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
                    if let course = viewModel.course {
                        PrepTodayRingCard(course: course, streak: home.streak,
                                          action: PrepCopy.runAction(reps: home.run.reps, remaining: home.run.remaining))
                    }
                    // Interview practice first: the mock ladders, then the story bank.
                    mockSection
                    storiesSection
                    if let course = viewModel.course {
                        PrepUnitPath(course: course)
                    }
                    if let gaps = viewModel.gaps {
                        PrepGapsSection(gaps: gaps)
                    }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await load() }
        }
    }

    // MARK: Mocks

    @ViewBuilder
    private var mockSection: some View {
        if let mocks = mockViewModel.mocks {
            PrepMockSection(mocks: mocks)
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

    var body: some View {
        let title = PrepCopy.runActionTitle(action)
        if action == .done {
            label(title, enabled: false)
                .accessibilityLabel(Text(verbatim: "Today's run is done"))
        } else {
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.run))) {
                label(title, enabled: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(title) today's run"))
        }
    }

    private func label(_ title: String, enabled: Bool) -> some View {
        Text(verbatim: title)
            .font(BrainStyle.rowSubtitle.weight(.semibold))
            .foregroundStyle(enabled ? Color.hxOnAccent : Color.hxTextSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, BrainStyle.l)
            .padding(.vertical, BrainStyle.s)
            .background(enabled ? Color.accentColor : Color.hxSeparator.opacity(0.6), in: Capsule())
            .frame(minHeight: BrainStyle.minTapTarget)
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

/// The gap ledger on Prep home: open gaps (red dot) and improving ones (amber dot), each
/// pushing its detail, then a "Closed this week" count. Replaces "Needs work" when the server
/// has the gaps route.
struct PrepGapsSection: View {
    let gaps: [PrepGapSummary]

    private var active: [PrepGapSummary] { gaps.filter { $0.status == .open || $0.status == .improving } }
    private var closed: Int { gaps.filter { $0.status == .closed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(
                title: "Gaps",
                trailing: PrepCopy.gapsHeader(open: gaps.filter { $0.status == .open }.count,
                                              improving: gaps.filter { $0.status == .improving }.count))
            SectionCard {
                VStack(spacing: 0) {
                    if active.isEmpty {
                        BrainRow(title: "No open gaps",
                                 subtitle: "Atlas names a gap when the same point is missed across answers.")
                    }
                    ForEach(Array(active.enumerated()), id: \.element.id) { offset, gap in
                        if offset > 0 { PrepRowDivider() }
                        NavigationLink(value: ShellPushDestination.brainRoute(.prep(.gap(gap.id)))) {
                            BrainRow(
                                leading: { PrepGapStatusDot(status: gap.status) },
                                title: gap.label,
                                subtitle: PrepCopy.stageChip(gap.stage),
                                trailing: PrepCopy.gapRowDetail(gap)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if closed > 0 {
                        PrepRowDivider()
                        BrainRow(title: "Closed this week", trailing: "\(closed)")
                    }
                }
            }
        }
    }
}

/// A gap's status as a small dot: open in the danger tint, improving in the warning tint.
struct PrepGapStatusDot: View {
    let status: PrepGapStatus

    var body: some View {
        Circle()
            .fill(status == .open ? Color.hxDanger : status == .improving ? Color.hxWarning : Color.hxTextSecondary)
            .frame(width: 8, height: 8)
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
                HXChip(paper: .request, label: statusWord(gap)) { EmptyView() }
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
                            Text(verbatim: [row.date, row.itemTitle].filter { !$0.isEmpty }.joined(separator: " · "))
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
