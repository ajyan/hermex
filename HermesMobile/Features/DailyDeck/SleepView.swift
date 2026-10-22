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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let paper = HermexPaper.notes

    var body: some View {
        HXCard(.glow(paper), spacing: 14, kicker: {
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
            if let hours = night.hours {
                SleepAmount(hours: hours, need: night.need, usual: usual.hours, inBedMinutes: night.inBedMinutes,
                            against: SleepReadout.hoursAgainstUsual(night, usual: usual), paper: paper)
            } else {
                Text(verbatim: "No sleep recorded")
                    .font(AppFont.display(style: .title2, weight: .semibold))
            }
            if let quality = night.quality {
                rating(quality)
            }
            if let bed = night.bedClock, let wake = night.wakeClock {
                SleepWindowTrack(bed: bed, wake: wake, usualBed: usual.bed, usualWake: usual.wake,
                                 awake: stages.filter { $0.kind == .awake }, awakeMinutes: night.awakeMinutes,
                                 shifts: SleepReadout.windowShifts(night, usual: usual), paper: paper)
            }
            let gauges = SleepReadout.gauges(night, usual: usual)
            if !gauges.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 3),
                          alignment: .leading, spacing: 8) {
                    ForEach(gauges, id: \.label) { SleepGaugeTile(gauge: $0, paper: paper) }
                }
            }
            if !stages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Stages")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(paper.glow)
                    SleepHypnogram(stages: stages, bedClock: night.bedClock, paper: paper)
                }
            }
        }, footer: { EmptyView() })
    }

    private var kicker: String {
        guard let day = night.day else { return "Last night" }
        let label = SleepTrend.label(day) { $0.weekday(.wide).month(.abbreviated).day() }
        return isLastNight ? "Last night · \(label)" : label
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

/// What a figure's mark means, drawn beside its caption: the white tick is the usual, the shaded
/// block a range (the usual window, Garmin's normal HRV), the gap an awake stretch.
private struct SleepKey: View {
    enum Mark { case tick, range, gap }

    let mark: Mark
    let text: String
    let paper: HermexPaper

    var body: some View {
        HStack(spacing: 4) {
            switch mark {
            case .tick:
                Capsule().fill(Color.hxTextPrimary).frame(width: 2, height: 10)
            case .range:
                RoundedRectangle(cornerRadius: 2).fill(paper.glow.opacity(0.3)).frame(width: 12, height: 8)
            case .gap:
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1).fill(paper.glow).frame(width: 5, height: 8)
                    RoundedRectangle(cornerRadius: 1).fill(paper.glow).frame(width: 5, height: 8)
                }
            }
            Text(verbatim: text)
                .font(AppFont.caption2())
                .foregroundStyle(Color.hxTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// How long he slept: a ring that fills to the night's need with a white tick at his usual, the
/// hours beside it, and the difference from usual.
private struct SleepAmount: View {
    let hours: Double
    let need: Double?
    let usual: Double?
    let inBedMinutes: Double?
    let against: (shift: SleepShift?, plain: String)?
    let paper: HermexPaper

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 96

    var body: some View {
        let full = need ?? usual ?? hours
        HStack(alignment: .center, spacing: 16) {
            VStack(spacing: 6) {
                ring(full: full)
                if let usual, need != nil {
                    SleepKey(mark: .tick, text: "usual \(SleepReadout.duration(usual))", paper: paper)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Asleep")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(paper.glow)
                Text(verbatim: SleepReadout.duration(hours))
                    .font(AppFont.display(style: .title2, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                if let need {
                    Text(verbatim: "of \(SleepReadout.duration(need)) needed")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
                if let shift = against?.shift {
                    HXChip(paper: paper, symbol: shift.symbol, label: shift.text)
                        .padding(.vertical, 3)
                } else if let plain = against?.plain {
                    Text(verbatim: plain)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextPrimary)
                }
                if let inBedMinutes {
                    Text(verbatim: "In bed \(SleepReadout.duration(inBedMinutes / 60))")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func ring(full: Double) -> some View {
        let fraction = full > 0 ? min(hours / full, 1) : 0
        let line = size * 0.11
        return ZStack {
            Circle().stroke(Color.hxSeparator, lineWidth: line)
            Circle().trim(from: 0, to: fraction)
                .stroke(paper.glow, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let usual, need != nil, full > 0 {
                Capsule().fill(Color.hxTextPrimary)
                    .frame(width: 3, height: line + 8)
                    .offset(y: -(size - line) / 2)
                    .rotationEffect(.degrees(360 * min(usual / full, 1)))
            }
            VStack(spacing: 0) {
                Text(verbatim: "\(Int((hours / full * 100).rounded()))%")
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Text(verbatim: need == nil ? "of usual" : "of need")
                    .font(AppFont.caption2())
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
        .frame(width: size, height: size)
        .padding(line / 2)
    }
}

/// When he slept, on a clock axis: last night's window as a bar with its awake stretches cut out,
/// over the usual window shaded behind it.
private struct SleepWindowTrack: View {
    let bed: Double
    let wake: Double
    let usualBed: Double?
    let usualWake: Double?
    let awake: [SleepStage]
    let awakeMinutes: Double?
    let shifts: [SleepShift]
    let paper: HermexPaper

    /// Room for both times side by side, and their line height.
    @ScaledMetric(relativeTo: .subheadline) private var timesWidth: CGFloat = 150
    @ScaledMetric(relativeTo: .subheadline) private var timesHeight: CGFloat = 20

    var body: some View {
        let axis = SleepClockAxis([bed, wake] + [usualBed, usualWake].compactMap { $0 })
        let start = axis.position(bed), end = axis.position(wake)
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    title
                    Spacer(minLength: 8)
                    chips
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    chips
                }
            }
            // Last night's times over the bar's two ends, pushed inward when the bar is too short
            // to hold both.
            GeometryReader { geo in
                let width = geo.size.width
                let lead = min(width * start, max(width - timesWidth, 0))
                let trail = min(width * (1 - end), max(width - lead - timesWidth, 0))
                HStack(spacing: 0) {
                    Color.clear.frame(width: lead)
                    Text(verbatim: SleepTrend.clockLabel(bed))
                    Spacer(minLength: 8)
                    Text(verbatim: SleepTrend.clockLabel(wake))
                    Color.clear.frame(width: trail)
                }
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
            }
            .frame(height: timesHeight)
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hxSeparator).frame(height: 4)
                    Capsule().fill(paper.glow)
                        .frame(width: max(width * (end - start), 4), height: 14)
                        .offset(x: width * start)
                    ForEach(Array(awake.enumerated()), id: \.offset) { _, stretch in
                        Rectangle().fill(paper.card)
                            .frame(width: max(width * (axis.position(bed + stretch.start + stretch.length) - axis.position(bed + stretch.start)), 1.5),
                                   height: 14)
                            .offset(x: width * axis.position(bed + stretch.start))
                    }
                    ForEach([usualBed, usualWake].compactMap { $0 }, id: \.self) { usual in
                        Capsule().fill(Color.hxTextPrimary)
                            .frame(width: 2, height: 24)
                            .offset(x: width * axis.position(usual) - 1)
                    }
                }
                .frame(height: 24)
            }
            .frame(height: 24)
            GeometryReader { geo in
                ForEach(axis.ticks, id: \.self) { tick in
                    Text(verbatim: Self.hour(tick))
                        .font(AppFont.caption2())
                        .foregroundStyle(Color.hxTextSecondary)
                        .fixedSize()
                        .position(x: min(max(geo.size.width * axis.position(tick), 14), geo.size.width - 14), y: 7)
                }
            }
            .frame(height: 14)
            FlowRow(spacing: 12) {
                if let usualBed, let usualWake {
                    SleepKey(mark: .tick, text: "usual \(SleepTrend.clockLabel(usualBed)) · \(SleepTrend.clockLabel(usualWake))", paper: paper)
                }
                if !awake.isEmpty {
                    SleepKey(mark: .gap, text: awakeMinutes.map { "gaps: awake \(Int($0.rounded())) min" } ?? "gaps: awake", paper: paper)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Sleep window"))
        .accessibilityValue(Text(verbatim: spoken))
    }

    private var title: some View {
        Text(verbatim: "Sleep window")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(paper.glow)
    }

    @ViewBuilder
    private var chips: some View {
        if !shifts.isEmpty {
            HStack(spacing: 6) {
                ForEach(shifts, id: \.text) { HXChip(paper: paper, symbol: $0.symbol, label: $0.text) }
            }
        }
    }

    private var spoken: String {
        var text = "Asleep \(SleepTrend.clockLabel(bed)), up \(SleepTrend.clockLabel(wake))"
        if let usualBed, let usualWake {
            text += ". Usually \(SleepTrend.clockLabel(usualBed)) to \(SleepTrend.clockLabel(usualWake))"
        }
        text += shifts.map { ". \($0.text)" }.joined()
        return text + (awake.isEmpty ? "" : ". \(awake.count) awake stretches")
    }

    /// "11 pm", "2 am" for minutes after noon on the hour.
    static func hour(_ minutesAfterNoon: Double) -> String {
        let hour = (Int(minutesAfterNoon / 60) + 12) % 24
        return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "am" : "pm")"
    }
}

/// One number as a tile: its value, a track with the value as a bar or dot and the usual as a white
/// tick or normal range shaded, a caption saying which, and a chip when it is far from usual (its
/// mark then drawn full strength).
private struct SleepGaugeTile: View {
    let gauge: SleepGauge
    let paper: HermexPaper

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: gauge.label)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(verbatim: gauge.value)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            track
            if let reference = gauge.reference {
                SleepKey(mark: gauge.band == nil ? .tick : .range, text: reference, paper: paper)
            }
            if let shift = gauge.shift {
                HXChip(paper: paper, symbol: shift.symbol, label: shift.text)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: gauge.label))
        .accessibilityValue(Text(verbatim: [gauge.value, gauge.reference, gauge.shift?.text].compactMap { $0 }.joined(separator: ", ")))
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let color = paper.glow.opacity(gauge.shift == nil ? 0.55 : 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hxSeparator).frame(height: 5)
                if let band = gauge.band {
                    Capsule().fill(paper.glow.opacity(0.35))
                        .frame(width: width * (gauge.position(band.upperBound) - gauge.position(band.lowerBound)), height: 5)
                        .offset(x: width * gauge.position(band.lowerBound))
                }
                if gauge.isBar {
                    Capsule().fill(color).frame(width: max(width * gauge.position(gauge.number), 5), height: 5)
                } else {
                    Circle().fill(color).frame(width: 10, height: 10)
                        .offset(x: width * gauge.position(gauge.number) - 5)
                }
                if let usual = gauge.usual {
                    Capsule().fill(Color.hxTextPrimary).frame(width: 2, height: 13)
                        .offset(x: width * gauge.position(usual) - 1)
                }
            }
            .frame(height: 13)
        }
        .frame(height: 13)
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
