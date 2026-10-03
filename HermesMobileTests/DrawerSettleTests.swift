import XCTest
@testable import HermesMobile

final class DrawerSettleTests: XCTestCase {
    func testSlowDragPastFortyPercentOpens() {
        XCTAssertTrue(DrawerSettle.isOpen(startedOpen: false, translation: 0.41 * 300, velocity: 0, width: 300))
        XCTAssertFalse(DrawerSettle.isOpen(startedOpen: false, translation: 0.39 * 300, velocity: 0, width: 300))
    }

    func testFlickWinsOverDistance() {
        XCTAssertTrue(DrawerSettle.isOpen(startedOpen: false, translation: 30, velocity: 700, width: 300))
        XCTAssertFalse(DrawerSettle.isOpen(startedOpen: true, translation: -30, velocity: -700, width: 300))
    }

    func testClosingDragFromOpen() {
        XCTAssertFalse(DrawerSettle.isOpen(startedOpen: true, translation: -200, velocity: 0, width: 300))
        XCTAssertTrue(DrawerSettle.isOpen(startedOpen: true, translation: -100, velocity: 0, width: 300))
    }

    func testEdgeOpenOnlyAtRootNearLeftEdge() {
        XCTAssertTrue(DrawerSettle.allowsEdgeOpen(startX: 10, pathIsEmpty: true))
        XCTAssertFalse(DrawerSettle.allowsEdgeOpen(startX: 30, pathIsEmpty: true))
        XCTAssertFalse(DrawerSettle.allowsEdgeOpen(startX: 10, pathIsEmpty: false))
    }

    func testOpenFractionClamps() {
        XCTAssertEqual(DrawerSettle.openFraction(startedOpen: false, translation: 150, width: 300), 0.5)
        XCTAssertEqual(DrawerSettle.openFraction(startedOpen: true, translation: 80, width: 300), 1)
        XCTAssertEqual(DrawerSettle.openFraction(startedOpen: false, translation: -40, width: 300), 0)
    }

    func testOpenDrawerTracksOnlyDragsFromTheScrimOrTrailingEdge() {
        XCTAssertFalse(DrawerSettle.tracksCloseDrag(startX: 150, width: 300), "row swipes inside the drawer belong to the row")
        XCTAssertTrue(DrawerSettle.tracksCloseDrag(startX: 290, width: 300))
        XCTAssertTrue(DrawerSettle.tracksCloseDrag(startX: 340, width: 300))
    }

    func testWidth() {
        XCTAssertEqual(DrawerSettle.width(screenWidth: 390, isAccessibilitySize: false), 331.5)
        XCTAssertEqual(DrawerSettle.width(screenWidth: 390, isAccessibilitySize: true), 346)
    }
}
