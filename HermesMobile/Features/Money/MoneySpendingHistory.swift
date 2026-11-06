import Foundation

/// `spending.json`'s `months` and `year`, written by the vault's `finance/sync/money_months.py`:
/// each month with its pace, what stood out, its one-off charges and every transaction, and the
/// year so far by month and category. Every field is optional on the wire.
extension MoneySpending {
    /// One month: shaped like `month`, plus its running total against the usual pace, what stood
    /// out, its biggest one-off charges (not rent or bills) and every transaction, newest first.
    struct MonthDetail: Decodable, Equatable, Identifiable {
        /// "2026-10".
        let month: String
        var summary: Month
        /// This month, still going.
        var current = false
        /// The log covers only part of it: this month, or the month the log starts in.
        var partial = false
        var pace: Pace?
        var stands: [Stand] = []
        var biggest: [String] = []
        var txns: [String] = []
        var id: String { month }

        enum CodingKeys: String, CodingKey { case month, current, partial, pace, stands, biggest, txns }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            month = try c.decode(String.self, forKey: .month)
            summary = try Month(from: decoder)
            current = (try? c.decodeIfPresent(Bool.self, forKey: .current)) ?? false
            partial = (try? c.decodeIfPresent(Bool.self, forKey: .partial)) ?? current
            pace = try? c.decodeIfPresent(Pace.self, forKey: .pace)
            stands = c.lossyArray(Stand.self, .stands)
            biggest = (try? c.decodeIfPresent([String].self, forKey: .biggest)) ?? []
            txns = (try? c.decodeIfPresent([String].self, forKey: .txns)) ?? []
        }

        /// This month from a file that has `month` but no `months`.
        init(current month: Month) {
            self.month = String(month.start.prefix(7))
            summary = month
            current = true
            partial = true
            txns = month.categories.flatMap(\.txns)
        }
    }

    /// Running totals from the 1st, one a day: `actual` through the month's last day so far, `usual`
    /// across the whole month (the average of up to three earlier full months), nil without one.
    struct Pace: Decodable, Equatable {
        var days: Int
        var actual: [Double]
        var usual: [Double]?
    }

    /// Something that stood out in a month or the year. `group` colors its dot; `question` is what
    /// Ask Atlas starts with.
    struct Stand: Decodable, Equatable, Identifiable {
        let kind: String
        var group: String?
        let title: String
        var detail: String
        var question: String
        /// The transactions behind it, so a flag about the same charge isn't shown twice.
        var txns: [String] = []
        var id: String { kind + "|" + title }

        enum CodingKeys: String, CodingKey { case kind, group, title, detail, question, txns }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "other"
            group = try? c.decodeIfPresent(String.self, forKey: .group)
            title = try c.decode(String.self, forKey: .title)
            detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
            question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? title
            txns = (try? c.decodeIfPresent([String].self, forKey: .txns)) ?? []
        }
    }

    /// The calendar year since `since` (Jan 1, or the day the log starts).
    struct Year: Decodable, Equatable {
        var year: Int
        var since: String?
        var spent: Double
        var income: Double
        /// What a complete month averages; nil until the log has one.
        var fullMonth: Double?
        var months: [CashFlowMonth] = []
        var categories: [YearCategory] = []
        var best: YearMonth?
        var toughest: YearMonth?
        var places: [Place] = []
        var stands: [Stand] = []

        enum CodingKeys: String, CodingKey {
            case year, since, spent, income, fullMonth, months, categories, best, toughest, places, stands
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            year = try c.decode(Int.self, forKey: .year)
            since = try? c.decodeIfPresent(String.self, forKey: .since)
            spent = (try? c.decodeIfPresent(Double.self, forKey: .spent)) ?? 0
            income = (try? c.decodeIfPresent(Double.self, forKey: .income)) ?? 0
            fullMonth = try? c.decodeIfPresent(Double.self, forKey: .fullMonth)
            months = c.lossyArray(CashFlowMonth.self, .months)
            categories = c.lossyArray(YearCategory.self, .categories)
            best = try? c.decodeIfPresent(YearMonth.self, forKey: .best)
            toughest = try? c.decodeIfPresent(YearMonth.self, forKey: .toughest)
            places = c.lossyArray(Place.self, .places)
            stands = c.lossyArray(Stand.self, .stands)
        }
    }

    /// A group across the year: the total, a full month's average, and each of `Year.months`' amounts.
    struct YearCategory: Decodable, Equatable, Identifiable {
        let key: String
        var name: String
        var total: Double
        var average: Double?
        var months: [Double]
        var id: String { key }
    }

    /// The best or toughest month by what was kept, and why in a few words.
    struct YearMonth: Decodable, Equatable {
        let month: String
        var kept: Double
        var note: String?
    }

    /// Where the most went this year, leaving out rent and bills.
    struct Place: Decodable, Equatable, Identifiable {
        let name: String
        var group: String?
        var visits: Int
        var total: Double
        var id: String { name }
    }
}

/// The month and year views' words and small derivations, apart from the views so tests can read them.
extension MoneySpendingCopy {
    struct Slice: Equatable, Identifiable {
        /// The `HermexSeries` key.
        let key: String
        let name: String
        let amount: Double
        var id: String { key }
    }

    struct DayGroup: Equatable, Identifiable {
        let day: String
        let rows: [MoneySpending.Transaction]
        var id: String { day }
    }

    /// "October 2026".
    static func monthLabel(_ month: String) -> String {
        MoneyPoint.dayFormatter.date(from: month + "-01")
            .map { $0.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()) } ?? month
    }

    /// Under the month's name: "So far · Oct 1–20", "From Jun 20" (where the log starts), or "Full month".
    static func monthNote(_ detail: MoneySpending.MonthDetail, historyStart: String?) -> String {
        let start = detail.summary.start, end = detail.summary.end
        if detail.current {
            let last = end.split(separator: "-").last.map { String(Int($0) ?? 0) } ?? ""
            return "So far · \(MoneyPoint.label(day: start))–\(last)"
        }
        if detail.partial { return "From " + MoneyPoint.label(day: max(start, historyStart ?? start)) }
        return "Full month"
    }

    /// The headline's second line: against the usual, or why there's none.
    static func usualLine(_ detail: MoneySpending.MonthDetail, historyStart: String?, hidden: Bool) -> String {
        let month = detail.summary
        guard let usual = month.usual else {
            return "No usual yet: the log starts \(MoneyPoint.label(day: historyStart ?? month.start))"
        }
        let versus = MoneyFormat.versusUsual(month.spent, usual: usual.spent, hidden: hidden)
        return detail.current ? versus + " by " + MoneyPoint.label(day: month.end) : versus
    }

    /// A finished month's "Kept $1,921 of the $5,734 that came in"; nil while it's going or part-covered.
    static func keptLine(_ detail: MoneySpending.MonthDetail, hidden: Bool) -> String? {
        guard !detail.partial, detail.summary.income > 0 else { return nil }
        return kept(income: detail.summary.income, spent: detail.summary.spent, hidden: hidden)
    }

    static func kept(income: Double, spent: Double, hidden: Bool) -> String {
        let kept = income - spent
        return kept >= 0
            ? "Kept \(MoneyFormat.amount(kept, hidden: hidden)) of the \(MoneyFormat.amount(income, hidden: hidden)) that came in"
            : "Spent \(MoneyFormat.amount(-kept, hidden: hidden)) more than the \(MoneyFormat.amount(income, hidden: hidden)) that came in"
    }

    /// "against Jul–Sep", "against July", or this month's "against the same days of 3 months".
    static func against(_ detail: MoneySpending.MonthDetail) -> String? {
        guard let usual = detail.summary.usual else { return nil }
        guard let from = usual.from, let to = usual.to else {
            return usual.months == 1 ? "against last month" : "against \(usual.months) months"
        }
        if from == to { return "against " + monthName(from) }
        return "against \(shortMonth(from))–\(shortMonth(to))"
    }

    /// "Jul" from "2026-07".
    static func shortMonth(_ month: String) -> String {
        MoneyPoint.dayFormatter.date(from: month + "-01")
            .map { $0.formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated)) } ?? month
    }

    /// "57%", or "<1%" for a sliver.
    static func share(_ amount: Double, of total: Double) -> String {
        guard total > 0 else { return "" }
        let percent = amount / total * 100
        return percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }

    /// The ring's slices in `HermexSeries.order`, so a category sits in the same place every month;
    /// the groups without a color of their own add up into `rest`.
    static func slices(_ categories: [MoneySpending.Category]) -> [Slice] {
        var amounts: [String: Double] = [:]
        for category in categories where category.amount > 0 {
            amounts[HermexSeries.key(for: category.key), default: 0] += category.amount
        }
        return HermexSeries.order.compactMap { key in
            guard let amount = amounts[key] else { return nil }
            let name = key == "rest" ? "Everything else" : categories.first { $0.key == key }?.name ?? key.capitalized
            return Slice(key: key, name: name, amount: amount)
        }
    }

    /// The legend beside the ring: the four biggest colored slices, then everything else together.
    static func legend(_ slices: [Slice]) -> [Slice] {
        let named = slices.filter { $0.key != "rest" }.sorted { $0.amount > $1.amount }
        let shown = Array(named.prefix(4))
        let restAmount = slices.map(\.amount).reduce(0, +) - shown.map(\.amount).reduce(0, +)
        return restAmount >= 0.5 ? shown + [Slice(key: "rest", name: "Everything else", amount: restAmount)] : shown
    }

    /// The pace chart's caption.
    static func paceCaption(_ detail: MoneySpending.MonthDetail) -> String {
        let against = against(detail).map { ", " + $0.replacingOccurrences(of: "against ", with: "") } ?? ""
        guard let pace = detail.pace, let usual = pace.usual else { return "Your running total this month." }
        let dotted = "Dotted: your usual running total\(against)."
        guard !detail.current else { return dotted }
        let under = zip(pace.actual, usual).allSatisfy { $0 <= $1 }
        return under ? dotted + " \(monthName(detail.month)) stayed under it all month." : dotted
    }

    /// "37 this month" or "50 in September".
    static func logCount(_ detail: MoneySpending.MonthDetail, count: Int) -> String {
        detail.current ? "\(count) this month" : "\(count) in \(monthName(detail.month))"
    }

    /// This month's flags that "What stands out" hasn't already told: none with the same title or
    /// only charges a stand-out names.
    static func untold(_ flags: [MoneySpending.Flag], _ detail: MoneySpending.MonthDetail) -> [MoneySpending.Flag] {
        let titles = Set(detail.stands.map(\.title))
        let told = Set(detail.stands.flatMap(\.txns))
        return flags.filter { !titles.contains($0.title) && !(!$0.txns.isEmpty && Set($0.txns).isSubset(of: told)) }
    }

    /// The month's transactions by day, newest first.
    static func byDay(_ rows: [MoneySpending.Transaction]) -> [DayGroup] {
        var groups: [DayGroup] = []
        for row in rows {
            if let last = groups.last, last.day == row.day {
                groups[groups.count - 1] = DayGroup(day: last.day, rows: last.rows + [row])
            } else {
                groups.append(DayGroup(day: row.day, rows: [row]))
            }
        }
        return groups
    }

    /// A transaction's amount: a charge as "$53.75", money in as "+$2,867.15".
    static func signedCents(_ amount: Double, hidden: Bool) -> String {
        amount > 0 ? "+" + MoneyFormat.cents(amount, hidden: hidden) : MoneyFormat.cents(-amount, hidden: hidden)
    }

    /// "Spent in 2026 so far".
    static func yearTitle(_ year: MoneySpending.Year) -> String { "Spent in \(year.year) so far" }

    /// "From Jun 20, when your history starts. It fills in as the log grows." while the log starts this year.
    static func yearSince(_ year: MoneySpending.Year) -> String? {
        guard let since = year.since, !since.hasSuffix("-01-01") else { return nil }
        return "From \(MoneyPoint.label(day: since)), when your history starts. It fills in as the log grows."
    }

    /// "Best month: September".
    static func yearMonthTitle(_ prefix: String, _ month: MoneySpending.YearMonth) -> String {
        "\(prefix): \(monthName(month.month))"
    }

    /// The month-by-month chart's spoken value.
    static func flowValue(_ months: [MoneySpending.CashFlowMonth], hidden: Bool) -> String {
        months.map { month in
            "\(monthName(month.month)): in \(MoneyFormat.amount(month.in, hidden: hidden)), spent \(MoneyFormat.amount(month.out, hidden: hidden))\(month.partial ? ", partly covered" : "")"
        }.joined(separator: "; ")
    }

    /// A category's sparkline values: its months, leaving out a first month the log only partly covers.
    static func sparkline(_ category: MoneySpending.YearCategory, _ months: [MoneySpending.CashFlowMonth]) -> [Double] {
        let skipFirst = months.count > 2 && months.first?.partial == true
        return Array(category.months.dropFirst(skipFirst ? 1 : 0))
    }

    /// "Jul → Oct": the span the sparklines cover.
    static func sparkSpan(_ months: [MoneySpending.CashFlowMonth]) -> String? {
        let shown = months.count > 2 && months.first?.partial == true ? Array(months.dropFirst()) : months
        guard let first = shown.first, let last = shown.last, first.month != last.month else { return nil }
        return "\(shortMonth(first.month)) → \(shortMonth(last.month))"
    }

}
