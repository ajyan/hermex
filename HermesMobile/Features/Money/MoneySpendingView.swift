import Charts
import SwiftUI

/// Spending, opened from Money's spending card. Month steps back through each month the log
/// covers: the total against the usual, its pace, the share ring, what stood out, the biggest
/// one-off charges, where it went and every transaction; this month adds what's left before
/// payday, what looks off, what's due, the weeks and interest. Year sums up the year so far.
/// Questions start a chat with Atlas, which answers from the same `spending.json`. Amounts follow
/// Money's eye button.
struct MoneySpendingView: View {
    enum Span: String, CaseIterable, Identifiable {
        case month = "Month", year = "Year"
        var id: String { rawValue }
    }

    let viewModel: MoneyViewModel
    let ask: (String) -> Void
    @State private var span = Span.month
    @State private var monthIndex = 0
    @State private var picked: String?
    @State private var showsAllLog = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: MoneyViewModel, ask: @escaping (String) -> Void, span: Span = .month, monthIndex: Int = 0) {
        self.viewModel = viewModel
        self.ask = ask
        _span = State(initialValue: span)
        _monthIndex = State(initialValue: monthIndex)
    }

    var body: some View {
        ScrollView {
            if let spending = viewModel.spending {
                VStack(alignment: .leading, spacing: 22) {
                    if spending.year != nil { spanPicker }
                    if span == .year, let year = spending.year {
                        MoneySpendingYearSections(year: year, hidden: hidden, ask: ask)
                    } else {
                        month(spending)
                    }
                    questions
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
                .accessibilityLabel(Text(verbatim: viewModel.isHidden ? "Show amounts" : "Hide amounts"))
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

    // MARK: Month and year

    /// The system segmented control, like Money's range: a control, so it wears the tint.
    private var spanPicker: some View {
        Picker(selection: $span) {
            ForEach(Span.allCases) { Text(verbatim: $0.rawValue).tag($0) }
        } label: {
            Text(verbatim: "Span")
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func month(_ spending: MoneySpending) -> some View {
        let months = spending.monthDetails
        if !months.isEmpty {
            let index = min(monthIndex, months.count - 1)
            let detail = months[index]
            MoneySpendingMonthSections(
                spending: spending, detail: detail, hidden: hidden,
                older: index + 1 < months.count ? { step(to: index + 1) } : nil,
                newer: index > 0 ? { step(to: index - 1) } : nil,
                picked: $picked, showsAllLog: $showsAllLog, ask: ask
            ) {
                if detail.current, let payday = spending.payday { beforePayday(payday, spending) }
            }
            if detail.current { thisMonth(spending, detail) }
        }
    }

    private func step(to index: Int) {
        withAnimation(HXMotion.swap(reduceMotion: reduceMotion)) {
            monthIndex = index
            picked = nil
            showsAllLog = false
        }
    }

    /// The sections only this month has, after its transactions.
    @ViewBuilder
    private func thisMonth(_ spending: MoneySpending, _ detail: MoneySpending.MonthDetail) -> some View {
        let flags = MoneySpendingCopy.untold(spending.flags, detail)
        if !flags.isEmpty { worthALook(flags) }
        if !spending.due.isEmpty { comingUp(spending) }
        if spending.weeks.count > 1 { weeks(spending.weeks) }
        if let interest = spending.interest, interest.total > 0 { interestSection(interest, spending) }
    }

    // MARK: Questions

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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hxCardSurface(.wash(.money))
        }
    }

    // MARK: Worth a look

    private func worthALook(_ flags: [MoneySpending.Flag]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Worth a look", trailing: "\(flags.count)")
            MoneyRowsCard(flags) { flag in
                MoneyAskRow(title: flag.title, detail: flag.detail, symbol: flag.symbol, hidden: hidden) { ask(flag.question) }
            }
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
