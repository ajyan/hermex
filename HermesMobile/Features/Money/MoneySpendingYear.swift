import SwiftUI

/// The year in Spending: what went out and what was kept, the best and toughest months, where the
/// most went, money in and spent month by month, what stood out, and each category's months.
struct MoneySpendingYearSections: View {
    let year: MoneySpending.Year
    let hidden: Bool
    let ask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            headline
            if year.best != nil || !year.places.isEmpty { soFar }
            if year.months.count > 1 { monthByMonth }
            if !year.stands.isEmpty { stands }
            if !year.categories.isEmpty { categories }
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: MoneySpendingCopy.yearTitle(year))
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
            Text(verbatim: MoneyFormat.cents(year.spent, hidden: hidden))
                .font(AppFont.display(style: .largeTitle, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.hxTextPrimary)
                .contentTransition(.numericText())
            if let full = year.fullMonth {
                Text(verbatim: "A full month runs about \(MoneyFormat.amount(full, hidden: hidden))")
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(Color.hxTextSecondary)
            }
            if year.income > 0 {
                Text(verbatim: MoneySpendingCopy.kept(income: year.income, spent: year.spent, hidden: hidden))
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(Color.hxTextPrimary)
            }
            if let since = MoneySpendingCopy.yearSince(year) {
                Text(verbatim: since)
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: The year so far

    private var soFar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if year.best != nil {
                HXSectionHeader(title: "The year so far")
                VStack(spacing: 0) {
                    if let best = year.best { monthRow("Best month", best) }
                    if let toughest = year.toughest {
                        Divider().overlay(Color.hxSeparator).padding(.leading, 12)
                        monthRow("Toughest month", toughest)
                    }
                }
                .hxCard()
            }
            if !year.places.isEmpty {
                HXSectionHeader(title: "Where you went most", trailing: "not rent or bills")
                    .padding(.top, year.best == nil ? 0 : 6)
                MoneyRowsCard(year.places) { place in
                    HStack(spacing: 10) {
                        MoneySeriesDot(group: place.group)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: place.name).font(AppFont.subheadline()).foregroundStyle(Color.hxTextPrimary).lineLimit(1)
                            Text(verbatim: place.visits == 1 ? "1 visit" : "\(place.visits) visits")
                                .font(AppFont.caption())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                        Spacer(minLength: 6)
                        Text(verbatim: MoneyFormat.amount(place.total, hidden: hidden))
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func monthRow(_ title: String, _ month: MoneySpending.YearMonth) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: MoneySpendingCopy.yearMonthTitle(title, month))
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(Color.hxTextPrimary)
                if let note = month.note {
                    Text(verbatim: hidden ? MoneySpendingCopy.masked(note) : note)
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            Spacer(minLength: 6)
            Text(verbatim: (month.kept < 0 ? "Over " : "Kept ") + MoneyFormat.amount(abs(month.kept), hidden: hidden))
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: Month by month

    private var monthByMonth: some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Month by month", trailing: "in and out")
            VStack(alignment: .leading, spacing: 6) {
                MoneyFlowChart(months: year.months, hidden: hidden)
                if year.months.contains(where: \.partial) {
                    Text(verbatim: "Hollow points and dashes are months the log only partly covers.")
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            .padding(12)
            .hxCard()
        }
    }

    private var stands: some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "What stands out this year")
            MoneyRowsCard(year.stands) { stand in
                MoneyAskRow(title: stand.title, detail: stand.detail, group: stand.group, hidden: hidden) { ask(stand.question) }
            }
        }
    }

    // MARK: By category

    private var categories: some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "By category", trailing: MoneySpendingCopy.sparkSpan(year.months))
            MoneyRowsCard(year.categories) { category in
                HStack(spacing: 10) {
                    MoneySeriesDot(group: category.key)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: category.name)
                            .font(AppFont.subheadline(weight: .medium))
                            .foregroundStyle(Color.hxTextPrimary)
                            .lineLimit(1)
                        Text(verbatim: MoneySpendingCopy.share(category.total, of: year.spent) + " of the year")
                            .font(AppFont.caption())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    Spacer(minLength: 6)
                    MoneySparkline(values: MoneySpendingCopy.sparkline(category, year.months),
                                   color: HermexSeries.color(for: category.key),
                                   fromZero: true, dashesLast: year.months.last?.partial == true)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: MoneyFormat.amount(category.total, hidden: hidden))
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                        if let average = category.average {
                            Text(verbatim: "\(MoneyFormat.amount(average, hidden: hidden)) a month")
                                .font(AppFont.caption())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                    }
                    .monospacedDigit()
                    .frame(minWidth: 78, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
            if year.months.last?.partial == true {
                Text(verbatim: "Each line is that category's own months, from zero; the dashed end is \(MoneySpendingCopy.monthName(year.months.last?.month ?? "")) so far.")
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}
