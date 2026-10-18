import SwiftUI

/// Prep's landing screen: today's run (the course's ring card and path when the server has a
/// course), the tracks as cover cards, and what needs work. Pushed as `.brainRoute(.prep(.home))`;
/// owns no `NavigationStack`.
struct PrepHomeView: View {
    @State private var viewModel: PrepHomeViewModel
    /// The voice mock ladders, loaded beside home; their section hides until they load.
    @State private var mockViewModel: PrepMockViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                        // The course replaces the run row: a ring card, then the path. Skill maps and
                        // gaps (fed by mocks) follow below.
                        PrepTodayRingCard(course: course, streak: home.streak,
                                          action: PrepCopy.runAction(reps: home.run.reps, remaining: home.run.remaining))
                        PrepUnitPath(course: course, showsTextMockRow: showsTextMockRow) {
                            storiesSection
                            mockSection
                        }
                    } else {
                        todaySection(home)
                        mockSection
                    }
                    if !home.tracks.isEmpty {
                        tracksSection(home.tracks, title: viewModel.course == nil ? "Tracks" : "Skill maps")
                    }
                    if let gaps = viewModel.gaps {
                        PrepGapsSection(gaps: gaps)
                    } else if !home.needsWork.isEmpty {
                        needsWorkSection(home.needsWork)
                    }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await load() }
        }
    }

    // MARK: Mocks

    /// The old text critique row stays on home whenever the ladders aren't there to carry it
    /// (a server without them); hidden while they load, so it doesn't flash.
    private var showsTextMockRow: Bool {
        mockViewModel.state != .loading && !PrepMockSection.isShown(mockViewModel.mocks)
    }

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

    // MARK: Today

    private func todaySection(_ home: PrepHome) -> some View {
        let action = PrepCopy.runAction(reps: home.run.reps, remaining: home.run.remaining)
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Today")
            SectionCard {
                VStack(spacing: 0) {
                    HStack(spacing: BrainStyle.m) {
                        BrainRow(
                            title: "Today's run",
                            subtitle: PrepCopy.runSubtitle(
                                minutes: home.run.minutes, reps: home.run.reps, focus: home.run.focus)
                        )
                        PrepRunButton(action: action)
                    }
                    PrepRowDivider()
                    BrainRow(
                        title: PrepCopy.streakTitle(days: home.streak.days),
                        subtitle: PrepCopy.streakSubtitle(days: home.streak.days, freezes: home.streak.freezes)
                    )
                    if let readiness = home.readiness {
                        PrepRowDivider()
                        BrainRow(title: PrepCopy.readiness(readiness))
                    }
                }
            }
        }
    }

    // MARK: Tracks

    private func tracksSection(_ tracks: [PrepTrackSummary], title: String) -> some View {
        let columns = BrainListLayout.columnCount(2, dynamicType: dynamicTypeSize)
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: title)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: BrainStyle.m, alignment: .top), count: columns),
                spacing: BrainStyle.m
            ) {
                ForEach(tracks) { track in
                    NavigationLink(value: ShellPushDestination.brainRoute(.prep(.track(track.id)))) {
                        PrepTrackCard(track: track)
                            .zoomSource(for: .brainRoute(.prep(.track(track.id))), cornerRadius: BrainStyle.cardCorner)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Needs work

    private func needsWorkSection(_ items: [PrepNeedsWork]) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Needs work", count: items.count)
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        if offset > 0 { PrepRowDivider() }
                        BrainRow(
                            leading: { PrepCoverThumbnail(id: PrepCopy.coverID(item.skill)) },
                            title: item.title,
                            subtitle: item.detail
                        )
                    }
                }
            }
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

/// A track as a Brain glow card (the `.knowledge` paper): cover, title, the server's
/// subtitle, and a thin progress bar. Built from the same pieces and constants as `BrainCard`.
private struct PrepTrackCard: View {
    let track: PrepTrackSummary
    /// Built once per card, never in `body`.
    private let cover: BrainCoverSpec

    init(track: PrepTrackSummary) {
        self.track = track
        self.cover = BrainCoverSpec.make(id: PrepCopy.coverID(track.id), tag: "career")
    }

    var body: some View {
        let paper = HermexPaper.knowledge
        let shape = BrainStyle.cardShape()
        VStack(alignment: .leading, spacing: 0) {
            // The clear base takes the card's full width at the cover ratio; the art
            // is an overlay so it can never be narrower than the card.
            Color.clear
                .aspectRatio(BrainStyle.coverAspectRatio, contentMode: .fit)
                .overlay { BrainCoverView(spec: cover).drawingGroup() }
                .clipped()
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: track.title)
                    .font(AppFont.display(style: .body))
                    .foregroundStyle(paper.glow)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !track.subtitle.isEmpty {
                    Text(verbatim: track.subtitle)
                        .font(BrainStyle.meta)
                        .foregroundStyle(paper.glow)
                        .lineLimit(2)
                }
                PrepProgressBar(fraction: track.progress, tint: paper.glow)
                    .padding(.top, BrainStyle.xs)
            }
            .padding(.horizontal, BrainStyle.cardHorizontalPadding)
            .padding(.vertical, BrainStyle.cardVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipShape(shape)
        .background(paper.card, in: shape)
        .overlay(shape.strokeBorder(paper.edge, lineWidth: 0.5))
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [track.title, track.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityValue(Text(verbatim: "\(Int((min(max(track.progress, 0), 1) * 100).rounded())) percent"))
    }
}

/// A 3pt bar: the filled share in `tint` on a separator track.
struct PrepProgressBar: View {
    let fraction: Double
    var tint: Color = .hxTextSecondary.opacity(0.55)

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(Color.hxSeparator)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Shared Prep pieces

/// A square cover thumbnail for a row's leading slot (40pt, scaled with Dynamic Type).
struct PrepCoverThumbnail: View {
    private let cover: BrainCoverSpec
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 40

    init(id: String) {
        self.cover = BrainCoverSpec.make(id: id, tag: "career")
    }

    var body: some View {
        BrainCoverView(spec: cover)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: BrainStyle.thumbnailCorner, style: .continuous))
            .drawingGroup()
    }
}

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
