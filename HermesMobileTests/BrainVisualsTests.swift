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

    /// Pins the hash itself, so a change to FNV-1a or SplitMix64 (or a slip to
    /// Swift's per-launch `hashValue`) fails here rather than reshuffling covers.
    func testCoverHashIsFNV1a64() {
        XCTAssertEqual(BrainCoverSpec.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(BrainCoverSpec.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
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

    func testGraphLayoutCentresAndIsStable() {
        let size = CGSize(width: 340, height: 180)
        let ids = ["wiki/c.md", "wiki/center.md", "wiki/a.md", "wiki/b.md", "wiki/d.md"]
        let positions = BrainGraphLayout.positions(nodeIDs: ids, centerID: "wiki/center.md", size: size)

        XCTAssertEqual(positions.count, ids.count)
        XCTAssertEqual(positions["wiki/center.md"], CGPoint(x: 170, y: 90))
        let bounds = CGRect(origin: .zero, size: size)
        let radius = min(size.width, size.height) * 0.36
        for id in ids where id != "wiki/center.md" {
            let point = try! XCTUnwrap(positions[id])
            XCTAssertTrue(bounds.contains(point), "\(id) at \(point) is outside \(bounds)")
            XCTAssertEqual(hypot(point.x - 170, point.y - 90), radius, accuracy: 0.001)
        }

        let again = BrainGraphLayout.positions(nodeIDs: ids.reversed(), centerID: "wiki/center.md", size: size)
        XCTAssertEqual(positions, again)
    }

    func testGraphLayoutWithoutNeighbours() {
        let positions = BrainGraphLayout.positions(nodeIDs: ["x"], centerID: "x", size: CGSize(width: 100, height: 50))
        XCTAssertEqual(positions, ["x": CGPoint(x: 50, y: 25)])
    }
}
