import XCTest
@testable import HermesMobile

@MainActor
final class InteractiveAnswerLiveBudgetTests: XCTestCase {
    func testEvictsLeastRecentlyVisible() {
        let budget = InteractiveAnswerLiveBudget(capacity: 3)
        ["a", "b", "c", "d"].forEach(budget.becameVisible)
        XCTAssertEqual(budget.live, ["b", "c", "d"])

        budget.becameVisible("b")
        budget.becameVisible("e")
        XCTAssertEqual(budget.live, ["b", "d", "e"])
    }

    func testHiddenDropsLive() {
        let budget = InteractiveAnswerLiveBudget(capacity: 3)
        budget.becameVisible("a")
        XCTAssertTrue(budget.isLive("a"))
        budget.becameHidden("a")
        XCTAssertFalse(budget.isLive("a"))
    }

    func testRestingHeightIsRemembered() {
        let budget = InteractiveAnswerLiveBudget(capacity: 3)
        budget.rememberHeight(412, for: "a")
        XCTAssertEqual(budget.height(for: "a"), 412)
        XCTAssertNil(budget.height(for: "zzz"))
    }

    func testCardIDStable() {
        let first = InteractiveAnswerCardID.make(fragment: "<p>a</p>")
        XCTAssertEqual(first, InteractiveAnswerCardID.make(fragment: "<p>a</p>"))
        XCTAssertNotEqual(first, InteractiveAnswerCardID.make(fragment: "<p>b</p>"))
        XCTAssertEqual(first.count, 16)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
    }
}
