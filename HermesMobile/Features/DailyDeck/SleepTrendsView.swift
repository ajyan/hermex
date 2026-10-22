import Charts
import SwiftUI

/// The Sleep screen's trends (a metric over a span) and its table of nights.

// MARK: Trends

struct SleepTrendSection: View {
    @Bindable var viewModel: SleepViewModel
    let showNight: (String) -> Void

    @State private var selection: Date?

    var body: some View {
        let points = viewModel.points
        let summary = viewModel.summary
        VStack(alignment: .leading, spacing: 10) {
            HXSectionHeader(title: "Trends", trailing: summaryText(summary))
            VStack(alignment: .leading, spacing: 12) {
                metricPicker
                Picker(selection: $viewModel.range) {
                    ForEach(SleepRange.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                } label: { Text(verbatim: "Span") }
                    .pickerStyle(.segmented)
                if points.isEmpty {
                    Text(verbatim: "No \(viewModel.metric.title.lowercased()) in this span.")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    SleepTrendChart(points: points, metric: viewModel.metric, average: summary.average,
                                    selected: selected(in: points), selection: $selection)
                        .frame(height: 200)
                    selectionLine(selected(in: points))
                }
            }
            .padding(HXCard<EmptyView, EmptyView, EmptyView>.padding)
            .hxCard()
        }
        .onChange(of: viewModel.metric) { selection = nil }
        .onChange(of: viewModel.range) { selection = nil }
    }

    private var metricPicker: some View {
        FlowRow(spacing: 8) {
            ForEach(SleepMetric.allCases) { metric in
                let isOn = metric == viewModel.metric
                Button { viewModel.metric = metric } label: {
                    Text(verbatim: metric.title)
                        .font(AppFont.subheadline(weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .foregroundStyle(isOn ? Color.white : Color.hxTextPrimary)
                        .background(isOn ? Color.accentColor : Color.hxCanvas, in: Capsule())
                        .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.hxSeparator, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func selected(in points: [SleepPoint]) -> SleepPoint? {
        guard let selection else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    @ViewBuilder
    private func selectionLine(_ point: SleepPoint?) -> some View {
        if let point {
            HStack {
                Text(verbatim: describe(point))
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextPrimary)
                Spacer()
                if let night = point.night {
                    Button("Show night") { showNight(night) }
                        .font(AppFont.footnote(weight: .semibold))
                }
            }
        } else {
            Text(verbatim: "Tap a bar to see that \(viewModel.range.isWeekly ? "week" : "night").")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
        }
    }

    private func describe(_ point: SleepPoint) -> String {
        let day = SleepTrend.label(point.date) { $0.weekday(.abbreviated).month(.abbreviated).day() }
        let value: String
        if viewModel.metric == .window, let low = point.low, let high = point.high {
            value = "\(SleepTrend.clockLabel(low)) – \(SleepTrend.clockLabel(high))"
        } else {
            value = viewModel.metric.format(point.value)
        }
        guard let date = point.night else { return "Week of \(SleepTrend.label(point.date) { $0.month(.abbreviated).day() }) · \(value)" }
        let quality = viewModel.history?.night(on: date)?.quality.map { " · you: \(SleepRating.labels[$0 - 1])" } ?? ""
        return "\(day) · \(value)\(quality)"
    }

    private func summaryText(_ summary: (average: Double?, change: Double?)) -> String? {
        guard let average = summary.average else { return nil }
        var text = "avg \(viewModel.metric.format(average))"
        if let change = summary.change, viewModel.metric != .window {
            let shown = viewModel.metric.format(abs(change))
            if shown != viewModel.metric.format(0) {
                text += " · \(change > 0 ? "+" : "−")\(shown) vs last \(viewModel.range.periodName)"
            }
        }
        return text
    }
}

private struct SleepTrendChart: View {
    let points: [SleepPoint]
    let metric: SleepMetric
    let average: Double?
    let selected: SleepPoint?
    @Binding var selection: Date?

    private let paper = HermexPaper.notes

    var body: some View {
        Chart {
            ForEach(points) { point in
                let isSelected = selected?.date == point.date
                let color = paper.glow.opacity(selected == nil || isSelected ? 1 : 0.4)
                if metric == .window, let low = point.low, let high = point.high {
                    // Negated so the evening sits above the morning, like a clock read downwards.
                    BarMark(x: .value("Night", point.date, unit: unit), yStart: .value("Bed", -low), yEnd: .value("Wake", -high))
                        .foregroundStyle(color)
                        .clipShape(Capsule())
                } else {
                    BarMark(x: .value("Night", point.date, unit: unit), y: .value(metric.title, point.value))
                        .foregroundStyle(color)
                }
            }
            // Hours get one line at the span's need instead of the average, which sits a few
            // minutes under it and would draw a second line in the same place.
            if let need = SleepTrend.mean(points.compactMap(\.need)) {
                RuleMark(y: .value("Need", need))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text(verbatim: "need \(metric.format(need))")
                            .font(AppFont.caption2(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                    }
            } else if let average, metric != .window {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.hxTextSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXSelection(value: $selection)
        .chartYScale(domain: yDomain)
        // Bars start at zero; a scale that starts higher cuts them at the plot's floor.
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.hxSeparator)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: metric == .window ? SleepTrend.clockLabel(-v) : metric.format(v))
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected?.date)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "\(metric.title) chart"))
        .accessibilityValue(Text(verbatim: average.map { "Average \(metric.format($0)), \(points.count) bars" } ?? ""))
    }

    private var unit: Calendar.Component { points.count > 60 || isWeekly ? .weekOfYear : .day }

    private var isWeekly: Bool { points.allSatisfy { $0.night == nil } }

    private var yDomain: ClosedRange<Double> {
        if metric == .window {
            let lows = points.compactMap(\.low), highs = points.compactMap(\.high)
            guard let early = lows.min(), let late = highs.max() else { return -1...0 }
            return (-late - 30)...(-early + 30)
        }
        let values = points.map(\.value) + points.compactMap(\.need)
        let top = values.max() ?? 1
        switch metric {
        case .hrv, .restingHR:
            let low = values.min() ?? 0
            let pad = max((top - low) * 0.15, 2)
            return max(0, low - pad)...(top + pad)
        default: return 0...max(top * 1.1, 1)
        }
    }
}

// MARK: Nights

struct SleepNightsTable: View {
    let viewModel: SleepViewModel
    let showNight: (String) -> Void

    /// Each number column's width, so columns line up across rows and grow with Dynamic Type.
    /// Bedtime ("11:40 pm") and his rating ("Very good") get wider ones.
    @ScaledMetric(relativeTo: .subheadline) private var cellWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var clockWidth: CGFloat = 66
    @ScaledMetric(relativeTo: .subheadline) private var ratingWidth: CGFloat = 78

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HXSectionHeader(title: "Nights", trailing: "newest first")
            VStack(spacing: 0) {
                row(cells: ["Night", "Bedtime", "Hours", "Wakes", "Rated"], isHeader: true)
                ForEach(viewModel.tableNights) { night in
                    Divider().overlay(Color.hxSeparator)
                    Button { showNight(night.date) } label: {
                        row(cells: cells(night), isHeader: false, isSelected: night.date == viewModel.night?.date)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: spoken(night)))
                    .accessibilityHint(Text(verbatim: "Shows this night at the top"))
                }
                if viewModel.hasMoreNights {
                    Divider().overlay(Color.hxSeparator)
                    Button("Show more nights") { viewModel.showMoreNights() }
                        .font(AppFont.subheadline(weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .padding(.horizontal, 12)
            .hxCard()
        }
    }

    private func row(cells: [String], isHeader: Bool, isSelected: Bool = false) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(verbatim: cell)
                    .font(isHeader ? AppFont.caption(weight: .semibold) : AppFont.subheadline(weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isHeader ? Color.hxTextSecondary : Color.hxTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: index == 0 ? .infinity : nil, alignment: .leading)
                    .frame(width: [nil, clockWidth, cellWidth, cellWidth, ratingWidth][index], alignment: .trailing)
            }
        }
        .padding(.vertical, isHeader ? 8 : 10)
        .contentShape(Rectangle())
        .accessibilityHidden(isHeader)
    }

    private func cells(_ night: SleepNight) -> [String] {
        let day = night.day.map { SleepTrend.label($0) { $0.weekday(.abbreviated).day() } } ?? night.date
        return [day, night.bedClock.map(SleepTrend.clockLabel) ?? "–", night.hours.map { String(format: "%.1f", $0) } ?? "–",
                whole(night.wakeUps), night.quality.map { SleepRating.labels[$0 - 1] } ?? "–"]
    }

    private func whole(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))" } ?? "–" }

    private func spoken(_ night: SleepNight) -> String {
        var parts = [night.day.map { SleepTrend.label($0) { $0.weekday(.wide).month(.wide).day() } } ?? night.date]
        if let bed = night.bedClock { parts.append("asleep at \(SleepTrend.clockLabel(bed))") }
        if let hours = night.hours { parts.append("\(String(format: "%.1f", hours)) hours") }
        if let wakeUps = night.wakeUps { parts.append("\(Int(wakeUps)) wake-ups") }
        if let quality = night.quality { parts.append("you rated it \(SleepRating.labels[quality - 1])") }
        return parts.joined(separator: ", ")
    }
}
