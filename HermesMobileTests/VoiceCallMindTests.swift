import XCTest
@testable import HermesMobile

final class MindNetworkTests: XCTestCase {
    /// Two knots with a line of stars between them, a few apart, and a far-off star.
    private func line() -> MindNetwork {
        var points = (0...10).map { SIMD3(Double($0) * 0.1, 0, 0) }
        points.append(SIMD3(5, 5, 5))
        return MindNetwork(points: points, knots: [SIMD3(0, 0, 0), SIMD3(1, 0, 0)], bends: Array(repeating: 0.5, count: points.count))
    }

    func testJoinsNearNeighborsOnlyAndBothWays() {
        let network = line()
        XCTAssertTrue(network.neighbors[0].contains(1))
        XCTAssertTrue(network.neighbors[1].contains(0))
        XCTAssertTrue(network.neighbors[11].isEmpty)
        XCTAssertTrue(network.links.allSatisfy { $0.a != $0.b })
        XCTAssertTrue(network.neighbors.allSatisfy { $0.count <= MindNetwork.fanOut * 2 })
    }

    func testHopsCountFromEachHubAndRoutesJoinTheKnots() {
        let network = line()
        XCTAssertEqual(network.hubs, [0, 10])
        XCTAssertEqual(network.hops[0][0], 0)
        XCTAssertEqual(network.hops[1][10], 0)
        XCTAssertEqual(network.hops[0][11], MindNetwork.unreachable)
        let route = network.routes[0]
        XCTAssertEqual(route.first, 0)
        XCTAssertEqual(route.last, 10)
        // Each step of the route is one fiber.
        for (a, b) in zip(route, route.dropFirst()) { XCTAssertTrue(network.neighbors[a].contains(b)) }
    }

    func testBreadthFirstFromSeveralSources() {
        let hops = line().breadthFirst(from: [0, 10])
        XCTAssertEqual(hops[0], 0)
        XCTAssertEqual(hops[10], 0)
        XCTAssertLessThanOrEqual(hops[5], 3)
    }
}

final class MindLatticeTests: XCTestCase {
    func testPointsSitOnTheSphereWithAFewNeighborsEach() {
        let lattice = MindLattice(count: 120, radius: 0.97)
        XCTAssertEqual(lattice.points.count, 120)
        for point in lattice.points { XCTAssertEqual((point * point).sum().squareRoot(), 0.97, accuracy: 0.0001) }
        var degree = Array(repeating: 0, count: 120)
        for edge in lattice.edges {
            degree[edge.a] += 1
            degree[edge.b] += 1
        }
        XCTAssertTrue(degree.allSatisfy { $0 >= 4 })
    }
}

final class MindSeekersTests: XCTestCase {
    func testSeekersStepAlongFibersAndMarkWhereTheyHaveBeen() {
        let points = (0..<40).map { SIMD3(Double($0 % 8) * 0.1, Double($0 / 8) * 0.1, 0) }
        let network = MindNetwork(points: points, knots: [points[0], points[39]], bends: Array(repeating: 0.5, count: 40))
        var rng = StarfieldRandom(seed: 3)
        var seekers = MindSeekers()
        seekers.reset(count: 3, starCount: points.count, at: 0, using: &rng)
        var clock = 0.0
        var previous = seekers.walkers.map(\.at)
        for _ in 0..<200 {
            clock += 1.0 / 60
            seekers.step(at: clock, network: network, using: &rng)
            for (index, walker) in seekers.walkers.enumerated() where walker.at != previous[index] {
                XCTAssertTrue(network.neighbors[previous[index]].contains(walker.at), "a seeker jumped instead of walking")
                XCTAssertEqual(seekers.visited[walker.at], clock)
            }
            previous = seekers.walkers.map(\.at)
        }
        XCTAssertGreaterThan(seekers.visited.filter { $0 > 0 }.count, 10)
    }
}

final class VoicePulsesTests: XCTestCase {
    /// Feeds `levels` one frame apart (60 fps) from `start`; returns the clock after the last.
    private func feed(_ pulses: inout VoicePulses, _ levels: [Double], from start: Double = 0) -> Double {
        var clock = start
        for level in levels {
            pulses.step(level: level, at: clock, dt: 1.0 / 60)
            clock += 1.0 / 60
        }
        return clock
    }

    func testOnePulsePerPhraseAndNoneForASteadyVoice() {
        var pulses = VoicePulses(rise: 0.16, spacing: 0.9, life: 2.4)
        var clock = feed(&pulses, Array(repeating: 0.7, count: 30))
        XCTAssertEqual(pulses.started.count, 1)
        // A word inside the same phrase shares its pulse.
        clock = feed(&pulses, Array(repeating: 0.1, count: 6) + Array(repeating: 0.7, count: 6), from: clock)
        XCTAssertEqual(pulses.started.count, 1)
        // After the spacing, the next rise is the next phrase.
        clock = feed(&pulses, Array(repeating: 0.1, count: 30) + Array(repeating: 0.7, count: 6), from: clock)
        XCTAssertEqual(pulses.started.count, 2)
        XCTAssertEqual(pulses.started.last?.strength ?? 0, 0.82, accuracy: 0.001)
        _ = feed(&pulses, Array(repeating: 0, count: 180), from: clock)
        XCTAssertTrue(pulses.started.isEmpty)
    }

    func testCutOffDropsThemAtOnce() {
        var pulses = VoicePulses(rise: 0.12, spacing: 0.22, life: 1.6)
        XCTAssertTrue(pulses.step(level: 1, at: 0, dt: 1.0 / 60))
        pulses.step(level: 0, at: 0.02, dt: 1.0 / 60, cutOff: true)
        XCTAssertTrue(pulses.started.isEmpty)
    }
}
