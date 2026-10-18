import Charts
import Observation
import SwiftUI

@MainActor
@Observable
final class SleepViewModel {
    enum State: Equatable {
        case loading
        /// The vault hasn't written `data/sleep/history.json` yet.
        case empty
        case ready
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var history: SleepHistory?
    var range: SleepRange = .month
    var metric: SleepMetric = .performance
    /// The night shown at the top; nil shows last night.
    private(set) var selectedDate: String?
    /// Rows shown in the nights table, newest first.
    private(set) var tableLimit = 14

    /// The deck's day (UTC midnight), so spans end on the brief's morning.
    let today: Date
    private let fetch: () async throws -> SleepHistory?

    init(today: Date, fetch: @escaping () async throws -> SleepHistory?) {
        self.today = today
        self.fetch = fetch
    }

    func load() async {
        if history == nil { state = .loading }
        do {
            history = try await fetch()
            state = history.map { $0.nights.isEmpty ? .empty : .ready } ?? .empty
        } catch is CancellationError {
            // A newer load owns the state.
        } catch {
            if history == nil { state = .failed(error.localizedDescription) }
        }
    }

    var night: SleepNight? {
        selectedDate.flatMap { history?.night(on: $0) } ?? history?.lastNight
    }

    var isShowingLastNight: Bool { night?.date == history?.lastNight?.date }

    var stages: [SleepStage] {
        guard let date = night?.date else { return [] }
        return history?.stages[date] ?? []
    }

    var points: [SleepPoint] {
        SleepTrend.points(history?.nights ?? [], metric: metric, range: range, today: today)
    }

    var summary: (average: Double?, change: Double?) {
        SleepTrend.summary(history?.nights ?? [], metric: metric, range: range, today: today)
    }

    var tableNights: [SleepNight] {
        Array((history?.nights ?? []).reversed().prefix(tableLimit))
    }

    var hasMoreNights: Bool { (history?.nights.count ?? 0) > tableLimit }

    func select(_ date: String?) { selectedDate = date }

    func showMoreNights() { tableLimit += 30 }

    func average(_ key: String) -> Double? { history?.averages[key] }
}

/// Sleep over time, from the sleep card: a night up top (last night by default) with its
/// hypnogram and every number against the 30-night average, trend charts by span, and a table
/// of nights. Tapping a bar or a row puts that night up top.
struct SleepView: View {
    @State var viewModel: SleepViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        content(proxy: proxy)
                    }
                    .padding(16)
                }
            }
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle("Sleep", subtitle: viewModel.history.map { "\($0.nights.count) nights" })
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }

    @ViewBuilder
    private func content(proxy: ScrollViewProxy) -> some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        case .empty:
            ContentUnavailableView("No sleep history yet", systemImage: "moon.zzz",
                                   description: Text(verbatim: "It appears after the morning Garmin pull runs."))
        case .failed(let message):
            ContentUnavailableView("Couldn't load sleep", systemImage: "exclamationmark.triangle",
                                   description: Text(verbatim: message))
        case .ready:
            if let night = viewModel.night {
                SleepNightCard(night: night, stages: viewModel.stages, isLastNight: viewModel.isShowingLastNight,
                               average: viewModel.average) {
                    viewModel.select(nil)
                }
                .id("night")
            }
            SleepTrendSection(viewModel: viewModel) { date in
                viewModel.select(date)
                withAnimation { proxy.scrollTo("night", anchor: .top) }
            }
            SleepNightsTable(viewModel: viewModel) { date in
                viewModel.select(date)
                withAnimation { proxy.scrollTo("night", anchor: .top) }
            }
        }
    }
}

// MARK: The night

private struct SleepNightCard: View {
    let night: SleepNight
    let stages: [SleepStage]
    let isLastNight: Bool
    let average: (String) -> Double?
    let showLastNight: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let paper = HermexPaper.notes

    var body: some View {
        HXCard(.glow(paper), title: headline, titleStyle: .title2, spacing: 10, kicker: {
            HStack {
                Text(verbatim: kicker)
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(paper.glow)
                Spacer()
                if !isLastNight {
                    Button("Last night", action: showLastNight)
                        .font(AppFont.caption(weight: .semibold))
                        .tint(.accentColor)
                }
            }
        }, content: {
            if let window {
                Text(verbatim: window)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
            }
            if let quality = night.quality {
                rating(quality)
            }
            if !stages.isEmpty {
                SleepHypnogram(stages: stages, bedClock: night.bedClock, paper: paper)
                    .padding(.top, 6)
            }
            ForEach(flagLines, id: \.self) { line in
                Label { Text(verbatim: line) } icon: { Image(systemName: "exclamationmark.circle") }
                    .font(AppFont.footnote(weight: .medium))
                    .foregroundStyle(paper.glow)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                                     count: dynamicTypeSize.isAccessibilitySize ? 2 : 3),
                      alignment: .leading, spacing: 14) {
                ForEach(tiles, id: \.label) { tile in
                    SleepTile(tile: tile, paper: paper)
                }
            }
            .padding(.top, 8)
        }, footer: { EmptyView() })
    }

    private var kicker: String {
        guard let day = night.day else { return "Last night" }
        let label = SleepTrend.label(day) { $0.weekday(.wide).month(.abbreviated).day() }
        return isLastNight ? "Last night · \(label)" : label
    }

    private var headline: String {
        guard let hours = night.hours else { return "No sleep recorded" }
        if let need = night.need { return "\(Self.hours(hours)) of \(Self.hours(need)) needed" }
        return "\(Self.hours(hours)) asleep"
    }

    private var window: String? {
        guard let bed = night.bedClock, let wake = night.wakeClock else { return nil }
        var parts = ["Asleep \(SleepTrend.clockLabel(bed))", "up \(SleepTrend.clockLabel(wake))"]
        if let inBed = night.inBedMinutes { parts.append("\(Self.hours(inBed / 60)) in bed") }
        return parts.joined(separator: " · ")
    }

    private func rating(_ quality: Int) -> some View {
        let label = SleepRating.labels[quality - 1]
        return (Text(verbatim: "You: \(label)").font(AppFont.subheadline(weight: .semibold))
            + Text(verbatim: night.felt.map { ". \($0)" } ?? "").font(AppFont.serif(style: .subheadline)))
            .foregroundStyle(Color.hxTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var flagLines: [String] {
        night.flags.compactMap { flag in
            switch flag {
            case "breathing_up": "Breathing rate 1+ breath a minute over your usual, an early sign of illness"
            case "hrv_low": "HRV below your normal (Garmin)"
            default: nil
            }
        }
    }

    private var tiles: [SleepTile.Model] {
        var out: [SleepTile.Model] = []
        func add(_ label: String, _ value: Double?, key: String?, format: (Double) -> String, note: String? = nil, lowerIsBetter: Bool = false) {
            guard let value else { return }
            let avg = key.flatMap(average)
            out.append(SleepTile.Model(label: label, value: format(value), note: note ?? avg.map { avg in
                SleepTile.delta(value - avg, format: format, lowerIsBetter: lowerIsBetter)
            }))
        }
        let percent: (Double) -> String = { "\(Int($0.rounded()))%" }
        let whole: (Double) -> String = { "\(Int($0.rounded()))" }
        add("Performance", night.performance, key: "performance", format: whole,
            note: night.performance.map(SleepRating.performanceTier))
        add("Wake-ups", night.wakeUps, key: nil, format: whole,
            note: night.awakeMinutes.map { "\(Int($0.rounded())) min awake" })
        add("Recovery", night.recovery, key: "recovery", format: whole, note: night.recovery.map(SleepRating.recoveryTier))
        add("Hours vs need", night.sufficiency, key: nil, format: percent)
        add("Consistency", night.consistency, key: "consistency", format: percent)
        add("Efficiency", night.efficiency, key: "efficiency", format: percent)
        add("HRV", night.hrv, key: "hrv", format: { "\(Int($0.rounded())) ms" },
            note: night.hrvStatus.map { $0.prefix(1) + $0.dropFirst().lowercased() })
        add("Resting HR", night.restingHR, key: "resting_hr", format: whole, lowerIsBetter: true)
        add("Breathing", night.respiration, key: "respiration", format: { String(format: "%.1f", $0) }, lowerIsBetter: true)
        add("Deep + REM", night.restorative, key: nil, format: percent)
        add("Sleep debt", night.debtHours, key: nil, format: { Self.hours($0) })
        add("Garmin score", night.garminScore, key: nil, format: whole)
        return out
    }

    static func hours(_ value: Double) -> String {
        let minutes = Int((value * 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) m"
    }
}

/// His rating words and WHOOP's tiers, in words so color is never the only signal.
enum SleepRating {
    static let labels = ["Very poor", "Poor", "Fair", "Good", "Very good"]

    static func performanceTier(_ value: Double) -> String {
        value >= 85 ? "Optimal" : value >= 70 ? "Sufficient" : "Poor"
    }

    static func recoveryTier(_ value: Double) -> String {
        value >= 67 ? "Green" : value >= 34 ? "Yellow" : "Red"
    }
}

private struct SleepTile: View {
    struct Model {
        let label: String
        let value: String
        let note: String?
    }

    let tile: Model
    let paper: HermexPaper

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: tile.label)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
            Text(verbatim: tile.value)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            if let note = tile.note {
                Text(verbatim: note)
                    .font(AppFont.caption2())
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }

    /// "+3 vs avg" against the 30-night average; "at avg" when it rounds to nothing.
    static func delta(_ diff: Double, format: (Double) -> String, lowerIsBetter: Bool) -> String {
        let shown = format(abs(diff))
        guard shown != format(0) else { return "at avg" }
        return "\(diff > 0 ? "+" : "−")\(shown) vs avg"
    }
}

/// The night's stages as lanes, deep at the bottom, in one hue: lanes, not colors, tell them apart.
private struct SleepHypnogram: View {
    let stages: [SleepStage]
    let bedClock: Double?
    let paper: HermexPaper

    private static let lanes = SleepStage.Kind.allCases.map(\.title)

    var body: some View {
        Chart(Array(stages.enumerated()), id: \.offset) { _, stage in
            RectangleMark(xStart: .value("Start", stage.start), xEnd: .value("End", stage.start + stage.length),
                          y: .value("Stage", stage.kind.title), height: .ratio(0.7))
                .foregroundStyle(paper.glow.opacity(Self.opacity(stage.kind)))
        }
        .chartYScale(domain: Self.lanes)
        .chartXScale(domain: 0...(stages.map { $0.start + $0.length }.max() ?? 1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.hxSeparator)
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(verbatim: bedClock.map { SleepTrend.clockLabel($0 + minutes) } ?? "\(Int(minutes / 60)) h")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in AxisValueLabel(centered: true) }
        }
        .frame(height: 140)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Sleep stages"))
        .accessibilityValue(Text(verbatim: summary))
    }

    private static func opacity(_ kind: SleepStage.Kind) -> Double {
        switch kind {
        case .deep: 1
        case .rem: 0.75
        case .light: 0.45
        case .awake: 0.25
        }
    }

    private var summary: String {
        SleepStage.Kind.allCases.map { kind in
            let minutes = stages.filter { $0.kind == kind }.reduce(0) { $0 + $1.length }
            return "\(kind.title) \(Int(minutes)) minutes"
        }.joined(separator: ", ")
    }
}
