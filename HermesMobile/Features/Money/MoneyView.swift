import SwiftUI

/// Money: net worth from the vault's snapshot, Robinhood-style. A big number, a chart you scrub,
/// the week's market card, then accounts. Amounts open hidden and hide again whenever the screen
/// goes away, so the app can be shown without showing them. Pushed from the drawer as `.money`.
struct MoneyView: View {
    @State private var viewModel: MoneyViewModel
    @State private var showsMarket = false
    @Environment(\.scenePhase) private var scenePhase

    init(server: URL) {
        _viewModel = State(initialValue: MoneyViewModel(server: server))
    }

    var body: some View {
        content
            .hxNavigationTitle("Money", subtitle: subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if viewModel.state == .ready {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { viewModel.toggleReveal() } label: {
                            Image(systemName: viewModel.isHidden ? "eye" : "eye.slash")
                        }
                        .accessibilityLabel(Text(verbatim: viewModel.isHidden ? "Show Amounts" : "Hide Amounts"))
                    }
                }
            }
            .navigationDestination(isPresented: $showsMarket) {
                MoneyMarketView(viewModel: viewModel)
            }
            .task { await viewModel.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { viewModel.hide() }
            }
            .onDisappear {
                // The market card is part of Money; anywhere else hides the amounts again.
                if !showsMarket { viewModel.hide() }
            }
    }

    private var subtitle: String? {
        guard let asOf = viewModel.snapshot?.asOf else { return nil }
        return "Updated " + MoneyView.relativeTime(asOf)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsWorkspace:
            ContentUnavailableView {
                Label { Text(verbatim: "Choose your vault") } icon: { Image(systemName: "folder") }
            } description: {
                Text(verbatim: "Open Daily Brief once to choose your vault.")
            }
        case .noSnapshot:
            ContentUnavailableView {
                Label { Text(verbatim: "No money snapshot yet") } icon: { Image(systemName: "chart.line.uptrend.xyaxis") }
            } description: {
                Text(verbatim: "Run the money-morning job on your server.")
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Check Again") }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load Money") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try Again") }
            }
        case .ready:
            if let snapshot = viewModel.snapshot { ready(snapshot) }
        }
    }

    private func ready(_ snapshot: MoneySnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headline
                    .padding(.horizontal, 16)
                MoneyChart(points: viewModel.points, scrubbed: viewModel.scrubbed, color: trendColor) { viewModel.scrub(to: $0) }
                    .frame(height: 190)
                    .padding(.top, 12)
                rangePicker
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                if let week = snapshot.week {
                    if !week.indexes.isEmpty {
                        indexChips(week.indexes)
                            .padding(.top, 18)
                    }
                    whyCard(week)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                if snapshot.holdingsMissing {
                    Text(verbatim: "Add finance/sync/holdings.yaml in your vault to split out the market.")
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                accounts(snapshot)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
            }
            .padding(.vertical, 12)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .scrollDisabled(viewModel.scrubbed != nil)
        .refreshable { await viewModel.load() }
    }

    // MARK: Headline

    private var trendColor: Color { MoneyView.color(for: MoneyChange.between(viewModel.points).amount) }

    private var headline: some View {
        let change = viewModel.change
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "Net worth")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
            Button { viewModel.toggleReveal() } label: {
                Text(verbatim: MoneyFormat.amount(viewModel.displayedValue, hidden: viewModel.isHidden))
                    .font(AppFont.display(style: .largeTitle, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.hxTextPrimary)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: viewModel.isHidden ? "Net worth, amount hidden" : "Net worth, \(MoneyFormat.amount(viewModel.displayedValue, hidden: false))"))
            .accessibilityHint(Text(verbatim: viewModel.isHidden ? "Shows amounts" : "Hides amounts"))
            HStack(spacing: 6) {
                Text(verbatim: "\(MoneyFormat.signed(change.amount, hidden: viewModel.isHidden)) (\(MoneyFormat.percent(change.percent)))")
                    .foregroundStyle(MoneyView.color(for: change.amount))
                    .monospacedDigit()
                Text(verbatim: scrubLabel)
                    .foregroundStyle(Color.hxTextSecondary)
            }
            .font(AppFont.subheadline(weight: .medium))
        }
    }

    private var scrubLabel: String {
        guard let point = viewModel.scrubbed else { return viewModel.range.label }
        let day = MoneyPoint.label(point.date, withYear: true)
        return point.e ? "\(day) · estimated" : day
    }

    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(MoneyRange.allCases) { range in
                let selected = viewModel.range == range
                Button { viewModel.range = range } label: {
                    Text(verbatim: range.rawValue)
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.hxTextSecondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(selected ? trendColor : Color.clear, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Market

    private func indexChips(_ indexes: [MoneyIndex]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(indexes) { index in
                    HStack(spacing: 4) {
                        Text(verbatim: index.name).foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: MoneyFormat.percent(index.returnPct)).foregroundStyle(MoneyView.color(for: index.returnPct))
                    }
                    .font(AppFont.caption(weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.hxSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.hxSeparator, lineWidth: 0.5))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func whyCard(_ week: MoneyWeek) -> some View {
        Button { showsMarket = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label { Text(verbatim: "Why it moved") } icon: { Image(systemName: "chart.line.uptrend.xyaxis") }
                        .font(AppFont.display(style: .subheadline, weight: .semibold))
                        .foregroundStyle(HermexPaper.money.glow)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(HermexPaper.money.glow)
                }
                MoneySplitBar(market: week.market, cashFlow: week.cashFlow)
                HStack(spacing: 14) {
                    splitLabel("Market", week.market)
                    splitLabel("Cash flow", week.cashFlow)
                }
                if let story = viewModel.market?.story, !story.isEmpty {
                    Text(verbatim: story)
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextPrimary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowSurface(.money, cornerRadius: HXRadius.md)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Opens the market card"))
    }

    private func splitLabel(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: title).foregroundStyle(Color.hxTextSecondary)
            Text(verbatim: MoneyFormat.compact(value, hidden: viewModel.isHidden)).foregroundStyle(MoneyView.color(for: value))
        }
        .font(AppFont.caption(weight: .medium))
        .monospacedDigit()
    }

    // MARK: Accounts

    private func accounts(_ snapshot: MoneySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Accounts", trailing: "\(snapshot.accounts.count)")
            VStack(spacing: 0) {
                ForEach(Array(snapshot.accounts.enumerated()), id: \.element.id) { offset, account in
                    if offset > 0 { Divider().overlay(Color.hxSeparator).padding(.leading, 12) }
                    accountRow(account, staleDays: snapshot.stale.first { $0.name == account.name }?.ageDays)
                }
            }
            .hxCard()
        }
    }

    private func accountRow(_ account: MoneyAccount, staleDays: Double?) -> some View {
        let color = MoneyView.color(for: account.change1w, neutralAtZero: true)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: account.name)
                    .font(AppFont.subheadline(weight: .medium))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let staleDays {
                        Circle().fill(Color.hxWarning).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(verbatim: "Updated \(Int(staleDays)) days ago")
                    } else {
                        Text(verbatim: account.subtitle)
                    }
                }
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            MoneySparkline(values: account.spark, color: color)
            VStack(alignment: .trailing, spacing: 3) {
                Text(verbatim: MoneyFormat.balance(account, hidden: viewModel.isHidden))
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                Text(verbatim: MoneyFormat.weekChange(account, hidden: viewModel.isHidden))
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(account.change1w == 0 ? Color.hxTextSecondary : Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(account.change1w == 0 ? Color.clear : color, in: RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous))
                    .accessibilityLabel(Text(verbatim: MoneyFormat.weekChangeLabel(account, hidden: viewModel.isHidden)))
            }
            .monospacedDigit()
            .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: Helpers

    /// Gain or loss, from the sign: the semantic success and danger colors.
    static func color(for value: Double, neutralAtZero: Bool = false) -> Color {
        if neutralAtZero && value == 0 { return Color.hxTextSecondary }
        return value >= 0 ? Color.hxSuccess : Color.hxDanger
    }

    /// "4:31 PM" today, "Oct 11, 4:31 PM" before.
    static func relativeTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

/// Market and cash flow side by side, each sized by its magnitude in its sign's color.
struct MoneySplitBar: View {
    let market: Double
    let cashFlow: Double

    var body: some View {
        GeometryReader { proxy in
            let total = abs(market) + abs(cashFlow)
            let marketWidth = total == 0 ? proxy.size.width / 2 : proxy.size.width * abs(market) / total
            HStack(spacing: 2) {
                Capsule().fill(MoneyView.color(for: market)).frame(width: max(marketWidth - 1, 2))
                Capsule().fill(MoneyView.color(for: cashFlow).opacity(0.55))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
