import SwiftUI
import XCTest
@testable import HermesMobile

final class ActivityPresentationTests: XCTestCase {
    func testOutcomeStyles() {
        XCTAssertEqual(ActivityPresentation.outcomeStyle(.blocked), .hxDanger)
        XCTAssertEqual(ActivityPresentation.outcomeStyle(.denied), .hxWarning)
        XCTAssertEqual(ActivityPresentation.outcomeStyle(.approved), Color.accentColor)
        XCTAssertEqual(ActivityPresentation.outcomeStyle(.ok), .hxTextSecondary)
        XCTAssertEqual(ActivityPresentation.outcomeStyle(.error), .hxDanger)
    }

    func testSourceLabels() {
        XCTAssertEqual(ActivityPresentation.sourceLabel("webui"), "Chat")
        XCTAssertEqual(ActivityPresentation.sourceLabel("cron"), "Scheduled")
        XCTAssertEqual(ActivityPresentation.sourceLabel("signal"), "Signal")
        XCTAssertEqual(ActivityPresentation.sourceLabel("cli"), "Terminal")
        XCTAssertEqual(ActivityPresentation.sourceLabel("oneshot"), "Oneshot")
    }

    func testDayHeaders() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
        let earlierToday = now.addingTimeInterval(-3600)
        let yesterday = now.addingTimeInterval(-86_400)
        let older = now.addingTimeInterval(-5 * 86_400)

        XCTAssertEqual(ActivityPresentation.dayHeader(for: earlierToday, now: now, calendar: calendar), "Today")
        XCTAssertEqual(ActivityPresentation.dayHeader(for: yesterday, now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(ActivityPresentation.dayHeader(for: older, now: now, calendar: calendar), "Sep 27, 2026")
    }
}
