import SwiftUI
import XCTest
@testable import HermesMobile

/// Review renders of the cue diagrams, for comparing against the reference renderer by eye.
@MainActor
final class CueDiagramSnapshotTests: XCTestCase {
    /// Writes every lift as `<lift>-<light|dark>-<start|mid|end>.png` (the start pose, halfway
    /// through the effort, and the end of it), only when `CUE_DIAGRAM_RENDERS` names a folder
    /// (`TEST_RUNNER_CUE_DIAGRAM_RENDERS=<folder>`).
    func testRenderEveryLiftForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["CUE_DIAGRAM_RENDERS"] else {
            throw XCTSkip("Set TEST_RUNNER_CUE_DIAGRAM_RENDERS to write review renders")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let palette = CueDiagramPalette(paper: .training, stage: .hxSurface)
        let side = 220.0
        let scale = 2.0

        for id in CueDiagramLibrary.shared.liftIDs {
            let figure = try XCTUnwrap(CueDiagramLibrary.shared.figure(for: id))
            for (appearance, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                for (moment, progress) in [("start", 0.0), ("mid", 0.5), ("end", 1.0)] {
                    let renderer = ImageRenderer(content: CueDiagramCanvas(figure: figure, progress: progress, palette: palette)
                        .frame(width: side, height: side)
                        .background(Color.hxSurface)
                        .environment(\.colorScheme, scheme))
                    renderer.scale = scale
                    let image = try XCTUnwrap(renderer.uiImage, "\(id) \(appearance) \(moment)")
                    XCTAssertEqual(image.size.width * image.scale, side * scale, "\(id) \(appearance) \(moment)")
                    try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(id)-\(appearance)-\(moment).png"))
                }
            }
        }
    }
}
