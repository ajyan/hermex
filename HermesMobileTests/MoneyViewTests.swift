import SwiftUI
import XCTest
@testable import HermesMobile

/// Money's screens hosted in a real window, on the synthetic fixtures only.
@MainActor
final class MoneyViewTests: XCTestCase {
    /// The fixtures loaded as of noon on their own day, or `daysLater`, with `missing` banks.
    private func loadedModel(daysLater: Int = 0, missing: Int = 0) async throws -> MoneyViewModel {
        let defaults = UserDefaults(suiteName: "MoneyViewTests")!
        defaults.removePersistentDomain(forName: "MoneyViewTests")
        let store = DailyDeckStore(defaults: defaults)
        let server = URL(string: "https://money-view-tests.invalid")!
        store.setWorkspace("/vault", for: server)
        let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12 + daysLater, hour: 12))!
        let client = try MockMoneyClient.withFixtures()
        if missing > 0 {
            client.files[MoneyPaths.snapshot] = client.files[MoneyPaths.snapshot]!
                .replacingOccurrences(of: #""holdings_missing""#, with: "\"missing\": \(missing), \"holdings_missing\"")
        }
        let model = MoneyViewModel(server: server, client: client, store: store,
                                   now: { noon }, isFixture: true)
        await model.load()
        XCTAssertEqual(model.state, .ready)
        return model
    }

    /// Hosts `root` in a window until `body` returns; `root` signals once it has appeared.
    private func host<Root: View>(_ root: (@escaping () -> Void) -> Root, size: CGSize = CGSize(width: 402, height: 874),
                                  style: UIUserInterfaceStyle = .light,
                                  _ body: (UIWindow) throws -> Void) async throws {
        let appeared = expectation(description: "Money appeared")
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

    func testLeavingTheAppHidesAmountsOnMoney() async throws {
        let model = try await loadedModel()
        try await host({ appeared in MoneyView(viewModel: model).onAppear(perform: appeared) }) { _ in
            model.toggleReveal()
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            XCTAssertTrue(model.isHidden)
        }
    }

    func testLeavingTheAppHidesAmountsOnTheMarketCard() async throws {
        let model = try await loadedModel()
        try await host({ appeared in MoneyMarketView(viewModel: model).onAppear(perform: appeared) }) { _ in
            model.toggleReveal()
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            XCTAssertTrue(model.isHidden, "The market card shows split amounts, so it hides them too")
        }
    }

    /// Writes the screen as PNGs for manual review, only when `MONEY_RENDERS` names a folder
    /// (`TEST_RUNNER_MONEY_RENDERS=<folder>`): light and dark, default and the largest text
    /// size before accessibility sizes, hidden and revealed. Synthetic fixtures only.
    func testRenderFixturesForReview() async throws {
        guard let folder = ProcessInfo.processInfo.environment["MONEY_RENDERS"] else {
            throw XCTSkip("Set TEST_RUNNER_MONEY_RENDERS to write review renders")
        }
        // Capture settled frames, not a navigation bar mid-fade.
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(true) }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, UIUserInterfaceStyle, DynamicTypeSize, Bool, Int)] = [
            ("light-hidden", .light, .large, false, 0),
            ("dark-revealed", .dark, .large, true, 0),
            ("light-xxxl-hidden", .light, .xxxLarge, false, 0),
            ("dark-stale-not-syncing", .dark, .large, false, 2),
        ]
        for (name, style, typeSize, revealed, missing) in cases {
            let model = try await loadedModel(daysLater: missing > 0 ? 3 : 0, missing: missing)
            if revealed { model.toggleReveal() }
            try await host({ appeared in
                MoneyView(viewModel: model).dynamicTypeSize(typeSize).onAppear(perform: appeared)
            }, size: CGSize(width: 402, height: 1500), style: style) { window in
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let data = try XCTUnwrap(image.pngData())
                try data.write(to: directory.appendingPathComponent("money-\(name).png"))
            }
        }
    }
}
