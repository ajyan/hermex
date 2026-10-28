import XCTest
@testable import HermesMobile

/// When the evening wind-down notification fires, from `data/sleep/history.json`.
final class WindDownReminderTests: XCTestCase {
    private func night(_ date: String, bed: String?, hours: Double? = 8, need: Double? = 8) -> SleepNight {
        var night = SleepNight(date: date)
        night.bed = bed
        night.hours = hours
        night.need = need
        return night
    }

    private func history(_ beds: [String], lastHours: Double = 8) -> SleepHistory {
        let nights = beds.enumerated().map { index, bed in
            night(String(format: "2026-10-%02d", index + 1), bed: "2026-10-01T\(bed)",
                  hours: index == beds.count - 1 ? lastHours : 8)
        }
        return SleepHistory(nights: nights, stages: [:])
    }

    func testAnHourBeforeTheUsualBedtime() {
        XCTAssertEqual(WindDownReminder.minuteOfDay(from: history(["22:30", "22:40", "23:50"])), 21 * 60 + 40)
    }

    func testBedtimesAfterMidnightCountAsLate() {
        // 23:00, 00:30, 01:00 has median 00:30; read as early morning, 23:00 would be the median.
        XCTAssertEqual(WindDownReminder.minuteOfDay(from: history(["00:30", "23:00", "01:00"])), 23 * 60 + 30)
    }

    func testAShortNightPullsItEarlierByAtMostHalfAnHour() {
        XCTAssertEqual(WindDownReminder.minuteOfDay(from: history(["22:40"], lastHours: 7.75)), 21 * 60 + 25)
        XCTAssertEqual(WindDownReminder.minuteOfDay(from: history(["22:40"], lastHours: 5.4)), 21 * 60 + 10)
        XCTAssertEqual(WindDownReminder.minuteOfDay(from: history(["22:40"], lastHours: 9)), 21 * 60 + 40,
                       "a long night doesn't push it later")
    }

    func testOnlyTheLastTwoWeeksCount() {
        let beds = Array(repeating: "20:00", count: 10) + Array(repeating: "23:00", count: 14)
        XCTAssertEqual(WindDownReminder.minuteOfDay(from: history(beds)), 22 * 60)
    }

    func testNoBedtimesNoTime() {
        let nights = [night("2026-10-01", bed: nil), night("2026-10-02", bed: "garbage")]
        XCTAssertNil(WindDownReminder.minuteOfDay(from: SleepHistory(nights: nights, stages: [:])))
        XCTAssertNil(WindDownReminder.minuteOfDay(from: SleepHistory(nights: [], stages: [:])))
    }

    func testOnUntilTurnedOff() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        XCTAssertTrue(WindDownReminder.isEnabled(defaults))
        defaults.set(false, forKey: WindDownReminder.enabledKey)
        XCTAssertFalse(WindDownReminder.isEnabled(defaults))
    }
}
