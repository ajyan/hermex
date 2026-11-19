import SwiftUI

/// The Usage screen: a window picker, one hero figure with a chart under it, the
/// window totals, and the per-model breakdown. Every figure comes from
/// `GET /api/insights`, or from local session metadata when that call fails.
struct InsightsView: View {
    let server: URL
    let onAPIError: (Error) -> Void

    @State private var viewModel: InsightsViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: InsightsViewModel(server: server))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle(String(localized: "Usage"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        // The spinner marks a re-fetch of something already on
                        // screen. A first load has its own placeholder, and a
                        // server that never answers must not pin it on here.
                        if viewModel.isRefreshing {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .task(id: viewModel.selectedTimeframe) {
                await loadInsights()
            }
            // A separate, unkeyed task on purpose: a cold account-limits probe
            // can take several seconds upstream and the chart must not wait on
            // it, and quota does not depend on the window. Keying it to the
            // window would restart the probe on every picker change, wasting
            // traffic and letting the restarted load supersede an in-flight
            // explicit refresh. This load never passes `refresh` — that belongs
            // to explicit gestures.
            .task {
                await viewModel.loadLimits()
            }
    }

    /// Which of the screen's states is up. `.hxLoadSwap` crossfades on this,
    /// never on the figures, so a refresh with new numbers doesn't fade the page.
    private enum Phase: Hashable {
        case loading, failed, loaded
    }

    /// Nothing loaded and nothing failed reads as loading: the first frame lands
    /// before `.task` starts the load, and it must not flash an empty state.
    private var phase: Phase {
        if viewModel.hasLoadedAnalytics { return .loaded }
        if viewModel.errorMessage != nil, !viewModel.isLoading { return .failed }
        return .loading
    }

    private var content: some View {
        Group {
            switch phase {
            case .failed:
                HXFailedView(title: String(localized: "Couldn't load usage"), message: viewModel.errorMessage) {
                    Task { await loadInsights() }
                }
            case .loading, .loaded:
                scrollContent
            }
        }
        .hxLoadSwap(phase)
    }

    /// The limits and the window picker hold their place from the first frame;
    /// only the analytics under them swap from placeholder to figures.
    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.showsLimits {
                    ProviderLimitsSection(
                        cards: viewModel.limitCards,
                        isLoading: viewModel.isLoadingLimits
                    )
                }

                Picker("Window", selection: $viewModel.selectedTimeframe) {
                    ForEach(AnalyticsTimeframe.allCases) { timeframe in
                        Text(timeframe.title).tag(timeframe)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.hasLoadedAnalytics {
                    loadedAnalytics
                } else {
                    UsageAnalyticsPlaceholder()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await refresh()
        }
    }

    @ViewBuilder
    private var loadedAnalytics: some View {
        if viewModel.dataSource != .server {
            SectionCard {
                Label {
                    Text(viewModel.sourceDescription)
                        .font(AppFont.caption())
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.hxWarning)
                }
            }
        }

        UsageChartCard(
            buckets: viewModel.chartBuckets,
            metric: $viewModel.metric,
            showsMetricToggle: viewModel.showsMetricToggle,
            windowTotal: viewModel.heroFigure,
            hourlyNote: viewModel.hourlyChartNote,
            chartAccessibilityLabel: viewModel.chartAccessibilityLabel
        )

        UsageTotalsGrid(cells: viewModel.totalsCells)

        if !viewModel.modelBreakdowns.isEmpty {
            UsageModelsCard(
                models: viewModel.modelBreakdowns,
                hasCost: viewModel.estimatedCost > 0
            )
        }

        if !viewModel.topSessions.isEmpty {
            UsageTopSessionsCard(sessions: viewModel.topSessions)
        }

        Text(viewModel.sourceDescription)
            .font(AppFont.caption())
            .foregroundStyle(.hxSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// An explicit refresh gesture: the toolbar button and pull-to-refresh. Only
    /// these bypass the server's 45 s quota cache. Both calls are started before
    /// either is awaited so the slower one does not serialize behind the other.
    private func refresh() async {
        let limits = Task { await viewModel.loadLimits(refresh: true) }
        await loadInsights()
        await limits.value
    }

    private func loadInsights() async {
        await viewModel.load()

        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }
    }
}

/// The chart and totals cards with sample figures, redacted, while the first
/// window loads, so the real cards land where these stood. Static: nothing here
/// animates or repaints, and VoiceOver hears one "Loading usage".
private struct UsageAnalyticsPlaceholder: View {
    private static let cells = [
        UsageTotalsCell(id: "sessions", label: "Sessions", value: "128", detail: nil),
        UsageTotalsCell(id: "messages", label: "Messages", value: "2,400", detail: nil),
        UsageTotalsCell(id: "input", label: "Input tokens", value: "1.2M", detail: nil),
        UsageTotalsCell(id: "output", label: "Output tokens", value: "340K", detail: nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            UsageChartCard(
                buckets: [],
                metric: .constant(.tokens),
                showsMetricToggle: false,
                windowTotal: UsageHeroFigure(label: "Tokens", value: "1,234,567", caption: "Last 30 days"),
                hourlyNote: nil,
                chartAccessibilityLabel: ""
            )
            UsageTotalsGrid(cells: Self.cells)
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading usage"))
    }
}
