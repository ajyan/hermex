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
        XCTAssertEqual(s.completeMonths.map(\.month), ["2026-07", "2026-08", "2026-09"])
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
        XCTAssertTrue(s.completeMonths.isEmpty)
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

    func testKeptLineAnswersSpendingMoreThanIMake() throws {
        let s = try fixture()
        XCTAssertTrue(MoneySpendingCopy.keptLine(s.completeMonths, hidden: false).hasPrefix("You kept $"))
        XCTAssertTrue(MoneySpendingCopy.keptLine(s.completeMonths, hidden: false).hasSuffix("a month on average, July–September."))
        let json = #"{"cash_flow": [{"month": "2026-09", "in": 100, "out": 300, "partial": false}]}"#
        let short = try MoneySpending.decode(Data(json.utf8))
        XCTAssertEqual(MoneySpendingCopy.keptLine(short.completeMonths, hidden: false), "You spent $200 a month more than came in, September.")
    }

    func testPartialMonthsSayWhy() throws {
        let s = try fixture()
        XCTAssertEqual(s.cashFlow.map { MoneySpendingCopy.monthRowName($0, s) },
                       ["June from Jun 20", "July", "August", "September", "October so far"])
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
            try await host({ appeared in
                MoneyView(viewModel: model).dynamicTypeSize(typeSize).onAppear(perform: appeared)
            }, size: CGSize(width: 402, height: 1700), style: style) { window in
                try write(window, to: directory.appendingPathComponent("money-with-spending-\(name).png"))
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
