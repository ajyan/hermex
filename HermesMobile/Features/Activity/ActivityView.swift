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
            .background(Color.hxCanvas)
            .navigationTitle("Activity")
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
            .onChange(of: viewModel.filter) {
                Task { await viewModel.reload() }
            }
            .task {
                await viewModel.reload()
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
            ContentUnavailableView("The activity service isn't running", systemImage: "bolt.slash")
        case .failed(let message) where viewModel.events.isEmpty:
            ContentUnavailableView("Couldn't load activity", systemImage: "exclamationmark.triangle", description: Text(message))
        case .idle, .loading where viewModel.events.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            timeline
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
            ForEach(sections, id: \.day) { section in
                Section(ActivityPresentation.dayHeader(for: section.day, now: .now, calendar: .current)) {
                    ForEach(section.events) { event in
                        ActivityRow(event: event)
                            .onAppear {
                                if event.id == viewModel.events.last?.id {
                                    Task { await viewModel.loadMore() }
                                }
                            }
                    }
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
            ForEach(episodeSections, id: \.day) { section in
                Section(ActivityPresentation.dayHeader(for: section.day, now: .now, calendar: .current)) {
                    ForEach(section.episodes) { episode in
                        EpisodeRow(episode: episode)
                            .onAppear {
                                if episode.id == viewModel.episodes.last?.id {
                                    Task { await viewModel.loadMore() }
                                }
                            }
                    }
                }
            }
        }
        .overlay {
            if viewModel.state == .loaded, viewModel.episodes.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "tray")
            }
        }
    }

    private var sections: [(day: Date, events: [AtlasActivityEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.events) { calendar.startOfDay(for: $0.ts) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private var episodeSections: [(day: Date, episodes: [AtlasEpisode])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.episodes) { calendar.startOfDay(for: $0.firstTs) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private func banner(_ text: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(text, systemImage: "exclamationmark.triangle").font(.footnote.weight(.semibold))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.hxTextSecondary)
            }
        }
        .foregroundStyle(.hxWarning)
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

private struct ActivityRow: View {
    let event: AtlasActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ActivityPresentation.symbol(forTool: event.toolName))
                .frame(width: 24)
                .foregroundStyle(.hxTextSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(ActivityPresentation.toolTitle(event.toolName))
                    .font(.subheadline.weight(.semibold))
                Text(event.summary)
                    .font(.system(.caption, design: .monospaced))
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
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ActivityPresentation.outcomeStyle(event.outcome))
                    }
                    if !display.actionNeeded.isEmpty {
                        Text(display.actionNeeded)
                            .font(.caption)
                            .foregroundStyle(ActivityPresentation.outcomeStyle(event.outcome))
                    }
                } else if let ruleID = event.ruleID, event.outcome == .blocked || event.outcome == .denied {
                    // Backward compat: older sidecars send no `display`.
                    Text("Rule: \(ruleID)")
                        .font(.caption.weight(.medium))
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
                .font(.caption)
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
            Image(systemName: ActivityPresentation.symbol(forTool: episode.tools.first ?? ""))
                .frame(width: 24)
                .foregroundStyle(.hxTextSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(ActivityPresentation.episodeTitle(rulePlain: episode.rulePlain))
                    .font(.subheadline.weight(.semibold))
                Text(ActivityPresentation.episodeSubtitle(count: episode.count, first: episode.firstTs, last: episode.lastTs))
                    .font(.caption)
                    .foregroundStyle(.hxTextSecondary)
                Text(episode.sampleCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.hxTextSecondary)
                    .lineLimit(2)
                if !episode.actionNeeded.isEmpty {
                    Text(episode.actionNeeded)
                        .font(.caption)
                        .foregroundStyle(actionColor)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
