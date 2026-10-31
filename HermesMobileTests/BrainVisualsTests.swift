import XCTest
import CoreGraphics
@testable import HermesMobile

final class BrainVisualsTests: XCTestCase {
    func testCoverSpecIsDeterministic() {
        let first = BrainCoverSpec.make(id: "wiki/virtues.md", tag: "stoicism")
        let second = BrainCoverSpec.make(id: "wiki/virtues.md", tag: "stoicism")
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, BrainCoverSpec.make(id: "wiki/networking.md", tag: "stoicism"))
    }

    /// Pins FNV-1a 64 to its published test vectors, so a change to the hash (or a
    /// slip to Swift's per-launch `hashValue`) fails here rather than reshuffling covers.
    func testCoverHashIsFNV1a64() {
        XCTAssertEqual(BrainCoverSpec.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(BrainCoverSpec.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(BrainCoverSpec.fnv1a64("wiki/virtues.md"), 0x0e2d_2f76_fbb7_741b)
    }

    /// SplitMix64's reference outputs for seed 0 (Vigna's `splitmix64.c`).
    func testSplitMix64MatchesReferenceVectors() {
        var rng = SplitMix64(seed: 0)
        XCTAssertEqual(rng.next(), 0xe220_a839_7b1d_cdaf)
        XCTAssertEqual(rng.next(), 0x6e78_9e6a_a1b9_65f4)
        XCTAssertEqual(rng.next(), 0x06c4_5d18_8009_454f)
    }

    /// One full spec, computed independently (Python) from FNV-1a 64 + SplitMix64.
    func testCoverSpecGoldenVector() {
        let spec = BrainCoverSpec.make(id: "wiki/virtues.md", tag: "stoicism")
        XCTAssertEqual(spec.motif, .waves)
        XCTAssertEqual(spec.ramp, 3)
        let expected = [0.7118957187993974, 0.6334364050885682, 0.8080716706120018,
                        0.4025383301954609, 0.22174883289065062, 0.5360952853920845]
        XCTAssertEqual(spec.params.count, expected.count)
        for (actual, golden) in zip(spec.params, expected) {
            XCTAssertEqual(actual, golden, accuracy: 1e-12)
        }
    }

    func testKnownTagPinsRamp() {
        XCTAssertEqual(BrainCoverSpec.make(id: "anything", tag: "career").ramp, 0)
        XCTAssertEqual(BrainCoverSpec.make(id: "wiki/other.md", tag: "career").ramp, 0)
        XCTAssertEqual(BrainCoverSpec.make(id: "anything", tag: "communication").ramp, 1)
        XCTAssertEqual(BrainCoverSpec.make(id: "anything", tag: "self").ramp, 4)
        XCTAssertEqual(BrainCoverSpec.make(id: "anything", tag: "llm").ramp, 5)
        XCTAssertEqual(BrainCoverSpec.make(id: "anything", tag: "ai-agents").ramp, 5)
    }

    func testUnknownOrMissingTagUsesHashRampInRange() {
        for id in ["a", "b", "wiki/virtues.md", "journal/2026-01-01.md", ""] {
            let untagged = BrainCoverSpec.make(id: id, tag: nil)
            XCTAssertTrue((0..<BrainStyle.coverPalette.count).contains(untagged.ramp))
            XCTAssertEqual(untagged.ramp, BrainCoverSpec.make(id: id, tag: "stoicism").ramp)
        }
        XCTAssertEqual(BrainStyle.coverPalette.count, 8)
    }

    func testParamsInUnitRange() {
        for index in 0..<200 {
            let spec = BrainCoverSpec.make(id: "item-\(index)", tag: nil)
            XCTAssertEqual(spec.params.count, 6)
            for value in spec.params {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThan(value, 1)
            }
        }
    }

    func testMotifsAllOccur() {
        let motifs = Set((0..<200).map { BrainCoverSpec.make(id: "item-\($0)", tag: nil).motif })
        XCTAssertEqual(motifs, [.circles, .waves, .bars])
    }

    func testBrainRouteDestinationsAreDistinct() {
        let destinations: [ShellPushDestination] = [
            .brain,
            .brainRoute(.module(.wiki)),
            .brainRoute(.module(.people)),
            .brainRoute(.page(.wiki, "wiki/virtues.md")),
            .brainRoute(.page(.articles, "wiki/virtues.md")),
            .brainRoute(.searchAll(.wiki, query: "marcus")),
            .brainRoute(.searchAll(.wiki, query: "seneca"))
        ]
        XCTAssertEqual(Set(destinations).count, destinations.count)
        XCTAssertEqual(
            ShellPushDestination.brainRoute(.page(.wiki, "wiki/virtues.md")),
            ShellPushDestination.brainRoute(.page(.wiki, "wiki/virtues.md"))
        )
    }

    func testMonogramInitials() {
        XCTAssertEqual(BrainMonogram.initials(for: "Sam Rivera"), "SR")
        XCTAssertEqual(BrainMonogram.initials(for: "  marcus  aurelius antoninus"), "MA")
        XCTAssertEqual(BrainMonogram.initials(for: "Plato"), "P")
        XCTAssertEqual(BrainMonogram.initials(for: ""), "")
    }

    // MARK: List layout

    private func item(_ id: String, _ module: BrainModuleID = .wiki, kind: String = "") -> BrainItem {
        BrainItem(module: module, id: id, title: id, kind: kind)
    }

    func testResolveKeepsGroupOrderAndSkipsMissingAndRepeatedIds() {
        let items = [item("a"), item("b"), item("c")]
        let resolved = BrainListLayout.resolve(["c", "missing", "a", "c"], in: items)
        XCTAssertEqual(resolved.map(\.id), ["c", "a"])
        XCTAssertEqual(BrainListLayout.resolve([], in: items), [])
    }

    func testSectionsDropEmptyGroupsAndFallBackToAllItems() {
        let items = [item("a"), item("b"), item("a")]
        let grouped = BrainList(items: items, groups: [
            BrainGroup(title: "Concepts", ids: ["b"]),
            BrainGroup(title: "Sources", ids: ["gone"]),
            BrainGroup(title: "Comparisons", ids: ["a", "b"])
        ])
        let sections = BrainListLayout.sections(grouped)
        XCTAssertEqual(sections.map(\.title), ["Concepts", "Comparisons"])
        XCTAssertEqual(sections[1].items.map(\.id), ["a", "b"])

        let flat = BrainListLayout.sections(BrainList(items: items))
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0].title, "")
        XCTAssertEqual(flat[0].items.map(\.id), ["a", "b"])
    }

    func testSplitHighlightsBooksByKindVideosByGroup() {
        let items = [
            item("book:meditations", .highlights, kind: "book"),
            item("yt:2", .highlights, kind: "video"),
            item("book:letters", .highlights, kind: "book"),
            item("yt:1", .highlights, kind: "video")
        ]
        let list = BrainList(items: items, groups: [
            BrainGroup(title: "Books", ids: ["book:meditations", "book:letters"]),
            BrainGroup(title: "YouTube", ids: ["yt:1", "yt:2", "yt:missing"])
        ])
        let split = BrainListLayout.splitHighlights(list)
        XCTAssertEqual(split.books.map(\.id), ["book:meditations", "book:letters"])
        XCTAssertEqual(split.videos.map(\.id), ["yt:1", "yt:2"])

        // No YouTube group: every non-book item is a video, in list order.
        let ungrouped = BrainListLayout.splitHighlights(BrainList(items: items))
        XCTAssertEqual(ungrouped.books.map(\.id), ["book:meditations", "book:letters"])
        XCTAssertEqual(ungrouped.videos.map(\.id), ["yt:2", "yt:1"])
    }

    func testTopTagsRanksByCountCapsAtTwelveAndKeepsSelection() {
        let tags = (0..<20).map { BrainTagCount(tag: "t\($0)", count: $0 % 5) }
            + [BrainTagCount(tag: "", count: 99), BrainTagCount(tag: "t4", count: 1)]
        let top = BrainListLayout.topTags(tags)
        XCTAssertEqual(top.count, 12)
        // Count 4 first (t4, t9, t14, t19), ties in server order; blanks and repeats dropped.
        XCTAssertEqual(Array(top.prefix(4)), ["t4", "t9", "t14", "t19"])
        XCTAssertFalse(top.contains(""))
        XCTAssertEqual(Set(top).count, top.count)

        let withSelected = BrainListLayout.topTags(tags, selected: "t0")
        XCTAssertEqual(withSelected.count, 13)
        XCTAssertEqual(withSelected.last, "t0")
        XCTAssertEqual(BrainListLayout.topTags(tags, selected: "t4").count, 12)
    }

    func testGridColumnsDropToOneAtAccessibilitySizes() {
        XCTAssertEqual(BrainListLayout.columnCount(3, dynamicType: .xxLarge), 3)
        XCTAssertEqual(BrainListLayout.columnCount(2, dynamicType: .large), 2)
        XCTAssertEqual(BrainListLayout.columnCount(3, dynamicType: .accessibility2), 1)
        XCTAssertEqual(BrainListLayout.columnCount(2, dynamicType: .accessibility1), 1)
    }

    func testChunksKeepOrderShortLastRowAndFirstItemIds() {
        let items = ["a", "b", "c", "d", "e"].map { item($0) }
        let chunks = BrainListLayout.chunks(items, size: 2)
        XCTAssertEqual(chunks.map(\.id), ["a", "c", "e"])
        XCTAssertEqual(chunks.map { $0.items.map(\.id) }, [["a", "b"], ["c", "d"], ["e"]])
        XCTAssertEqual(BrainListLayout.chunks(items, size: 3).map(\.items.count), [3, 2])
        XCTAssertEqual(BrainListLayout.chunks([], size: 3), [])
        // Ids stay stable as later pages append.
        let grown = BrainListLayout.chunks(items + [item("f"), item("g")], size: 2)
        XCTAssertEqual(Array(grown.prefix(3)).map(\.id), ["a", "c", "e"])
    }

    func testBookRouteDetection() {
        XCTAssertTrue(BrainHighlightsBookView.isBook(module: .highlights, id: "book:meditations"))
        XCTAssertFalse(BrainHighlightsBookView.isBook(module: .highlights, id: "yt:abc"))
        XCTAssertFalse(BrainHighlightsBookView.isBook(module: .wiki, id: "book:meditations"))
        XCTAssertEqual(BrainHighlightsBookContent.countLabel(1), "1 highlight")
        XCTAssertEqual(BrainHighlightsBookContent.countLabel(3), "3 highlights")
    }

    // MARK: - Reader

    func testWikiMetaLineSaysHowLongAgoTheDateLabelApplies() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let today = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)))
        let updated = BrainItem(module: .wiki, id: "w", date: "2026-10-10", kind: "concept", dateLabel: "updated")
        XCTAssertEqual(BrainReaderLayout.metaLine(for: updated, today: today, calendar: utc), "Concept · updated 3 wk ago")
        let added = BrainItem(module: .wiki, id: "s", date: "2026-10-31", kind: "source", dateLabel: "added")
        XCTAssertEqual(BrainReaderLayout.metaLine(for: added, today: today, calendar: utc), "Source · added today")
        let us = Locale(identifier: "en_US")
        let article = BrainItem(module: .articles, id: "a", date: "2026-10-06", kind: "article")
        XCTAssertEqual(BrainReaderLayout.metaLine(for: article, today: today, calendar: utc, locale: us),
                       "Article · Oct 6, 2026", "a page without a date label keeps the plain date")
        let undated = BrainItem(module: .wiki, id: "u", date: "someday", kind: "concept", dateLabel: "updated")
        XCTAssertEqual(BrainReaderLayout.metaLine(for: undated, today: today, calendar: utc, locale: us), "Concept · someday")
    }

    func testAHubSaysSoInItsMetaLine() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let today = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)))
        let item = BrainItem(module: .wiki, id: "h", date: "2026-10-10", kind: "concept", dateLabel: "updated")
        XCTAssertEqual(BrainReaderLayout.metaLine(for: item, hubPageCount: 8, today: today, calendar: utc),
                       "Hub · 8 pages · updated 3 wk ago")
        let undated = BrainItem(module: .wiki, id: "h", kind: "entity")
        XCTAssertEqual(BrainReaderLayout.metaLine(for: undated, hubPageCount: 5, today: today, calendar: utc), "Hub · 5 pages")
    }

    func testAHubInsideAHubCountsItsOwnPagesInWords() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let today = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)))
        let item = BrainItem(module: .wiki, id: "h", date: "2026-10-24", kind: "concept", dateLabel: "updated")
        XCTAssertEqual(BrainReaderLayout.metaLine(for: item, hubPageCount: 7, nested: true, today: today, calendar: utc),
                       "7 pages under this one · updated 7d ago", "never \"Hub · 7\" beside the pager's \"1 of 7\"")
    }

    func testPagerPlaceLineSaysWhenAStepFailed() {
        let hub = BrainHubContext(ref: BrainRef(module: .wiki, id: "h"), index: 0, count: 7)
        XCTAssertEqual(BrainConnectionsLayout.placeLine(hub, failed: false), "1 of 7")
        XCTAssertEqual(BrainConnectionsLayout.placeLine(hub, failed: true), "Couldn't open it · try again")
    }

    func testWikiMatchesTitleOrGistWordPrefixesWithoutRepeats() {
        let items = [
            BrainItem(module: .wiki, id: "a", title: "Atomic Habits", preview: "Results lag inputs."),
            BrainItem(module: .wiki, id: "b", title: "Café culture", preview: "Small rituals."),
            BrainItem(module: .wiki, id: "a", title: "Atomic Habits", preview: "Results lag inputs."),
            BrainItem(module: .wiki, id: "c", title: "Kafka", preview: "A distributed log."),
        ]
        XCTAssertEqual(BrainListLayout.wikiMatches(items, query: "hab").map(\.id), ["a"], "a recent page listed twice matches once")
        XCTAssertEqual(BrainListLayout.wikiMatches(items, query: "cafe rit").map(\.id), ["b"], "accents and the gist count")
        XCTAssertEqual(BrainListLayout.wikiMatches(items, query: "log").map(\.id), ["c"])
        XCTAssertEqual(BrainListLayout.wikiMatches(items, query: "  ").map(\.id), [])
        XCTAssertEqual(BrainListLayout.wikiMatches(items, query: "abits").map(\.id), [], "words match from their start")
        let ranked = [BrainItem(module: .wiki, id: "gist", title: "Talks", preview: "Consistency matters."),
                      BrainItem(module: .wiki, id: "title", title: "Consistent reads")]
        XCTAssertEqual(BrainListLayout.wikiMatches(ranked, query: "consist").map(\.id), ["title", "gist"],
                       "a title match leads")
    }

    func testSectionCountsTheWholeGroupNotJustTheLoadedRows() {
        let list = BrainList(items: [BrainItem(module: .wiki, id: "s1"), BrainItem(module: .wiki, id: "s2")],
                             groups: [BrainGroup(title: "Sources", ids: ["s1", "s2"], total: 99),
                                      BrainGroup(title: "Other", ids: ["s1"])])
        let sections = BrainListLayout.sections(list)
        XCTAssertEqual(sections.map(\.count), [99, 1], "an older server's group counts what loaded")
    }

    func testListAgeUsesThePeopleListSteps() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let today = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)))
        XCTAssertEqual(BrainListLayout.age("2026-10-31", today: today, calendar: utc), "today")
        XCTAssertEqual(BrainListLayout.age("2026-10-25", today: today, calendar: utc), "6d")
        XCTAssertEqual(BrainListLayout.age("2026-10-01", today: today, calendar: utc), "4 wk")
        XCTAssertEqual(BrainListLayout.age("2026-05-01", today: today, calendar: utc), "6 mo")
        XCTAssertNil(BrainListLayout.age("", today: today, calendar: utc))
    }

    func testReaderMetaLineCapitalisesKindAndOmitsEmptyDate() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "note", date: "2026-10-06", locale: us), "Note · Oct 6, 2026")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "journal", date: "", locale: us), "Journal")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "", date: "2026-10-06", locale: us), "Oct 6, 2026")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "", date: "", locale: us), "")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "day", date: "2026-10-08", locale: us), "Journal")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "éclair", date: "", locale: us), "Éclair")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "note", date: "someday", locale: us), "Note · someday")
    }

    func testReaderBacklinksShowFiveThenAll() {
        let refs = (1...7).map { BrainRef(module: .wiki, id: "w\($0)", title: "W\($0)") }
        XCTAssertEqual(BrainReaderLayout.visibleBacklinks(refs, expanded: false).map(\.id), ["w1", "w2", "w3", "w4", "w5"])
        XCTAssertEqual(BrainReaderLayout.visibleBacklinks(refs, expanded: true).count, 7)
        XCTAssertTrue(BrainReaderLayout.hasMoreBacklinks(refs, expanded: false))
        XCTAssertFalse(BrainReaderLayout.hasMoreBacklinks(refs, expanded: true))
        XCTAssertFalse(BrainReaderLayout.hasMoreBacklinks(Array(refs.prefix(5)), expanded: false))
        XCTAssertEqual(BrainReaderLayout.showAllTitle(refs.count), "Show all 7")
    }

    func testReaderSectionTitles() {
        XCTAssertEqual(BrainReaderLayout.linkedFromTitle(.people), "Mentioned in")
        XCTAssertEqual(BrainReaderLayout.linkedFromTitle(.wiki), "Linked mentions")
    }

    // MARK: - Final fix wave

    func testDisplayDateRendersISOAsMediumDateInUTC() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(BrainStyle.displayDate("2026-03-25", locale: us), "Mar 25, 2026")
        XCTAssertEqual(BrainStyle.displayDate("1815-12-10", locale: us), "Dec 10, 1815")
        XCTAssertEqual(BrainStyle.displayDate("2026-01-01", locale: us), "Jan 1, 2026", "no day shift at a year edge")
    }

    func testDisplayDatePassesAnythingElseThrough() {
        let us = Locale(identifier: "en_US")
        for raw in ["", "London", "2026-13-45", "2026-02-30", "Oct 7, 2026", "20260325", "2026-3-5"] {
            XCTAssertEqual(BrainStyle.displayDate(raw, locale: us), raw)
        }
    }

    func testDisplayDateTakesTheDateOfADatetime() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(BrainStyle.displayDate("2026-03-25T23:30:00Z", locale: us), "Mar 25, 2026")
        XCTAssertEqual(BrainStyle.displayDate("2026-03-25T23:30:00-08:00", locale: us), "Mar 25, 2026")
        XCTAssertEqual(BrainStyle.displayDate("2026-03-25 08:15", locale: us), "Mar 25, 2026")
        XCTAssertEqual(BrainStyle.displayDate("2026-03-25Tnonsense", locale: us), "2026-03-25Tnonsense")
    }

    func testCardMetaLineFormatsTheDate() {
        let us = Locale(identifier: "en_US")
        let item = BrainItem(module: .articles, id: "a.md", title: "A", subtitle: "Daily Stoic", date: "2025-03-01")
        XCTAssertEqual(BrainCard.metaLine(for: item, locale: us), "Daily Stoic · Mar 1, 2025")
        let undated = BrainItem(module: .articles, id: "b.md", title: "B", subtitle: "Daily Stoic")
        XCTAssertEqual(BrainCard.metaLine(for: undated, locale: us), "Daily Stoic")
    }

    func testCachedCopyFooterSaysRemovedWhenMissing() {
        XCTAssertEqual(BrainReaderLayout.cachedCopyFooter(isMissing: false), "Offline, showing saved copy")
        XCTAssertEqual(BrainReaderLayout.cachedCopyFooter(isMissing: true), "Removed from the Brain · saved copy")
    }

    func testReaderLinkAction() throws {
        let valid = try XCTUnwrap(URL(string: "brain://wiki/wiki%2Fvirtues.md"))
        XCTAssertEqual(BrainReaderLayout.linkAction(for: valid), .push(.page(.wiki, "wiki/virtues.md")))
        let unknownModule = try XCTUnwrap(URL(string: "brain://goals/x"))
        XCTAssertEqual(BrainReaderLayout.linkAction(for: unknownModule), .discard)
        let noID = try XCTUnwrap(URL(string: "brain://wiki"))
        XCTAssertEqual(BrainReaderLayout.linkAction(for: noID), .discard)
        let web = try XCTUnwrap(URL(string: "https://example.com/a"))
        XCTAssertEqual(BrainReaderLayout.linkAction(for: web), .system)
        let mail = try XCTUnwrap(URL(string: "mailto:a@example.com"))
        XCTAssertEqual(BrainReaderLayout.linkAction(for: mail), .system)
    }
}

final class BrainConnectionsTests: XCTestCase {
    private func ref(_ id: String, _ module: BrainModuleID = .wiki) -> BrainRef {
        BrainRef(module: module, id: id, title: id.uppercased())
    }

    func testLinkCardsDropRepeatsAndThePageItself() {
        let page = BrainPage(item: BrainItem(module: .wiki, id: "self"),
                             links: [ref("a"), ref("self"), ref("b", .people), ref("a")])
        XCTAssertEqual(BrainConnectionsLayout.linkCards(page).map(\.id), ["a", "b"])
    }

    func testLinkCardsLeaveOutTheTrailHubAndAHubsOwnPages() {
        let member = BrainPage(item: BrainItem(module: .wiki, id: "self"), links: [ref("hub"), ref("a")],
                               hub: BrainHubContext(ref: ref("hub"), index: 0, count: 3))
        XCTAssertEqual(BrainConnectionsLayout.linkCards(member).map(\.id), ["a"], "the trail already names the hub")
        let hub = BrainPage(item: BrainItem(module: .wiki, id: "self"), links: [ref("a"), ref("b"), ref("c")],
                            hubPages: [ref("a"), ref("b")])
        XCTAssertEqual(BrainConnectionsLayout.linkCards(hub).map(\.id), ["c"], "In this hub lists a and b")
    }

    func testALongMentionIsMarkedWithoutTheWash() {
        let paper = HermexPaper.wiki
        let short = BrainConnectionsLayout.highlighted("Read Virtues today", mention: "Virtues", paper: paper)
        XCTAssertTrue(short.runs.contains { $0.backgroundColor != nil })
        let title = "Dr. K's Meditation Techniques: Cognitive Fingerprint Mapping"
        let long = BrainConnectionsLayout.highlighted("See \(title) for more", mention: title, paper: paper)
        XCTAssertFalse(long.runs.contains { $0.backgroundColor != nil })
        XCTAssertTrue(long.runs.contains { $0.foregroundColor != nil }, "still marked in the glow")
    }

    func testFurtherReadingSplitsSourcesFromTaggedPages() {
        let refs = [BrainRef(module: .wiki, id: "s", reason: "source"),
                    BrainRef(module: .wiki, id: "t", reason: "#rome · #person"),
                    BrainRef(module: .wiki, id: "old", reason: "shares #stoicism")]
        let groups = BrainReaderLayout.furtherGroups(refs)
        XCTAssertEqual(groups.sources.map(\.id), ["s"])
        XCTAssertEqual(groups.tagged.map(\.id), ["t", "old"], "an older server's reasons still land in Also tagged")
    }

    func testReaderTagsReadAsOneMetaLine() {
        XCTAssertEqual(BrainReaderLayout.tagLine(["habits", "email", "self"]), "#habits · #self")
        XCTAssertEqual(BrainReaderLayout.tagLine([]), "")
    }

    func testAHubInsideAHubListsItsPagesWithoutItsParent() {
        let page = BrainPage(item: BrainItem(module: .wiki, id: "self"),
                             hub: BrainHubContext(ref: ref("parent"), index: 2, count: 7),
                             hubPages: [ref("parent"), ref("a"), ref("self"), ref("b")])
        XCTAssertEqual(BrainConnectionsLayout.hubPages(page).map(\.id), ["a", "b"])
    }

    func testHubPagesDecodeOnThePageAndInTheHubContext() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = #"""
        {"item": {"module": "wiki", "id": "p1"},
         "hub": {"ref": {"module": "wiki", "id": "h"}, "index": 0, "count": 2,
                 "pages": [{"module": "wiki", "id": "p1", "snippet": "One."}, {"module": "nope", "id": "x"},
                           {"module": "wiki", "id": "p2"}]},
         "hub_pages": [{"module": "wiki", "id": "c1", "title": "C1", "snippet": "Gist."}]}
        """#
        let page = try decoder.decode(BrainPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.hub?.pages.map(\.id), ["p1", "p2"], "an unknown module drops one row, not the list")
        XCTAssertEqual(page.hub?.pages.first?.snippet, "One.")
        XCTAssertEqual(page.hubPages.map(\.snippet), ["Gist."])
        let older = try decoder.decode(BrainPage.self, from: Data(#"{"item": {"module": "wiki", "id": "p"}}"#.utf8))
        XCTAssertEqual(older.hubPages, [])
    }

    func testPagerShowsOnlyForAPageInItsHubWithANeighbour() {
        XCTAssertFalse(BrainConnectionsLayout.showsPager(nil))
        XCTAssertFalse(BrainConnectionsLayout.showsPager(BrainHubContext(ref: ref("hub"), index: nil, count: 4, next: ref("b"))),
                       "a hub from front matter the page isn't listed in shows the trail only")
        XCTAssertFalse(BrainConnectionsLayout.showsPager(BrainHubContext(ref: ref("hub"), index: 0, count: 1)))
        XCTAssertTrue(BrainConnectionsLayout.showsPager(BrainHubContext(ref: ref("hub"), index: 3, count: 4, prev: ref("c"))))
    }

    func testPositionReadsAsOneBased() {
        XCTAssertEqual(BrainConnectionsLayout.position(BrainHubContext(ref: ref("hub"), index: 3, count: 14)), "4 of 14")
        XCTAssertNil(BrainConnectionsLayout.position(BrainHubContext(ref: ref("hub"), index: nil, count: 14)))
    }

    func testMentionRangeIsTheFirstCaseInsensitiveMatch() throws {
        let snippet = "Both anthropic and Anthropic's labs"
        let range = try XCTUnwrap(BrainConnectionsLayout.mentionRange(in: snippet, mention: "Anthropic"))
        XCTAssertEqual(snippet[range], "anthropic")
        XCTAssertNil(BrainConnectionsLayout.mentionRange(in: snippet, mention: "  "))
        XCTAssertNil(BrainConnectionsLayout.mentionRange(in: snippet, mention: "OpenAI"))
    }

    func testHighlightedMarksOnlyTheMention() throws {
        let text = BrainConnectionsLayout.highlighted("see Virtues here", mention: "virtues", paper: .wiki)
        XCTAssertEqual(String(text.characters), "see Virtues here")
        let marked = text.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
        XCTAssertEqual(marked.count, 1)
        XCTAssertEqual(String(text[try XCTUnwrap(marked.first).range].characters), "Virtues")
        let plain = BrainConnectionsLayout.highlighted("no match", mention: "virtues", paper: .wiki)
        XCTAssertTrue(plain.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    func testCappedFooterOnlyWhenSomeAreHidden() {
        XCTAssertEqual(BrainConnectionsLayout.cappedFooter(shown: 8, total: 13), "Showing 8 of 13")
        XCTAssertNil(BrainConnectionsLayout.cappedFooter(shown: 8, total: 8))
    }

    func testEachKindWearsItsBriefPaper() {
        XCTAssertEqual(BrainModuleID.wiki.paper, .wiki)
        XCTAssertEqual(BrainModuleID.people.paper, .advisor)
        XCTAssertEqual(BrainModuleID.journal.paper, .past)
        XCTAssertEqual(BrainModuleID.articles.paper, .reading)
        XCTAssertEqual(BrainModuleID.highlights.paper, .book)
        XCTAssertEqual(BrainModuleID.people.kindName, "Person")
    }
}

final class BrainJournalCalendarTests: XCTestCase {
    private typealias Layout = BrainJournalCalendarLayout

    private func day(_ key: String, id: String? = nil) -> BrainItem {
        BrainItem(module: .journal, id: id ?? "journal/2026/10-October/\(key).md", title: key, date: key)
    }

    private func utc(_ key: String) throws -> Date {
        try XCTUnwrap(Layout.date(fromKey: key))
    }

    func testDayKeyComesFromTheDateOrTheFileName() {
        XCTAssertEqual(Layout.dayKey(of: day("2026-10-06")), "2026-10-06")
        XCTAssertEqual(Layout.dayKey(of: BrainItem(module: .journal, id: "journal/2026/10-October/2026-10-07.md", date: "")), "2026-10-07")
        XCTAssertNil(Layout.dayKey(of: BrainItem(module: .journal, id: "journal/notes.md", date: "Oct 7")))
        XCTAssertNil(Layout.date(fromKey: "2026-02-30"), "impossible days are not days")
    }

    func testEntriesKeepTheFirstItemForADay() {
        let entries = Layout.entries([day("2026-10-06", id: "a"), day("2026-10-06", id: "b"), day("2026-10-07")])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries["2026-10-06"]?.id, "a")
    }

    func testMonthsRunFromThisMonthBackToTheOldestEntryWithGaps() throws {
        let months = Layout.months(for: ["2026-08-03", "2026-10-06"], today: try utc("2026-12-01"))
        XCTAssertEqual(months.map(\.id), ["2026-12", "2026-11", "2026-10", "2026-09", "2026-08"])
        let acrossYear = Layout.months(for: ["2025-12-31", "2026-01-02"], today: try utc("2026-01-15"))
        XCTAssertEqual(acrossYear.map(\.id), ["2026-01", "2025-12"])
        XCTAssertEqual(Layout.months(for: [String](), today: .now), [])
    }

    func testCellsStartOnTheLocalesFirstWeekday() {
        // October 2026 starts on a Thursday.
        let october = Layout.Month(year: 2026, month: 10)
        let sundayStart = Layout.cells(for: october, calendar: Layout.calendar(firstWeekday: 1))
        XCTAssertEqual(Array(sundayStart.prefix(5)), [nil, nil, nil, nil, 1])
        XCTAssertEqual(sundayStart.compactMap { $0 }.count, 31)
        let mondayStart = Layout.cells(for: october, calendar: Layout.calendar(firstWeekday: 2))
        XCTAssertEqual(Array(mondayStart.prefix(4)), [nil, nil, nil, 1])
        XCTAssertEqual(Layout.cells(for: Layout.Month(year: 2028, month: 2)).compactMap { $0 }.count, 29, "leap February")
    }

    func testWeekdaySymbolsRotateToTheFirstWeekday() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(Layout.weekdaySymbols(calendar: Layout.calendar(firstWeekday: 1), locale: english),
                       ["S", "M", "T", "W", "T", "F", "S"])
        XCTAssertEqual(Layout.weekdaySymbols(calendar: Layout.calendar(firstWeekday: 2), locale: english),
                       ["M", "T", "W", "T", "F", "S", "S"])
    }

    func testTitleCountAndSpokenDate() {
        let english = Locale(identifier: "en_US")
        let october = Layout.Month(year: 2026, month: 10)
        XCTAssertEqual(Layout.title(of: october, locale: english), "October 2026")
        let entries = Layout.entries([day("2026-10-06"), day("2026-10-07"), day("2026-09-07")])
        XCTAssertEqual(Layout.entryCount(in: october, entries: entries), "2 days")
        XCTAssertEqual(Layout.entryCount(in: Layout.Month(year: 2026, month: 9), entries: entries), "1 day")
        XCTAssertNil(Layout.entryCount(in: Layout.Month(year: 2026, month: 11), entries: entries))
        XCTAssertEqual(Layout.spokenDate("2026-10-06", locale: english), "Tuesday, October 6, 2026")
    }
}

final class BrainPeopleSearchTests: XCTestCase {
    private func person(_ name: String) -> BrainItem {
        BrainItem(module: .people, id: "crm/contacts/\(name).md", title: name)
    }

    private func names(_ query: String, in list: [String]) -> [String] {
        BrainPeopleSearch.matches(list.map(person), query: query).map(\.title)
    }

    func testBlankQueryKeepsEveryoneInOrder() {
        let list = ["Brian Wang", "Alex Fisher", "Ann Lei"]
        XCTAssertEqual(names("", in: list), list)
        XCTAssertEqual(names("   ", in: list), list)
    }

    func testMatchesTheStartOfAnyWordInTheName() {
        let list = ["Alex Fisher", "Brian Wang", "Ann Lei"]
        XCTAssertEqual(names("wang", in: list), ["Brian Wang"])
        XCTAssertEqual(names("fi", in: list), ["Alex Fisher"])
        XCTAssertEqual(names("ang", in: list), [], "the middle of a word is not a match")
    }

    func testIgnoresCaseAndAccents() {
        XCTAssertEqual(names("JOSE", in: ["José Núñez"]), ["José Núñez"])
        XCTAssertEqual(names("nun", in: ["José Núñez"]), ["José Núñez"])
    }

    func testFirstNameMatchesRankAboveLaterWordMatches() {
        let list = ["Alex Brown", "Brett Stallon", "Brian Wang"]
        XCTAssertEqual(names("br", in: list), ["Brett Stallon", "Brian Wang", "Alex Brown"])
    }

    func testEveryTypedWordMustMatchSomeWord() {
        let list = ["Ben Strawsburg", "Brett Stallon", "Ben Lee"]
        XCTAssertEqual(names("ben st", in: list), ["Ben Strawsburg"])
    }
}
