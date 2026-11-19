import XCTest
@testable import HermesMobile

/// Every lift the plan can name, each of which ships a cue diagram.
private let plannedLifts = [
    "curl-up", "side-plank", "bird-dog", "band-pull-apart", "incline-bench", "strict-press", "db-bench", "bench-dips",
    "lateral-raise", "chest-fly", "suitcase-carry", "goblet-squat", "db-rdl", "split-squat", "reverse-lunge",
    "sl-glute-bridge", "pallof-press", "wall-sit", "pull-ups", "lat-pulldown", "db-row", "face-pull", "hammer-curl",
    "farmer-carry",
]

private func library(_ json: String) throws -> CueDiagramLibrary {
    try CueDiagramLibrary(data: Data(json.utf8))
}

/// A standing side-view figure whose arm is the only thing a test moves.
private func sideLift(_ rest: String) -> String {
    #"""
    {"name":"Sample","cue":"Reach up","view":"side",
     "a":{"head":[100,32],"shoulder":[100,54],"elbow":[100,82],"hand":[100,108],"hip":[100,102],"knee":[100,142],"ankle":[100,182],"toe":[120,186]},
     \#(rest)}
    """#
}

/// The bundled file and the tolerant decode around it.
final class CueDiagramDataTests: XCTestCase {
    func testEveryPlannedLiftHasADiagram() {
        let shared = CueDiagramLibrary.shared
        for id in plannedLifts {
            XCTAssertNotNil(shared.figure(for: id), "\(id) has no diagram in CueDiagrams.json")
        }
        XCTAssertEqual(shared.liftIDs, plannedLifts.sorted(), "A new diagram joins the planned list in this test")
    }

    func testAnAliasDrawsTheLiftItNames() throws {
        let alias = try XCTUnwrap(CueDiagramLibrary.shared.figure(for: "machine-chest-fly"))
        XCTAssertEqual(alias.id, "chest-fly")
        XCTAssertNil(CueDiagramLibrary.shared.figure(for: "zercher-squat"), "A lift without a diagram has none")
        XCTAssertFalse(CueDiagramLibrary.shared.liftIDs.contains("machine-chest-fly"), "An alias is not a second diagram")
    }

    /// The bundled data uses only props, cues, muscles and points the drawing knows: nothing the
    /// file names is dropped by the tolerant decode or left undrawn.
    func testNothingInTheBundledFileIsSkipped() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "CueDiagrams", withExtension: "json"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let lifts = try XCTUnwrap(raw["lifts"] as? [String: [String: Any]])
        XCTAssertEqual(lifts.count, plannedLifts.count)
        for (id, entry) in lifts {
            let figure = try XCTUnwrap(CueDiagramLibrary.shared.figure(for: id), id)
            let lift = figure.lift
            XCTAssertEqual(lift.a.count, (entry["a"] as? [String: Any])?.count, "\(id) joints")
            XCTAssertEqual(lift.b.count, (entry["b"] as? [String: Any])?.count, "\(id) end joints")
            XCTAssertEqual(lift.props.count, (entry["props"] as? [Any])?.count ?? 0, "\(id) props")
            XCTAssertEqual(lift.cues.count, (entry["cues"] as? [Any])?.count ?? 0, "\(id) cues")
            XCTAssertEqual(lift.muscles.count, (entry["muscles"] as? [Any])?.count ?? 0, "\(id) muscles")
            XCTAssertFalse(lift.cue.isEmpty, "\(id) has a cue for VoiceOver")
            XCTAssertTrue(lift.b.keys.allSatisfy { lift.a[$0] != nil }, "\(id) moves only joints it has")

            let pose = figure.pose(at: 0)
            for muscle in lift.muscles {
                XCTAssertFalse(figure.shapes(for: muscle, in: pose).isEmpty, "\(id) can't draw \(muscle)")
            }
            var points: [CueDiagramPoint] = []
            for prop in lift.props {
                switch prop {
                case .link(_, let from, let to): points += [from, to]
                case .dumbbell(let at, _, _), .plate(let at), .handle(let at): points.append(at)
                case .floor, .wall, .box, .bench: break
                }
            }
            for cue in lift.cues {
                switch cue {
                case .arrow(let from, let to, _, _), .line(let from, let to): points += [from, to]
                case .ring(let at, _, _, _), .dot(let at): points.append(at)
                }
            }
            for point in points {
                XCTAssertNotNil(figure.point(point, in: pose), "\(id) can't place \(point)")
            }
            for joint in lift.swing {
                XCTAssertNotNil(CueDiagramSkeleton.parent[joint], "\(id) swings \(joint), which has no parent")
                XCTAssertFalse(lift.solve.contains(joint), "\(id) lists \(joint) in both swing and solve")
            }
            for joint in lift.solve {
                XCTAssertNotNil(CueDiagramSkeleton.neighbours[joint], "\(id) solves \(joint), which is not an elbow or knee")
            }
        }
    }

    func testUnknownPropsCuesAndKeysAreSkipped() throws {
        let lifts = try library(#"""
        {"version": 9, "someday": {"a": 1}, "aliases": {"other": "sample", "broken": 4},
         "lifts": {
           "sample": \#(sideLift(#"""
             "b": {"hand": [100, 2], "tail": [0, 0], "elbow": "up"},
             "tempo": "3-1-1",
             "props": [{"type": "floor"}, {"type": "trampoline", "x": 4}, {"type": "wall"}, {"type": "handle", "at": "hand"}, 7],
             "muscles": ["abs", ["shoulder", "elbow"], ["hip"], 3, "wings"],
             "cues": [{"type": "sparkle", "at": "hand"}, {"type": "dot", "at": "hand"},
                      {"type": "arrow", "from": [1, 2], "to": "hand", "when": "later", "wiggle": true}, {"type": "ring"}]
           """#)),
           "sideways": {"name": "Sideways", "cue": "Lean", "view": "above", "a": {}},
           "empty": "soon"
         }}
        """#)

        XCTAssertEqual(lifts.liftIDs, ["sample"], "A lift in a view the app can't draw is left out")
        XCTAssertEqual(lifts.figure(for: "other")?.id, "sample")
        XCTAssertNil(lifts.figure(for: "broken"))
        let figure = try XCTUnwrap(lifts.figure(for: "sample"))
        XCTAssertEqual(figure.lift.props, [.floor(from: 20, to: 180), .handle(at: .named("hand"))],
                       "An unknown prop, and a wall with no place, are skipped")
        XCTAssertEqual(figure.lift.cues, [
            .dot(at: .named("hand")),
            .arrow(from: .fixed(CGPoint(x: 1, y: 2)), to: .named("hand"), dashed: false, onEffort: false),
        ])
        XCTAssertEqual(figure.lift.muscles, [.region("abs"), .segment("shoulder", "elbow"), .region("wings")])
        XCTAssertEqual(figure.shapes(for: .region("wings"), in: figure.start), [], "An unknown region lights nothing")
        XCTAssertEqual(figure.end["hand"], CGPoint(x: 100, y: 2))
        XCTAssertEqual(figure.end["elbow"], figure.start["elbow"], "A joint with a broken end place stays put")
        XCTAssertNil(figure.end["tail"], "A joint the start pose doesn't have is not drawn")
        XCTAssertNil(figure.point(.named("tail"), in: figure.start))
    }

    func testAFileWithNothingUsableIsAnEmptyLibrary() throws {
        XCTAssertEqual(try library("{}").liftIDs, [])
        XCTAssertNil(try library(#"{"lifts": []}"#).figure(for: "curl-up"))
        XCTAssertThrowsError(try library("not json"))
    }

    func testVoiceOverReadsTheCue() {
        XCTAssertEqual(CueDiagramView.accessibilityLabel(cue: "Hug a big tree"), "Moving diagram: Hug a big tree")
        XCTAssertEqual(CueDiagramView.accessibilityLabel(cue: ""), "Moving diagram")
    }
}

/// Posing the figure: straight lines, `swing` arcs and `solve` IK.
final class CueDiagramGeometryTests: XCTestCase {
    func testAPoseIsTheStartAtZeroAndTheEndAtOne() throws {
        for id in plannedLifts {
            let figure = try XCTUnwrap(CueDiagramLibrary.shared.figure(for: id))
            let (first, last) = (figure.pose(at: 0), figure.pose(at: 1))
            XCTAssertEqual(Set(first.keys), Set(figure.lift.a.keys), id)
            for (joint, place) in figure.lift.a {
                let moved = figure.lift.b[joint] ?? place
                XCTAssertEqual(try XCTUnwrap(first[joint]), place, 0.001, "\(id) \(joint) at the start")
                XCTAssertEqual(try XCTUnwrap(last[joint]), moved, 0.001, "\(id) \(joint) at the end")
            }
        }
    }

    func testAPlainJointMovesInAStraightLine() throws {
        let figure = try XCTUnwrap(library(#"{"lifts": {"sample": \#(sideLift(#""b": {"hand": [140, 28]}"#))}}"#).figure(for: "sample"))
        XCTAssertEqual(try XCTUnwrap(figure.pose(at: 0.25)["hand"]), CGPoint(x: 110, y: 88), 0.001)
        XCTAssertEqual(figure.pose(at: 0.25)["elbow"], CGPoint(x: 100, y: 82), "A joint the end pose doesn't name stays put")
    }

    /// Segments the approved poses shorten in the middle of the rep, though both ends match: a
    /// limb turning toward the viewer on a straight path, or a foot whose ankle swings while its
    /// toe doesn't. The reference renderer draws them this way.
    private static let shortensMidRep: Set<String> = [
        "bird-dog ankle-toe", "incline-bench shoulder-elbow", "strict-press shoulder-elbow", "db-bench shoulder-elbow",
        "db-rdl hip-shoulder", "reverse-lunge ankle2-toe2", "lat-pulldown shoulder-elbow", "face-pull elbow-hand",
    ]

    /// No limb stretches or shrinks by more than 8% anywhere in the rep, unless the data says it
    /// foreshortens. `swing` and `solve` exist to keep this true on a curved path.
    func testLimbsKeepTheirLengthThroughTheRep() throws {
        var shortened: Set<String> = []
        for id in plannedLifts {
            let figure = try XCTUnwrap(CueDiagramLibrary.shared.figure(for: id))
            for bone in figure.farBones + figure.nearBones {
                if figure.lift.foreshorten.contains(where: { $0.count == 2 && bone.joins($0[0], $0[1]) }) { continue }
                func length(at progress: Double) throws -> Double {
                    let pose = figure.pose(at: progress)
                    return CueDiagramGeometry.distance(try XCTUnwrap(pose[bone.from]), try XCTUnwrap(pose[bone.to]))
                }
                let name = "\(id) \(bone.from)-\(bone.to)"
                let (first, last) = (try length(at: 0), try length(at: 1))
                XCTAssertEqual(last, first, accuracy: first * 0.08, "\(name) changes length between the poses")
                let allowed = (min(first, last) * 0.92)...(max(first, last) * 1.08)
                for step in 1..<32 {
                    let midway = try length(at: Double(step) / 32)
                    if !allowed.contains(midway) { shortened.insert(name) }
                }
            }
        }
        XCTAssertEqual(shortened, Self.shortensMidRep)
    }

    func testASwingJointKeepsToAnArcTheShortestWayRound() throws {
        let centre = CGPoint(x: 50, y: 50)
        func onCircle(_ degrees: Double, radius: Double = 10, around: CGPoint = centre) -> CGPoint {
            CGPoint(x: around.x + radius * cos(degrees * .pi / 180), y: around.y + radius * sin(degrees * .pi / 180))
        }
        let quarter = CueDiagramGeometry.swing(start: onCircle(0), startParent: centre, end: onCircle(90), endParent: centre,
                                               parent: centre, progress: 0.5)
        XCTAssertEqual(quarter, onCircle(45), 0.001)

        // From 170° to -170° is 20° through 180°, not 340° back through 0°.
        let across = CueDiagramGeometry.swing(start: onCircle(170), startParent: centre, end: onCircle(-170), endParent: centre,
                                              parent: centre, progress: 0.5)
        XCTAssertEqual(across, onCircle(180), 0.001)

        // The arc follows a parent that moves, and the bone's length is interpolated.
        let moved = CGPoint(x: 80, y: 20)
        let carried = CueDiagramGeometry.swing(start: onCircle(0), startParent: centre,
                                               end: onCircle(90, radius: 20, around: moved), endParent: moved,
                                               parent: CGPoint(x: 65, y: 35), progress: 0.5)
        XCTAssertEqual(carried, onCircle(45, radius: 15, around: CGPoint(x: 65, y: 35)), 0.001)
    }

    func testASolvedJointSitsAtBothBoneLengthsOnItsSide() {
        let hip = CGPoint(x: 0, y: 0)
        let ankle = CGPoint(x: 6, y: 0)
        XCTAssertEqual(CueDiagramGeometry.solve(hip, ankle, upper: 5, lower: 5, side: 1), CGPoint(x: 3, y: 4), 0.001)
        XCTAssertEqual(CueDiagramGeometry.solve(hip, ankle, upper: 5, lower: 5, side: -1), CGPoint(x: 3, y: -4), 0.001)
        XCTAssertGreaterThan(CueDiagramGeometry.side(hip, ankle, CGPoint(x: 3, y: 4)), 0)
        XCTAssertLessThan(CueDiagramGeometry.side(hip, ankle, CGPoint(x: 3, y: -4)), 0)
        // Out of reach, the leg is straight along the line.
        XCTAssertEqual(CueDiagramGeometry.solve(hip, CGPoint(x: 20, y: 0), upper: 5, lower: 5, side: 1), CGPoint(x: 5, y: 0), 0.001)
        // Two places on top of each other still give a finite joint.
        let stacked = CueDiagramGeometry.solve(hip, hip, upper: 5, lower: 3, side: 1)
        XCTAssertTrue(stacked.x.isFinite && stacked.y.isFinite)
    }

    /// A planted hand or foot stays planted, and the elbow or knee between bends the way the poses do.
    func testSolvedJointsBendTheSameWayAllTheWay() throws {
        for id in plannedLifts {
            let figure = try XCTUnwrap(CueDiagramLibrary.shared.figure(for: id))
            for joint in figure.lift.solve {
                let between = try XCTUnwrap(CueDiagramSkeleton.neighbours[joint])
                func side(at progress: Double) throws -> Double {
                    let pose = figure.pose(at: progress)
                    return CueDiagramGeometry.side(try XCTUnwrap(pose[between[0]]), try XCTUnwrap(pose[between[1]]),
                                                   try XCTUnwrap(pose[joint]))
                }
                let bend = try side(at: 0) + side(at: 1)
                for step in 1..<16 {
                    XCTAssertGreaterThan(try side(at: Double(step) / 16) * bend, 0, "\(id) \(joint) flips at step \(step)")
                }
            }
        }
    }

    func testTheRepHoldsEasesThereAndComesBackTheSameWay() {
        XCTAssertEqual(CueDiagramMotion.repDuration, 4)
        for hold in [0, 0.05, 0.1, 0.92, 0.96, 0.999] {
            XCTAssertEqual(CueDiagramMotion.progress(phase: hold), 0, accuracy: 1e-9, "Holds the start pose at \(hold)")
        }
        for hold in [0.48, 0.55, 0.62] {
            XCTAssertEqual(CueDiagramMotion.progress(phase: hold), 1, accuracy: 1e-9, "Holds the end of the effort at \(hold)")
        }
        // cubic-bezier(0.45, 0, 0.2, 1), as the reference renderer samples it.
        XCTAssertEqual(CueDiagramMotion.ease(0), 0)
        XCTAssertEqual(CueDiagramMotion.ease(1), 1)
        XCTAssertEqual(CueDiagramMotion.ease(0.25), 0.18765, accuracy: 1e-4)
        XCTAssertEqual(CueDiagramMotion.ease(0.5), 0.76225, accuracy: 1e-4)
        XCTAssertEqual(CueDiagramMotion.ease(0.75), 0.95864, accuracy: 1e-4)

        var previous = 0.0
        for step in 0...40 {
            let fraction = Double(step) / 40
            let there = CueDiagramMotion.progress(phase: 0.1 + 0.38 * fraction)
            let back = CueDiagramMotion.progress(phase: 0.62 + 0.30 * fraction)
            XCTAssertGreaterThanOrEqual(there, previous, "The effort never goes backward")
            XCTAssertEqual(there + back, 1, accuracy: 1e-9, "The way back mirrors the way there at \(fraction)")
            XCTAssertEqual(there, CueDiagramMotion.ease(fraction), accuracy: 1e-9)
            previous = there
        }
    }
}

/// When the diagram moves: three reps, then rest.
final class CueDiagramPlaybackTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func progress(_ playback: CueDiagramPlayback, after seconds: TimeInterval, reduceMotion: Bool = false) -> Double {
        playback.progress(at: start.addingTimeInterval(seconds), reduceMotion: reduceMotion)
    }

    func testItRestsOnTheStartPoseUntilPlayed() {
        let playback = CueDiagramPlayback()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(playback.endsAt)
        XCTAssertEqual(progress(playback, after: 2.2), 0)
    }

    func testItPlaysThreeRepsThenRests() {
        var playback = CueDiagramPlayback()
        playback.play(at: start, reduceMotion: false)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(CueDiagramPlayback.reps, 3)
        XCTAssertEqual(playback.endsAt, start.addingTimeInterval(12))

        for rep in 0..<3 {
            let began = Double(rep) * 4
            XCTAssertEqual(progress(playback, after: began + 0.2), 0, "Rep \(rep + 1) holds the start pose")
            XCTAssertEqual(progress(playback, after: began + 1.16), CueDiagramMotion.progress(phase: 0.29), accuracy: 1e-9)
            XCTAssertGreaterThan(progress(playback, after: began + 1.16), 0.5, "Rep \(rep + 1) is on its way")
            XCTAssertEqual(progress(playback, after: began + 2.2), 1, "Rep \(rep + 1) reaches the end of the effort")
            XCTAssertEqual(progress(playback, after: began + 3.9), 0, "Rep \(rep + 1) comes home")
        }
        XCTAssertEqual(progress(playback, after: 12), 0, "No fourth rep")
        XCTAssertEqual(progress(playback, after: 14.2), 0, "It rests where a fourth rep would peak")
        XCTAssertEqual(progress(playback, after: -1), 0, "A date before it started draws the start pose")

        playback.stop()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(progress(playback, after: 2.2), 0, "Stopped, it rests on the start pose")
    }

    func testPlayingAgainStartsThreeMoreReps() {
        var playback = CueDiagramPlayback()
        playback.play(at: start, reduceMotion: false)
        playback.stop()

        let again = start.addingTimeInterval(30)
        playback.play(at: again, reduceMotion: false)
        XCTAssertEqual(playback.endsAt, again.addingTimeInterval(12))
        XCTAssertEqual(progress(playback, after: 30 + 2.2), 1)
        XCTAssertEqual(progress(playback, after: 30 + 8 + 2.2), 1, "The replay has a third rep too")
        XCTAssertEqual(progress(playback, after: 30 + 12 + 2.2), 0)

        // A tap in the middle of a run starts over from the start pose.
        let midRun = again.addingTimeInterval(2.2)
        playback.play(at: midRun, reduceMotion: false)
        XCTAssertEqual(playback.progress(at: midRun, reduceMotion: false), 0)
        XCTAssertEqual(playback.endsAt, midRun.addingTimeInterval(12))
    }

    func testReduceMotionNeverPlaysAndShowsTheEndOfTheEffort() {
        var playback = CueDiagramPlayback()
        playback.play(at: start, reduceMotion: true)
        XCTAssertFalse(playback.isPlaying, "A tap does nothing under Reduce Motion")
        XCTAssertNil(playback.endsAt)
        for seconds in [0, 0.2, 2.2, 3.9, 20] {
            XCTAssertEqual(progress(playback, after: seconds, reduceMotion: true), 1, "The end pose, still, at \(seconds) s")
        }

        // Turned on in the middle of a run, the figure goes straight to the end pose.
        playback.play(at: start, reduceMotion: false)
        XCTAssertEqual(progress(playback, after: 0.2, reduceMotion: true), 1)
    }
}

private func XCTAssertEqual(_ point: CGPoint, _ expected: CGPoint, _ accuracy: Double, _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(point.x, expected.x, accuracy: accuracy, message(), file: file, line: line)
    XCTAssertEqual(point.y, expected.y, accuracy: accuracy, message(), file: file, line: line)
}
