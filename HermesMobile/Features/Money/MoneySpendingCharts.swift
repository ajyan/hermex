import Charts
import SwiftUI

/// A month's running total against the usual pace: the month in Money's glow, the usual dotted,
/// the latest day marked with its amount.
struct MoneyPaceChart: View {
    let detail: MoneySpending.MonthDetail
    let pace: MoneySpending.Pace
    let hidden: Bool

    var body: some View {
        let last = pace.actual.last ?? 0
        let top = max(pace.usual?.max() ?? 0, pace.actual.max() ?? 0, 1) * 1.12
        Chart {
            if let usual = pace.usual {
                ForEach(Array(usual.enumerated()), id: \.offset) { day, value in
                    LineMark(x: .value("Day", day + 1), y: .value("Spent", value), series: .value("Line", "Usual"))
                        .foregroundStyle(Color.hxTextSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 4]))
                }
            }
            ForEach(Array(pace.actual.enumerated()), id: \.offset) { day, value in
                LineMark(x: .value("Day", day + 1), y: .value("Spent", value), series: .value("Line", "This month"))
                    .foregroundStyle(HermexPaper.money.glow)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if !pace.actual.isEmpty {
                PointMark(x: .value("Day", pace.actual.count), y: .value("Spent", last))
                    .foregroundStyle(HermexPaper.money.glow)
                    .symbolSize(44)
                    .annotation(position: .top, alignment: pace.actual.count > pace.days * 4 / 5 ? .trailing : .center, spacing: 4) {
                        Text(verbatim: MoneyFormat.amount(last, hidden: hidden))
                            .font(AppFont.caption2(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .monospacedDigit()
                    }
            }
        }
        .chartXScale(domain: 1...max(pace.days, 2))
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: [1, pace.days]) { value in
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing) {
                    Text(verbatim: dayLabel(value.as(Int.self) ?? 1))
                        .font(AppFont.caption2())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Running total this month against your usual"))
        .accessibilityValue(Text(verbatim: spokenValue(last)))
    }

    private func dayLabel(_ day: Int) -> String {
        MoneyPoint.label(day: detail.month + String(format: "-%02d", day))
    }

    private func spokenValue(_ last: Double) -> String {
        let by = "\(MoneyFormat.amount(last, hidden: hidden)) by \(dayLabel(pace.actual.count))"
        guard let usual = pace.usual, pace.actual.count <= usual.count else { return by }
        return by + ", usually \(MoneyFormat.amount(usual[pace.actual.count - 1], hidden: hidden))"
    }
}

/// The share of a month's spending by category: slices in their fixed colors and order, the
/// picked one full strength and the rest dimmed, its name and share in the middle.
struct MoneyShareRing: View {
    let slices: [MoneySpendingCopy.Slice]
    let picked: String?

    var body: some View {
        let total = slices.map(\.amount).reduce(0, +)
        let shown = slices.first { $0.key == picked } ?? slices.max { $0.amount < $1.amount }
        Chart(slices) { slice in
            SectorMark(angle: .value("Spent", slice.amount), innerRadius: .ratio(0.66), angularInset: 1)
                .foregroundStyle(HermexSeries.color(for: slice.key))
                .opacity(picked == nil || picked == slice.key ? 1 : 0.25)
        }
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame, let shown {
                    let rect = geometry[frame]
                    VStack(spacing: 2) {
                        Text(verbatim: shown.name.components(separatedBy: " ").first ?? shown.name)
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(Color.hxTextSecondary)
                        Text(verbatim: MoneySpendingCopy.share(shown.amount, of: total))
                            .font(AppFont.display(style: .title3, weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .monospacedDigit()
                    }
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .frame(width: 136, height: 136)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Share of spending"))
        .accessibilityValue(Text(verbatim: slices.sorted { $0.amount > $1.amount }
            .map { "\($0.name) \(MoneySpendingCopy.share($0.amount, of: total))" }.joined(separator: ", ")))
    }
}

/// Money in and spent by month across the year: spent in Money's glow, in quieter, and the months
/// the log only partly covers hollow and dashed.
struct MoneyFlowChart: View {
    let months: [MoneySpending.CashFlowMonth]
    let hidden: Bool

    private struct Segment: Identifiable {
        let id: String
        let line: String
        let points: [(Int, Double)]
        let dashed: Bool
    }

    private var segments: [Segment] {
        guard months.count > 1 else { return [] }
        return (0..<(months.count - 1)).flatMap { i -> [Segment] in
            let dashed = months[i].partial || months[i + 1].partial
            return [
                Segment(id: "in\(i)", line: "In", points: [(i, months[i].in), (i + 1, months[i + 1].in)], dashed: dashed),
                Segment(id: "out\(i)", line: "Spent", points: [(i, months[i].out), (i + 1, months[i + 1].out)], dashed: dashed),
            ]
        }
    }

    var body: some View {
        let top = max(months.map { max($0.in, $0.out) }.max() ?? 0, 1) * 1.15
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.points, id: \.0) { point in
                    LineMark(x: .value("Month", point.0), y: .value("Amount", point.1), series: .value("Segment", segment.id))
                        .foregroundStyle(segment.line == "In" ? Color.hxTextSecondary : HermexPaper.money.glow)
                        .lineStyle(StrokeStyle(lineWidth: segment.line == "In" ? 1.5 : 2, lineCap: .round,
                                               dash: segment.dashed ? [4, 4] : []))
                }
            }
            ForEach(Array(months.enumerated()), id: \.offset) { index, month in
                PointMark(x: .value("Month", index), y: .value("Amount", month.out))
                    .symbol {
                        Circle()
                            .fill(month.partial ? Color.hxSurface : HermexPaper.money.glow)
                            .overlay(Circle().strokeBorder(HermexPaper.money.glow, lineWidth: 2))
                            .frame(width: 9, height: 9)
                    }
                    .annotation(position: .bottom, spacing: 4) {
                        if index == months.count - 1 { lineLabel("Spent", primary: true) }
                    }
                if index == months.count - 1 {
                    PointMark(x: .value("Month", index), y: .value("Amount", month.in))
                        .opacity(0)
                        .annotation(position: .top, spacing: 2) { lineLabel("In", primary: false) }
                }
            }
        }
        .chartXScale(domain: -0.3...(Double(max(months.count, 2) - 1) + 0.3))
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: Array(months.indices)) { value in
                AxisValueLabel(centered: false) {
                    Text(verbatim: value.as(Int.self).flatMap { months.indices.contains($0) ? MoneySpendingCopy.shortMonth(months[$0].month) : nil } ?? "")
                        .font(AppFont.caption2())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Money in and spent by month"))
        .accessibilityValue(Text(verbatim: MoneySpendingCopy.flowValue(months, hidden: hidden)))
    }

    private func lineLabel(_ text: String, primary: Bool) -> some View {
        Text(verbatim: text)
            .font(AppFont.caption2(weight: primary ? .semibold : .medium))
            .foregroundStyle(primary ? Color.hxTextPrimary : Color.hxTextSecondary)
    }
}
