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
        let rx = size.width * 0.38
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
        let neighbours = (1...6).map { "wiki/a-very-long-title-that-would-never-fit-\($0).md" }
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
                    let center = try XCTUnwrap(
                        BrainGraphLayout.positions(nodeIDs: ids, centerID: centerID, size: size)[centerID]
                    )
                    let side = BrainGraphLayout.centerDot
                    let centerDot = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                    let rects = neighbours.compactMap { frames[$0] }
                    for (index, rect) in rects.enumerated() {
                        let context = "\(centerID) at \(width), label \(index): \(rect)"
                        XCTAssertGreaterThanOrEqual(rect.height, 44, context)
                        XCTAssertLessThanOrEqual(rect.width, width * 0.30 + 0.001, context)
                        XCTAssertTrue(inner.contains(rect), "outside bounds: \(context)")
                        XCTAssertFalse(rect.intersects(centerDot), "covers the centre: \(context)")
                        for other in rects[(index + 1)...] {
                            XCTAssertFalse(rect.intersects(other), "overlaps \(other): \(context)")
                        }
                    }
                }
            }
        }
    }
}
