import SwiftUI

/// One month of Spending, stepped through with the arrows: the total against the usual, the running
/// total against the usual pace, the share ring, what stood out, the biggest one-off charges, where
/// it went (a row picks its slice and opens its transactions) and every transaction by day.
/// `beforeLog` holds this month's own sections, such as Before payday.
struct MoneySpendingMonthSections<BeforeLog: View>: View {
    let spending: MoneySpending
    let detail: MoneySpending.MonthDetail
    let hidden: Bool
    let older: (() -> Void)?
    let newer: (() -> Void)?
    @Binding var picked: String?
    @Binding var showsAllLog: Bool
    let ask: (String) -> Void
    @ViewBuilder let beforeLog: () -> BeforeLog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var logPreview: Int { 12 }

    var body: some View {
        let slices = MoneySpendingCopy.slices(detail.summary.categories)
        VStack(alignment: .leading, spacing: 22) {
            switcher
            headline
            if let pace = detail.pace, !pace.actual.isEmpty { paceCard(pace) }
            if !slices.isEmpty { ringCard(slices) }
            if !detail.stands.isEmpty { stands }
            if !detail.biggest.isEmpty { biggest }
            if !detail.summary.categories.isEmpty { categories }
            beforeLog()
            if !detail.txns.isEmpty { log }
        }
    }

    // MARK: The month

    private var switcher: some View {
        HStack {
            arrow("chevron.left", label: "Previous Month", action: older)
            Spacer()
            VStack(spacing: 1) {
                Text(verbatim: MoneySpendingCopy.monthLabel(detail.month))
                    .font(AppFont.display(style: .title3, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Text(verbatim: MoneySpendingCopy.monthNote(detail, historyStart: spending.historyStart))
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            arrow("chevron.right", label: "Next Month", action: newer)
        }
    }

    private func arrow(_ symbol: String, label: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(AppFont.body(weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(action == nil ? Color.hxTextSecondary.opacity(0.4) : Color.accentColor)
        .disabled(action == nil)
        .accessibilityLabel(Text(verbatim: label))
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: MoneySpendingCopy.monthTitle(detail.summary))
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
            Text(verbatim: MoneyFormat.cents(detail.summary.spent, hidden: hidden))
                .font(AppFont.display(style: .largeTitle, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.hxTextPrimary)
                .contentTransition(.numericText())
            Text(verbatim: MoneySpendingCopy.usualLine(detail, historyStart: spending.historyStart, hidden: hidden))
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(Color.hxTextSecondary)
            if let kept = MoneySpendingCopy.keptLine(detail, hidden: hidden) {
                Text(verbatim: kept)
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func paceCard(_ pace: MoneySpending.Pace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MoneyPaceChart(detail: detail, pace: pace, hidden: hidden)
            Text(verbatim: MoneySpendingCopy.paceCaption(detail))
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
        }
        .padding(12)
        .hxCard()
    }

    private func ringCard(_ slices: [MoneySpendingCopy.Slice]) -> some View {
        let total = slices.map(\.amount).reduce(0, +)
        return HStack(spacing: 16) {
            MoneyShareRing(slices: slices, picked: picked.map { HermexSeries.key(for: $0) })
            VStack(alignment: .leading, spacing: 7) {
                ForEach(MoneySpendingCopy.legend(slices)) { slice in
                    HStack(spacing: 8) {
                        MoneySeriesDot(group: slice.key)
                        Text(verbatim: slice.name)
                            .foregroundStyle(Color.hxTextPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(verbatim: MoneySpendingCopy.share(slice.amount, of: total))
                            .foregroundStyle(Color.hxTextSecondary)
                            .monospacedDigit()
                    }
                    .font(AppFont.footnote())
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .hxCard()
    }

    // MARK: What stood out

    private var stands: some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "What stands out")
            MoneyRowsCard(detail.stands) { stand in
                MoneyAskRow(title: stand.title, detail: stand.detail, group: stand.group, hidden: hidden) { ask(stand.question) }
            }
        }
    }

    private var biggest: some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Biggest one-off charges", trailing: "not rent or bills")
            MoneyRowsCard(spending.transactions(detail.biggest)) { row in
                HStack(spacing: 10) {
                    MoneySeriesDot(group: row.group)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: row.name).font(AppFont.subheadline()).foregroundStyle(Color.hxTextPrimary).lineLimit(1)
                        Text(verbatim: MoneyPoint.label(day: row.day) + (groupName(row.group).map { " · " + $0 } ?? ""))
                            .font(AppFont.caption())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    Spacer(minLength: 6)
                    Text(verbatim: MoneyFormat.cents(-row.amount, hidden: hidden))
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

    private func groupName(_ group: String?) -> String? {
        detail.summary.categories.first { $0.key == group }?.name
    }

    // MARK: Where it went

    private var categories: some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Where it went", trailing: MoneySpendingCopy.against(detail))
            MoneyRowsCard(detail.summary.categories) { category in
                categoryRow(category)
            }
        }
    }

    private func categoryRow(_ category: MoneySpending.Category) -> some View {
        let isOpen = picked == category.key
        return VStack(spacing: 0) {
            Button {
                withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) { picked = isOpen ? nil : category.key }
            } label: {
                HStack(spacing: 10) {
                    MoneySeriesDot(group: category.key)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: category.name)
                            .font(AppFont.subheadline(weight: .medium))
                            .foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: (category.count == 1 ? "1 transaction" : "\(category.count) transactions")
                             + " · " + MoneySpendingCopy.share(category.amount, of: detail.summary.spent))
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isOpen ? Color(uiColor: .tertiarySystemFill) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            .accessibilityHint(Text(verbatim: isOpen ? "Hides the transactions" : "Shows its slice and the transactions behind it"))
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(spending.transactions(category.txns)) { row in
                        MoneyTransactionRow(row: row, account: spending.account(row.account), hidden: hidden, showsDay: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Every transaction

    private var log: some View {
        let rows = spending.transactions(detail.txns)
        let shown = showsAllLog ? rows : Array(rows.prefix(Self.logPreview))
        return VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Every transaction", trailing: MoneySpendingCopy.logCount(detail, count: rows.count))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(MoneySpendingCopy.byDay(shown)) { group in
                    Text(verbatim: MoneySpendingCopy.weekdayLabel(group.day))
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in
                        MoneyTransactionRow(row: row, account: spending.account(row.account), hidden: hidden, showsDay: false)
                    }
                }
                if rows.count > shown.count || showsAllLog && rows.count > Self.logPreview {
                    Button(showsAllLog ? "Show fewer" : "Show all \(rows.count)") {
                        withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) { showsAllLog.toggle() }
                    }
                    .font(AppFont.subheadline(weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hxCard()
        }
    }
}

// MARK: - Shared rows

/// A category's fixed color as a 10 pt dot.
struct MoneySeriesDot: View {
    let group: String?

    var body: some View {
        Circle()
            .fill(HermexSeries.color(for: group))
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}

/// Rows in one card, with hairlines between them.
struct MoneyRowsCard<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    init(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                if offset > 0 { Divider().overlay(Color.hxSeparator).padding(.leading, 12) }
                row(item)
            }
        }
        .hxCard()
    }
}

/// Something worth asking about: a dot or symbol, a title and a one-line why, and the bubble that
/// starts a chat with Atlas.
struct MoneyAskRow: View {
    let title: String
    let detail: String
    var group: String?
    var symbol: String?
    let hidden: Bool
    let ask: () -> Void

    var body: some View {
        Button(action: ask) {
            HStack(alignment: .top, spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(HermexPaper.money.glow)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                } else {
                    MoneySeriesDot(group: group).padding(.top, 5)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: hidden ? MoneySpendingCopy.masked(title) : title)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    Text(verbatim: hidden ? MoneySpendingCopy.masked(detail) : detail)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: "Asks Atlas about it"))
    }
}

/// One transaction: its category dot, name and account, and the amount (money in as "+$…" in green).
struct MoneyTransactionRow: View {
    let row: MoneySpending.Transaction
    let account: MoneySpending.Account?
    let hidden: Bool
    let showsDay: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsDay {
                Text(verbatim: MoneyPoint.label(day: row.day))
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
            MoneySeriesDot(group: row.group)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: row.name).font(AppFont.footnote()).foregroundStyle(Color.hxTextPrimary).lineLimit(1)
                if let account {
                    Text(verbatim: account.label).font(AppFont.caption2()).foregroundStyle(Color.hxTextSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(verbatim: MoneySpendingCopy.signedCents(row.amount, hidden: hidden))
                .font(AppFont.footnote())
                .foregroundStyle(row.amount > 0 ? Color.hxSuccess : Color.hxTextPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
