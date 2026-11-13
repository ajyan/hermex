import Charts
import SwiftUI

/// Last night on the sleep card, once rated: its stats as tiles, the sleep coach's note, the week's
/// HRV against Garmin's normal range, and the week's hours against need, every value labeled. A deck
/// without tiles (built before them) shows the headline and lines instead.
struct SleepNumbers: View {
    let sleep: DeckSleep
    let palette: DeckPalette
    /// Opens the Sleep screen: every night, trends, and the table.
    let openHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sleep.tiles.isEmpty {
                legacy
            } else {
                SleepTiles(tiles: sleep.tiles, palette: palette)
                if let coach = sleep.coach {
                    SleepCoachNote(coach: coach, palette: palette)
                } else if let insight = sleep.insight {
                    SleepBox(palette: palette) {
                        Text(verbatim: insight)
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if sleep.nights.contains(where: { $0.hrv != nil }) {
                SleepBox(palette: palette) {
                    SleepBoxHeader(title: "HRV · 7 nights", detail: hrvDetail, palette: palette)
                    SleepHRVChart(nights: sleep.nights, band: sleep.hrvBand, palette: palette)
                }
            }
            if sleep.nights.contains(where: { $0.hours != nil }) {
                SleepBox(palette: palette) {
                    SleepBoxHeader(title: "Hours · 7 nights", detail: SleepDot.key, palette: palette)
                    SleepStrip(nights: sleep.nights, palette: palette)
                }
            }
            Button(action: openHistory) {
                Label { Text(verbatim: "Sleep trends") } icon: { Image(systemName: "chart.xyaxis.line") }
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "84 ms · balanced (85–104)": last night's HRV, Garmin's read of it, and its normal range.
    private var hrvDetail: String? {
        guard let last = sleep.nights.last?.hrv else { return nil }
        let range = sleep.hrvBand.map { "\(Int($0.lowerBound))–\(Int($0.upperBound))" }
        let status = [sleep.hrvStatus, range.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return (["\(Int(last.rounded())) ms"] + (status.isEmpty ? [] : [status])).joined(separator: " · ")
    }

    @ViewBuilder
    private var legacy: some View {
        if let headline = sleep.headline {
            Text(verbatim: headline)
                .font(AppFont.display(style: .title3, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let insight = sleep.insight {
            Text(verbatim: insight)
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(sleep.lines.enumerated()), id: \.offset) { _, line in
            Text(verbatim: line)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One box on the sleep card: the paper's wash, `sm` corners.
private struct SleepBox<Content: View>: View {
    let palette: DeckPalette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
    }
}

private struct SleepBoxHeader: View {
    let title: String
    let detail: String?
    let palette: DeckPalette

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title).font(AppFont.caption(weight: .semibold)).foregroundStyle(palette.ink)
            Spacer(minLength: 8)
            if let detail {
                Text(verbatim: detail).font(AppFont.caption2()).foregroundStyle(Color.hxTextPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Last night's stats, two to a row: the label in the card's ink, the value, and its note.
private struct SleepTiles: View {
    let tiles: [DeckSleepTile]
    let palette: DeckPalette

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading),
                                 count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                  alignment: .leading, spacing: 8) {
            ForEach(tiles, id: \.label) { tile in
                SleepBox(palette: palette) {
                    Text(verbatim: tile.label)
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Text(verbatim: tile.value)
                        .font(AppFont.display(style: .title3, weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let note = tile.note {
                        Text(verbatim: note)
                            .font(AppFont.caption2())
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The sleep coach's note: her name with a moon in the card's ink, then what she said.
private struct SleepCoachNote: View {
    let coach: DeckSleepCoach
    let palette: DeckPalette

    var body: some View {
        SleepBox(palette: palette) {
            Label { Text(verbatim: "\(coach.name) · sleep coach") } icon: { Image(systemName: "moon.stars") }
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(palette.ink)
            Text(verbatim: coach.text)
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The week's overnight HRV as a line with each night's value, over Garmin's normal range shaded.
private struct SleepHRVChart: View {
    let nights: [DeckNight]
    let band: ClosedRange<Double>?
    let palette: DeckPalette

    var body: some View {
        let points = Array(nights.enumerated()).compactMap { index, night in night.hrv.map { (index, night.day, $0) } }
        VStack(spacing: 4) {
            Chart {
                if let band {
                    RectangleMark(xStart: .value("Start", -0.5), xEnd: .value("End", Double(nights.count) - 0.5),
                                  yStart: .value("Low", band.lowerBound), yEnd: .value("High", band.upperBound))
                        .foregroundStyle(palette.ink.opacity(0.14))
                }
                ForEach(points, id: \.0) { index, _, value in
                    LineMark(x: .value("Night", Double(index)), y: .value("HRV", value))
                        .foregroundStyle(palette.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    PointMark(x: .value("Night", Double(index)), y: .value("HRV", value))
                        .foregroundStyle(index == nights.count - 1 ? Color.hxTextPrimary : palette.ink)
                        .symbolSize(28)
                        .annotation(position: .top, spacing: 3) {
                            Text(verbatim: "\(Int(value.rounded()))")
                                .font(AppFont.caption2(weight: index == nights.count - 1 ? .semibold : .regular))
                                .foregroundStyle(Color.hxTextPrimary)
                        }
                }
            }
            .chartXScale(domain: -0.5...(Double(nights.count) - 0.5))
            .chartYScale(domain: yDomain(points.map(\.2)))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 84)
            // The plot spans seven equal slots (-0.5...6.5), so seven equal-width labels sit under the points.
            HStack(spacing: 0) {
                ForEach(Array(nights.enumerated()), id: \.offset) { index, night in
                    Text(verbatim: night.day)
                        .font(AppFont.caption2(weight: index == nights.count - 1 ? .semibold : .regular))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "HRV, last \(nights.count) nights"))
        .accessibilityValue(Text(verbatim: points.map { "\($0.1): \(Int($0.2.rounded()))" }.joined(separator: ", ")
            + (band.map { ". Normal \(Int($0.lowerBound)) to \(Int($0.upperBound))" } ?? "")))
    }

    private func yDomain(_ values: [Double]) -> ClosedRange<Double> {
        let all = values + (band.map { [$0.lowerBound, $0.upperBound] } ?? [])
        guard let low = all.min(), let high = all.max() else { return 0...1 }
        let pad = max((high - low) * 0.18, 3)
        return (low - pad)...(high + pad * 1.6)
    }
}

/// The last seven nights as dots (`SleepDot`), one fixed column a night with its hours and day under
/// it, last night's labels bold. Numbers are dots, never bars.
private struct SleepStrip: View {
    let nights: [DeckNight]
    let palette: DeckPalette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(nights.enumerated()), id: \.offset) { index, night in
                let last = index == nights.count - 1
                VStack(spacing: 4) {
                    DeckDot(state: SleepDot.state(hours: night.hours, need: night.need), ink: palette.ink,
                            column: DeckDots.dot)
                    Text(verbatim: night.hours.map { String(format: "%.1f", $0) } ?? "–")
                        .font(AppFont.caption2(weight: last ? .semibold : .regular))
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(verbatim: night.day)
                        .font(AppFont.caption2(weight: last ? .semibold : .regular))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Hours slept, last \(nights.count) nights"))
        .accessibilityValue(Text(verbatim: nights.map { night in
            "\(night.day): " + (night.hours.map { "\($0.formatted()) hours" } ?? "no data")
                + (night.need.map { " of \($0.formatted()) needed" } ?? "")
        }.joined(separator: ", ")))
    }
}

/// A night's hours as a `DeckDot`, the way Goals' running year tiers its months: filled once the night
/// met its need (7.5 h when the need isn't known), a faint fill within an hour of it, a faint ring below that,
/// and the small off mark with no data. Never the ring or ringed + that mean today and waiting.
enum SleepDot {
    static let defaultNeed = 7.5
    /// The key beside a row of sleep dots.
    static let key = "full = need met · faint = within 1 h"

    static func state(hours: Double?, need: Double?) -> String {
        guard let hours, hours > 0 else { return "off" }
        let need = need ?? defaultNeed
        return hours >= need ? "done" : hours >= need - 1 ? "skip" : "missed"
    }
}
