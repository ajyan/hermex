import SwiftUI

/// The Sunday review's money card: the week's day-to-day spending against a usual week, the last eight
/// weeks as one line, the week and the month against their averages, the top categories with their own
/// lines, and what was out of the ordinary. The deck names only the week; the numbers come live from
/// `spending.json`, so they never sit in the deck file. Amounts open hidden, as everywhere in Money.
struct WeekMoneyCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var week: MoneySpending.WeekDetail?
    @State private var loaded = false
    @State private var revealed = false
    @State private var spendingScreen: MoneyViewModel?
    @Environment(\.scenePhase) private var scenePhase

    /// A week already in hand (a render or preview) skips the read; `revealed` opens it with amounts shown.
    init(card: DeckCard, palette: DeckPalette, viewModel: DailyDeckViewModel,
         week: MoneySpending.WeekDetail? = nil, revealed: Bool = false) {
        self.card = card
        self.palette = palette
        self.viewModel = viewModel
        _week = State(initialValue: week)
        _loaded = State(initialValue: week != nil)
        _revealed = State(initialValue: revealed)
    }

    private var hidden: Bool { !revealed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                DeckKindLabel(symbol: palette.symbol, text: "Money · " + (week.map(MoneyWeekCopy.range) ?? "this week"),
                              ink: palette.ink)
                Spacer(minLength: 0)
                if week != nil {
                    Button { revealed.toggle() } label: {
                        Image(systemName: revealed ? "eye" : "eye.slash")
                            .font(AppFont.body(weight: .medium))
                            .foregroundStyle(palette.ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -12)
                    .padding(.trailing, -10)
                    .accessibilityLabel(Text(verbatim: revealed ? "Hide amounts" : "Show amounts"))
                }
            }
            Text(verbatim: week?.headline ?? card.title ?? "Your week in money")
                .font(AppFont.display(style: .title2, weight: .semibold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            if let week {
                content(week)
            } else if loaded {
                Text(verbatim: "This week's spending isn't in yet. It comes in with the morning money run.")
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            DeckFootnote(card: card, palette: palette)
        }
        .task(id: card.id) {
            guard !loaded else { return }
            let spending = try? await viewModel.spending()
            week = spending?.week(starting: card.weekStart)
            loaded = true
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealed = false } }
        .onDisappear { revealed = false }
        .sheet(item: $spendingScreen, onDismiss: { revealed = false }) { money in
            NavigationStack {
                MoneySpendingView(viewModel: money) { words in
                    spendingScreen = nil
                    viewModel.askAtlas?(words)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { spendingScreen = nil } label: { Text(verbatim: "Done") }
                    }
                }
                .task { await money.load() }
            }
        }
    }

    @ViewBuilder
    private func content(_ week: MoneySpending.WeekDetail) -> some View {
        Text(verbatim: MoneyWeekCopy.lead(week, hidden: hidden))
            .font(AppFont.body())
            .foregroundStyle(Color.hxTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        if let bills = MoneyWeekCopy.bills(week, hidden: hidden) {
            Text(verbatim: bills)
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        if week.trend.count > 1 {
            section("The last \(week.trend.count) weeks")
            MoneyWeekTrendChart(trend: week.trend, usual: week.usual, hidden: hidden)
                .padding(.top, 6)
            Text(verbatim: MoneyWeekCopy.trendCaption(usual: week.usual, hidden: hidden))
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        if let usual = week.usual {
            section("Against your averages")
            rule
            averageRow(title: week.partial ? "This week so far" : "This week",
                       meta: "A usual week runs about " + MoneyFormat.amount(usual, hidden: hidden),
                       amount: week.spent, delta: MoneyWeekCopy.delta(week.spent, usual: usual, hidden: hidden))
            if let month = week.month {
                rule
                averageRow(title: MoneySpendingCopy.monthName(month.month) + (month.days < month.length ? " so far" : ""),
                           meta: MoneyWeekCopy.monthMeta(month, hidden: hidden), amount: month.spent,
                           delta: month.usual.map { MoneyWeekCopy.delta(month.pace ?? month.spent, usual: $0, hidden: hidden) })
            }
        }
        if !week.categories.isEmpty {
            section("Trends by category")
            ForEach(week.categories) { category in
                rule
                categoryRow(category, partial: week.partial)
            }
        }
        if !week.odd.isEmpty {
            section("Out of the ordinary")
            ForEach(week.odd) { odd in
                rule
                let row = MoneyWeekCopy.odd(odd)
                MoneyAskRow(title: row.title, detail: row.detail, group: odd.group, hidden: hidden, inset: 0) {
                    viewModel.askAtlas?(odd.question)
                }
            }
        }
        Button { spendingScreen = MoneyViewModel(server: viewModel.server) } label: {
            Text(verbatim: "Open Spending").bodyTapHeight()
        }
        .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
        .environment(\.hxPaper, palette.colors)
        .padding(.top, 22)
    }

    private func section(_ title: String) -> some View {
        Text(verbatim: title)
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(palette.ink.opacity(0.75))
            .padding(.top, 22)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private var rule: some View {
        Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5)
    }

    private func averageRow(title: String, meta: String, amount: Double, delta: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(AppFont.subheadline(weight: .medium)).foregroundStyle(Color.hxTextPrimary)
                Text(verbatim: meta).font(AppFont.caption()).foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: MoneyFormat.amount(amount, hidden: hidden))
                    .font(AppFont.subheadline()).monospacedDigit().foregroundStyle(Color.hxTextPrimary)
                if let delta {
                    Text(verbatim: delta).font(AppFont.caption(weight: .semibold)).foregroundStyle(Color.hxTextPrimary)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func categoryRow(_ category: MoneySpending.WeekCategory, partial: Bool) -> some View {
        HStack(spacing: 10) {
            MoneySeriesDot(group: category.key)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: category.name).font(AppFont.subheadline(weight: .medium)).foregroundStyle(Color.hxTextPrimary)
                let meta = MoneyWeekCopy.categoryMeta(category, hidden: hidden)
                if !meta.isEmpty {
                    Text(verbatim: meta).font(AppFont.caption()).foregroundStyle(Color.hxTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            MoneySparkline(values: category.trend, color: HermexSeries.color(for: category.key), fromZero: true, dashesLast: partial)
            Text(verbatim: MoneyFormat.amount(category.spent, hidden: hidden))
                .font(AppFont.subheadline()).monospacedDigit().foregroundStyle(Color.hxTextPrimary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

extension MoneyViewModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
