import SwiftUI

/// The market card, opened from Money's "Why it moved": the week's change split into market and
/// cash flow, each index's move with Andrew's exposure, and the drivers Atlas found with sources.
struct MoneyMarketView: View {
    let viewModel: MoneyViewModel

    var body: some View {
        ScrollView {
            if let week = viewModel.snapshot?.week {
                VStack(alignment: .leading, spacing: 20) {
                    split(week)
                    if !week.indexes.isEmpty { indexes(week.indexes) }
                    drivers
                    footer
                }
                .padding(16)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle("Market This Week", subtitle: subtitle)
    }

    private var hidden: Bool { viewModel.isHidden }

    private var subtitle: String? {
        guard let week = viewModel.snapshot?.week,
              let start = MoneyPoint.dayFormatter.date(from: week.start),
              let end = MoneyPoint.dayFormatter.date(from: week.end) else { return nil }
        return "\(MoneyPoint.label(start)) – \(MoneyPoint.label(end))"
    }

    private func split(_ week: MoneyWeek) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Your change, split")
            VStack(spacing: 0) {
                row("Market moves", week.market)
                Divider().overlay(Color.hxSeparator)
                row("Cash flow", week.cashFlow)
                Divider().overlay(Color.hxSeparator)
                row("Total", week.change, bold: true)
            }
            .hxCard()
            Text(verbatim: "Market is what your index funds did on their own. Cash flow is everything else: pay, spending, and card or loan payments.")
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
        }
    }

    private func row(_ title: String, _ value: Double, bold: Bool = false) -> some View {
        HStack {
            Text(verbatim: title).foregroundStyle(Color.hxTextPrimary)
            Spacer()
            Text(verbatim: MoneyFormat.signed(value, hidden: hidden))
                .foregroundStyle(MoneyView.color(for: value))
                .monospacedDigit()
        }
        .font(bold ? AppFont.subheadline(weight: .semibold) : AppFont.subheadline())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func indexes(_ indexes: [MoneyIndex]) -> some View {
        let total = indexes.reduce(0) { $0 + max($1.exposure, 0) }
        return VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Indexes", trailing: "your exposure")
            VStack(spacing: 12) {
                ForEach(indexes) { index in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(verbatim: index.name).foregroundStyle(Color.hxTextPrimary)
                            Text(verbatim: index.symbol).foregroundStyle(Color.hxTextSecondary)
                            Text(verbatim: MoneyFormat.percent(index.returnPct)).foregroundStyle(MoneyView.color(for: index.returnPct))
                            Spacer()
                            Text(verbatim: MoneyFormat.amount(index.exposure, hidden: hidden)).foregroundStyle(Color.hxTextPrimary)
                        }
                        .font(AppFont.subheadline())
                        .monospacedDigit()
                        GeometryReader { proxy in
                            Capsule().fill(Color.hxSeparator)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(HermexPaper.money.glow)
                                        .frame(width: total == 0 ? 0 : proxy.size.width * max(index.exposure, 0) / total)
                                }
                        }
                        .frame(height: 5)
                        .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(12)
            .hxCard()
        }
    }

    @ViewBuilder
    private var drivers: some View {
        if let note = viewModel.market, note.story != nil || !note.drivers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HXSectionHeader(title: "What drove it")
                VStack(alignment: .leading, spacing: 12) {
                    if let story = note.story {
                        Text(verbatim: story)
                            .font(AppFont.subheadline(weight: .medium))
                            .foregroundStyle(HermexPaper.money.glow)
                    }
                    ForEach(Array(note.drivers.enumerated()), id: \.offset) { offset, driver in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "\(offset + 1).")
                                .foregroundStyle(Color.hxTextSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: driver.text).foregroundStyle(Color.hxTextPrimary)
                                if let url = driver.url {
                                    Link(destination: url) { Text(verbatim: driver.source ?? "Source") }
                                        .font(AppFont.caption(weight: .medium))
                                }
                            }
                        }
                        .font(AppFont.subheadline())
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glowSurface(.money, cornerRadius: HXRadius.lg)
            }
        } else {
            Text(verbatim: "Atlas hasn't written this week's market story yet.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let written = viewModel.market?.writtenAt {
            Text(verbatim: "Written by Atlas at \(MoneyView.relativeTime(written)) from index closes and news. Not financial advice.")
                .font(AppFont.caption())
                .foregroundStyle(Color.hxTextSecondary)
        }
    }
}
