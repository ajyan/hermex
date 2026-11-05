import Charts
import SwiftUI

/// Spending, opened from Money's spending card: this month by category against the usual, what's
/// left before payday, what looks off, what's due, money in and out, the weeks, and interest, each
/// number one tap from the transactions behind it. The questions start a chat with Atlas, which
/// answers from the same `spending.json`. Amounts follow Money's eye button.
struct MoneySpendingView: View {
    let viewModel: MoneyViewModel
    let ask: (String) -> Void
    @State private var open: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            if let spending = viewModel.spending {
                VStack(alignment: .leading, spacing: 22) {
                    headline(spending)
                    questions
                    if let month = spending.month, !month.categories.isEmpty { categories(month, spending) }
                    if let payday = spending.payday { beforePayday(payday, spending) }
                    if !spending.flags.isEmpty { flags(spending) }
                    if !spending.due.isEmpty { comingUp(spending) }
                    if !spending.completeMonths.isEmpty { inAndOut(spending) }
                    if spending.weeks.count > 1 { weeks(spending.weeks) }
                    if let interest = spending.interest, interest.total > 0 { interestSection(interest, spending) }
                    footer(spending)
                }
                .padding(16)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle("Spending", subtitle: subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) { viewModel.toggleReveal() } } label: {
                    Image(systemName: viewModel.isHidden ? "eye" : "eye.slash")
                }
                .accessibilityLabel(Text(verbatim: viewModel.isHidden ? "Show Amounts" : "Hide Amounts"))
            }
        }
        .hidesMoneyOnResign(viewModel)
    }

    private var hidden: Bool { viewModel.isHidden }

    private var subtitle: String? {
        guard let spending = viewModel.spending else { return nil }
        let updated = spending.asOf.map { "Updated " + MoneyView.relativeTime($0) }
        return [viewModel.isFixture ? "Fixtures" : nil, updated].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Headline and questions

    private func headline(_ spending: MoneySpending) -> some View {
        let month = spending.month
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: MoneySpendingCopy.monthTitle(month))
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
            Text(verbatim: MoneyFormat.cents(month?.spent ?? 0, hidden: hidden))
                .font(AppFont.display(style: .largeTitle, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.hxTextPrimary)
                .contentTransition(.numericText())
            Text(verbatim: MoneySpendingCopy.usualLine(spending, hidden: hidden))
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(Color.hxTextSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// The questions Personal Finance answers, each starting a chat with Atlas.
    private var questions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Ask Atlas")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(MoneyQuestions.all, id: \.self) { question in
                        askChip(question)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)
        }
    }

    private func askChip(_ question: String, symbol: String = "bubble.left") -> some View {
        Button { ask(question) } label: {
            HXChip(paper: .money, symbol: symbol, label: question)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Starts a chat with Atlas"))
    }

    // MARK: Where it went

    private func categories(_ month: MoneySpending.Month, _ spending: MoneySpending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Where it went", trailing: month.usual.map { "against \($0.months == 1 ? "last month" : "the last \($0.months) months")" })
            VStack(spacing: 0) {
                ForEach(Array(month.categories.enumerated()), id: \.element.id) { offset, category in
                    if offset > 0 { Divider().overlay(Color.hxSeparator).padding(.leading, 12) }
                    categoryRow(category, spending)
                }
            }
            .hxCard()
        }
    }

    private func categoryRow(_ category: MoneySpending.Category, _ spending: MoneySpending) -> some View {
        let isOpen = open.contains(category.key)
        return VStack(spacing: 0) {
            Button { toggle(category.key) } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: category.name)
                            .font(AppFont.subheadline(weight: .medium))
                            .foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: category.count == 1 ? "1 transaction" : "\(category.count) transactions")
                            .font(AppFont.caption())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: MoneyFormat.cents(category.amount, hidden: hidden))
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                        if let usual = category.usual {
                            Text(verbatim: MoneyFormat.versusUsual(category.amount, usual: usual, hidden: hidden))
                                .font(AppFont.caption())
                                .foregroundStyle(category.amount > usual * 1.05 + 5 ? Color.hxWarning : Color.hxTextSecondary)
                        }
                    }
                    .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(verbatim: isOpen ? "Hides the transactions" : "Shows the transactions behind this number"))
            if isOpen {
                transactionList(spending.transactions(category.txns), spending)
                    .padding(.bottom, 6)
            }
        }
    }

    private func toggle(_ key: String) {
        withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
    }

    private func transactionList(_ rows: [MoneySpending.Transaction], _ spending: MoneySpending) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(verbatim: MoneyPoint.label(day: row.day))
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(minWidth: 48, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: row.name).foregroundStyle(Color.hxTextPrimary).lineLimit(1)
                        if let account = spending.account(row.account) {
                            Text(verbatim: account.label).font(AppFont.caption2()).foregroundStyle(Color.hxTextSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(verbatim: MoneyFormat.cents(-row.amount, hidden: hidden))
                        .foregroundStyle(row.amount > 0 ? Color.hxSuccess : Color.hxTextPrimary)
                        .monospacedDigit()
                }
                .font(AppFont.caption())
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.leading, 8)
    }

    // MARK: Before payday

    private func beforePayday(_ payday: MoneySpending.Payday, _ spending: MoneySpending) -> some View {
        let days = MoneySpendingCopy.daysUntil(payday, today: spending.month?.end)
        return VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Before payday", trailing: MoneySpendingCopy.weekdayLabel(payday.next))
            VStack(alignment: .leading, spacing: 10) {
                if !days.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(days, id: \.day) { day in
                            DeckDot(state: day.state, ink: HermexPaper.money.glow)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: MoneySpendingCopy.dotsLabel(days)))
                }
                ForEach(payday.due) { bill in
                    HStack {
                        Text(verbatim: MoneySpendingCopy.weekdayLabel(bill.day)).foregroundStyle(Color.hxTextSecondary)
                            .frame(minWidth: 82, alignment: .leading)
                        Text(verbatim: bill.name).foregroundStyle(Color.hxTextPrimary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(verbatim: (bill.estimate ? "about " : "") + MoneyFormat.cents(bill.amount, hidden: hidden))
                            .foregroundStyle(Color.hxTextPrimary)
                            .monospacedDigit()
                    }
                    .font(AppFont.subheadline())
                    .accessibilityElement(children: .combine)
                }
                if let left = payday.left {
                    Divider().overlay(HermexPaper.money.edge)
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: MoneySpendingCopy.leftLabel(payday, spending))
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        Spacer()
                        Text(verbatim: MoneyFormat.cents(left, hidden: hidden))
                            .font(AppFont.display(style: .title3, weight: .semibold))
                            .foregroundStyle(left < 0 ? Color.hxDanger : HermexPaper.money.glow)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowSurface(.money, cornerRadius: HXRadius.md)
        }
    }

    // MARK: Worth a look

    private func flags(_ spending: MoneySpending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Worth a look", trailing: "\(spending.flags.count)")
            VStack(spacing: 0) {
                ForEach(Array(spending.flags.enumerated()), id: \.element.id) { offset, flag in
                    if offset > 0 { Divider().overlay(Color.hxSeparator).padding(.leading, 40) }
                    Button { ask(flag.question) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: flag.symbol)
                                .font(AppFont.subheadline(weight: .semibold))
                                .foregroundStyle(HermexPaper.money.glow)
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: flag.title)
                                    .font(AppFont.subheadline(weight: .medium))
                                    .foregroundStyle(Color.hxTextPrimary)
                                Text(verbatim: hidden ? MoneySpendingCopy.masked(flag.detail) : flag.detail)
                                    .font(AppFont.caption())
                                    .foregroundStyle(Color.hxTextSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "bubble.left")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Text(verbatim: "Asks Atlas about it"))
                }
            }
            .hxCard()
        }
    }

    // MARK: Coming up

    private func comingUp(_ spending: MoneySpending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Coming up", trailing: "next 30 days")
            VStack(spacing: 0) {
                ForEach(Array(spending.due.enumerated()), id: \.element.id) { offset, bill in
                    if offset > 0 { Divider().overlay(Color.hxSeparator).padding(.leading, 12) }
                    HStack(spacing: 10) {
                        Text(verbatim: MoneyPoint.label(day: bill.day))
                            .font(AppFont.subheadline(weight: .medium))
                            .foregroundStyle(Color.hxTextSecondary)
                            .frame(minWidth: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: bill.name).font(AppFont.subheadline()).foregroundStyle(Color.hxTextPrimary).lineLimit(1)
                            if let account = spending.account(bill.account) {
                                Text(verbatim: account.label).font(AppFont.caption()).foregroundStyle(Color.hxTextSecondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(verbatim: (bill.estimate ? "about " : "") + MoneyFormat.cents(bill.amount, hidden: hidden))
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
            .hxCard()
        }
    }

    // MARK: In and out

    private func inAndOut(_ spending: MoneySpending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "In and out")
            Text(verbatim: MoneySpendingCopy.keptLine(spending.completeMonths, hidden: hidden))
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
            VStack(spacing: 0) {
                ForEach(Array(spending.cashFlow.enumerated()), id: \.element.id) { offset, month in
                    if offset > 0 { Divider().overlay(Color.hxSeparator).padding(.leading, 12) }
                    HStack {
                        Text(verbatim: MoneySpendingCopy.monthRowName(month, spending))
                            .foregroundStyle(month.partial ? Color.hxTextSecondary : Color.hxTextPrimary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(verbatim: MoneyFormat.signed(month.kept, hidden: hidden))
                                .foregroundStyle(MoneyView.color(for: month.kept))
                            Text(verbatim: "in \(MoneyFormat.amount(month.in, hidden: hidden)) · out \(MoneyFormat.amount(month.out, hidden: hidden))")
                                .font(AppFont.caption())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                        .monospacedDigit()
                    }
                    .font(AppFont.subheadline())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
            .hxCard()
        }
    }

    // MARK: Weeks

    private func weeks(_ weeks: [MoneySpending.Week]) -> some View {
        let average = weeks.map(\.spent).reduce(0, +) / Double(weeks.count)
        return VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Week by week", trailing: "\(weeks.count) weeks")
            Chart {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(Color.hxTextSecondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 4]))
                ForEach(weeks) { week in
                    LineMark(x: .value("Week", MoneyPoint.dayFormatter.date(from: week.start) ?? .distantPast),
                             y: .value("Spent", week.spent))
                        .foregroundStyle(HermexPaper.money.glow)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    PointMark(x: .value("Week", MoneyPoint.dayFormatter.date(from: week.start) ?? .distantPast),
                              y: .value("Spent", week.spent))
                        .foregroundStyle(HermexPaper.money.glow)
                        .symbolSize(18)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 96)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Spending by week"))
            .accessibilityValue(Text(verbatim: MoneySpendingCopy.weeksValue(weeks, hidden: hidden)))
            Text(verbatim: "Dotted line: \(MoneyFormat.amount(average, hidden: hidden)) a week on average. Rent weeks run high.")
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
        }
    }

    // MARK: Interest

    private func interestSection(_ interest: MoneySpending.Interest, _ spending: MoneySpending) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Interest this year", trailing: interest.since.map { MoneySpendingCopy.sinceLabel($0) })
            VStack(spacing: 0) {
                ForEach(Array(interest.accounts.enumerated()), id: \.element.id) { offset, row in
                    if offset > 0 { Divider().overlay(Color.hxSeparator).padding(.leading, 12) }
                    let account = spending.account(row.account)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: account?.label ?? "Card").foregroundStyle(Color.hxTextPrimary).lineLimit(1)
                            if let limit = account?.limit {
                                Text(verbatim: "\(MoneyFormat.amount(limit, hidden: hidden)) limit")
                                    .font(AppFont.caption())
                                    .foregroundStyle(Color.hxTextSecondary)
                            }
                        }
                        Spacer()
                        Text(verbatim: MoneyFormat.cents(row.amount, hidden: hidden))
                            .foregroundStyle(Color.hxTextPrimary)
                            .monospacedDigit()
                    }
                    .font(AppFont.subheadline())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .hxCard()
            askChip(MoneyQuestions.apr, symbol: "percent")
        }
    }

    // MARK: Footer

    private func footer(_ spending: MoneySpending) -> some View {
        Text(verbatim: MoneySpendingCopy.footer(spending))
            .font(AppFont.caption())
            .foregroundStyle(Color.hxTextSecondary)
    }
}
