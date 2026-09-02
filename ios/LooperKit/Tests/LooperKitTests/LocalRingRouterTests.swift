import XCTest
@testable import LooperKit

/// The ported ring generator: the one the service actually answers walkers with.
final class LocalRingRouterTests: XCTestCase {

    private func ground(size: Int = 15, spacing: Double = 200) -> (LocalWalkingGraph, LocalEdgeIndex) {
        let (graph, _) = LocalWalkingGraphBuilder.build(from: SyntheticOSM.grid(size: size, spacingMetres: spacing))
        return (graph, LocalEdgeIndex(graph: graph))
    }

    // MARK: - Deterministic candidates

    /// A walker who reloads is offered the walks they were looking at, not a
    /// fresh shuffle. Only `variation` moves the seed.
    func testTheSameDoorstepAndTargetGiveTheSameBearingsForever() {
        let seed = LocalLoopRouter.ringSeed(lon: -4.4816, lat: 54.1506, targetMetres: 5000, variation: 0)
        let again = LocalLoopRouter.ringSeed(lon: -4.4816, lat: 54.1506, targetMetres: 5000, variation: 0)
        XCTAssertEqual(seed, again)
        let moved = LocalLoopRouter.ringSeed(lon: -4.4816, lat: 54.1506, targetMetres: 5000, variation: 1)
        XCTAssertNotEqual(seed, moved, "a variation is the one thing that reshuffles")

        // Rounded to about 11 m before it reaches the seed, so GPS drift of a
        // few metres does not reshuffle the answer.
        let drifted = LocalLoopRouter.ringSeed(lon: -4.48161, lat: 54.15061, targetMetres: 5000, variation: 0)
        XCTAssertEqual(seed, drifted)

        let attempts = LocalLoopRouter.ringAttempts(seed: seed)
        XCTAssertEqual(attempts.count, LocalLoopRouter.ringCandidateCount)
        XCTAssertEqual(
            attempts.map(\.initialBearing),
            LocalLoopRouter.ringAttempts(seed: seed).map(\.initialBearing)
        )
    }

    /// Bearings come in mirrored pairs: the same three streets can make a good
    /// loop one way round and an awkward one the other.
    func testEveryBearingIsTriedBothWaysRound() {
        let attempts = LocalLoopRouter.ringAttempts(seed: 12345)
        for pair in stride(from: 0, to: attempts.count, by: 2) {
            XCTAssertEqual(attempts[pair].initialBearing, attempts[pair + 1].initialBearing)
            XCTAssertEqual(attempts[pair].direction, .clockwise)
            XCTAssertEqual(attempts[pair + 1].direction, .counterClockwise)
        }
        // Slots evenly around the compass, nudged by no more than the jitter.
        let pairs = attempts.count / 2
        for pair in 0..<pairs {
            let slot = Double(pair) * 360 / Double(pairs)
            var offset = abs(LocalGeo.normaliseBearing(attempts[pair * 2].initialBearing - slot))
            if offset > 180 { offset = 360 - offset }
            XCTAssertLessThanOrEqual(offset, LocalLoopRouter.ringBearingJitterDegrees + 0.001)
        }
    }

    /// The generator can stop partway, so any prefix of the sweep has to be a
    /// sample of the whole compass rather than of one side of it.
    func testAnyPrefixOfTheSweepAlreadyCoversTheCompass() {
        let attempts = LocalLoopRouter.ringSpreadAcrossCompass(LocalLoopRouter.ringAttempts(seed: 99))
        XCTAssertEqual(
            Set(attempts.map(\.pair)), Set(0..<(LocalLoopRouter.ringCandidateCount / 2)),
            "a permutation: the same attempts, in a different order"
        )
        // Six attempts is three bearings; they should not be three neighbours.
        let firstSix = attempts.prefix(6).map(\.initialBearing)
        let octants = Set(firstSix.map { LocalGeo.bearingOctant($0) })
        XCTAssertGreaterThanOrEqual(octants.count, 3, "the first three bearings sit in three different octants")
    }

    // MARK: - Corridors

    /// The walker's complaint, as a test: a few metres up one side of the road
    /// and back down the other. The two sides are different ways, so an edge
    /// penalty says nothing about the one across the carriageway — only a
    /// corridor does. See `LocalLoopRouter.ringCorridor`.
    func testGroundBesideAWalkedStreetIsInsideItsCorridor() {
        // Two parallel streets 15 m apart, and a third 300 m away.
        let centre = SyntheticOSM.douglas
        func row(_ id: Int64, offsetMetres: Double) -> ([OSMNode], OSMWay) {
            var nodes: [OSMNode] = []
            for step in 0...4 {
                let along = LocalGeo.destination(
                    lat: centre.lat, lon: centre.lng, metres: Double(step) * 100, bearing: 90)
                let placed = LocalGeo.destination(
                    lat: along.lat, lon: along.lon, metres: offsetMetres, bearing: 0)
                nodes.append(OSMNode(id: id * 100 + Int64(step), lat: placed.lat, lon: placed.lon))
            }
            return (nodes, OSMWay(id: id, nodes: nodes.map(\.id), tags: ["highway": "residential"]))
        }
        let (aNodes, aWay) = row(1, offsetMetres: 0)
        let (bNodes, bWay) = row(2, offsetMetres: 15)
        let (cNodes, cWay) = row(3, offsetMetres: 300)
        let data = OSMData(nodes: aNodes + bNodes + cNodes, ways: [aWay, bWay, cWay])
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)

        let walked = aNodes.map { Point($0.lon, $0.lat) }
        let corridor = LocalLoopRouter().ringCorridor(around: walked, graph: graph, index: index)

        func edges(ofWay way: Int64) -> Set<Int32> {
            Set((0..<graph.edgeMetres.count).filter { graph.edgeWayID[$0] == way }.map(Int32.init))
        }
        XCTAssertFalse(edges(ofWay: 1).isEmpty)
        XCTAssertTrue(edges(ofWay: 1).isSubset(of: corridor), "the ground walked is in its own corridor")
        XCTAssertTrue(
            edges(ofWay: 2).isSubset(of: corridor),
            "the other side of the road, 15 m away, is the ground the walker complains about"
        )
        XCTAssertTrue(
            edges(ofWay: 3).isDisjoint(with: corridor),
            "a street 300 m away is a different street"
        )
    }

    // MARK: - Whole walks

    func testItOffersLoopsThatPassTheGate() throws {
        let (graph, index) = ground()
        let result = try LocalLoopRouter().findRingLoops(
            .init(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 2000
            ),
            in: graph, index: index
        )
        XCTAssertEqual(result.routes.count, 3)
        for route in result.routes {
            XCTAssertLessThanOrEqual(
                abs(route.distanceMeters / 2000 - 1), RouteQuality.maxDistanceError,
                "\(route.name) is \(Int(route.distanceMeters))m against a 2000m ask"
            )
            XCTAssertGreaterThan(route.steps.count, 1)
            let line = route.geometry.coordinates
            XCTAssertEqual(line.first, line.last, "a loop ends where it began")
        }
        XCTAssertEqual(
            Set(result.routes.map(\.name)).count, result.routes.count,
            "three walks a walker can tell apart by name"
        )
    }

    /// Deterministic, and moved only by the variation — the same property the
    /// searched engine has, by the same means.
    func testAVariationFindsDifferentWalks() throws {
        let (graph, index) = ground()
        func offers(variation: Int) throws -> [String] {
            try LocalLoopRouter().findRingLoops(
                .init(
                    lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 2000, variation: variation
                ),
                in: graph, index: index
            ).routes.map { $0.geometry.coordinates.map { p in "\(p.lng),\(p.lat)" }.joined() }
        }
        XCTAssertEqual(try offers(variation: 0), try offers(variation: 0), "the same ask twice is the same answer")
        XCTAssertNotEqual(try offers(variation: 0), try offers(variation: 7))
    }

    /// A walk already offered is taken out of the pool before the selector sees
    /// it, which is the only place removing it can produce a different walk.
    func testARefreshOffersGroundTheWalkerHasNotSeen() throws {
        let (graph, index) = ground()
        let first = try LocalLoopRouter().findRingLoops(
            .init(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 2000
            ),
            in: graph, index: index
        )
        let refreshed = try LocalLoopRouter().findRingLoops(
            .init(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 2000, variation: 1,
                exclude: first.routes.map(\.geometry.coordinates)
            ),
            in: graph, index: index
        )
        XCTAssertGreaterThan(refreshed.routes.count, 0)
        XCTAssertGreaterThan(refreshed.diagnostics.excludedAsAlreadySeen, 0, "the pool was filtered, not the answer")
    }
}
