import SwiftUI

/// Money: net worth from the vault's snapshot. A big number, a chart you scrub, the week's
/// market card, then accounts. Amounts open hidden, show only from the eye button, and hide
/// again whenever the app or the screen goes away, so the app can be shown without showing them.
/// Pushed from the drawer as `.money`.
struct MoneyView: View {
    @State private var viewModel: MoneyViewModel
    @State private var showsMarket = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(server: URL) {
        self.init(viewModel: MoneyViewModel(server: server))
    }

    init(viewModel: MoneyViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        content
            .hxNavigationTitle("Money", subtitle: subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if viewModel.state == .ready {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) { viewModel.toggleReveal() } } label: {
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
            .hidesMoneyOnResign(viewModel)
            .onDisappear {
                // The market card is part of Money; anywhere else hides the amounts again.
                if !showsMarket { viewModel.hide() }
            }
    }

    private var subtitle: String? {
        guard let asOf = viewModel.snapshot?.asOf else { return nil }
        return (viewModel.isFixture ? "Fixtures · " : "") + "Updated " + MoneyView.relativeTime(asOf)
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
                    whyCard(week)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
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
            // Not a button: a tap on the number is the first thing someone shown the phone does.
            Text(verbatim: MoneyFormat.amount(viewModel.displayedValue, hidden: viewModel.isHidden))
                .font(AppFont.display(style: .largeTitle, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.hxTextPrimary)
                .contentTransition(.numericText())
                .accessibilityLabel(Text(verbatim: viewModel.isHidden ? "Net worth, amount hidden" : "Net worth, \(MoneyFormat.amount(viewModel.displayedValue, hidden: false))"))
            HStack(spacing: 6) {
                Text(verbatim: "\(MoneyFormat.signed(change.amount, hidden: viewModel.isHidden)) (\(MoneyFormat.percent(change.percent)))")
                    .foregroundStyle(MoneyView.color(for: change.amount))
                    .monospacedDigit()
                Text(verbatim: scrubLabel)
                    .foregroundStyle(Color.hxTextSecondary)
            }
            .font(AppFont.subheadline(weight: .medium))
            if let warning = viewModel.trustWarning {
                Label { Text(verbatim: warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(AppFont.footnote(weight: .medium))
                    .foregroundStyle(Color.hxWarning)
                    .padding(.top, 6)
            }
        }
    }

    private var scrubLabel: String {
        guard let point = viewModel.scrubbed else { return viewModel.range.label }
        let day = MoneyPoint.label(point.date, withYear: true)
        return point.e ? "\(day) · estimated" : day
    }

    /// The system segmented control, like the Sleep screen's span: a control, so it wears the
    /// tint, never the gain or loss color.
    private var rangePicker: some View {
        Picker(selection: Binding(get: { viewModel.range }, set: { viewModel.range = $0 })) {
            ForEach(MoneyRange.allCases) { range in
                Text(verbatim: range.rawValue)
                    .accessibilityLabel(Text(verbatim: range.spokenName))
                    .tag(range)
            }
        } label: {
            Text(verbatim: "Range")
        }
        .pickerStyle(.segmented)
    }

    // MARK: Market

    private func indexChips(_ indexes: [MoneyIndex]) -> some View {
        FlowRow(spacing: 6) {
            ForEach(indexes) { index in
                HXChip(paper: .money, label: index.name) {
                    Text(verbatim: MoneyFormat.percent(index.returnPct))
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(MoneyView.color(for: index.returnPct))
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func whyCard(_ week: MoneyWeek) -> some View {
        Button { showsMarket = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label { Text(verbatim: "Why it moved this week") } icon: { Image(systemName: "chart.line.uptrend.xyaxis") }
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
                if !week.indexes.isEmpty { indexChips(week.indexes) }
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
                    accountRow(account, staleDays: snapshot.staleEntry(for: account)?.ageDays)
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
                        Text(verbatim: MoneyFormat.lastSynced(ageDays: staleDays))
                    } else {
                        Text(verbatim: account.subtitle)
                    }
                }
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
                .lineLimit(staleDays == nil ? 1 : 2)
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

extension View {
    /// Hides Money's amounts the moment the app stops being active (the app switcher, Control
    /// Center, locking), from whichever Money screen is on top.
    func hidesMoneyOnResign(_ viewModel: MoneyViewModel) -> some View {
        onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            viewModel.hide()
        }
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
