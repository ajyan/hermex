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
            .safeAreaInset(edge: .top) { filterChips }
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

    private var timeline: some View {
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

    private var sections: [(day: Date, events: [AtlasActivityEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: viewModel.events) { calendar.startOfDay(for: $0.ts) }
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

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AtlasActivityFilter.allCases) { filter in
                    Button {
                        guard viewModel.filter != filter else { return }
                        viewModel.filter = filter
                        Task { await viewModel.reload() }
                    } label: {
                        Text(ActivityPresentation.filterTitle(filter))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                viewModel.filter == filter ? Color.accentColor : Color.hxSeparator.opacity(0.4),
                                in: Capsule()
                            )
                            .foregroundStyle(viewModel.filter == filter ? Color.hxOnAccent : Color.hxTextPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(viewModel.filter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
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
                Text(event.summary).font(.subheadline).lineLimit(3)
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
