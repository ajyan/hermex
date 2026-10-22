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
    var metric: SleepMetric = .hours
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

    /// The shown night's usual: the 30 nights before it.
    var usual: SleepUsual {
        guard let night else { return SleepUsual() }
        return SleepUsual(before: night.date, in: history?.nights ?? [])
    }
}

/// Sleep over time, from the sleep card: a night up top (last night by default) with its
/// hypnogram and its numbers against usual, trend charts by span, and a table of nights. Tapping a bar or a row puts that night up top.
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
                SleepNightCard(night: night, stages: viewModel.stages, usual: viewModel.usual,
                               isLastNight: viewModel.isShowingLastNight) {
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
    let usual: SleepUsual
    let isLastNight: Bool
    let showLastNight: () -> Void

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
            if night.hours != nil, let hours = usual.hours {
                Text(verbatim: "Usually \(SleepReadout.duration(hours))")
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
            ForEach(SleepReadout.groups(night, usual: usual), id: \.title) { group in
                SleepReadingList(group: group, paper: paper)
                    .padding(.top, 10)
            }
        }, footer: { EmptyView() })
    }

    private var kicker: String {
        guard let day = night.day else { return "Last night" }
        let label = SleepTrend.label(day) { $0.weekday(.wide).month(.abbreviated).day() }
        return isLastNight ? "Last night · \(label)" : label
    }

    private var headline: String {
        guard let hours = night.hours else { return "No sleep recorded" }
        if let need = night.need { return "\(SleepReadout.duration(hours)) of \(SleepReadout.duration(need)) needed" }
        return "\(SleepReadout.duration(hours)) asleep"
    }

    private func rating(_ quality: Int) -> some View {
        let label = SleepRating.labels[quality - 1]
        return (Text(verbatim: "You: \(label)").font(AppFont.subheadline(weight: .semibold))
            + Text(verbatim: night.felt.map { ". \($0)" } ?? "").font(AppFont.serif(style: .subheadline)))
            .foregroundStyle(Color.hxTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// His rating words.
enum SleepRating {
    static let labels = ["Very poor", "Poor", "Fair", "Good", "Very good"]
}

/// One group of the night's readout: its title in the paper's ink, then a row per reading with
/// the label and how it sits against usual on the left and the value on the right.
private struct SleepReadingList: View {
    let group: SleepReadingGroup
    let paper: HermexPaper

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: group.title)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.readings, id: \.label) { reading in
                Divider().overlay(Color.hxSeparator)
                row(reading)
            }
        }
    }

    private func row(_ reading: SleepReading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: reading.label)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                if let note = reading.note {
                    if reading.standsOut {
                        Label { Text(verbatim: note) } icon: { Image(systemName: "exclamationmark.circle") }
                            .font(AppFont.footnote(weight: .semibold))
                            .foregroundStyle(paper.glow)
                    } else {
                        Text(verbatim: note)
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(verbatim: reading.value)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
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
            // Extended so the lane names sit beside the plot, not over its first bars.
            AxisMarks(preset: .extended, position: .leading) { _ in AxisValueLabel() }
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
