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
                         BrainEncounter(id: "e-mid", date: "2026-09-25", title: "Mid")],
            journal: [BrainJournalMention(id: "2026-09-24", date: "2026-09-24", snippet: "Dinner"),
                      BrainJournalMention(id: "2026-09-10", date: "2026-09-10", snippet: "Earlier")])
        let layout = layout(person)
        XCTAssertEqual(layout.timeline.map(\.id), ["e-new", "e-mid", "journal:2026-09-24", "journal:2026-09-10", "e-old"])
        XCTAssertEqual(layout.timeline[0].meta, BrainStyle.displayDate("2026-10-08") + " · 6 days ago")
        XCTAssertEqual(layout.timeline[2].meta, "Journal · " + BrainStyle.displayDate("2026-09-24"))
        XCTAssertEqual(layout.timeline[2].headline, "Dinner")
    }

    func testSameDayJournalFoldsIntoTheFirstEncounterOfThatDay() {
        let person = BrainPerson(
            encounters: [BrainEncounter(id: "e-new", date: "2026-10-08", title: "New"),
                         BrainEncounter(id: "e-a", date: "2026-09-25", title: "A"),
                         BrainEncounter(id: "e-b", date: "2026-09-25", title: "B")],
            journal: [BrainJournalMention(id: "j-same", date: "2026-09-25", snippet: "- Dinner with Ada", mention: "Ada"),
                      BrainJournalMention(id: "j-other", date: "2026-09-10", snippet: "Walk")])
        let layout = layout(person)
        XCTAssertEqual(layout.timeline.map(\.id), ["e-new", "e-a", "e-b", "journal:j-other"])
        XCTAssertNil(layout.timeline[0].journal)
        XCTAssertEqual(layout.timeline[1].journal?.id, "j-same")
        XCTAssertEqual(layout.timeline[1].journal?.snippet, "Dinner with Ada")
        XCTAssertEqual(layout.timeline[1].journal?.mention, "Ada")
        XCTAssertNil(layout.timeline[2].journal)
        XCTAssertNil(layout.timeline[3].journal)
        XCTAssertEqual(layout.hiddenMentionIDs, ["j-same", "j-other"])
    }

    func testFoldedJournalIsNotRepeatedByADuplicateID() {
        let person = BrainPerson(
            encounters: [BrainEncounter(id: "e", date: "2026-10-01", title: "Call")],
            journal: [BrainJournalMention(id: "j", date: "2026-08-01", snippet: "Older copy"),
                      BrainJournalMention(id: "j", date: "2026-10-01", snippet: "Same day")])
        let layout = layout(person)
        XCTAssertEqual(layout.timeline.map(\.id), ["e"])
        XCTAssertEqual(layout.timeline[0].journal?.snippet, "Same day")
        XCTAssertEqual(layout.hiddenMentionIDs, ["j"])
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

    func testDuplicateIDsKeepTheFirstInTimelineOrder() {
        let person = BrainPerson(
            encounters: [BrainEncounter(id: "dup", date: "2026-09-01", title: "Older"),
                         BrainEncounter(id: "dup", date: "2026-10-01", title: "Newer")],
            journal: [BrainJournalMention(id: "j", date: "2026-08-01", snippet: "First"),
                      BrainJournalMention(id: "j", date: "2026-08-01", snippet: "Second")])
        let layout = layout(person)
        XCTAssertEqual(layout.timeline.map(\.id), ["dup", "journal:j"])
        XCTAssertEqual(layout.timeline.map(\.headline), ["Newer", "First"])
    }

    func testRemainingMentionsDropTimelineJournalDays() {
        let shownDay = "journal/2026/09-September/2026-09-25.md"
        let layout = layout(BrainPerson(journal: [BrainJournalMention(id: shownDay, date: "2026-09-25", snippet: "Dinner")]))
        let refs = [BrainRef(module: .journal, id: shownDay, title: "Thursday 25 September"),
                    BrainRef(module: .wiki, id: "wiki/orbit.md", title: "Orbit Labs")]
        let remaining = layout.remainingMentions(refs, total: 13)
        XCTAssertEqual(remaining.refs.map(\.id), ["wiki/orbit.md"])
        XCTAssertEqual(remaining.total, 12)
        XCTAssertEqual(layout.remainingMentions([refs[0]], total: 1).total, 0)
        XCTAssertEqual(layout.remainingMentions([refs[1]], total: 1).refs.map(\.id), ["wiki/orbit.md"])
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
        XCTAssertEqual(first.rest, ["three", "four"])
        XCTAssertEqual(first.moreCount, 2)
        XCTAssertEqual(second.headline, "a")
        XCTAssertEqual(second.preview, ["b", "c"])
        XCTAssertEqual(second.rest, ["d", "e"])
        XCTAssertEqual(second.moreCount, 2)
    }

    func testExpandedSplitsRestBulletsFromExtraLines() {
        let encounter = BrainEncounter(
            id: "w", date: "2026-10-08", title: "Walk",
            bullets: ["a", "b", "c\n  continued", "d"],
            body: "- a\n- b\n- c\n  continued\n\n- d\n\n#### Later\nprose line\n_Source: invented note_")
        let entry = layout(BrainPerson(encounters: [encounter])).timeline[0]
        XCTAssertEqual(entry.headline, "Walk")
        XCTAssertEqual(entry.preview, ["a", "b"])
        XCTAssertEqual(entry.rest, ["c\n  continued", "d"])
        XCTAssertEqual(entry.extra, "#### Later\nprose line\n_Source: invented note_")
        XCTAssertTrue(entry.canExpand)
    }

    func testExtraSkipsTheHeadlineAndProseShownAsItems() {
        // With no bullets the server makes the column-0 prose lines the items.
        let prose = BrainEncounter(id: "p", date: "2026-10-08", bullets: ["First line", "Second", "Third", "Fourth"],
                                   body: "First line\nSecond\nThird\nFourth")
        let titled = BrainEncounter(id: "t", date: "2026-10-07", title: "Tea", bullets: ["a"],
                                    body: "Tea\n- a\n---\nAfterthought")
        let untitled = BrainEncounter(id: "u", date: "2026-10-06", bullets: ["a", "b"],
                                      body: "- a\n- b\n_Source: x_")
        let timeline = layout(BrainPerson(encounters: [prose, titled, untitled])).timeline
        XCTAssertEqual(timeline[0].headline, "First line")
        XCTAssertEqual(timeline[0].rest, ["Fourth"])
        XCTAssertEqual(timeline[0].extra, "")
        XCTAssertEqual(timeline[1].headline, "Tea")
        XCTAssertEqual(timeline[1].extra, "Afterthought")
        XCTAssertEqual(timeline[2].headline, "a")
        XCTAssertEqual(timeline[2].preview, ["b"])
        XCTAssertEqual(timeline[2].rest, [])
        XCTAssertEqual(timeline[2].extra, "_Source: x_")
    }

    func testNestedContinuationStaysInsideItsBullet() {
        let encounter = BrainEncounter(id: "n", date: "2026-10-01", title: "T",
                                       bullets: ["one", "two\n  - nested", "three", "four\n  deeper"],
                                       body: "- one\n- two\n  - nested\n- three\n- four\n\n  deeper")
        let entry = layout(BrainPerson(encounters: [encounter])).timeline[0]
        XCTAssertEqual(entry.preview, ["one", "two\n  - nested"])
        XCTAssertEqual(entry.rest, ["three", "four\n  deeper"])
        XCTAssertEqual(entry.extra, "")
    }

    func testCanExpandWhenBodyHoldsMoreThanThePreview() {
        let prose = BrainEncounter(id: "p", date: "2026-10-08", title: "Walk", bullets: ["- a"],
                                   body: "- a\n\n_Source: invented note_")
        let subhead = BrainEncounter(id: "s", date: "2026-10-07", bullets: ["- a", "- b"],
                                     body: "- a\n#### Later\n- b")
        let hidden = BrainEncounter(id: "h", date: "2026-10-06", title: "T", bullets: ["- a", "- b", "- c"],
                                    body: "- a\n- b\n- c")
        let timeline = layout(BrainPerson(encounters: [prose, subhead, hidden])).timeline
        XCTAssertEqual(timeline.map(\.moreCount), [0, 0, 1])
        XCTAssertEqual(timeline.map(\.canExpand), [true, true, true])
    }

    func testCannotExpandWhenThePreviewShowsEverything() {
        let titled = BrainEncounter(id: "t", date: "2026-10-08", title: "Tea", bullets: ["- a", "* b"],
                                    body: "- a\n\n* b\n")
        let untitled = BrainEncounter(id: "u", date: "2026-10-07", bullets: ["- one", "- two\n  - nested"],
                                      body: "- one\n- two\n  - nested")
        let empty = BrainEncounter(id: "e", date: "2026-10-06", title: "Call")
        let timeline = layout(BrainPerson(
            encounters: [titled, untitled, empty],
            journal: [BrainJournalMention(id: "j", date: "2026-10-05", snippet: "Saw Ada.", mention: "Ada")])).timeline
        XCTAssertEqual(timeline.map(\.canExpand), [false, false, false, false])
    }

    func testNestedBulletKeepsNewlines() {
        let encounter = BrainEncounter(id: "n", date: "2026-10-01", title: "T", bullets: ["- parent\n  - child"])
        XCTAssertEqual(layout(BrainPerson(encounters: [encounter])).timeline[0].preview, ["parent\n  - child"])
    }

    func testChipsAreCappedAtThreeInOrder() {
        let person = BrainPerson(profile: [
            BrainProfileSection(label: "Likes", items: ["climbing"]),
            BrainProfileSection(label: "school", items: ["Rivermont High", "Night classes"]),
            BrainProfileSection(label: "Company", items: ["  ", "Orbit Labs", "Old job"]),
            BrainProfileSection(label: "Family", items: ["sister Mina"]),
        ])
        let layout = layout(person, facts: [BrainFact(label: "Industry", value: "Robotics"),
                                            BrainFact(label: "Birthday", value: "1990-01-20")])
        XCTAssertEqual(layout.chips, ["Birthday Jan 20", "Orbit Labs", "Rivermont High"])
        XCTAssertEqual(layout.aboutSections.map(\.title), ["Family", "Work", "School", "Likes"])
        XCTAssertEqual(layout.aboutSections[1].items, ["Old job"])
        XCTAssertEqual(layout.aboutSections[2].items, ["Night classes"])
    }

    func testIndustryChipWhenThereIsNoCompany() {
        let layout = layout(BrainPerson(profile: [BrainProfileSection(label: "Likes", items: ["jazz"])]),
                            facts: [BrainFact(label: "Industry", value: "Robotics")])
        XCTAssertEqual(layout.chips, ["Robotics"])
    }

    func testLongChipValueStaysInAbout() {
        let long = String(repeating: "x", count: 33)
        let layout = layout(BrainPerson(profile: [BrainProfileSection(label: "Company", items: [long]),
                                                  BrainProfileSection(label: "School", items: [String(repeating: "y", count: 32)])]))
        XCTAssertEqual(layout.chips, [String(repeating: "y", count: 32)])
        XCTAssertEqual(layout.aboutSections.map(\.id), ["work"])
        XCTAssertEqual(layout.aboutSections[0].items, [long])
    }

    func testBirthdayChipKeepsNonISOValue() {
        let layout = layout(BrainPerson(), facts: [BrainFact(label: "Birthday", value: "Jan 20")])
        XCTAssertEqual(layout.chips, ["Birthday Jan 20"])
        XCTAssertTrue(layout.aboutSections.isEmpty)
    }

    func testAboutSectionsMapMergeAndOrder() {
        let person = BrainPerson(
            profile: [
                BrainProfileSection(label: "Misc. notes", items: ["met through climbing"]),
                BrainProfileSection(label: "Likes", items: ["climbing"]),
                BrainProfileSection(label: "LinkedIn", items: ["[profile](https://example.com/ada)"]),
                BrainProfileSection(label: "Pets", items: ["a cat"]),
                BrainProfileSection(label: "Family", items: ["Father: Bo Test", "", "sister Mina"]),
                BrainProfileSection(label: "Company", items: ["Orbit Labs", "Old job"]),
                BrainProfileSection(label: "Interests", items: ["jazz"]),
                BrainProfileSection(label: "Education", items: ["State U"]),
                BrainProfileSection(label: "pets", items: ["a dog"]),
            ],
            questions: ["How is the move?", " "])
        let sections = layout(person).aboutSections
        XCTAssertEqual(sections.map(\.title), ["Family", "Work", "School", "Likes", "Notes", "Pets", "Questions"])
        XCTAssertEqual(sections.map(\.id), ["family", "work", "school", "likes", "notes", "pets", "questions"])
        XCTAssertEqual(sections.map(\.items), [
            ["Father: Bo Test", "sister Mina"],
            ["[profile](https://example.com/ada)", "Old job"],
            ["State U"],
            ["climbing", "jazz"],
            ["met through climbing"],
            ["a cat", "a dog"],
            ["How is the move?"],
        ])
    }

    func testQuestionsAloneMakeTheirOwnSection() {
        let sections = layout(BrainPerson(questions: ["Ask about the move"])).aboutSections
        XCTAssertEqual(sections, [BrainPersonLayout.AboutSection(id: "questions", title: "Questions",
                                                                 items: ["Ask about the move"])])
    }

    func testRoleSplit() {
        let split = BrainPersonLayout.roleSplit("Father: Bo Test")
        XCTAssertEqual(split?.role, "Father")
        XCTAssertEqual(split?.value, "Bo Test")
        XCTAssertEqual(BrainPersonLayout.roleSplit("Step-sister: Ana: twin")?.value, "Ana: twin")
        XCTAssertNil(BrainPersonLayout.roleSplit("Twenty-one characters: x"))
        XCTAssertNil(BrainPersonLayout.roleSplit("sister Mina"))
        XCTAssertNil(BrainPersonLayout.roleSplit("Mother:Ann"))
        XCTAssertNil(BrainPersonLayout.roleSplit(": nobody"))
        XCTAssertNil(BrainPersonLayout.roleSplit("Father: "))
    }

    func testNextTimeIsOnlyANearBirthday() {
        let questions = ["Ask about the move"]
        let near = layout(BrainPerson(questions: questions, nextBirthday: "2026-10-26"))
        XCTAssertEqual(near.nextTime, ["Birthday Oct 26, in 12 days"])
        XCTAssertTrue(layout(BrainPerson(questions: questions, nextBirthday: "2027-01-19")).nextTime.isEmpty)
        XCTAssertTrue(layout(BrainPerson(questions: questions)).nextTime.isEmpty)
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
