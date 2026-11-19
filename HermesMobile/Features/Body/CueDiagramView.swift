import SwiftUI

/// A lift's moving cue diagram: a mannequin easing between the start pose and the end of the
/// effort, with the working muscle and the coach's cue in `paper`. It plays three reps when it
/// appears, then rests on the start pose without redrawing; a tap plays three more. Under Reduce
/// Motion it never moves and shows the end of the effort. Square, as wide as it is given.
/// A lift without a diagram draws nothing and takes no space.
struct CueDiagramView: View {
    let liftID: String
    var paper: HermexPaper
    /// The surface the diagram sits on: joint dots and the spine dashes are cut out in it.
    var stage: Color

    private let figure: CueDiagramFigure?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = CueDiagramPlayback()

    init(liftID: String, paper: HermexPaper = .training, stage: Color = .hxSurface) {
        self.liftID = liftID
        self.paper = paper
        self.stage = stage
        figure = CueDiagramLibrary.shared.figure(for: liftID)
    }

    var body: some View {
        if let figure {
            let palette = CueDiagramPalette(paper: paper, stage: stage)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || !playback.isPlaying)) { timeline in
                // Equatable, so the frames of a hold, which are all the same, aren't drawn again.
                CueDiagramCanvas(figure: figure, progress: playback.progress(at: timeline.date, reduceMotion: reduceMotion),
                                 palette: palette)
                    .equatable()
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
            .onTapGesture(perform: play)
            .onAppear(perform: play)
            .onDisappear { playback.stop() }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { playback.stop() }
            }
            .task(id: playback.endsAt) {
                // Rest once the last rep is home, which pauses the timeline.
                guard let endsAt = playback.endsAt else { return }
                try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
                if !Task.isCancelled { playback.stop() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Self.accessibilityLabel(cue: figure.lift.cue)))
            .accessibilityAddTraits(reduceMotion ? .isImage : .isButton)
            .accessibilityHint(Text(verbatim: reduceMotion ? "" : "Plays the movement again"))
            .accessibilityAction(.default, play)
        }
    }

    private func play() {
        playback.play(at: .now, reduceMotion: reduceMotion)
    }

    static func accessibilityLabel(cue: String) -> String {
        cue.isEmpty ? "Moving diagram" : "Moving diagram: \(cue)"
    }
}

/// One still frame of a cue diagram at `progress` (0 the start pose, 1 the end of the effort).
/// Two frames are equal when they draw the same lift's diagram at the same progress in the same colours.
struct CueDiagramCanvas: View, Equatable {
    let figure: CueDiagramFigure
    let progress: Double
    let palette: CueDiagramPalette

    static func == (lhs: CueDiagramCanvas, rhs: CueDiagramCanvas) -> Bool {
        lhs.figure.id == rhs.figure.id && lhs.progress == rhs.progress && lhs.palette == rhs.palette
    }

    var body: some View {
        Canvas { context, size in
            figure.draw(in: &context, size: size, progress: progress, palette: palette)
        }
    }
}

#if DEBUG
/// Every bundled diagram in a grid, for eyeballing in Xcode's canvas. Not reachable in the app.
private struct CueDiagramGallery: View {
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(CueDiagramLibrary.shared.liftIDs, id: \.self) { id in
                    VStack(spacing: 4) {
                        CueDiagramView(liftID: id)
                        Text(verbatim: id)
                            .font(AppFont.caption2())
                            .foregroundStyle(.hxSecondary)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .hxCard()
                }
            }
            .padding(16)
        }
        .background(Color.hxCanvas)
    }
}

#Preview("Cue diagrams, light") {
    CueDiagramGallery().preferredColorScheme(.light)
}

#Preview("Cue diagrams, dark") {
    CueDiagramGallery().preferredColorScheme(.dark)
}
#endif
