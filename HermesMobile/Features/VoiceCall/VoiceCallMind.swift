import Foundation

/// The call constellation's wiring, rebuilt whenever the cloud takes a new shape: every star
/// joined to its nearest neighbors (the synapses), how many hops each star is from each knot's hub,
/// and the route through the network from one knot to the next. Signals in the starfield travel
/// along it hop by hop.
struct MindNetwork {
    struct Link {
        let a: Int
        let b: Int
        /// How far the fiber bows to one side, as a fraction of its length.
        let bend: Double
    }

    static let unreachable = UInt8.max
    /// Stars farther apart than this (in cloud radii) are never joined.
    static let reach = 0.22
    /// Each star joins at most this many of its nearest neighbors.
    static let fanOut = 3

    private(set) var links: [Link] = []
    private(set) var neighbors: [[Int]] = []
    /// The star nearest each knot.
    private(set) var hubs: [Int] = []
    /// `hops[k][i]`: hops from knot `k`'s hub to star `i`, or `unreachable`.
    private(set) var hops: [[UInt8]] = []
    /// `routes[k]`: the stars from knot `k`'s hub to knot `k + 1`'s, in order.
    private(set) var routes: [[Int]] = []

    init() {}

    /// Wires `points` (one per star, in cloud space) around `knots`. `bends` gives each star's
    /// fiber bow, so the same cloud always draws the same fibers.
    init(points: [SIMD3<Double>], knots: [SIMD3<Double>], bends: [Double]) {
        let count = points.count
        // A grid of `reach`-sized cells over the cloud (which stays inside radius ~1.3), so each
        // star only checks the 27 cells around it. Flat arrays: this runs on the main thread.
        let span = 7, side = span * 2 + 1
        func cell(_ value: Double) -> Int { min(max(Int((value / Self.reach).rounded(.down)) + span, 0), side - 1) }
        var cellOf = [Int](repeating: 0, count: count)
        var buckets = Array(repeating: [Int](), count: side * side * side)
        for (index, point) in points.enumerated() {
            let key = (cell(point.x) * side + cell(point.y)) * side + cell(point.z)
            cellOf[index] = key
            buckets[key].append(index)
        }

        var adjacency = Array(repeating: [Int](), count: count)
        let reach2 = Self.reach * Self.reach
        for i in 0..<count {
            let point = points[i]
            let cz = cellOf[i] % side, cy = (cellOf[i] / side) % side, cx = cellOf[i] / (side * side)
            // The `fanOut` nearest within reach, kept sorted by hand.
            var best: [(d2: Double, j: Int)] = []
            best.reserveCapacity(Self.fanOut + 1)
            for x in max(cx - 1, 0)...min(cx + 1, side - 1) {
                for y in max(cy - 1, 0)...min(cy + 1, side - 1) {
                    for z in max(cz - 1, 0)...min(cz + 1, side - 1) {
                        for j in buckets[(x * side + y) * side + z] where j != i {
                            let d = points[j] - point
                            let d2 = d.x * d.x + d.y * d.y + d.z * d.z
                            guard d2 <= reach2, best.count < Self.fanOut || d2 < best[best.count - 1].d2 else { continue }
                            let at = best.firstIndex { $0.d2 > d2 } ?? best.count
                            best.insert((d2, j), at: at)
                            if best.count > Self.fanOut { best.removeLast() }
                        }
                    }
                }
            }
            for (_, j) in best where !adjacency[i].contains(j) {
                links.append(Link(a: i, b: j, bend: ((i < bends.count ? bends[i] : 0.5) - 0.5) * 0.5))
                adjacency[i].append(j)
                adjacency[j].append(i)
            }
        }
        neighbors = adjacency

        hubs = knots.map { knot in
            var hub = 0, nearest = Double.infinity
            for (index, point) in points.enumerated() {
                let d = point - knot
                let d2 = d.x * d.x + d.y * d.y + d.z * d.z
                if d2 < nearest {
                    nearest = d2
                    hub = index
                }
            }
            return hub
        }
        hops = hubs.map { breadthFirst(from: [$0]) }
        routes = (0..<max(knots.count - 1, 0)).map { k in route(from: hubs[k], toward: k + 1) }
    }

    /// Hops from the nearest of `sources` to every star.
    func breadthFirst(from sources: [Int]) -> [UInt8] {
        var result = Array(repeating: Self.unreachable, count: neighbors.count)
        var queue: [Int] = []
        for source in sources where source < result.count {
            result[source] = 0
            queue.append(source)
        }
        var head = 0
        while head < queue.count {
            let i = queue[head]
            head += 1
            guard result[i] < Self.unreachable - 1 else { continue }
            for j in neighbors[i] where result[j] == Self.unreachable {
                result[j] = result[i] + 1
                queue.append(j)
            }
        }
        return result
    }

    /// Walks from `start` down the hop count toward knot `k`'s hub; just `start` when cut off.
    private func route(from start: Int, toward k: Int) -> [Int] {
        let toward = hops[k]
        var path = [start]
        var at = start
        while toward[at] > 0, toward[at] != Self.unreachable, path.count < 120 {
            guard let next = neighbors[at].min(by: { toward[$0] < toward[$1] }), toward[next] < toward[at] else { break }
            path.append(next)
            at = next
        }
        return path
    }
}

/// The mind's membrane: points spread evenly over a sphere (a Fibonacci lattice), each joined
/// to its four nearest, so the cloud reads as a ball with a geodesic net around it.
struct MindLattice {
    struct Edge {
        let a: Int
        let b: Int
    }

    static let shared = MindLattice(count: 220, radius: 0.97)

    let points: [SIMD3<Double>]
    let edges: [Edge]
    let radius: Double

    init(count: Int, radius: Double) {
        self.radius = radius
        let points: [SIMD3<Double>] = (0..<count).map { index in
            let y = 1 - (Double(index) + 0.5) / Double(count) * 2
            let ring = (1 - y * y).squareRoot(), angle = Double(index) * 2.399963
            return SIMD3(cos(angle) * ring, y, sin(angle) * ring) * radius
        }
        var joined = Set<Int>()
        var edges: [Edge] = []
        for (i, point) in points.enumerated() {
            var nearest: [(d2: Double, j: Int)] = []
            for (j, other) in points.enumerated() where j != i {
                let d = other - point
                let d2 = d.x * d.x + d.y * d.y + d.z * d.z
                guard nearest.count < 4 || d2 < nearest[3].d2 else { continue }
                nearest.insert((d2, j), at: nearest.firstIndex { $0.d2 > d2 } ?? nearest.count)
                if nearest.count > 4 { nearest.removeLast() }
            }
            for (_, j) in nearest where joined.insert(min(i, j) * count + max(i, j)).inserted {
                edges.append(Edge(a: i, b: j))
            }
        }
        self.points = points
        self.edges = edges
    }
}

/// Thinking's search: a few probes walk the network a link at a time, each heading for the
/// neighbor visited longest ago, now and then pausing on a busy star. Stars light as they're visited.
struct MindSeekers {
    struct Walker {
        var at: Int
        var next: Int?
        var stepStart: Double
        /// The last stars it stepped through, oldest first.
        var trail: [Int] = []
        var dwellUntil = -Double.infinity
    }

    static let stepSeconds = 0.14
    static let trailLength = 14
    static let dwellSeconds = 0.4

    private(set) var walkers: [Walker] = []
    /// When each star was last visited.
    private(set) var visited: [Double] = []

    /// `count` probes at random stars of a network of `starCount` stars.
    mutating func reset<G: RandomNumberGenerator>(count: Int, starCount: Int, at clock: Double, using rng: inout G) {
        visited = Array(repeating: -.infinity, count: starCount)
        walkers = (0..<count).map { _ in Walker(at: Int.random(in: 0..<max(starCount, 1), using: &rng), stepStart: clock) }
    }

    mutating func step<G: RandomNumberGenerator>(at clock: Double, network: MindNetwork, using rng: inout G) {
        guard !visited.isEmpty else { return }
        for index in walkers.indices {
            var walker = walkers[index]
            defer { walkers[index] = walker }
            guard clock >= walker.dwellUntil else { continue }
            let options = walker.at < network.neighbors.count ? network.neighbors[walker.at] : []
            if walker.next == nil {
                guard !options.isEmpty else {
                    walker.at = Int.random(in: 0..<visited.count, using: &rng)
                    continue
                }
                // Least recently visited, with a little randomness so probes don't march in step.
                walker.next = options.min { a, b in
                    visited[a] + Double.random(in: 0..<0.4, using: &rng) < visited[b] + Double.random(in: 0..<0.4, using: &rng)
                }
                walker.stepStart = clock
            }
            guard let next = walker.next, clock - walker.stepStart >= Self.stepSeconds else { continue }
            walker.trail.append(walker.at)
            if walker.trail.count > Self.trailLength { walker.trail.removeFirst() }
            walker.at = next
            walker.next = nil
            visited[next] = clock
            if network.neighbors[next].count >= 4, Double.random(in: 0..<1, using: &rng) < 0.08 {
                walker.dwellUntil = clock + Self.dwellSeconds
            }
        }
    }
}

/// Beats in a loudness level: each rise of at least `rise` over the last dip starts one, at
/// most one per `spacing`, so a steady sound starts none. The call's voice makes one per phrase
/// (spacing 0.9 s) and the user's voice one per word.
struct VoicePulses {
    let rise: Double
    let spacing: Double
    let life: Double

    /// When each beat started and how loud it was, 0.4...1.
    private(set) var started: [(at: Double, strength: Double)] = []
    private var floor = 0.0

    init(rise: Double, spacing: Double, life: Double) {
        self.rise = rise
        self.spacing = spacing
        self.life = life
    }

    /// Feeds one frame's level; returns true when it starts a beat. `cutOff` drops them all.
    @discardableResult
    mutating func step(level: Double, at clock: Double, dt: Double, cutOff: Bool = false) -> Bool {
        started.removeAll { clock - $0.at > life || cutOff }
        var began = false
        if level - floor > rise, clock - (started.last?.at ?? -.infinity) > spacing {
            started.append((clock, 0.4 + 0.6 * min(level, 1)))
            floor = level
            began = true
        }
        // The floor follows a dip at once and creeps back up, so the next rise counts from it.
        floor = min(level, floor + dt * 1.5)
        return began
    }

    mutating func reset() {
        started = []
        floor = 0
    }
}
