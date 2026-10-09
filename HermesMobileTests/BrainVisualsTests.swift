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

    func testGraphLayoutCentresAndIsStable() throws {
        let size = CGSize(width: 340, height: 180)
        let ids = ["wiki/c.md", "wiki/center.md", "wiki/a.md", "wiki/b.md", "wiki/d.md"]
        let positions = BrainGraphLayout.positions(nodeIDs: ids, centerID: "wiki/center.md", size: size)

        XCTAssertEqual(positions.count, ids.count)
        XCTAssertEqual(positions["wiki/center.md"], CGPoint(x: 170, y: 90))
        let bounds = CGRect(origin: .zero, size: size)
        let rx = size.width * 0.20
        let ry = size.height * 0.30
        for id in ids where id != "wiki/center.md" {
            let point = try XCTUnwrap(positions[id])
            XCTAssertTrue(bounds.contains(point), "\(id) at \(point) is outside \(bounds)")
            let dx = (point.x - 170) / rx
            let dy = (point.y - 90) / ry
            XCTAssertEqual(dx * dx + dy * dy, 1, accuracy: 0.0001, "\(id) is off the ellipse")
        }

        let again = BrainGraphLayout.positions(nodeIDs: ids.reversed(), centerID: "wiki/center.md", size: size)
        XCTAssertEqual(positions, again)
    }

    func testGraphLayoutWithoutNeighbours() {
        let positions = BrainGraphLayout.positions(nodeIDs: ["x"], centerID: "x", size: CGSize(width: 100, height: 50))
        XCTAssertEqual(positions, ["x": CGPoint(x: 50, y: 25)])
    }

    func testVisibleNodesCapsOrdersDedupesAndExcludesCentre() {
        let nodes = [
            BrainGraphNode(module: .wiki, id: "center", title: "Centre", weight: 99),
            BrainGraphNode(module: .wiki, id: "b", weight: 5),
            BrainGraphNode(module: .wiki, id: "a", weight: 5),
            BrainGraphNode(module: .wiki, id: "low", weight: 0),
            BrainGraphNode(module: .wiki, id: "top", weight: 9),
            BrainGraphNode(module: .journal, id: "a", weight: 1),
            BrainGraphNode(module: .wiki, id: "c", weight: 3),
            BrainGraphNode(module: .wiki, id: "d", weight: 2),
            BrainGraphNode(module: .wiki, id: "e", weight: 2),
            BrainGraphNode(module: .wiki, id: "f", weight: 1)
        ]
        let visible = BrainGraphLayout.visibleNodes(of: BrainGraph(nodes: nodes), centerID: "center")
        XCTAssertEqual(BrainGraphLayout.maxNeighbours, 6)
        XCTAssertEqual(visible.map(\.id), ["top", "a", "b", "c", "d", "e"])
        XCTAssertEqual(visible.first { $0.id == "a" }?.module, .wiki, "keeps the first of a duplicate id")
    }

    func testGraphLabelFramesDoNotCollide() throws {
        let centerIDs = ["wiki/virtues.md", "wiki/networking.md", "journal/2026-09-01.md", "a", "b", "c", "d", "e"]
        let allNeighbours = (1...6).map { "wiki/a-very-long-title-that-would-never-fit-\($0).md" }
        for count in 1...6 {
            let neighbours = Array(allNeighbours.prefix(count))
            for width in [375.0, 320.0] {
                let size = CGSize(width: width, height: 180)
                let inner = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
                for centerID in centerIDs {
                    for labelHeight in [16.0, 22.0] {
                        let ids = [centerID] + neighbours
                        let frames = BrainGraphLayout.labelFrames(
                            nodeIDs: ids, centerID: centerID, size: size, labelHeight: labelHeight
                        )
                        XCTAssertEqual(Set(frames.keys), Set(neighbours))
                        XCTAssertNil(frames[centerID])
                        let dots = BrainGraphLayout.positions(nodeIDs: ids, centerID: centerID, size: size)
                        let center = try XCTUnwrap(dots[centerID])
                        let side = BrainGraphLayout.centerDot
                        let centerDot = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                        let rects = neighbours.compactMap { frames[$0] }
                        for (index, rect) in rects.enumerated() {
                            let context = "\(count) neighbours, \(centerID) at \(width), label \(index): \(rect)"
                            XCTAssertGreaterThanOrEqual(rect.height, 44, context)
                            XCTAssertLessThanOrEqual(rect.width, width * 0.25 + 0.001, context)
                            XCTAssertTrue(inner.contains(rect), "outside bounds: \(context)")
                            XCTAssertFalse(rect.intersects(centerDot), "covers the centre: \(context)")
                            for (dotID, dot) in dots {
                                XCTAssertFalse(rect.contains(dot), "covers the dot of \(dotID): \(context)")
                            }
                            for other in rects[(index + 1)...] {
                                XCTAssertFalse(rect.intersects(other), "overlaps \(other): \(context)")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Routing

    /// Every Brain push rides the shell's typed path, so each route must hash to a
    /// distinct destination (and equal routes must collapse).
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

    func testReaderMetaLineCapitalisesKindAndOmitsEmptyDate() {
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "note", date: "2026-10-06"), "Note · 2026-10-06")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "journal", date: ""), "Journal")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "", date: "2026-10-06"), "2026-10-06")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "", date: ""), "")
        XCTAssertEqual(BrainReaderLayout.metaLine(kind: "éclair", date: ""), "Éclair")
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

    func testReaderBacklinkSubtitleIsTheJournalSnippetOnly() {
        let day = BrainRef(module: .journal, id: "j", title: "Oct 6", snippet: "met Ada")
        let wiki = BrainRef(module: .wiki, id: "w", title: "W", snippet: "mentions")
        XCTAssertEqual(BrainReaderLayout.backlinkSubtitle(day), "met Ada")
        XCTAssertNil(BrainReaderLayout.backlinkSubtitle(wiki))
    }

    func testReaderSectionTitlesAndGraphThreshold() {
        XCTAssertEqual(BrainReaderLayout.linkedFromTitle(.people), "Mentioned in")
        XCTAssertEqual(BrainReaderLayout.linkedFromTitle(.wiki), "Linked from")
        let center = BrainGraphNode(module: .wiki, id: "a")
        let other = BrainGraphNode(module: .wiki, id: "b")
        XCTAssertFalse(BrainReaderLayout.showsGraph(nil, centerID: "a"))
        XCTAssertFalse(BrainReaderLayout.showsGraph(BrainGraph(nodes: [center]), centerID: "a"))
        XCTAssertFalse(BrainReaderLayout.showsGraph(BrainGraph(nodes: [center, center]), centerID: "a"))
        XCTAssertTrue(BrainReaderLayout.showsGraph(BrainGraph(nodes: [center, other]), centerID: "a"))
    }

    func testReaderGraphRampMatchesTheCover() {
        let item = BrainItem(module: .wiki, id: "wiki/virtues.md", tags: ["habits"])
        XCTAssertEqual(BrainReaderLayout.cover(for: item), BrainCoverSpec.make(id: item.id, tag: "habits"))
        XCTAssertEqual(BrainReaderLayout.cover(for: item).ramp, 2)
    }

    func testFactValuesFormatDatesAndKeepAnythingElse() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(BrainPersonCardView.displayValue("1815-12-10", locale: locale), "December 10, 1815")
        XCTAssertEqual(BrainPersonCardView.displayValue("2026-10-01", locale: locale), "October 1, 2026")
        XCTAssertEqual(BrainPersonCardView.displayValue("London", locale: locale), "London")
        XCTAssertEqual(BrainPersonCardView.displayValue("2026-13-45", locale: locale), "2026-13-45")
        XCTAssertEqual(BrainPersonCardView.displayValue("", locale: locale), "")
    }
}
