import CoreGraphics
import Foundation

/// The cue diagrams' data (`CueDiagrams.json`): one moving mannequin per lift, as two poses, the
/// equipment, the working muscle and the coach's cue marks. Everything decodes tolerantly: a prop,
/// cue or lift the app doesn't know is left out, never an error.
struct CueDiagramFile: Decodable {
    static let defaultViewBox = CGRect(x: -10, y: -16, width: 220, height: 216)
    static let defaultFloorY = 190.0

    /// The drawing's coordinate space: x right, y down, side-view figures facing right.
    let viewBox: CGRect
    let floorY: Double
    /// Other lift ids that draw an existing diagram (`machine-chest-fly` → `chest-fly`).
    let aliases: [String: String]
    let lifts: [String: CueDiagramLift]

    private enum CodingKeys: String, CodingKey { case viewBox, floorY, aliases, lifts }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let box = (try? container.decode([Double].self, forKey: .viewBox)) ?? []
        viewBox = box.count == 4 && box[2] > 0 && box[3] > 0
            ? CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) : Self.defaultViewBox
        floorY = (try? container.decode(Double.self, forKey: .floorY)) ?? Self.defaultFloorY
        aliases = (try? container.decode([String: Lenient<String>].self, forKey: .aliases))?.compactMapValues(\.value) ?? [:]
        lifts = (try? container.decode([String: Lenient<CueDiagramLift>].self, forKey: .lifts))?.compactMapValues(\.value) ?? [:]
    }
}

/// Which skeleton a lift draws: a profile with one line for the torso, or both sides from the front.
enum CueDiagramViewKind: String, Decodable {
    case side, front
}

/// One lift's diagram, as the file writes it.
struct CueDiagramLift: Decodable {
    let name: String
    /// The primary cue, which the colour marks illustrate and VoiceOver reads.
    let cue: String
    let view: CueDiagramViewKind
    /// The start pose: every joint the figure has.
    let a: [String: CGPoint]
    /// The end of the effort: only the joints that move. A hold has none.
    let b: [String: CGPoint]
    let props: [CueDiagramProp]
    let muscles: [CueDiagramMuscle]
    let cues: [CueDiagramCue]
    /// Side view only: draws the neutral-spine dashes along the torso.
    let spine: Bool
    /// Joints that travel on an arc around their parent instead of a straight line.
    let swing: [String]
    /// Elbows or knees placed by two-bone IK between their neighbours.
    let solve: [String]
    /// Segments whose drawn length is meant to change between the poses. The drawing ignores it;
    /// the length check in the tests reads it.
    let foreshorten: [[String]]

    private enum CodingKeys: String, CodingKey {
        case name, cue, view, a, b, props, muscles, cues, spine, swing, solve, foreshorten
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        cue = (try? container.decode(String.self, forKey: .cue)) ?? ""
        view = try container.decode(CueDiagramViewKind.self, forKey: .view)
        a = Self.joints(container, .a)
        b = Self.joints(container, .b)
        props = Self.items(container, .props)
        muscles = Self.items(container, .muscles)
        cues = Self.items(container, .cues)
        spine = (try? container.decode(Bool.self, forKey: .spine)) ?? false
        swing = Self.items(container, .swing)
        solve = Self.items(container, .solve)
        foreshorten = Self.items(container, .foreshorten)
    }

    private static func joints(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String: CGPoint] {
        let raw = (try? container.decode([String: Lenient<[Double]>].self, forKey: key)) ?? [:]
        return raw.compactMapValues { entry in
            guard let xy = entry.value, xy.count >= 2 else { return nil }
            return CGPoint(x: xy[0], y: xy[1])
        }
    }

    private static func items<Item: Decodable>(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [Item] {
        ((try? container.decode([Lenient<Item>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

/// Where something sits: a fixed place, or a name that follows the figure (a joint, or an anchor
/// such as `belly`, `chest` and `hands`).
enum CueDiagramPoint: Decodable, Equatable {
    case fixed(CGPoint)
    case named(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .named(name)
            return
        }
        let xy = try container.decode([Double].self)
        guard xy.count >= 2 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A point needs x and y")
        }
        self = .fixed(CGPoint(x: xy[0], y: xy[1]))
    }

    /// Whether it rides the figure, which draws a prop over the figure instead of under it.
    var isAttached: Bool {
        if case .named = self { return true }
        return false
    }
}

/// A piece of equipment, from the schema's closed set.
enum CueDiagramProp: Decodable, Equatable {
    enum Link: String { case bar, band, cable }
    /// How a dumbbell lies: seen end-on (a disc), lengthwise across the forearm, or lengthwise upright.
    enum Lie: String { case end, cross, upright }

    case floor(from: Double, to: Double)
    case wall(x: Double)
    case box(CGRect)
    /// A pad with a leg to the floor at each fraction along it.
    case bench(from: CGPoint, to: CGPoint, posts: [Double])
    case link(Link, from: CueDiagramPoint, to: CueDiagramPoint)
    case dumbbell(at: CueDiagramPoint, lie: Lie, radius: Double)
    case plate(at: CueDiagramPoint)
    case handle(at: CueDiagramPoint)

    private enum CodingKeys: String, CodingKey { case type, span, x, y, w, h, from, to, posts, at, lie, r }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        func number(_ key: CodingKeys) throws -> Double { try container.decode(Double.self, forKey: key) }
        func point(_ key: CodingKeys) throws -> CueDiagramPoint { try container.decode(CueDiagramPoint.self, forKey: key) }
        func fixed(_ key: CodingKeys) throws -> CGPoint {
            guard case .fixed(let place) = try point(key) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Needs a fixed point")
            }
            return place
        }
        switch type {
        case "floor":
            let span = (try? container.decode([Double].self, forKey: .span)) ?? []
            self = span.count >= 2 ? .floor(from: span[0], to: span[1]) : .floor(from: 20, to: 180)
        case "wall":
            self = .wall(x: try number(.x))
        case "box":
            self = .box(CGRect(x: try number(.x), y: try number(.y), width: try number(.w), height: try number(.h)))
        case "bench":
            let posts = (try? container.decode([Double].self, forKey: .posts)) ?? [0.2, 0.8]
            self = .bench(from: try fixed(.from), to: try fixed(.to), posts: posts)
        case "bar", "band", "cable":
            self = .link(Link(rawValue: type) ?? .bar, from: try point(.from), to: try point(.to))
        case "dumbbell":
            let lie = (try? container.decode(String.self, forKey: .lie)).map { Lie(rawValue: $0) ?? .upright } ?? .end
            self = .dumbbell(at: try point(.at), lie: lie, radius: (try? number(.r)) ?? 8)
        case "plate":
            self = .plate(at: try point(.at))
        case "handle":
            self = .handle(at: try point(.at))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown prop \(type)")
        }
    }
}

/// What lights up on the effort: a limb segment between two joints, or a named part of the torso.
enum CueDiagramMuscle: Decodable, Equatable {
    case segment(String, String)
    case region(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .region(name)
            return
        }
        let joints = try container.decode([String].self)
        guard joints.count == 2 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "A segment names two joints")
        }
        self = .segment(joints[0], joints[1])
    }
}

/// A mark for the coach's cue, from the schema's closed set. Arrows and lines sit under the
/// figure, rings and dots over it.
enum CueDiagramCue: Decodable, Equatable {
    /// Dashed is the path the weight or body travels, solid a push. `onEffort` fades it in as the
    /// figure reaches the end pose.
    case arrow(from: CueDiagramPoint, to: CueDiagramPoint, dashed: Bool, onEffort: Bool)
    /// A thing to aim at or stay between.
    case line(from: CueDiagramPoint, to: CueDiagramPoint)
    /// A dashed ellipse: the brace, a grip. `pulse` tightens it by a fifth on the effort.
    case ring(at: CueDiagramPoint, rx: Double, ry: Double, pulse: Bool)
    /// A target dot that rides a joint or anchor.
    case dot(at: CueDiagramPoint)

    private enum CodingKeys: String, CodingKey { case type, from, to, dashed, when, at, rx, ry, pulse }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        func point(_ key: CodingKeys) throws -> CueDiagramPoint { try container.decode(CueDiagramPoint.self, forKey: key) }
        func flag(_ key: CodingKeys) -> Bool { (try? container.decode(Bool.self, forKey: key)) ?? false }
        switch type {
        case "arrow":
            let when = try? container.decode(String.self, forKey: .when)
            self = .arrow(from: try point(.from), to: try point(.to), dashed: flag(.dashed), onEffort: when == "effort")
        case "line":
            self = .line(from: try point(.from), to: try point(.to))
        case "ring":
            self = .ring(at: try point(.at), rx: (try? container.decode(Double.self, forKey: .rx)) ?? 15,
                         ry: (try? container.decode(Double.self, forKey: .ry)) ?? 7, pulse: flag(.pulse))
        case "dot":
            self = .dot(at: try point(.at))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown cue \(type)")
        }
    }
}

/// Decodes a value or, when it doesn't fit, nothing, so one unknown entry never fails its list.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Every diagram the app ships, parsed once and looked up by lift id.
struct CueDiagramLibrary {
    /// The bundled diagrams. Parsed on first use and kept for the life of the app.
    static let shared = CueDiagramLibrary(bundle: .main)

    private let figures: [String: CueDiagramFigure]
    private let aliases: [String: String]

    init(data: Data) throws {
        let file = try JSONDecoder().decode(CueDiagramFile.self, from: data)
        figures = Dictionary(uniqueKeysWithValues: file.lifts.map { id, lift in
            (id, CueDiagramFigure(id: id, lift: lift, viewBox: file.viewBox, floorY: file.floorY))
        })
        aliases = file.aliases
    }

    /// The diagrams in `CueDiagrams.json`, or none when the file is missing or unreadable.
    init(bundle: Bundle) {
        let bundled = bundle.url(forResource: "CueDiagrams", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? CueDiagramLibrary(data: $0) }
        figures = bundled?.figures ?? [:]
        aliases = bundled?.aliases ?? [:]
    }

    /// Lift ids that have their own diagram, in alphabetical order.
    var liftIDs: [String] { figures.keys.sorted() }

    /// The diagram for a lift, by its own id or an alias; nil when it has none.
    func figure(for liftID: String) -> CueDiagramFigure? {
        figures[liftID] ?? aliases[liftID].flatMap { figures[$0] }
    }
}
