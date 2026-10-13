import Charts
import SwiftUI

/// Net worth over a range, Robinhood-style: one line in the range's gain or loss color, no axes,
/// a dotted baseline at the range's first value, and a dashed segment for estimated days.
/// Dragging across it scrubs: `onScrub` gets the date under the finger, then nil on release.
struct MoneyChart: View {
    let points: [MoneyPoint]
    let scrubbed: MoneyPoint?
    let color: Color
    let onScrub: (Date?) -> Void

    @State private var selection: Date?

    var body: some View {
        Chart {
            if let first = points.first {
                RuleMark(y: .value("Start", first.v))
                    .foregroundStyle(Color.hxTextSecondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 4]))
            }
            ForEach(estimated) { point in
                LineMark(x: .value("Day", point.date), y: .value("Net worth", point.v), series: .value("Part", "estimated"))
                    .foregroundStyle(color.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
            }
            ForEach(real) { point in
                LineMark(x: .value("Day", point.date), y: .value("Net worth", point.v), series: .value("Part", "real"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            if let scrubbed {
                RuleMark(x: .value("Day", scrubbed.date))
                    .foregroundStyle(Color.hxTextSecondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Day", scrubbed.date), y: .value("Net worth", scrubbed.v))
                    .foregroundStyle(color)
                    .symbolSize(70)
            } else if points.count == 1, let only = points.first {
                PointMark(x: .value("Day", only.date), y: .value("Net worth", only.v))
                    .foregroundStyle(color)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartXSelection(value: $selection)
        .onChange(of: selection) { _, date in onScrub(date) }
        .sensoryFeedback(.selection, trigger: scrubbed?.d)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "Net worth chart"))
        .accessibilityValue(Text(verbatim: accessibilitySummary))
    }

    /// Estimated days plus the first real day, so the dashed and solid lines meet.
    private var estimated: [MoneyPoint] {
        let head = points.filter(\.e)
        guard !head.isEmpty else { return [] }
        return head + (points.first { !$0.e }.map { [$0] } ?? [])
    }

    private var real: [MoneyPoint] { points.filter { !$0.e } }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.v)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.08, abs(high) * 0.002, 1)
        return (low - pad)...(high + pad)
    }

    private var accessibilitySummary: String {
        let change = MoneyChange.between(points)
        return "\(MoneyFormat.percent(change.percent)) over \(points.count) days"
    }
}
