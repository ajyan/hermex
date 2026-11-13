import SwiftUI

struct ActivityView: View {
    let server: URL

    @State private var viewModel: ActivityViewModel

    init(server: URL) {
        self.server = server
        _viewModel = State(initialValue: ActivityViewModel(apiClient: APIClient(baseURL: server)))
    }

    var body: some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle(String(localized: "Activity"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AtlasRulesView(server: server)
                    } label: {
                        Text("Rules")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { filterPicker }
            // Keyed on the filter so SwiftUI cancels the previous filter's load.
            .task(id: viewModel.filter) {
                await viewModel.reload()
            }
            .task {
                await viewModel.loadRules()
            }
            .refreshable {
                await viewModel.reload()
                await viewModel.loadRules()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .notInstalled:
            ContentUnavailableView("Activity isn't set up on this server", systemImage: "tray")
        case .notConsented:
            ContentUnavailableView("Approve Atlas Activity in the web UI under Settings → Extensions", systemImage: "lock")
        case .serviceDown where viewModel.events.isEmpty:
            pullToRetry { ContentUnavailableView("The activity service isn't running", systemImage: "bolt.slash") }
        case .failed(let message) where viewModel.events.isEmpty:
            pullToRetry {
                HXFailedView(title: String(localized: "Couldn't load activity"), message: message) {
                    Task { await viewModel.reload() }
                }
            }
        case .idle, .loading where viewModel.events.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            timeline
        }
    }

    /// A screen-filling message inside a scroll view, so pull to refresh reaches it and retries.
    private func pullToRetry<Message: View>(@ViewBuilder _ message: () -> Message) -> some View {
        ScrollView {
            message().containerRelativeFrame([.horizontal, .vertical])
        }
    }

    // `AnyView` (not `some View`) so the two branch types, which differ in
    // their opaque types, unify in a single non-ViewBuilder property.
    private var timeline: AnyView {
        if viewModel.filter == .attention && viewModel.episodesAvailable {
            AnyView(episodeTimeline)
        } else {
            AnyView(eventTimeline)
        }
    }

    private var eventTimeline: some View {
        List {
            if viewModel.state == .serviceDown {
                banner(String(localized: "The activity service isn't running"))
            }
            if let rulesError = viewModel.rulesError {
                banner(String(localized: "Rules file has an error; using the previous version"), detail: rulesError)
            }
            ForEach(viewModel.eventDays, id: \.day) { section in
                Section {
                    ForEach(section.items) { event in
                        ActivityRow(event: event)
                            .onAppear {
                                if event.id == viewModel.events.last?.id {
                                    Task { await viewModel.loadMore() }
                                }
                            }
                    }
                    .listRowBackground(Color.hxSurface)
                } header: {
                    dayHeader(section.day)
                }
            }
        }
        .overlay {
            if viewModel.state == .loaded, viewModel.events.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "tray")
            }
        }
    }

    private var episodeTimeline: some View {
        List {
            if viewModel.state == .serviceDown {
                banner(String(localized: "The activity service isn't running"))
            }
            if let rulesError = viewModel.rulesError {
                banner(String(localized: "Rules file has an error; using the previous version"), detail: rulesError)
            }
            ForEach(viewModel.episodeDays, id: \.day) { section in
                Section {
                    ForEach(section.items) { episode in
                        EpisodeRow(episode: episode)
                            .onAppear {
                                if episode.id == viewModel.episodes.last?.id {
                                    Task { await viewModel.loadMore() }
                                }
                            }
                    }
                    .listRowBackground(Color.hxSurface)
                } header: {
                    dayHeader(section.day)
                }
            }
        }
        .overlay {
            if viewModel.state == .loaded, viewModel.episodes.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "tray")
            }
        }
    }

    /// A day's section title in sentence case (DESIGN.md § Section header).
    private func dayHeader(_ day: Date) -> some View {
        HXSectionHeader(title: ActivityPresentation.dayHeader(for: day, now: .now, calendar: .current))
            .textCase(nil)
    }

    private func banner(_ text: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(text, systemImage: "exclamationmark.triangle").font(AppFont.footnote(weight: .semibold))
            if let detail {
                Text(detail).font(AppFont.caption()).foregroundStyle(.hxTextSecondary)
            }
        }
        .foregroundStyle(.hxWarning)
        .listRowBackground(Color.hxSurface)
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $viewModel.filter) {
            ForEach(AtlasActivityFilter.allCases) { filter in
                Text(ActivityPresentation.filterTitle(filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Matches the navigation bar and list, so no seam shows under the picker.
        .background(Color.hxCanvas)
    }
}

/// A tool step's icon on a 20 pt tile in the tool paper, as chat's tool log rows draw it.
private struct ActivityToolTile: View {
    let symbol: String

    var body: some View {
        let paper = HermexPaper.tool
        Image(systemName: symbol)
            .font(AppFont.caption2(weight: .semibold))
            .foregroundStyle(paper.glow)
            .frame(width: 20, height: 20)
            .background(paper.wash, in: RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct ActivityRow: View {
    let event: AtlasActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityToolTile(symbol: ActivityPresentation.symbol(forTool: event.toolName))
            VStack(alignment: .leading, spacing: 4) {
                Text(ActivityPresentation.toolTitle(event.toolName))
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Text(event.summary)
                    .font(AppFont.mono(style: .caption))
                    .foregroundStyle(.hxTextSecondary)
                    .lineLimit(2)
                if let display = event.display {
                    // Newer sidecars send a human-readable projection; prefer it
                    // over the raw rule id when it carries a sentence.
                    if ActivityPresentation.showsRulePlain(
                        display.rulePlain,
                        outcome: event.outcome,
                        actionNeeded: display.actionNeeded
                    ) {
                        Text(display.rulePlain!)
                            .font(AppFont.caption(weight: .medium))
                            .foregroundStyle(ActivityPresentation.outcomeStyle(event.outcome))
                    }
                    if !display.actionNeeded.isEmpty {
                        Text(display.actionNeeded)
                            .font(AppFont.caption())
                            .foregroundStyle(ActivityPresentation.outcomeStyle(event.outcome))
                    }
                } else if let ruleID = event.ruleID, event.outcome == .blocked || event.outcome == .denied {
                    // Backward compat: older sidecars send no `display`.
                    Text("Rule: \(ruleID)")
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(ActivityPresentation.outcomeStyle(event.outcome))
                }
                HStack(spacing: 8) {
                    Text(ActivityPresentation.sourceLabel(event.source))
                    HStack(spacing: 4) {
                        Circle().fill(ActivityPresentation.outcomeStyle(event.outcome)).frame(width: 7, height: 7)
                        Text(ActivityPresentation.outcomeLabel(event.outcome))
                    }
                    Spacer(minLength: 0)
                    Text(event.ts, style: .time)
                }
                .font(AppFont.caption())
                .foregroundStyle(.hxTextSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EpisodeRow: View {
    let episode: AtlasEpisode

    private var actionColor: Color {
        ActivityPresentation.outcomeStyle(ActivityPresentation.episodeHighlightOutcome(episode.outcomes) ?? .unknown)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityToolTile(symbol: ActivityPresentation.symbol(forTool: episode.tools.first ?? ""))
            VStack(alignment: .leading, spacing: 4) {
                Text(ActivityPresentation.episodeTitle(rulePlain: episode.rulePlain))
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Text(ActivityPresentation.episodeSubtitle(count: episode.count, first: episode.firstTs, last: episode.lastTs))
                    .font(AppFont.caption())
                    .foregroundStyle(.hxTextSecondary)
                Text(episode.sampleCommand)
                    .font(AppFont.mono(style: .caption))
                    .foregroundStyle(.hxTextSecondary)
                    .lineLimit(2)
                if !episode.actionNeeded.isEmpty {
                    Text(episode.actionNeeded)
                        .font(AppFont.caption())
                        .foregroundStyle(actionColor)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
