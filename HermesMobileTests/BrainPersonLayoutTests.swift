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
        XCTAssertEqual(layout.timeline[0].kicker, "Note · Oct 8 · 6 days ago")
        XCTAssertEqual(layout.timeline[0].when, "Oct 8 · 6 days ago")
        XCTAssertEqual(layout.timeline.map(\.symbol), ["person.2.fill", "person.2.fill", "book.closed.fill", "book.closed.fill", "person.2.fill"])
        XCTAssertEqual(layout.timeline[2].kicker, "Journal · Sep 24 · 2 weeks ago")
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
        XCTAssertEqual(layout.timeline[0].kicker, "Note · Oct 20 · today")
    }

    func testSourceLinesAndInvisibleMarksStayOffThePage() {
        let person = BrainPerson(encounters: [
            BrainEncounter(id: "e", date: "2026-10-12", bullets: ["\u{FFFC} Coming on November 12"],
                           body: "- \u{FFFC} Coming on November 12\n\n_Source: followups touch_\n\nThey stayed late."),
        ])
        let entry = layout(person).timeline[0]
        XCTAssertEqual(entry.headline, "Coming on November 12")
        XCTAssertEqual(entry.extra, "They stayed late.", "where the note came from is the pipeline's")
    }

    func testALoggedTextReadsAsTheMessage() {
        let person = BrainPerson(encounters: [
            BrainEncounter(id: "t", date: "2026-10-12", bullets: ["Texted: \"Drinks Friday?\""]),
            BrainEncounter(id: "u", date: "2026-10-11", title: "Texted: Running late", bullets: ["He said fine"]),
            BrainEncounter(id: "n", date: "2026-10-10", bullets: ["Texted him about the move"]),
        ])
        let timeline = layout(person).timeline
        XCTAssertEqual(timeline.map(\.kicker), ["Texted · Oct 12 · 2 days ago", "Texted · Oct 11 · 3 days ago",
                                                "Note · Oct 10 · 4 days ago"])
        XCTAssertEqual(timeline.map(\.headline), ["\u{201C}Drinks Friday?\u{201D}", "\u{201C}Running late\u{201D}",
                                                  "Texted him about the move"], "only a `Texted:` line is a text")
        XCTAssertEqual(timeline.map(\.symbol), ["message.fill", "message.fill", "person.2.fill"])
        XCTAssertEqual(timeline[1].bullets, ["He said fine"])
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

    func testHeadlineAndBullets() {
        let titled = BrainEncounter(id: "t", date: "2026-10-08", title: "Coffee",
                                    bullets: ["- one", "* two", "three", "four"])
        let untitled = BrainEncounter(id: "u", date: "2026-10-07",
                                      bullets: ["- a", "b", "c", "d", "e"])
        let layout = layout(BrainPerson(encounters: [titled, untitled]))
        let first = layout.timeline[0], second = layout.timeline[1]
        XCTAssertEqual(first.headline, "Coffee")
        XCTAssertEqual(first.bullets, ["one", "two", "three", "four"])
        XCTAssertEqual(second.headline, "a")
        XCTAssertEqual(second.bullets, ["b", "c", "d", "e"])
    }

    func testBulletsSplitFromExtraLines() {
        let encounter = BrainEncounter(
            id: "w", date: "2026-10-08", title: "Walk",
            bullets: ["a", "b", "c\n  continued", "d"],
            body: "- a\n- b\n- c\n  continued\n\n- d\n\n#### Later\nprose line\n_Source: invented note_")
        let entry = layout(BrainPerson(encounters: [encounter])).timeline[0]
        XCTAssertEqual(entry.headline, "Walk")
        XCTAssertEqual(entry.bullets, ["a", "b", "c\n  continued", "d"])
        XCTAssertEqual(entry.extra, "#### Later\nprose line", "the `_Source:` line stays off the page")
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
        XCTAssertEqual(timeline[0].bullets, ["Second", "Third", "Fourth"])
        XCTAssertEqual(timeline[0].extra, "")
        XCTAssertEqual(timeline[1].headline, "Tea")
        XCTAssertEqual(timeline[1].extra, "Afterthought")
        XCTAssertEqual(timeline[2].headline, "a")
        XCTAssertEqual(timeline[2].bullets, ["b"])
        XCTAssertEqual(timeline[2].extra, "")
    }

    func testNestedContinuationStaysInsideItsBullet() {
        let encounter = BrainEncounter(id: "n", date: "2026-10-01", title: "T",
                                       bullets: ["one", "two\n  - nested", "three", "four\n  deeper"],
                                       body: "- one\n- two\n  - nested\n- three\n- four\n\n  deeper")
        let entry = layout(BrainPerson(encounters: [encounter])).timeline[0]
        XCTAssertEqual(entry.bullets, ["one", "two\n  - nested", "three", "four\n  deeper"])
        XCTAssertEqual(entry.extra, "")
    }

    func testKickerFallsBackToTheRawDate() {
        let person = BrainPerson(encounters: [BrainEncounter(id: "e", date: "spring", title: "Hike")],
                                 journal: [BrainJournalMention(id: "j", date: "", snippet: "Saw Ada.")])
        XCTAssertEqual(layout(person).timeline.map(\.kicker), ["Note · spring", "Journal"])
    }

    func testNestedBulletKeepsNewlines() {
        let encounter = BrainEncounter(id: "n", date: "2026-10-01", title: "T", bullets: ["- parent\n  - child"])
        XCTAssertEqual(layout(BrainPerson(encounters: [encounter])).timeline[0].bullets, ["parent\n  - child"])
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
        XCTAssertEqual(layout.aboutSections[1].items, ["Old job", "Robotics"], "Industry that isn't a chip stays in Work")
        XCTAssertEqual(layout.aboutSections[2].items, ["Night classes"])
    }

    func testIndustryChipWhenTheCompanyIsTooLong() {
        let long = String(repeating: "x", count: 33)
        let layout = layout(BrainPerson(profile: [BrainProfileSection(label: "Company", items: [long])]),
                            facts: [BrainFact(label: "Industry", value: "Robotics")])
        XCTAssertEqual(layout.chips, ["Robotics"])
        XCTAssertEqual(layout.aboutSections.map(\.items), [[long]])
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

    func testIndustryAsAChipIsNotRepeatedInAbout() {
        let layout = layout(BrainPerson(profile: [BrainProfileSection(label: "Work", items: ["robotics"])]),
                            facts: [BrainFact(label: "Industry", value: "Robotics")])
        XCTAssertEqual(layout.chips, ["Robotics"])
        XCTAssertEqual(layout.aboutSections.map(\.items), [["robotics"]])
        let named = self.layout(BrainPerson(profile: [BrainProfileSection(label: "Company", items: ["Orbit Labs"]),
                                                      BrainProfileSection(label: "Work", items: ["Robotics"])]),
                                facts: [BrainFact(label: "Industry", value: "Robotics")])
        XCTAssertEqual(named.aboutSections.map(\.items), [["Robotics"]], "Work already says it")
    }

    func testBirthdayChipReadsAYearlessBirthday() {
        XCTAssertEqual(layout(BrainPerson(), facts: [BrainFact(label: "Birthday", value: "11-01")]).chips, ["Birthday Nov 1"])
        XCTAssertEqual(layout(BrainPerson(), facts: [BrainFact(label: "Birthday", value: "--02-29")]).chips, ["Birthday Feb 29"])
        XCTAssertNil(BrainPersonLayout.monthDay("2026-02-30"), "an impossible date is not rolled into March")
        XCTAssertNil(BrainPersonLayout.monthDay("13-01"))
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

    func testUnmappedSectionLabelsReadInSentenceCase() {
        let person = BrainPerson(profile: [BrainProfileSection(label: "favorite foods", items: ["dumplings"]),
                                           BrainProfileSection(label: "Pets", items: ["a cat"])])
        XCTAssertEqual(layout(person).aboutSections.map(\.title), ["Favorite foods", "Pets"])
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
        XCTAssertEqual(BrainPersonLayout.roleSplit("**Wife**: Meg Fisher")?.role, "Wife")
        XCTAssertEqual(BrainPersonLayout.roleSplit("**Wife**: Meg Fisher")?.value, "Meg Fisher")
        XCTAssertEqual(BrainPersonLayout.roleSplit("__Wife__: Meg Fisher")?.role, "Wife")
        XCTAssertEqual(BrainPersonLayout.roleSplit("Step-sister: Ana: twin")?.value, "Ana: twin")
        // 28 characters: "Paris & French Culture" fits, a 29-character role does not.
        XCTAssertEqual(BrainPersonLayout.roleSplit("**Paris & French Culture**: speaks fluent French")?.role, "Paris & French Culture")
        XCTAssertNil(BrainPersonLayout.roleSplit("Twenty-nine characters here and: x"))
        XCTAssertNil(BrainPersonLayout.roleSplit("sister Mina"))
        XCTAssertNil(BrainPersonLayout.roleSplit("Mother:Ann"))
        XCTAssertNil(BrainPersonLayout.roleSplit(": nobody"))
        XCTAssertNil(BrainPersonLayout.roleSplit("Father: "))
    }

    func testIsBoldLeadIn() {
        XCTAssertTrue(BrainPersonLayout.isBoldLeadIn("**Education**: M.S. in Robotics"))
        XCTAssertTrue(BrainPersonLayout.isBoldLeadIn("**Paris & French Culture**: plans to teach"))
        // A plain sentence with a colon is not a label.
        XCTAssertFalse(BrainPersonLayout.isBoldLeadIn("Philosophy: Doesn't accept compliments."))
        XCTAssertFalse(BrainPersonLayout.isBoldLeadIn("sister Mina"))
        // A colon inside the bold text: "**Note: see**: …" is not a "**X**:" lead-in.
        XCTAssertFalse(BrainPersonLayout.isBoldLeadIn("**Note: see**: details"))
    }

    func testAboutItemStripsBrokenWikiLinks() {
        XCTAssertEqual(
            BrainPersonLayout.aboutItem("Douglas Fisher (Alex's half-brother) - See [Douglas Fisher.md](Douglas Fisher.md)"),
            "Douglas Fisher (Alex's half-brother)")
        // The em-dash spelling and a spaceless `.md` target are dropped too.
        XCTAssertEqual(
            BrainPersonLayout.aboutItem("cousin Teo — See [Teo Quill.md](Teo Quill.md)"),
            "cousin Teo")
        // A vault link that is not a trailing "See" keeps its plain text (no ".md").
        XCTAssertEqual(BrainPersonLayout.aboutItem("worked with [Orbit Labs.md](Orbit Labs.md)"),
                       "worked with Orbit Labs")
        // A valid web link is kept intact.
        XCTAssertEqual(BrainPersonLayout.aboutItem("[profile](https://example.com/ada)"),
                       "[profile](https://example.com/ada)")
        // A "See" note that is not a link passes through.
        XCTAssertEqual(BrainPersonLayout.aboutItem("a cat - See the photos"), "a cat - See the photos")
        // Ordinary text is untouched.
        XCTAssertEqual(BrainPersonLayout.aboutItem("Father: Bo Test"), "Father: Bo Test")
    }

    func testCatchUpBirthdayLineIsOnlyANearBirthday() {
        let questions = ["Ask about the move"]
        let near = layout(BrainPerson(questions: questions, nextBirthday: "2026-10-26"))
        XCTAssertEqual(near.catchUp, BrainPersonLayout.CatchUp(summary: nil, lines: ["Birthday Oct 26, in 12 days"]))
        XCTAssertNil(layout(BrainPerson(questions: questions, nextBirthday: "2027-01-19")).catchUp)
        XCTAssertNil(layout(BrainPerson(questions: questions)).catchUp)
        XCTAssertEqual(layout(BrainPerson(nextBirthday: "2026-10-14")).catchUp?.lines, ["Birthday today"])
        XCTAssertEqual(layout(BrainPerson(nextBirthday: "2026-10-15")).catchUp?.lines, ["Birthday Oct 15, in 1 day"])
        XCTAssertEqual(layout(BrainPerson(nextBirthday: "2026-11-13")).catchUp?.lines, ["Birthday Nov 13, in 30 days"])
        XCTAssertNil(layout(BrainPerson(nextBirthday: "2026-11-14")).catchUp)
    }

    func testCatchUpPutsTheBirthdayBeforeTheThreads() {
        let person = BrainPerson(nextBirthday: "2026-10-26", catchup: "  Moving to Lisbon in spring.  ",
                                 threads: ["the Lisbon move", "  ", " her sister's visit "])
        XCTAssertEqual(layout(person).catchUp, BrainPersonLayout.CatchUp(
            summary: "Moving to Lisbon in spring.",
            lines: ["Birthday Oct 26, in 12 days", "the Lisbon move", "her sister's visit"]))
    }

    func testCatchUpSummaryOrThreadsAlone() {
        XCTAssertEqual(layout(BrainPerson(catchup: "Just back from Lisbon.")).catchUp,
                       BrainPersonLayout.CatchUp(summary: "Just back from Lisbon.", lines: []))
        XCTAssertEqual(layout(BrainPerson(threads: ["the move"])).catchUp,
                       BrainPersonLayout.CatchUp(summary: nil, lines: ["the move"]))
        XCTAssertNil(layout(BrainPerson(catchup: " ", threads: [""])).catchUp)
    }

    func testRhythmRunsFromElevenMonthsAgoToThisMonth() {
        let counts = [1, 0, 0, 2, 0, 0, 0, 0, 0, 0, 1, 3]
        let layout = layout(BrainPerson(rhythm: counts))
        XCTAssertEqual(layout.rhythm.map(\.id), Array(0..<12))
        XCTAssertEqual(layout.rhythm.map(\.label),
                       ["Nov", "Dec", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct"])
        XCTAssertEqual(layout.rhythm.map(\.seen), counts.map { $0 > 0 })
        XCTAssertEqual(layout.rhythmAccessibilityLabel, "Seen in 4 of the last 12 months")
    }

    func testRhythmCrossesTheYearFromEarlyInTheYear() {
        let february = calendar.date(from: DateComponents(year: 2027, month: 2, day: 3, hour: 12))!
        let person = BrainPerson(rhythm: Array(repeating: 0, count: 12))
        let page = BrainPage(item: BrainItem(module: .people, id: "people/ada-test.md", title: "Ada Test"), person: person)
        let layout = BrainPersonLayout(page: page, person: person, today: february, calendar: calendar)
        XCTAssertEqual(layout.rhythm.first?.label, "Mar")
        XCTAssertEqual(layout.rhythm.last?.label, "Feb")
        XCTAssertEqual(layout.rhythmAccessibilityLabel, "Seen in 0 of the last 12 months")
    }

    func testRhythmLabelsFollowTheServersEndMonth() {
        // A saved copy counted through October, read in December: the dots still end at Oct.
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 3, hour: 12))!
        let person = BrainPerson(rhythm: Array(repeating: 0, count: 12), rhythmEnd: "2026-10")
        let page = BrainPage(item: BrainItem(module: .people, id: "people/ada-test.md", title: "Ada Test"), person: person)
        let layout = BrainPersonLayout(page: page, person: person, today: december, calendar: calendar)
        XCTAssertEqual(layout.rhythm.first?.label, "Nov")
        XCTAssertEqual(layout.rhythm.last?.label, "Oct")
        let odd = BrainPerson(rhythm: Array(repeating: 0, count: 12), rhythmEnd: "2026-13")
        XCTAssertEqual(BrainPersonLayout(page: page, person: odd, today: december, calendar: calendar).rhythm.last?.label,
                       "Dec", "an unreadable end month falls back to today's")
    }

    func testRhythmNeedsTwelveMonths() {
        XCTAssertTrue(layout(BrainPerson(rhythm: Array(repeating: 1, count: 11))).rhythm.isEmpty)
        XCTAssertTrue(layout(BrainPerson(rhythm: Array(repeating: 1, count: 13))).rhythm.isEmpty)
        XCTAssertTrue(layout(BrainPerson()).rhythm.isEmpty)
        XCTAssertEqual(layout(BrainPerson()).rhythmAccessibilityLabel, "")
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
