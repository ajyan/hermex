import XCTest
@testable import HermesMobile

final class StoryVideoStoreTests: XCTestCase {
    private let one = StoryVideoStore(server: URL(string: "https://one.example.test")!)
    private let two = StoryVideoStore(server: URL(string: "https://two.example.test")!)

    override func tearDown() {
        for store in [one, two] {
            for date in ["2026-11-01", "2026-11-20", "2026-11-21"] {
                try? FileManager.default.removeItem(at: store.url(for: date))
            }
        }
        super.tearDown()
    }

    private func recording(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "story-test-\(UUID().uuidString).mov")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func day(_ text: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    func testARetakeReplacesTheDaysTelling() throws {
        let today = day("2026-11-21")
        _ = try one.save(recording("first"), for: "2026-11-21", today: today)
        let saved = try one.save(recording("second"), for: "2026-11-21", today: today)
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "second")
        XCTAssertEqual(one.video(for: "2026-11-21")?.url, saved)
    }

    func testEachServerKeepsItsOwnTellings() throws {
        _ = try one.save(recording("mine"), for: "2026-11-21", today: day("2026-11-21"))
        XCTAssertNotNil(one.video(for: "2026-11-21"))
        XCTAssertNil(two.video(for: "2026-11-21"), "another server never sees this server's telling")
    }

    func testSavingAnOldDecksTellingKeepsIt() throws {
        let saved = try one.save(recording("late"), for: "2026-11-01", today: day("2026-11-21"))
        XCTAssertEqual(one.video(for: "2026-11-01")?.url, saved, "the day just saved is never pruned")
    }

    func testSavingDeletesTellingsOlderThanTheKeepWindow() throws {
        let today = day("2026-11-21")
        _ = try one.save(recording("old"), for: "2026-11-01", today: day("2026-11-01"))
        _ = try one.save(recording("recent"), for: "2026-11-20", today: day("2026-11-20"))
        _ = try one.save(recording("today"), for: "2026-11-21", today: today)
        XCTAssertNil(one.video(for: "2026-11-01"), "20 days old, past the \(StoryVideoStore.keepDays)-day window")
        XCTAssertNotNil(one.video(for: "2026-11-20"))
    }

    func testATellingOnItsWayToTheMacOutlivesItsDaysButNotAMonth() throws {
        _ = try one.save(recording("picked"), for: "2026-11-01", today: day("2026-11-01"))
        one.markKeeping("2026-11-01")
        one.prune(today: day("2026-11-21"))
        XCTAssertNotNil(one.video(for: "2026-11-01"), "held while its upload is pending")
        one.prune(today: day("2026-12-05"))
        XCTAssertNil(one.video(for: "2026-11-01"), "a month on, the phone lets it go")
        XCTAssertFalse(one.isKeeping("2026-11-01"))
    }
}
