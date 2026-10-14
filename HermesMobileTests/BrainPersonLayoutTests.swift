import XCTest
@testable import HermesMobile

final class BrainPersonLayoutTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-10-14, midday UTC.
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))! }

    private func layout(_ person: BrainPerson, facts: [BrainFact] = [], subtitle: String = "") -> BrainPersonLayout {
        let page = BrainPage(item: BrainItem(module: .people, id: "people/ada-test.md", title: "Ada Test", subtitle: subtitle),
                             facts: facts, person: person)
        return BrainPersonLayout(page: page, person: person, today: today, calendar: calendar)
    }

    func testRelativeBuckets() {
        let expected: [(Int, String)] = [
            (0, "today"), (1, "yesterday"), (6, "6 days ago"), (13, "13 days ago"), (14, "2 weeks ago"),
            (59, "8 weeks ago"), (60, "2 months ago"), (400, "13 months ago"), (800, "2 years ago"),
        ]
        for (days, text) in expected {
            XCTAssertEqual(BrainPersonLayout.relative(daysAgo: days), text, "\(days) days")
        }
    }

    func testTimelineInterleavesNewestFirst() {
        let person = BrainPerson(
            encounters: [BrainEncounter(id: "e-old", date: "2026-06-05", title: "Old"),
                         BrainEncounter(id: "e-new", date: "2026-10-08", title: "New"),
                         BrainEncounter(id: "e-same", date: "2026-09-25", title: "Same day")],
            journal: [BrainJournalMention(id: "2026-09-25", date: "2026-09-25", snippet: "Dinner"),
                      BrainJournalMention(id: "2026-09-10", date: "2026-09-10", snippet: "Earlier")])
        let layout = layout(person)
        XCTAssertEqual(layout.timeline.map(\.id), ["e-new", "e-same", "journal:2026-09-25", "journal:2026-09-10", "e-old"])
        XCTAssertEqual(layout.timeline[0].meta, BrainStyle.displayDate("2026-10-08") + " · 6 days ago")
        XCTAssertEqual(layout.timeline[2].meta, "Journal · " + BrainStyle.displayDate("2026-09-25"))
        XCTAssertEqual(layout.timeline[2].headline, "Dinner")
    }

    func testFutureEncounterClampsToToday() {
        let layout = layout(BrainPerson(encounters: [BrainEncounter(id: "e", date: "2026-10-20", title: "Soon")]))
        XCTAssertEqual(layout.timeline[0].meta, BrainStyle.displayDate("2026-10-20") + " · today")
    }

    func testEmptyIDsAreDropped() {
        let person = BrainPerson(
            encounters: [BrainEncounter(id: "", date: "2026-10-08", title: "No id"),
                         BrainEncounter(id: "e1", date: "2026-10-07", title: "Kept")],
            journal: [BrainJournalMention(id: "", date: "2026-10-06", snippet: "No id")])
        let layout = layout(person)
        XCTAssertEqual(layout.timeline.map(\.id), ["e1"])
        XCTAssertTrue(layout.hiddenMentionIDs.isEmpty)
    }

    func testHeadlineAndFold() {
        let titled = BrainEncounter(id: "t", date: "2026-10-08", title: "Coffee",
                                    bullets: ["- one", "* two", "three", "four"])
        let untitled = BrainEncounter(id: "u", date: "2026-10-07",
                                      bullets: ["- a", "b", "c", "d", "e"])
        let layout = layout(BrainPerson(encounters: [titled, untitled]))
        let first = layout.timeline[0], second = layout.timeline[1]
        XCTAssertEqual(first.headline, "Coffee")
        XCTAssertEqual(first.preview, ["one", "two"])
        XCTAssertEqual(first.moreCount, 2)
        XCTAssertEqual(second.headline, "a")
        XCTAssertEqual(second.preview, ["b", "c"])
        XCTAssertEqual(second.moreCount, 2)
    }

    func testNestedBulletKeepsNewlines() {
        let encounter = BrainEncounter(id: "n", date: "2026-10-01", title: "T", bullets: ["- parent\n  - child"])
        XCTAssertEqual(layout(BrainPerson(encounters: [encounter])).timeline[0].preview, ["parent\n  - child"])
    }

    func testChipsOrderAndLongItems() {
        let long = String(repeating: "x", count: 60)
        let person = BrainPerson(profile: [
            BrainProfileSection(label: "Likes", items: ["climbing"]),
            BrainProfileSection(label: "Pets", items: ["a cat"]),
            BrainProfileSection(label: "school", items: ["Rivermont High", long]),
            BrainProfileSection(label: "Family", items: ["sister Mina"]),
        ])
        let layout = layout(person, facts: [BrainFact(label: "Industry", value: "Robotics"),
                                            BrainFact(label: "Birthday", value: "1990-01-20")])
        XCTAssertEqual(layout.chips, ["Birthday Jan 20", "Robotics", "sister Mina", "Rivermont High", "climbing", "a cat"])
        XCTAssertEqual(layout.longItems, [long])
    }

    func testBirthdayChipKeepsNonISOValue() {
        let layout = layout(BrainPerson(), facts: [BrainFact(label: "Birthday", value: "Jan 20")])
        XCTAssertEqual(layout.chips, ["Birthday Jan 20"])
    }

    func testNextTimeBirthdayWindow() {
        let questions = ["Ask about the move"]
        let near = layout(BrainPerson(questions: questions, nextBirthday: "2026-10-26"))
        XCTAssertEqual(near.nextTime, ["Ask about the move", "Birthday Oct 26, in 12 days"])
        let far = layout(BrainPerson(questions: questions, nextBirthday: "2027-01-19"))
        XCTAssertEqual(far.nextTime, questions)
        XCTAssertTrue(layout(BrainPerson(nextBirthday: "2027-01-19")).nextTime.isEmpty)
        XCTAssertEqual(layout(BrainPerson(nextBirthday: "2026-10-14")).nextTime, ["Birthday today"])
        XCTAssertEqual(layout(BrainPerson(nextBirthday: "2026-10-15")).nextTime, ["Birthday Oct 15, in 1 day"])
        XCTAssertEqual(layout(BrainPerson(nextBirthday: "2026-11-13")).nextTime, ["Birthday Nov 13, in 30 days"])
        XCTAssertTrue(layout(BrainPerson(nextBirthday: "2026-11-14")).nextTime.isEmpty)
    }

    func testSubtitleSkipsEmptyParts() {
        let full = layout(BrainPerson(lastSeen: "2026-10-08"),
                          facts: [BrainFact(label: "Location", value: "Lisbon")], subtitle: "college friend")
        XCTAssertEqual(full.subtitle, "college friend · Lisbon · seen 6 days ago")
        XCTAssertEqual(layout(BrainPerson(), facts: [BrainFact(label: "Location", value: "Lisbon")]).subtitle, "Lisbon")
        XCTAssertEqual(layout(BrainPerson(lastSeen: "2026-10-13")).subtitle, "seen yesterday")
        XCTAssertEqual(layout(BrainPerson()).subtitle, "")
    }

    func testHiddenMentionIDs() {
        let person = BrainPerson(journal: [BrainJournalMention(id: "2026-09-25", date: "2026-09-25", snippet: "Dinner"),
                                           BrainJournalMention(id: "2026-09-10", date: "2026-09-10", snippet: "Walk")])
        XCTAssertEqual(layout(person).hiddenMentionIDs, ["2026-09-25", "2026-09-10"])
    }
}
