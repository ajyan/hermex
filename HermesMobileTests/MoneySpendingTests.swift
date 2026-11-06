import SwiftUI
import XCTest
@testable import HermesMobile

/// Spending on the synthetic `spending.json`, which `finance/sync/money_fixture.py` writes through
/// the real `money_spending.py`: Tuesday Oct 20, 2026, ten days before a Friday payday.
@MainActor
final class MoneySpendingTests: XCTestCase {
    private func fixture() throws -> MoneySpending {
        try MoneySpending.decode(MoneyModelsTests.fixture("spending.json"))
    }

    // MARK: Decoding

    func testFixtureDecodesEverySection() throws {
        let s = try fixture()
        let month = try XCTUnwrap(s.month)
        XCTAssertEqual(month.start, "2026-10-01")
        XCTAssertEqual(month.end, "2026-10-20")
        XCTAssertEqual(month.spent, month.categories.map(\.amount).reduce(0, +), accuracy: 0.02)
        XCTAssertEqual(month.categories.first?.key, "home")
        XCTAssertEqual(month.usual?.months, 3)
        XCTAssertEqual(s.payday?.next, "2026-10-30")
        XCTAssertEqual(s.payday?.due.count, 4)
        XCTAssertEqual(s.flags.map(\.kind), [.twice, .fee, .fee, .creep, .unusual])
        XCTAssertFalse(s.due.isEmpty)
        XCTAssertEqual(s.cashFlow.filter { !$0.partial }.map(\.month), ["2026-07", "2026-08", "2026-09"])
        XCTAssertEqual(s.weeks.count, 12)
        XCTAssertGreaterThan(s.interest?.total ?? 0, 0)
        XCTAssertEqual(s.account("fx-card")?.label, "Sapphire Card ··1934")
        XCTAssertEqual(s.account("fx-card")?.limit, 10_000)
        XCTAssertNotNil(s.asOf)
    }

    func testEveryCategoryAndFlagFindsItsTransactions() throws {
        let s = try fixture()
        for category in s.month?.categories ?? [] {
            XCTAssertEqual(s.transactions(category.txns).count, category.txns.count, category.name)
        }
        for flag in s.flags {
            XCTAssertEqual(s.transactions(flag.txns).count, flag.txns.count, flag.title)
            XCTAssertTrue(flag.question.hasSuffix("?"))
        }
    }

    func testDecodingToleratesMissingAndBadFields() throws {
        let json = """
        {"as_of": "nope", "month": {"spent": 12.5, "categories": [{"key": "food", "amount": 12.5}, {"amount": 3}]},
         "payday": {"left": 4}, "flags": [{"kind": "new-kind", "title": "Something"}, {"kind": "fee"}],
         "cash_flow": [{"month": "2026-10", "in": 1, "out": 2, "partial": true}], "extra": [1, 2]}
        """
        let s = try MoneySpending.decode(Data(json.utf8))
        XCTAssertNil(s.asOf)
        XCTAssertEqual(s.month?.categories.map(\.key), ["food"])
        XCTAssertEqual(s.month?.categories.first?.name, "Food")
        XCTAssertNil(s.month?.usual)
        XCTAssertNil(s.payday, "A payday without a date is dropped")
        XCTAssertEqual(s.flags.map(\.kind), [.other])
        XCTAssertEqual(s.flags.first?.question, "Something")
        XCTAssertTrue(s.months.isEmpty && s.year == nil)
        XCTAssertTrue(s.due.isEmpty && s.accounts.isEmpty)
    }

    // MARK: Copy

    func testHeadlineAgainstTheUsual() throws {
        let s = try fixture()
        XCTAssertEqual(MoneySpendingCopy.monthTitle(s.month), "Spent in October")
        let line = MoneySpendingCopy.usualLine(s, hidden: false)
        XCTAssertTrue(line.hasSuffix("more than usual by Oct 20"), line)
        XCTAssertEqual(MoneySpendingCopy.usualLine(s, hidden: true), "$•••••• more than usual by Oct 20")
        XCTAssertEqual(MoneyFormat.versusUsual(100, usual: 98, hidden: false), "About usual")
        XCTAssertEqual(MoneyFormat.versusUsual(40, usual: 100, hidden: false), "$60 less than usual")
    }

    func testNoUsualSaysWhereTheLogStarts() throws {
        let json = #"{"history_start": "2026-10-03", "month": {"start": "2026-10-01", "end": "2026-10-20", "spent": 10}}"#
        let s = try MoneySpending.decode(Data(json.utf8))
        XCTAssertEqual(MoneySpendingCopy.usualLine(s, hidden: false), "No usual yet: the log starts Oct 3")
    }

    func testDotsRunToPaydayWithBillsFilled() throws {
        let s = try fixture()
        let payday = try XCTUnwrap(s.payday)
        let days = MoneySpendingCopy.daysUntil(payday, today: s.month?.end)
        XCTAssertEqual(days.count, 10)
        XCTAssertEqual(days.first?.day, "2026-10-21")
        XCTAssertEqual(days.last, .init(day: "2026-10-30", state: "ask"))
        XCTAssertEqual(days.filter { $0.state == "done" }.map(\.day), payday.due.map(\.day))
        XCTAssertEqual(MoneySpendingCopy.dotsLabel(days), "10 days to payday, 4 days with a bill")
        XCTAssertEqual(MoneySpendingCopy.leftLabel(payday, s), "Left after 4 bills in Everyday Checking ··4821")
        XCTAssertEqual(MoneySpendingCopy.weekdayLabel(payday.next), "Fri, Oct 30")
    }

    // MARK: Months and the year

    func testMonthsStepBackToWhereTheLogStarts() throws {
        let s = try fixture()
        XCTAssertEqual(s.months.map(\.month), ["2026-10", "2026-09", "2026-08", "2026-07", "2026-06"])
        let october = s.months[0], september = s.months[1]
        XCTAssertTrue(october.current && october.partial)
        XCTAssertEqual(october.summary.categories, s.month?.categories)
        XCTAssertEqual(october.summary.usual?.spent, s.month?.usual?.spent)
        XCTAssertEqual(october.pace?.days, 31)
        XCTAssertEqual(october.pace?.actual.count, 20)
        XCTAssertEqual(october.pace?.actual.last ?? 0, october.summary.spent, accuracy: 0.01)
        XCTAssertEqual(october.stands.map(\.title), ["Subscriptions up $189", "Food & drink up $158", "Noodle Bar Brooklyn charged twice"])
        XCTAssertEqual(MoneySpendingCopy.untold(s.flags, october).map(\.kind), [.fee, .fee, .creep],
                       "The duplicate and the renewal are already told above")
        XCTAssertEqual(september.summary.usual?.from, "2026-07")
        XCTAssertFalse(september.partial)
        for month in s.months {
            XCTAssertEqual(s.transactions(month.txns).count, month.txns.count, month.month)
            XCTAssertEqual(s.transactions(month.biggest).count, month.biggest.count, month.month)
        }
    }

    func testAnOlderFileStillShowsThisMonth() throws {
        let json = #"{"month": {"start": "2026-10-01", "end": "2026-10-20", "spent": 10, "categories": [{"key": "food", "amount": 10, "txns": ["a"]}]}}"#
        let s = try MoneySpending.decode(Data(json.utf8))
        XCTAssertEqual(s.monthDetails.map(\.month), ["2026-10"])
        XCTAssertTrue(s.monthDetails[0].current)
        XCTAssertEqual(s.monthDetails[0].txns, ["a"])
        XCTAssertNil(s.monthDetails[0].pace)
    }

    func testMonthWords() throws {
        let s = try fixture()
        let october = s.months[0], september = s.months[1], june = s.months[4]
        XCTAssertEqual(MoneySpendingCopy.monthLabel(october.month), "October 2026")
        XCTAssertEqual(MoneySpendingCopy.monthNote(october, historyStart: s.historyStart), "So far · Oct 1–20")
        XCTAssertEqual(MoneySpendingCopy.monthNote(september, historyStart: s.historyStart), "Full month")
        XCTAssertEqual(MoneySpendingCopy.monthNote(june, historyStart: s.historyStart), "From Jun 20")
        XCTAssertEqual(MoneySpendingCopy.usualLine(october, historyStart: s.historyStart, hidden: false), "$311 more than usual by Oct 20")
        XCTAssertEqual(MoneySpendingCopy.usualLine(september, historyStart: s.historyStart, hidden: false), "$415 less than usual")
        XCTAssertEqual(MoneySpendingCopy.usualLine(june, historyStart: s.historyStart, hidden: false), "No usual yet: the log starts Jun 20")
        XCTAssertNil(MoneySpendingCopy.keptLine(october, hidden: false))
        XCTAssertEqual(MoneySpendingCopy.keptLine(september, hidden: false), "Kept $1,921 of the $5,734 that came in")
        XCTAssertEqual(MoneySpendingCopy.against(september), "against Jul–Aug")
        XCTAssertEqual(MoneySpendingCopy.against(s.months[2]), "against July")
        XCTAssertEqual(MoneySpendingCopy.paceCaption(september), "Dotted: your usual running total, Jul–Aug. September stayed under it all month.")
        XCTAssertEqual(MoneySpendingCopy.logCount(september, count: 53), "53 in September")
        XCTAssertEqual(MoneySpendingCopy.kept(income: 100, spent: 300, hidden: false), "Spent $200 more than the $100 that came in")
    }

    func testRingSlicesKeepTheirPlaceAndColor() throws {
        let s = try fixture()
        let september = s.months[1].summary.categories
        let slices = MoneySpendingCopy.slices(september)
        XCTAssertEqual(slices.map(\.key), HermexSeries.order.filter { key in slices.contains { $0.key == key } })
        XCTAssertEqual(slices.map(\.amount).reduce(0, +), s.months[1].summary.spent, accuracy: 0.02)
        XCTAssertEqual(slices.last?.name, "Everything else", "Loans and fees fold into the gray slice")
        let legend = MoneySpendingCopy.legend(slices)
        XCTAssertLessThanOrEqual(legend.count, 5)
        XCTAssertEqual(legend.first?.key, "home")
        XCTAssertEqual(legend.last?.key, "rest")
        XCTAssertEqual(HermexSeries.key(for: "loans"), "rest")
        XCTAssertEqual(HermexSeries.key(for: nil), "rest")
        XCTAssertEqual(MoneySpendingCopy.share(0.4, of: 100), "<1%")
        XCTAssertEqual(MoneySpendingCopy.share(57.4, of: 100), "57%")
    }

    func testTheLogGroupsByDayNewestFirst() throws {
        let s = try fixture()
        let groups = MoneySpendingCopy.byDay(s.transactions(s.months[0].txns))
        XCTAssertEqual(groups.first?.day, "2026-10-20")
        XCTAssertEqual(groups.map(\.day), groups.map(\.day).sorted(by: >))
        XCTAssertEqual(Set(groups.map(\.day)).count, groups.count)
        XCTAssertEqual(MoneySpendingCopy.signedCents(-53.75, hidden: false), "$53.75")
        XCTAssertEqual(MoneySpendingCopy.signedCents(2867.15, hidden: false), "+$2,867.15")
    }

    func testTheYear() throws {
        let year = try XCTUnwrap(try fixture().year)
        XCTAssertEqual(year.spent, 16708.25, accuracy: 0.01)
        XCTAssertEqual(year.fullMonth ?? 0, 4090.16, accuracy: 0.01)
        XCTAssertEqual(year.months.map(\.partial), [true, false, false, false, true])
        XCTAssertEqual(year.best?.month, "2026-09")
        XCTAssertEqual(year.toughest?.note, "Shopping $527, food & drink $1,064")
        XCTAssertEqual(year.places.first?.name, "Trader Joe's")
        XCTAssertEqual(year.stands.count, 4)
        XCTAssertEqual(MoneySpendingCopy.yearSince(year), "From Jun 20, when your history starts. It fills in as the log grows.")
        XCTAssertEqual(MoneySpendingCopy.yearMonthTitle("Best month", try XCTUnwrap(year.best)), "Best month: September")
        XCTAssertEqual(MoneySpendingCopy.sparkSpan(year.months), "Jul → Oct")
        let subscriptions = try XCTUnwrap(year.categories.first { $0.key == "subscriptions" })
        XCTAssertEqual(MoneySpendingCopy.sparkline(subscriptions, year.months), [27.48, 27.48, 27.48, 216.48])
    }

    func testHiddenFlagDetailsMaskEveryAmount() {
        XCTAssertEqual(MoneySpendingCopy.masked("$42.80 on Oct 14 and $1,242.67 later"), "$•••••• on Oct 14 and $•••••• later")
    }

    // MARK: Loading and the screen

    func testMoneyWorksWithoutSpending() async throws {
        let client = try MockMoneyClient.withFixtures()
        client.files[MoneyPaths.spending] = nil
        let model = try await loaded(client)
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.spending)
    }

    func testABadSpendingFileLeavesMoneyReady() async throws {
        let client = try MockMoneyClient.withFixtures()
        client.files[MoneyPaths.spending] = "not json"
        let model = try await loaded(client)
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.spending)
    }

    func testLeavingTheAppHidesAmountsOnSpending() async throws {
        let model = try await loaded(try MockMoneyClient.withFixtures())
        try await host({ appeared in MoneySpendingView(viewModel: model, ask: { _ in }).onAppear(perform: appeared) }) { _ in
            model.toggleReveal()
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            XCTAssertTrue(model.isHidden)
        }
    }

    /// Writes Money and Spending as PNGs for manual review, only when `MONEY_RENDERS` names a folder
    /// (`TEST_RUNNER_MONEY_RENDERS=<folder>`). Synthetic fixtures only.
    func testRenderSpendingForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MONEY_RENDERS"] else {
            throw XCTSkip("Set TEST_RUNNER_MONEY_RENDERS to write review renders")
        }
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, UIUserInterfaceStyle, DynamicTypeSize, Bool)] = [
            ("light-revealed", .light, .large, true),
            ("dark-hidden", .dark, .large, false),
            ("light-xxxl-revealed", .light, .xxxLarge, true),
        ]
        for (name, style, typeSize, revealed) in cases {
            let model = try await loaded(try MockMoneyClient.withFixtures())
            if revealed { model.toggleReveal() }
            try await host({ appeared in
                MoneySpendingView(viewModel: model, ask: { _ in }).dynamicTypeSize(typeSize).onAppear(perform: appeared)
            }, size: CGSize(width: 402, height: 2700), style: style) { window in
                try write(window, to: directory.appendingPathComponent("spending-\(name).png"))
            }
            for (suffix, span, index) in [("september", MoneySpendingView.Span.month, 1), ("year", .year, 0)] {
                try await host({ appeared in
                    MoneySpendingView(viewModel: model, ask: { _ in }, span: span, monthIndex: index)
                        .dynamicTypeSize(typeSize).onAppear(perform: appeared)
                }, size: CGSize(width: 402, height: 2700), style: style) { window in
                    try write(window, to: directory.appendingPathComponent("spending-\(suffix)-\(name).png"))
                }
            }
            try await host({ appeared in
                MoneyView(viewModel: model).dynamicTypeSize(typeSize).onAppear(perform: appeared)
            }, size: CGSize(width: 402, height: 1700), style: style) { window in
                try write(window, to: directory.appendingPathComponent("money-with-spending-\(name).png"))
            }
        }
    }

    // MARK: The week (the Sunday review's money card)

    func testWeekDetailsDecodeNewestFirst() throws {
        let s = try fixture()
        XCTAssertEqual(s.weekDetails.count, 8)
        XCTAssertEqual(s.weekDetails.first?.start, "2026-10-19")
        XCTAssertTrue(s.weekDetails[0].partial)
        let week = try XCTUnwrap(s.week(starting: "2026-10-12"))
        XCTAssertEqual(week.end, "2026-10-18")
        XCTAssertEqual(week.headline, "Food carried the week")
        XCTAssertEqual(week.spent, 333.6, accuracy: 0.001)
        XCTAssertEqual(week.trend.count, 8)
        XCTAssertEqual(week.trend.last?.start, "2026-10-12")
        XCTAssertEqual(week.categories.map(\.key), ["food", "shopping", "transport"])
        XCTAssertEqual(week.categories.first?.note, "Up 3 weeks in a row")
        XCTAssertEqual(week.odd.map(\.kind), ["bigger", "twice"])
        XCTAssertEqual(week.month?.days, 18)
        XCTAssertNil(s.week(starting: "2025-01-06"))
    }

    func testAFileWithoutWeeksHasNone() throws {
        let s = try MoneySpending.decode(Data(#"{"version": 1, "weeks": [{"start": "2026-10-12", "spent": 10}]}"#.utf8))
        XCTAssertTrue(s.weekDetails.isEmpty)
    }

    func testWeekWords() throws {
        let s = try fixture()
        let week = try XCTUnwrap(s.week(starting: "2026-10-12"))
        XCTAssertEqual(MoneyWeekCopy.range(week), "Oct 12–18")
        XCTAssertEqual(MoneyWeekCopy.lead(week, hidden: false), "$334 day to day, about $25 over a usual week.")
        XCTAssertEqual(MoneyWeekCopy.lead(week, hidden: true), "Over a usual week, day to day.")
        XCTAssertEqual(MoneyWeekCopy.bills(week, hidden: false), "Bills on top: $70 (Spectrum Internet).")
        XCTAssertEqual(MoneyWeekCopy.bills(week, hidden: true), "Bills on top: \(MoneyFormat.mask) (Spectrum Internet).")
        let month = try XCTUnwrap(week.month)
        XCTAssertEqual(MoneyWeekCopy.monthMeta(month, hidden: false), "18 days in, on pace for about $1,371. A usual month is $1,339.")
        XCTAssertEqual(MoneyWeekCopy.delta(month.pace ?? 0, usual: month.usual ?? 0, hidden: false), "About usual")
        XCTAssertEqual(MoneyWeekCopy.delta(244.5, usual: 309.1, hidden: false), "−$65 under")
        XCTAssertEqual(MoneyWeekCopy.delta(244.5, usual: 309.1, hidden: true), "Under")
        XCTAssertEqual(MoneyWeekCopy.categoryMeta(week.categories[0], hidden: false), "Up 3 weeks in a row · usual $199")
        XCTAssertEqual(MoneyWeekCopy.categoryMeta(week.categories[1], hidden: true),
                       "Nothing for 2 weeks, after \(MoneyFormat.mask) · usual \(MoneyFormat.mask)")
        let bigger = MoneyWeekCopy.odd(week.odd[0])
        XCTAssertEqual(bigger.title, "Trader Joe's $116.04")
        XCTAssertEqual(bigger.detail, "Bigger than usual · Oct 17. Usually about $71 there.")
        let quiet = try XCTUnwrap(s.week(starting: "2026-10-05"))
        XCTAssertEqual(quiet.headline, "A quiet week, apart from Blink")
        XCTAssertEqual(MoneyWeekCopy.odd(quiet.odd[0]).detail, "One-time · Oct 6. A renewal, left out of the totals above.")
        XCTAssertEqual(MoneyWeekCopy.range(try XCTUnwrap(s.week(starting: "2026-09-28"))), "Sep 28–Oct 4")
    }

    func testTrendLabelsEveryOtherWeekEndingOnThisOne() throws {
        let trend = try XCTUnwrap(try fixture().week(starting: "2026-10-12")).trend
        XCTAssertEqual(trend.indices.map { MoneyWeekCopy.trendLabel(trend, at: $0) },
                       ["", "Aug 31", "", "Sep 14", "", "Sep 28", "", "Oct 12"])
    }

    func testTheDeckNamesTheMoneyCardsWeek() throws {
        let deck = try DailyDeck.decode(#"""
        {"version": 4, "date": "2026-10-18", "kind": "weekly", "cards": [
          {"id": "money", "type": "week_money", "title": "Your week in money", "color": "ledger", "week_start": "2026-10-12"}]}
        """#)
        let card = try XCTUnwrap(deck.cards.first)
        XCTAssertEqual(card.type, .weekMoney)
        XCTAssertEqual(card.weekStart, "2026-10-12")
        XCTAssertEqual(DeckPalette.of(card), .money)
        XCTAssertFalse(card.takesFeedback)
    }

    func testTheDeckReadsSpendingThroughItsSession() async throws {
        let client = ScriptedDailyDeckClient(workspaces: ["/vault"], names: [], deck: "{}")
        client.files[MoneyPaths.spending] = String(decoding: try MoneyModelsTests.fixture("spending.json"), as: UTF8.self)
        let defaults = UserDefaults(suiteName: "MoneySpendingTests.deck")!
        defaults.removePersistentDomain(forName: "MoneySpendingTests.deck")
        let deck = DailyDeckViewModel(server: URL(string: "https://money-week-tests.invalid")!, client: client,
                                      store: DailyDeckStore(defaults: defaults))
        let before = try await deck.spending()
        XCTAssertNil(before, "no session yet, nothing read")
        await deck.load()
        let spending = try await deck.spending()
        XCTAssertEqual(spending?.week(starting: "2026-10-12")?.headline, "Food carried the week")
        XCTAssertTrue(client.readPaths.contains(MoneyPaths.spending))
    }

    /// Writes the Sunday review's money card as PNGs for manual review, only when `MONEY_RENDERS` names a
    /// folder. Synthetic fixtures only.
    func testRenderWeekMoneyCardForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MONEY_RENDERS"] else {
            throw XCTSkip("Set TEST_RUNNER_MONEY_RENDERS to write review renders")
        }
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let spending = try fixture()
        let deck = DailyDeckViewModel(server: URL(string: "https://money-week-tests.invalid")!,
                                      client: ScriptedDailyDeckClient(workspaces: [], names: [], deck: "{}"))
        let cases: [(String, String, UIUserInterfaceStyle, Bool)] = [
            ("oct12-light-revealed", "2026-10-12", .light, true),
            ("oct12-dark-hidden", "2026-10-12", .dark, false),
            ("oct5-light-revealed", "2026-10-05", .light, true),
        ]
        for (name, start, style, revealed) in cases {
            let card = try XCTUnwrap(try DailyDeck.decode(#"{"date": "2026-10-18", "kind": "weekly", "cards": [{"id": "money", "type": "week_money", "title": "Your week in money", "week_start": "\#(start)"}]}"#).cards.first)
            let week = spending.week(starting: start)
            try await host({ appeared in
                ScrollView {
                    WeekMoneyCard(card: card, palette: .money, viewModel: deck, week: week, revealed: revealed)
                        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DeckPalette.money.paper, in: RoundedRectangle(cornerRadius: HXRadius.xl))
                .environment(\.colorScheme, .light)
                .padding(12)
                .background(Color.hxCanvas)
                .onAppear(perform: appeared)
            }, size: CGSize(width: 402, height: 1500), style: style) { window in
                try write(window, to: directory.appendingPathComponent("week-money-\(name).png"))
            }
        }
    }

    // MARK: Helpers

    private func loaded(_ client: MockMoneyClient) async throws -> MoneyViewModel {
        let defaults = UserDefaults(suiteName: "MoneySpendingTests")!
        defaults.removePersistentDomain(forName: "MoneySpendingTests")
        let store = DailyDeckStore(defaults: defaults)
        let server = URL(string: "https://money-spending-tests.invalid")!
        store.setWorkspace("/vault", for: server)
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        let model = MoneyViewModel(server: server, client: client, store: store, now: { noon }, isFixture: true)
        await model.load()
        return model
    }

    private func write(_ window: UIWindow, to url: URL) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: url)
    }

    private func host<Root: View>(_ root: (@escaping () -> Void) -> Root, size: CGSize = CGSize(width: 402, height: 874),
                                  style: UIUserInterfaceStyle = .light,
                                  _ body: (UIWindow) throws -> Void) async throws {
        let appeared = expectation(description: "Spending appeared")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: NavigationStack { root { appeared.fulfill() } })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await fulfillment(of: [appeared], timeout: 5)
        window.layoutIfNeeded()
        try body(window)
    }
}
