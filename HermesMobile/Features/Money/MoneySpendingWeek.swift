import Charts
import SwiftUI

/// One week of `week_details` in `spending.json` (vault `finance/sync/money_weeks.py`): its day-to-day
/// spending against a usual week, the bills on top, the eight weeks to it, the month so far, its top
/// categories and what was out of the ordinary. The Sunday review's money card shows one.
extension MoneySpending {
    struct WeekDetail: Decodable, Equatable, Identifiable {
        let start: String
        var end: String
        var partial: Bool
        /// Day to day: no rent, bills, loans, fees, transfers or one-time charges.
        var spent: Double
        /// A usual week, from a usual month; nil before the log has a full month.
        var usual: Double?
        var headline: String?
        var bills: Bills?
        /// The eight weeks to this one, oldest first.
        var trend: [TrendWeek]
        var month: SoFar?
        var categories: [WeekCategory]
        var odd: [Odd]
        var id: String { start }

        private enum CodingKeys: String, CodingKey {
            case start, end, partial, spent, usual, headline, bills, trend, month, categories, odd
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(String.self, forKey: .start)
            end = (try? c.decodeIfPresent(String.self, forKey: .end)) ?? start
            partial = (try? c.decodeIfPresent(Bool.self, forKey: .partial)) ?? false
            spent = (try? c.decodeIfPresent(Double.self, forKey: .spent)) ?? 0
            usual = try? c.decodeIfPresent(Double.self, forKey: .usual)
            headline = try? c.decodeIfPresent(String.self, forKey: .headline)
            bills = try? c.decodeIfPresent(Bills.self, forKey: .bills)
            trend = c.lossyArray(TrendWeek.self, .trend)
            month = try? c.decodeIfPresent(SoFar.self, forKey: .month)
            categories = c.lossyArray(WeekCategory.self, .categories)
            odd = c.lossyArray(Odd.self, .odd)
        }
    }

    struct Bills: Decodable, Equatable {
        var spent: Double
        var count: Int
        var names: [String]
    }

    struct TrendWeek: Decodable, Equatable {
        let start: String
        var spent: Double
        var partial: Bool?
    }

    /// The week's month so far: day-to-day spending, how many days in, where it's heading, and a usual month.
    struct SoFar: Decodable, Equatable {
        let month: String
        var spent: Double
        var days: Int
        var length: Int
        var pace: Double?
        var usual: Double?
    }

    struct WeekCategory: Decodable, Equatable, Identifiable {
        let key: String
        var name: String
        var spent: Double
        var usual: Double?
        var trend: [Double]
        /// "Up 3 weeks in a row", "About usual", "Nothing for 2 weeks, after $341".
        var note: String?
        var id: String { key }
    }

    /// A one-time charge, a charge well over a place's usual, a double charge, or a fee.
    struct Odd: Decodable, Equatable, Identifiable {
        let kind: String
        var group: String?
        var title: String
        var amount: Double
        var day: String
        var detail: String
        var question: String
        var txns: [String]?
        var id: String { "\(kind)|\(day)|\(title)" }
    }

    func week(starting start: String?) -> WeekDetail? {
        weekDetails.first { $0.start == start }
    }
}

/// The money card's words. Amounts go through `MoneyFormat`, so a hidden card keeps its sentences.
enum MoneyWeekCopy {
    /// "Oct 12–18", or "Sep 28–Oct 4" across a month.
    static func range(_ week: MoneySpending.WeekDetail) -> String {
        let start = MoneyPoint.label(day: week.start)
        let end = MoneyPoint.label(day: week.end)
        guard start.prefix(3) == end.prefix(3), let day = end.split(separator: " ").last else { return "\(start)–\(end)" }
        return "\(start)–\(day)"
    }

    /// How far over or under a usual amount: nil when it's close enough to call usual.
    static func gap(_ value: Double, usual: Double) -> Double? {
        let gap = value - usual
        return abs(gap) <= max(5, usual * 0.05) ? nil : gap
    }

    /// "$334 day to day, about $25 over a usual week."
    static func lead(_ week: MoneySpending.WeekDetail, hidden: Bool) -> String {
        guard let usual = week.usual else {
            return hidden ? "Day-to-day spending this week." : "\(MoneyFormat.amount(week.spent, hidden: false)) day to day."
        }
        guard let gap = gap(week.spent, usual: usual) else {
            return hidden ? "About a usual week, day to day." : "\(MoneyFormat.amount(week.spent, hidden: false)) day to day, about a usual week."
        }
        let side = gap > 0 ? "over" : "under"
        if hidden { return "\(side == "over" ? "Over" : "Under") a usual week, day to day." }
        return "\(MoneyFormat.amount(week.spent, hidden: false)) day to day, about \(MoneyFormat.amount(abs(gap), hidden: false)) \(side) a usual week."
    }

    /// "Bills on top: $70 (Spectrum Internet)."; nil without bills.
    static func bills(_ week: MoneySpending.WeekDetail, hidden: Bool) -> String? {
        guard let bills = week.bills, bills.count > 0 else { return nil }
        var names = bills.names.joined(separator: ", ")
        if bills.count > bills.names.count { names += " and \(bills.count - bills.names.count) more" }
        return "Bills on top: \(MoneyFormat.amount(bills.spent, hidden: hidden))" + (names.isEmpty ? "." : " (\(names)).")
    }

    /// The trailing word on an average row: "+$25 over", "−$65 under" or "About usual".
    static func delta(_ value: Double, usual: Double, hidden: Bool) -> String {
        guard let gap = gap(value, usual: usual) else { return "About usual" }
        if hidden { return gap > 0 ? "Over" : "Under" }
        return (gap > 0 ? "+" : "−") + MoneyFormat.amount(abs(gap), hidden: false) + (gap > 0 ? " over" : " under")
    }

    /// "18 days in, on pace for about $1,370. A usual month is $1,340."
    static func monthMeta(_ month: MoneySpending.SoFar, hidden: Bool) -> String {
        var line = "\(month.days) \(month.days == 1 ? "day" : "days") in"
        if month.days >= month.length { line = "The whole month" }
        if let pace = month.pace { line += ", on pace for about \(MoneyFormat.amount(pace, hidden: hidden))" }
        line += "."
        if let usual = month.usual { line += " A usual month is \(MoneyFormat.amount(usual, hidden: hidden))." }
        return line
    }

    /// "Up 3 weeks in a row · usual $200".
    static func categoryMeta(_ category: MoneySpending.WeekCategory, hidden: Bool) -> String {
        let usual = category.usual.map { "usual " + MoneyFormat.amount($0, hidden: hidden) }
        let note = category.note.flatMap { $0.isEmpty ? nil : (hidden ? MoneySpendingCopy.masked($0) : $0) }
        return [note, usual].compactMap { $0 }.joined(separator: " · ")
    }

    /// An odd one's row: its title (with the amount when the detail doesn't carry it) and why.
    static func odd(_ odd: MoneySpending.Odd) -> (title: String, detail: String) {
        let money = "$" + String(format: "%.2f", odd.amount)
        switch odd.kind {
        case "one_time": return ("\(odd.title) \(money)", "One-time · \(odd.detail)")
        case "bigger": return ("\(odd.title) \(money)", "Bigger than usual · \(odd.detail)")
        case "fee": return (odd.title, "A fee · \(odd.detail)")
        default: return (odd.title, odd.detail)
        }
    }

    /// Under the chart: what the line is, and the dotted usual week.
    static func trendCaption(usual: Double?, hidden: Bool) -> String {
        let dotted = usual.map { " The dotted line is a usual week, \(MoneyFormat.amount($0, hidden: hidden))." } ?? ""
        return "Day-to-day spending each week, in dollars; the filled point is this one.\(dotted) Bills and one-time charges are left out."
    }

    /// "Sep 7" under every other week, ending on this one.
    static func trendLabel(_ trend: [MoneySpending.TrendWeek], at index: Int) -> String {
        (trend.count - 1 - index) % 2 == 0 ? MoneyPoint.label(day: trend[index].start) : ""
    }
}

/// The weeks to this one as one line, this week filled, against a dotted usual week.
struct MoneyWeekTrendChart: View {
    let trend: [MoneySpending.TrendWeek]
    let usual: Double?
    let hidden: Bool
    /// Labels and the usual line: the paper's `secondaryInk` on the review card.
    var secondary: Color = .hxTextSecondary

    /// The scale's lines: $0 and two round steps up to the top, so the line reads as dollars.
    static func ticks(top: Double) -> [Double] {
        let raw = top / 2.5
        let magnitude = pow(10, floor(log10(max(raw, 1))))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
        return (0...3).map { Double($0) * step }.filter { $0 <= top }
    }

    var body: some View {
        let top = max(trend.map(\.spent).max() ?? 0, usual ?? 0, 1) * 1.2
        let last = trend.count - 1
        let ticks = Self.ticks(top: top)
        Chart {
            ForEach(ticks, id: \.self) { tick in
                RuleMark(y: .value("Scale", tick))
                    .foregroundStyle(HermexPaper.money.glow.opacity(tick == 0 ? 0.25 : 0.1))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            if let usual {
                RuleMark(y: .value("Usual", usual))
                    .foregroundStyle(secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 4]))
            }
            ForEach(Array(trend.enumerated()), id: \.offset) { index, week in
                LineMark(x: .value("Week", index), y: .value("Spent", week.spent))
                    .foregroundStyle(HermexPaper.money.glow)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Week", index), y: .value("Spent", week.spent))
                    .symbol {
                        Circle()
                            .fill(index == last && week.partial != true ? HermexPaper.money.glow : HermexPaper.money.card)
                            .overlay(Circle().strokeBorder(HermexPaper.money.glow, lineWidth: 2))
                            .frame(width: index == last ? 10 : 7, height: index == last ? 10 : 7)
                    }
            }
        }
        .chartXScale(domain: -0.3...(Double(max(trend.count, 2) - 1) + 0.3))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(.bottom, 22).padding(.leading, hidden ? 0 : 46).padding(.top, 16) }
        .chartOverlay { proxy in
            // Labels drawn on their marks: the axes' own labels sit half a step off on these values.
            GeometryReader { geometry in
                if let plot = proxy.plotFrame.map({ geometry[$0] }) {
                    ForEach(Array(trend.indices), id: \.self) { index in
                        let label = MoneyWeekCopy.trendLabel(trend, at: index)
                        if !label.isEmpty, let x = proxy.position(forX: index) {
                            Text(verbatim: label)
                                .font(AppFont.caption2())
                                .foregroundStyle(secondary)
                                .fixedSize()
                                .position(x: plot.minX + x, y: plot.maxY + 14)
                        }
                    }
                    if !hidden {
                        let usualY = usual.flatMap { proxy.position(forY: $0) }
                        ForEach(ticks, id: \.self) { tick in
                            if let y = proxy.position(forY: tick), usualY.map({ abs($0 - y) > 18 }) ?? true {
                                gutter(MoneyFormat.amount(tick, hidden: false), y: plot.minY + y, plot: plot)
                                    .foregroundStyle(secondary)
                            }
                        }
                        if let usual, let y = usualY {
                            gutter(MoneyFormat.amount(usual, hidden: false), y: plot.minY + y, plot: plot)
                                .fontWeight(.semibold)
                                .foregroundStyle(secondary)
                        }
                        if trend.indices.contains(last), let x = proxy.position(forX: last),
                           let y = proxy.position(forY: trend[last].spent) {
                            Text(verbatim: MoneyFormat.amount(trend[last].spent, hidden: false))
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(Color.hxTextPrimary)
                                .fixedSize()
                                // Above the point, or below it when the dotted usual line runs just above.
                                .position(x: plot.minX + x - 8,
                                          y: plot.minY + y + (trend[last].spent < (usual ?? 0) ? 16 : -16))
                        }
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .frame(height: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    /// A dollar label in the gutter left of the plot, level with its line.
    private func gutter(_ text: String, y: CGFloat, plot: CGRect) -> some View {
        Text(verbatim: text)
            .font(AppFont.caption2())
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 42, alignment: .trailing)
            .position(x: plot.minX - 25, y: y)
    }

    private var accessibilityText: String {
        let weeks = trend.map { "week of \(MoneyPoint.label(day: $0.start)): \(MoneyFormat.amount($0.spent, hidden: hidden))" }
        let usualText = usual.map { ", against a usual week of \(MoneyFormat.amount($0, hidden: hidden))" } ?? ""
        return "Day-to-day spending for the last \(trend.count) weeks\(usualText). " + weeks.joined(separator: "; ")
    }
}
