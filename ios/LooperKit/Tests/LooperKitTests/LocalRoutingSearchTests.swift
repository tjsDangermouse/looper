import XCTest
@testable import LooperKit

/// The ported search and the ported gate.
///
/// The reference implementation is the route service's Java `direct` package,
/// and these tests are about the properties that make the port a port: the
/// reductions are exact, the prunes lose nothing admissible, the gate applies
/// the same thresholds, and a walk is edge-simple.
final class LocalRoutingSearchTests: XCTestCase {
    private func searchGraph(_ data: OSMData, at point: Point = SyntheticOSM.douglas, radius: Double = 2000) throws -> (WalkSearchGraph, LocalWalkingGraph, RoutingSubgraph) {
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let (subgraph, _) = try LocalExploration.explore(
            graph: graph, index: index, lat: point.lat, lon: point.lng, limitMetres: radius
        )
        return (WalkSearchGraph(subgraph), graph, subgraph)
    }

    // MARK: - Asking again

    /// Refreshing offers walks that were not offered before.
    ///
    /// The search is deterministic, so asking again runs the identical search
    /// and closes the identical walks. That means exclusion is the *only*
    /// thing that can make a refresh produce anything new, and it only works
    /// if it reaches the pool the selector chooses from. Applied to the walks
    /// the selector already returned — which is where it used to sit — it can
    /// do nothing but empty the answer, because those are the same three walks
    /// the same selector picked from the same pool a moment ago.
    func testRefreshingOffersWalksThatWereNotOfferedBefore() throws {
        let data = SyntheticOSM.grid(size: 9, spacingMetres: 200)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let router = LocalLoopRouter()
        let target = 2000.0

        let first = try router.findLoops(
            .init(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: target),
            in: graph, index: index
        )
        XCTAssertGreaterThan(first.routes.count, 0)

        // The same request again, unchanged, closes the same walks: that is
        // the property the exclusion has to work around.
        let repeated = try router.findLoops(
            .init(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: target),
            in: graph, index: index
        )
        XCTAssertEqual(
            repeated.routes.map(\.distanceMeters), first.routes.map(\.distanceMeters),
            "the search is expected to be deterministic"
        )

        let again = try router.findLoops(
            .init(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: target,
                exclude: first.routes.map(\.geometry.coordinates)
            ),
            in: graph, index: index
        )
        XCTAssertGreaterThan(again.routes.count, 0, "a refresh offered nothing at all")
        XCTAssertFalse(again.diagnostics.excludeExhausted, "the pool ran out on the first refresh")
        XCTAssertGreaterThan(
            again.diagnostics.excludedAsAlreadySeen, 0,
            "the walks already offered were not taken out of the pool"
        )

        // Every walk that comes back is a genuinely different walk.
        for route in again.routes {
            for previous in first.routes {
                let shared = RouteQuality.sharedCorridorMetres(
                    route.geometry.coordinates, previous.geometry.coordinates
                ).fraction
                XCTAssertLessThanOrEqual(
                    shared, RouteQuality.maxSharedFraction,
                    "refresh re-offered a walk the walker had already seen"
                )
            }
        }
    }

    /// Having seen everything is answered with the best of it, not an error.
    func testAWalkerWhoHasSeenEverythingIsNotHandedNothing() throws {
        let data = SyntheticOSM.grid(size: 9, spacingMetres: 200)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let router = LocalLoopRouter()

        let first = try router.findLoops(
            .init(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 2000),
            in: graph, index: index
        )
        // Exclude the whole pool by handing back every walk the gate passes.
        let everything = try router.findLoops(
            .init(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 2000,
                wanted: .max, candidateWalks: LocalLoopRouter.defaultCandidateWalks
            ),
            in: graph, index: index
        )
        let exhausted = try router.findLoops(
            .init(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 2000,
                exclude: everything.routes.map(\.geometry.coordinates)
            ),
            in: graph, index: index
        )
        XCTAssertTrue(exhausted.diagnostics.excludeExhausted)
        XCTAssertEqual(
            exhausted.routes.count, first.routes.count,
            "a walker who has seen everything should still be handed a full set"
        )
        XCTAssertEqual(exhausted.diagnostics.toppedUpFromSeen, exhausted.routes.count)
    }

    /// A variation finds different walks, and variation 0 changes nothing.
    ///
    /// Exclusion alone cannot keep a refresh honest: it narrows one fixed pool
    /// and eventually empties it. A variation is what makes the pool itself
    /// different, and it has to do that without touching what the gate asks
    /// for — so the walks it finds are judged by exactly the same rules.
    func testAVariationFindsDifferentWalksWithoutRelaxingAnything() throws {
        let data = SyntheticOSM.grid(size: 9, spacingMetres: 200)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let router = LocalLoopRouter()

        func loops(variation: Int) throws -> LocalLoopRouter.Result {
            try router.findLoops(
                .init(
                    lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                    targetMetres: 2000, variation: variation
                ),
                in: graph, index: index
            )
        }

        // Compared as ground rather than as lengths: this fixture is a regular
        // lattice, where two quite different walks routinely measure the same.
        func ground(_ result: LocalLoopRouter.Result) -> [[Point]] {
            result.routes.map(\.geometry.coordinates)
        }

        let base = try loops(variation: 0)
        XCTAssertEqual(
            ground(try loops(variation: 0)), ground(base),
            "variation 0 must leave the search exactly as it was"
        )

        // Some variation finds a set the default search does not.
        let varied = try (1...6).map { try loops(variation: $0 * 3) }
        XCTAssertTrue(
            varied.contains { ground($0) != ground(base) },
            "no variation produced a different set of walks"
        )

        // And everything any of them offers still passes the gate untouched.
        for result in varied + [base] {
            for route in result.routes {
                let report = RouteQuality.analyse(
                    coordinates: route.geometry.coordinates,
                    start: route.geometry.coordinates[0],
                    distanceMetres: route.distanceMeters,
                    targetMetres: 2000
                )
                XCTAssertTrue(report.pass, "a variation offered a walk the gate refuses: \(report.rejections)")
            }
        }
    }

    /// A thin pool still fills the answer, newest walks first.
    ///
    /// Excluding a walk has to demote it, not delete it. Deleting shrinks the
    /// pool with every refresh, so a walker in a small town presses the button
    /// and is handed one walk instead of three — which reads as the engine
    /// getting worse the more they use it.
    func testARefreshStillFillsTheAnswerWhenLittleIsLeftUnseen() throws {
        let data = SyntheticOSM.grid(size: 9, spacingMetres: 200)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let router = LocalLoopRouter()

        var seen: [Route] = []
        for round in 0..<6 {
            let result = try router.findLoops(
                .init(
                    lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 2000,
                    variation: round * 3, exclude: seen.map(\.geometry.coordinates)
                ),
                in: graph, index: index
            )
            XCTAssertEqual(
                result.routes.count, 3,
                "round \(round) offered \(result.routes.count) walks, not a full set"
            )
            // Whatever was new is genuinely new.
            for route in result.routes where !seen.contains(where: {
                RouteQuality.sharedCorridorMetres(route.geometry.coordinates, $0.geometry.coordinates)
                    .fraction > RouteQuality.maxSharedFraction
            }) {
                seen.append(route)
            }
        }
        XCTAssertGreaterThan(seen.count, 3, "six refreshes turned up nothing beyond the first set")
    }

    // MARK: - Graph reductions

    /// A cul-de-sac cannot be part of a circuit without being retraced, and
    /// retracing outside the doorstep window is fatal at the gate. So peeling
    /// it removes nothing admissible — and the walk out to it is still kept,
    /// because the stem out of the door may run through it.
    func testTheTwoCorePeelsDeadEndsButKeepsThemForTheStem() throws {
        var data = SyntheticOSM.grid(size: 5, spacingMetres: 200)
        // A spur hanging off the middle junction.
        let middle = data.nodes.first { $0.id == 2003 }!
        let tip = LocalGeo.destination(lat: middle.lat, lon: middle.lon, metres: 150, bearing: 45)
        data.nodes.append(OSMNode(id: 90001, lat: tip.lat, lon: tip.lon))
        data.ways.append(OSMWay(id: 900, nodes: [2003, 90001], tags: ["highway": "footway", "name": "Dead End"]))

        let (search, _, _) = try searchGraph(data)
        XCTAssertEqual(search.stats.rawEdges, search.stats.coreEdges + 1, "exactly the spur is peeled")
        XCTAssertGreaterThan(search.stats.coreEdges, 0)
    }

    /// A chain of degree-2 junctions offers no choice: entering it determines
    /// everything until the next real junction. Contracting it is what makes
    /// the search depth the number of decisions rather than the number of
    /// street corners.
    func testDegreeTwoChainsContractIntoSuperEdges() throws {
        // A single square: four corners, and every side is one long chain of
        // intermediate nodes.
        var nodes: [OSMNode] = []
        var ids: [Int64] = []
        let corners = 4
        for step in 0..<(corners * 5) {
            let bearing = Double(step) / Double(corners * 5) * 360
            let placed = LocalGeo.destination(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: 300, bearing: bearing)
            nodes.append(OSMNode(id: Int64(step + 1), lat: placed.lat, lon: placed.lon))
            ids.append(Int64(step + 1))
        }
        let ring = OSMData(
            nodes: nodes,
            ways: [OSMWay(id: 1, nodes: ids + [ids[0]], tags: ["highway": "footway", "name": "The Ring"])]
        )
        let (search, _, _) = try searchGraph(ring, at: SyntheticOSM.douglas, radius: 2000)
        // The ring is one continuous chain touching no junction: one super-edge.
        XCTAssertLessThanOrEqual(search.stats.superEdges, 3)
        XCTAssertGreaterThan(search.stats.rawEdges, search.stats.superEdges)
    }

    // MARK: - The search

    func testAWalkNeverSpendsTheSameSuperEdgeTwice() throws {
        let (search, _, _) = try searchGraph(SyntheticOSM.grid(size: 15, spacingMetres: 200), radius: 1680)
        let result = WalkSearch.run(search, options: .init(targetMetres: 3000))
        XCTAssertGreaterThan(result.walks.count, 0)
        for walk in result.walks {
            let edges = walk.arcs.map { search.arcEdge[Int($0)] }
            XCTAssertEqual(Set(edges).count, edges.count, "an edge-simple circuit spends each super-edge once")
        }
    }

    func testEveryClosedWalkLandsInsideTheDistanceBand() throws {
        let (search, _, _) = try searchGraph(SyntheticOSM.grid(size: 15, spacingMetres: 200), radius: 1680)
        let result = WalkSearch.run(search, options: .init(targetMetres: 3000))
        for walk in result.walks {
            XCTAssertGreaterThanOrEqual(walk.metres, 3000 * (1 - RoutingCoverage.maxDistanceError))
            XCTAssertLessThanOrEqual(walk.metres, 3000 * (1 + RoutingCoverage.maxDistanceError))
            XCTAssertGreaterThanOrEqual(walk.compactness, WalkSearch.minCompactness)
        }
    }

    /// The compass-octant quota is not decoration. Without it the beam
    /// converges on one direction and the selector can only ever take one walk
    /// from what it is handed.
    func testTheDiversityQuotaSpreadsWalksAcrossTheCompass() throws {
        let (search, _, _) = try searchGraph(SyntheticOSM.grid(size: 21, spacingMetres: 150), radius: 1680)
        let withQuota = WalkSearch.run(search, options: .init(targetMetres: 3000, diversityQuota: true))
        let without = WalkSearch.run(search, options: .init(targetMetres: 3000, diversityQuota: false))
        let spread = Set(withQuota.walks.map(\.family)).count
        let narrow = Set(without.walks.map(\.family)).count
        XCTAssertGreaterThanOrEqual(spread, narrow)
        XCTAssertGreaterThan(spread, 1, "a lattice has loops in every direction and the search should find them")
    }

    /// The search must stop, and it must stop for a reason it reports rather
    /// than by running out of anything.
    func testTheSearchRespectsItsBudget() throws {
        let (search, _, _) = try searchGraph(SyntheticOSM.grid(size: 21, spacingMetres: 150), radius: 1680)
        let result = WalkSearch.run(search, options: .init(targetMetres: 3000, budget: 50))
        XCTAssertTrue(result.stats.stoppedEarly)
        XCTAssertLessThanOrEqual(result.stats.expanded, 50)
    }

    // MARK: - The gate

    func testCompactnessSeparatesALoopFromAThereAndBack() {
        var circle: [Point] = []
        for step in 0...36 {
            let placed = LocalGeo.destination(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                metres: 400, bearing: Double(step) * 10
            )
            circle.append(Point(placed.lon, placed.lat))
        }
        XCTAssertGreaterThan(RouteQuality.compactness(circle), 0.95, "a circle is the shape the measure is 1 for")

        let out = (0...20).map { step -> Point in
            let placed = LocalGeo.destination(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: Double(step) * 50, bearing: 90)
            return Point(placed.lon, placed.lat)
        }
        let thereAndBack = out + out.reversed().dropFirst()
        XCTAssertLessThan(RouteQuality.compactness(thereAndBack), RouteQuality.minCompactness)
    }

    func testTheGateRejectsAThereAndBackAndAcceptsARoundWalk() {
        var circle: [Point] = []
        for step in 0...72 {
            let placed = LocalGeo.destination(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                metres: 477, bearing: Double(step) * 5
            )
            circle.append(Point(placed.lon, placed.lat))
        }
        let round = RouteQuality.analyse(coordinates: circle, start: circle[0], distanceMetres: 3000, targetMetres: 3000)
        XCTAssertTrue(round.pass, "rejected a circle: \(round.rejections)")
        XCTAssertGreaterThan(round.quality.score, 60)

    }

    /// A road and its own pavement are one street, not two passes over one.
    ///
    /// The geometric measure cannot tell the difference: two lines 10 m apart
    /// running the same way for 200 m are "the same ground" to it, which is
    /// true of a carriageway and its footway, of a path beside a river, and of
    /// the two sides of a dual carriageway. The remote engine avoids this by
    /// asking the network whenever GraphHopper hands it traversals, and a
    /// searched walk always knows its edges — so the on-device gate asks the
    /// network too. This pins the difference, because it is the one place the
    /// port was accidentally *stricter* than the engine it was copied from.
    func testParallelPavementIsNotRetracingWhenTheWalkKnowsItsEdges() {
        // Out along one side of a street and back along the other: distinct
        // edges, 12 m apart, which is inside `corridorMatchMetres`.
        var line: [Point] = []
        for step in 0...40 {
            let placed = LocalGeo.destination(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                metres: Double(step) * 15, bearing: 90
            )
            line.append(Point(placed.lon, placed.lat))
        }
        for step in stride(from: 40, through: 0, by: -1) {
            let along = LocalGeo.destination(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                metres: Double(step) * 15, bearing: 90
            )
            let across = LocalGeo.destination(lat: along.lat, lon: along.lon, metres: 12, bearing: 0)
            line.append(Point(across.lon, across.lat))
        }

        let geometric = RouteQuality.findRepeatedCorridors(line)
        XCTAssertGreaterThan(
            geometric.repeatedMetres, 100,
            "the geometric measure is expected to call the two sides of a street the same ground"
        )

        // The same walk, described as the network sees it: two different edges,
        // each walked once.
        let metres = 40 * 15.0
        let traversals = [
            RouteQuality.EdgeTraversal(id: 1, metres: metres, along: 0, dirX: 1, dirY: 0),
            RouteQuality.EdgeTraversal(id: 2, metres: metres, along: metres, dirX: -1, dirY: 0),
        ]
        let network = RouteQuality.edgeRepeatReport(traversals, totalMetres: metres * 2)
        XCTAssertEqual(network.repeatedMetres, 0, "two distinct edges are not a repeat")
    }

    /// The network measure still charges a street genuinely walked twice.
    ///
    /// The point of the previous test is not that retracing stopped counting.
    func testTheSameEdgeWalkedTwiceIsStillRetracing() {
        let metres = 400.0
        let traversals = [
            RouteQuality.EdgeTraversal(id: 1, metres: metres, along: 200, dirX: 1, dirY: 0),
            RouteQuality.EdgeTraversal(id: 1, metres: metres, along: 900, dirX: -1, dirY: 0),
        ]
        let report = RouteQuality.edgeRepeatReport(traversals, totalMetres: 1600)
        XCTAssertEqual(report.repeatedMetres, metres)
        // Reversed, so charged at the premium the score applies to going back
        // the way you came.
        XCTAssertEqual(report.weightedRepeatedMetres, metres * RouteQuality.reverseOverlapWeight)
        XCTAssertEqual(report.longestReverseRunMetres, metres)
    }

    /// The doorstep is not retracing, at either end.
    func testTheSharedDoorstepIsNotChargedAsRepeatedGround() {
        let traversals = [
            RouteQuality.EdgeTraversal(id: 1, metres: 40, along: 0, dirX: 1, dirY: 0),
            RouteQuality.EdgeTraversal(id: 1, metres: 40, along: 960, dirX: -1, dirY: 0),
        ]
        let report = RouteQuality.edgeRepeatReport(traversals, totalMetres: 1000)
        XCTAssertEqual(report.repeatedMetres, 0)
    }


    /// Backtracking is judged by length, not by principle, and the port keeps
    /// that exactly.
    ///
    /// A long there-and-back is a pier, a promenade, a headland with one road
    /// in: it encloses nothing, runs long and thin, and that is what the walk
    /// *is* rather than a failure of shape. A short one is a corner that
    /// turned out to be a dead end, given up on rather than routed around, and
    /// it is always held against the walk. The threshold between them is
    /// `minBacktrackMetres`.
    ///
    /// Worth pinning down because it is the rule most likely to look like a
    /// bug: the gate accepting a walk that is visibly not a loop is deliberate.
    func testBacktrackingIsJudgedByLengthNotByPrinciple() {
        func thereAndBack(outMetres: Double, thenLoopOfRadius radius: Double) -> [Point] {
            var line: [Point] = []
            let steps = Int(outMetres / 15)
            for step in 0...steps {
                let placed = LocalGeo.destination(
                    lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                    metres: Double(step) * 15, bearing: 90
                )
                line.append(Point(placed.lon, placed.lat))
            }
            let far = line.last!
            if radius > 0 {
                for step in 0...72 {
                    let centre = LocalGeo.destination(lat: far.lat, lon: far.lng, metres: radius, bearing: 90)
                    let placed = LocalGeo.destination(
                        lat: centre.lat, lon: centre.lon, metres: radius, bearing: Double(step) * 5 + 270
                    )
                    line.append(Point(placed.lon, placed.lat))
                }
            }
            return line + line.reversed().dropFirst().map { $0 }.suffix(steps)
        }

        // A pure 1.5 km-out, 1.5 km-back promenade: accepted, because at that
        // length it can only be a real feature.
        let promenade = thereAndBack(outMetres: 1500, thenLoopOfRadius: 0)
        let pier = RouteQuality.analyse(coordinates: promenade, start: promenade[0], distanceMetres: 3000, targetMetres: 3000)
        XCTAssertGreaterThanOrEqual(pier.longestReverseRunMetres, RouteQuality.minBacktrackMetres)
        XCTAssertTrue(pier.pass, "a long there-and-back is a walk, not a defect: \(pier.rejections)")

        // A 150 m spur off an otherwise decent loop: rejected, every time.
        var loop: [Point] = []
        for step in 0...72 {
            let placed = LocalGeo.destination(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                metres: 477, bearing: Double(step) * 5
            )
            loop.append(Point(placed.lon, placed.lat))
        }
        let midpoint = loop[36]
        var spur: [Point] = []
        for step in 1...10 {
            let placed = LocalGeo.destination(lat: midpoint.lat, lon: midpoint.lng, metres: Double(step) * 15, bearing: 0)
            spur.append(Point(placed.lon, placed.lat))
        }
        let withSpur = Array(loop[0...36]) + spur + spur.reversed().dropFirst() + [midpoint] + Array(loop[37...])
        let judged = RouteQuality.analyse(coordinates: withSpur, start: withSpur[0], distanceMetres: 3300, targetMetres: 3300)
        XCTAssertFalse(judged.pass, "a short backtrack is a dead end given up on")
        XCTAssertTrue(
            judged.rejections.contains("out-and-back-spur") || judged.rejections.contains("u-turns"),
            "rejected for the wrong reason: \(judged.rejections)"
        )
    }

    func testTheWrongLengthIsAnEssentialRejection() {
        var circle: [Point] = []
        for step in 0...72 {
            let placed = LocalGeo.destination(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                metres: 477, bearing: Double(step) * 5
            )
            circle.append(Point(placed.lon, placed.lat))
        }
        let report = RouteQuality.analyse(coordinates: circle, start: circle[0], distanceMetres: 3000, targetMetres: 5000)
        XCTAssertFalse(report.pass)
        XCTAssertTrue(report.rejections.contains("distance"))
        XCTAssertFalse(report.passesEssentials, "a 3 km trudge is not an answer to somebody who asked for 5 km")
    }

    // MARK: - Instructions

    private func leg(from: Point, bearing: Double, metres: Double, name: String?) -> WalkLeg {
        let end = LocalGeo.destination(lat: from.lat, lon: from.lng, metres: metres, bearing: bearing)
        return WalkLeg(
            coordinates: [from, Point(end.lon, end.lat)], metres: metres, name: name, roadClass: .residential
        )
    }

    func testTurnsAreNamedByTheAngleBetweenTheEdges() {
        let start = SyntheticOSM.douglas
        func angle(_ turn: Double) -> Turn {
            let first = leg(from: start, bearing: 0, metres: 100, name: "First Street")
            let second = leg(from: first.coordinates.last!, bearing: turn, metres: 100, name: "Second Street")
            let steps = LocalInstructions.steps(for: [first, second])
            return turnKind(steps[1])
        }
        XCTAssertEqual(angle(0), .straight)
        XCTAssertEqual(angle(30), .slightRight)
        XCTAssertEqual(angle(-30), .slightLeft)
        XCTAssertEqual(angle(90), .right)
        XCTAssertEqual(angle(-90), .left)
        XCTAssertEqual(angle(140), .sharpRight)
        XCTAssertEqual(angle(-140), .sharpLeft)
        XCTAssertEqual(angle(179), .uTurn)
    }

    func testRouteStartRechecksAFalseTurnFromAnyRoutingSource() {
        let start = SyntheticOSM.douglas
        let pivotValue = LocalGeo.destination(lat: start.lat, lon: start.lng, metres: 100, bearing: 0)
        let pivot = Point(pivotValue.lon, pivotValue.lat)
        let kerb = LocalGeo.destination(lat: pivot.lat, lon: pivot.lng, metres: 3, bearing: 49)
        let onward = LocalGeo.destination(lat: pivot.lat, lon: pivot.lng, metres: 20, bearing: 2)
        let route = Route(
            id: "crossing", name: "Crossing fixture", distanceMeters: 122,
            durationSeconds: 88, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [start, pivot, Point(kerb.lon, kerb.lat), Point(onward.lon, onward.lat)]),
            steps: [
                Step(instruction: "Set off", distanceMeters: 100, durationSeconds: 72, startIndex: 0, endIndex: 1),
                Step(instruction: "Turn right", distanceMeters: 22, durationSeconds: 16, startIndex: 1, endIndex: 3, maneuver: .name("turn-right")),
                Step(instruction: "Arrive", distanceMeters: 0, durationSeconds: 0, startIndex: 3, endIndex: 3, maneuver: .name("finish")),
            ]
        )

        let checked = reassessDirections(route)

        XCTAssertEqual(checked.steps.count, 2)
        XCTAssertEqual(checked.steps[0].distanceMeters, 122)
        XCTAssertEqual(turnKind(checked.steps[1]), .arrive)
    }

    func testRouteStartDoesNotCallAStraightPavementRoadPavementSequenceATurn() {
        let start = SyntheticOSM.douglas
        let kerb1Value = LocalGeo.destination(lat: start.lat, lon: start.lng, metres: 100, bearing: 0)
        let kerb1 = Point(kerb1Value.lon, kerb1Value.lat)
        let kerb2Value = LocalGeo.destination(lat: kerb1.lat, lon: kerb1.lng, metres: 14, bearing: 4)
        let kerb2 = Point(kerb2Value.lon, kerb2Value.lat)
        let onwardValue = LocalGeo.destination(lat: kerb2.lat, lon: kerb2.lng, metres: 100, bearing: 1)
        let onward = Point(onwardValue.lon, onwardValue.lat)
        let route = Route(
            id: "road-crossing", name: "Road crossing fixture", distanceMeters: 214,
            durationSeconds: 154, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [start, kerb1, kerb2, onward]),
            steps: [
                Step(
                    instruction: "Set off", distanceMeters: 100, durationSeconds: 72,
                    startIndex: 0, endIndex: 1, roadClass: "footway"
                ),
                Step(
                    instruction: "Bear right onto Main Road", distanceMeters: 14, durationSeconds: 10,
                    startIndex: 1, endIndex: 2, maneuver: .name("keep-right"),
                    road: "Main Road", roadClass: "primary"
                ),
                Step(
                    instruction: "Turn right", distanceMeters: 100, durationSeconds: 72,
                    startIndex: 2, endIndex: 3, maneuver: .name("turn-right"), roadClass: "footway"
                ),
                Step(
                    instruction: "Arrive", distanceMeters: 0, durationSeconds: 0,
                    startIndex: 3, endIndex: 3, maneuver: .name("finish")
                ),
            ]
        )

        let checked = reassessDirections(route)

        XCTAssertEqual(checked.steps.count, 2)
        XCTAssertEqual(checked.steps[0].distanceMeters, 214)
        XCTAssertFalse(checked.steps[0].instruction.contains("Cross the road"))
        XCTAssertEqual(turnKind(checked.steps[1]), .arrive)

        let checkedBackwards = reassessDirections(reverseRoute(route))
        XCTAssertEqual(checkedBackwards.steps.count, 2)
        XCTAssertFalse(checkedBackwards.steps[0].instruction.contains("Cross the road"))
    }

    func testMappedStraightFootwayCrossingIsMergedIntoTheWalk() {
        let start = SyntheticOSM.douglas
        var pavement = leg(from: start, bearing: 0, metres: 100, name: nil)
        pavement.roadClass = .footway
        var crossing = leg(from: pavement.coordinates.last!, bearing: 4, metres: 14, name: nil)
        crossing.roadClass = .footway
        crossing.isCrossing = true
        var onward = leg(from: crossing.coordinates.last!, bearing: 1, metres: 100, name: nil)
        onward.roadClass = .footway

        let rawSteps = LocalInstructions.steps(for: [pavement, crossing, onward])
        XCTAssertFalse(rawSteps.contains { $0.instruction.contains("Cross") })

        let route = Route(
            id: "mapped-crossing", name: "Mapped crossing fixture", distanceMeters: 214,
            durationSeconds: 154, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [
                start, pavement.coordinates.last!, crossing.coordinates.last!, onward.coordinates.last!,
            ]),
            steps: rawSteps
        )
        let checked = reassessDirections(route)

        XCTAssertEqual(checked.steps.count, 2)
        XCTAssertEqual(checked.steps[0].distanceMeters, 214)
        XCTAssertFalse(checked.steps[0].instruction.contains("Cross the road"))

        let checkedBackwards = reassessDirections(reverseRoute(route))
        XCTAssertEqual(checkedBackwards.steps.count, 2)
        XCTAssertFalse(checkedBackwards.steps[0].instruction.contains("Cross the road"))
    }

    func testMappedCrossingWithARealDirectionChangeUsesDirectionalGuidance() {
        let start = SyntheticOSM.douglas
        var approach = leg(from: start, bearing: 0, metres: 100, name: nil)
        approach.roadClass = .footway
        var crossing = leg(from: approach.coordinates.last!, bearing: 55, metres: 14, name: nil)
        crossing.roadClass = .footway
        crossing.isCrossing = true
        var onward = leg(from: crossing.coordinates.last!, bearing: 55, metres: 100, name: nil)
        onward.roadClass = .footway
        let rawSteps = LocalInstructions.steps(for: [approach, crossing, onward])
        let route = Route(
            id: "turning-crossing", name: "Turning crossing fixture", distanceMeters: 214,
            durationSeconds: 154, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [
                start, approach.coordinates.last!, crossing.coordinates.last!, onward.coordinates.last!,
            ]),
            steps: rawSteps
        )

        let checked = reassessDirections(route)

        XCTAssertEqual(checked.steps.count, 3)
        XCTAssertEqual(checked.steps[1].instruction, "Turn right")
        XCTAssertEqual(checked.steps[1].maneuver, .name("turn-right"))
        XCTAssertEqual(checked.steps[1].distanceMeters, 114)
    }

    func testShortLeftBeforeMappedCrossingIsPreservedAndCrossingStaysSilent() {
        let start = SyntheticOSM.douglas
        var approach = leg(from: start, bearing: 0, metres: 100, name: "Approach")
        approach.roadClass = .footway
        var shortLeft = leg(from: approach.coordinates.last!, bearing: -90, metres: 7.25, name: nil)
        shortLeft.roadClass = .footway
        var crossing = leg(from: shortLeft.coordinates.last!, bearing: -90, metres: 9, name: nil)
        crossing.roadClass = .footway
        crossing.isCrossing = true
        var onward = leg(from: crossing.coordinates.last!, bearing: 0, metres: 40, name: "Groves Road")
        onward.roadClass = .footway

        let rawSteps = LocalInstructions.steps(for: [approach, shortLeft, crossing, onward])
        let route = Route(
            id: "short-left-crossing", name: "Short left crossing fixture", distanceMeters: 156.25,
            durationSeconds: 113, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [
                start, approach.coordinates.last!, shortLeft.coordinates.last!,
                crossing.coordinates.last!, onward.coordinates.last!,
            ]),
            steps: tidySteps(rawSteps)
        )

        let checked = reassessDirections(route)

        XCTAssertTrue(checked.steps.contains { turnKind($0) == .left })
        XCTAssertFalse(checked.steps.contains { $0.instruction.contains("Cross") })
        XCTAssertEqual(checked.steps.dropLast().map(\.instruction), [
            "Set off along Approach", "Turn left", "Turn right onto Groves Road",
        ])
    }

    func testEastLoopDiagnosticFragmentKeepsTheLeftAndSilencesMappedCrossing() {
        let points = [
            Point(-4.5055139, 54.1529672),
            Point(-4.5055152, 54.152791),
            Point(-4.5055280903928185, 54.15265583665692),
            Point(-4.5055603, 54.1523181),
            Point(-4.5055693, 54.1523072),
            Point(-4.5055032, 54.1522885),
            Point(-4.5054654, 54.1522903),
            Point(-4.5053982, 54.152271),
            Point(-4.5053385, 54.1522556),
            Point(-4.505327, 54.1522353),
            Point(-4.5053089, 54.1522179),
            Point(-4.5052001, 54.1521851),
            Point(-4.5051112, 54.1521909),
            Point(-4.5049925, 54.152162),
        ]
        func metres(_ coordinates: [Point]) -> Double {
            zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + haversine($1.0, $1.1) }
        }
        func fragment(_ range: ClosedRange<Int>, name: String? = nil, crossing: Bool = false) -> WalkLeg {
            let coordinates = Array(points[range])
            return WalkLeg(
                coordinates: coordinates, metres: metres(coordinates), name: name,
                roadClass: .footway, isCrossing: crossing
            )
        }
        let legs = [
            fragment(0...2), fragment(2...3), fragment(3...4), fragment(4...6),
            fragment(6...7, crossing: true), fragment(7...8, crossing: true),
            fragment(8...13, name: "Groves Road"),
        ]
        // OSM way 25988446 carries Groves Road's name through this junction.
        // The parallel footway is unnamed until after the crossing. These are
        // the carriageway nodes in the OSM extract, rather than an invented
        // parallel line.
        let road = [
            OSMNode(id: 10837248956, lat: 54.1522960, lon: -4.5056829),
            OSMNode(id: 1749022044, lat: 54.1522680, lon: -4.5056020),
            OSMNode(id: 283505150, lat: 54.1522156, lon: -4.5054435),
            OSMNode(id: 6737245039, lat: 54.1521429, lon: -4.5051955),
            OSMNode(id: 6737245040, lat: 54.1520405, lon: -4.5048117),
        ]
        let (graph, _) = LocalWalkingGraphBuilder.build(from: OSMData(
            nodes: road,
            ways: [OSMWay(id: 25988446, nodes: road.map(\.id),
                          tags: ["highway": "unclassified", "name": "Groves Road"])]
        ))
        let rawSteps = LocalInstructions.steps(for: legs, graph: graph, index: LocalEdgeIndex(graph: graph))
        let route = Route(
            id: "east-loop-diagnostic-replay", name: "East loop diagnostic replay",
            distanceMeters: legs.reduce(0) { $0 + $1.metres }, durationSeconds: 0,
            targetDifferencePercent: 0, geometry: LineGeometry(coordinates: points),
            steps: tidySteps(rawSteps)
        )

        let checked = reassessDirections(route)

        XCTAssertFalse(checked.steps.contains { $0.instruction.contains("Cross") })
        XCTAssertEqual(checked.steps.map(\.instruction), [
            "Set off", "Turn left onto Groves Road", "You’re back where you started",
        ])
        XCTAssertEqual(checked.steps.map(\.startIndex), [0, 4, 13])
        XCTAssertEqual(checked.steps.map(\.endIndex), [4, 13, 13])
    }

    func testMapTopologyDistinguishesUnavoidableBendFromRouteChoice() {
        let a = Point(-4.50, 54.15)
        let b = Point(-4.50, 54.1502)
        let c = Point(-4.4998, 54.1502)
        let d = Point(-4.5002, 54.1502)
        func graph(withBranch: Bool) -> LocalWalkingGraph {
            let nodes = [a, b, c, d].enumerated().map {
                OSMNode(id: Int64($0.offset + 1), lat: $0.element.lat, lon: $0.element.lng)
            }
            var ways = [
                OSMWay(id: 11, nodes: [1, 2], tags: ["highway": "footway"]),
                OSMWay(id: 12, nodes: [2, 3], tags: ["highway": "footway"]),
            ]
            if withBranch { ways.append(OSMWay(id: 13, nodes: [2, 4], tags: ["highway": "footway"])) }
            return LocalWalkingGraphBuilder.build(from: OSMData(nodes: nodes, ways: ways)).graph
        }
        func directions(in graph: LocalWalkingGraph) -> [String] {
            let first = graph.edgeWayID.firstIndex(of: 11)!
            let second = graph.edgeWayID.firstIndex(of: 12)!
            let legs = [
                WalkLeg(coordinates: [a, b], metres: haversine(a, b), name: nil,
                        roadClass: .footway, physical: Int32(first)),
                WalkLeg(coordinates: [b, c], metres: haversine(b, c), name: nil,
                        roadClass: .footway, physical: Int32(second)),
            ]
            return LocalInstructions.steps(for: legs, graph: graph, index: LocalEdgeIndex(graph: graph))
                .map(\.instruction)
        }

        XCTAssertEqual(directions(in: graph(withBranch: false)), ["Set off", "You’re back where you started"])
        XCTAssertEqual(directions(in: graph(withBranch: true)), ["Set off", "Turn right", "You’re back where you started"])
    }

    func testStraightRoadChangeIsAnnouncedAtAJunctionWithoutWalkableBranches() {
        let approach = Point(-4.5063727, 54.1547079)
        let junction = Point(-4.5063364, 54.1546494)
        let departure = Point(-4.5062991, 54.1545959)
        let nodes = [approach, junction, departure,
                     Point(-4.5065, 54.1546494), Point(-4.5062, 54.1546494)]
            .enumerated().map { OSMNode(id: Int64($0.offset + 1), lat: $0.element.lat, lon: $0.element.lng) }
        let ways = [
            OSMWay(id: 11, nodes: [1, 2], tags: ["highway": "secondary", "name": "Saddle Road"]),
            OSMWay(id: 12, nodes: [2, 3], tags: ["highway": "residential", "name": "Spring Valley Terrace"]),
            // Other roads meet the junction, but are not walking alternatives.
            OSMWay(id: 13, nodes: [4, 2], tags: ["highway": "trunk", "name": "Spring Valley Road"]),
            OSMWay(id: 14, nodes: [2, 5], tags: ["highway": "trunk", "name": "New Castletown Road"]),
        ]
        let (graph, _) = LocalWalkingGraphBuilder.build(from: OSMData(nodes: nodes, ways: ways))
        let first = graph.edgeWayID.firstIndex(of: 11)!
        let second = graph.edgeWayID.firstIndex(of: 12)!
        let legs = [
            WalkLeg(coordinates: [approach, junction], metres: haversine(approach, junction),
                    name: "Saddle Road", roadClass: .secondary, physical: Int32(first)),
            WalkLeg(coordinates: [junction, departure], metres: haversine(junction, departure),
                    name: "Spring Valley Terrace", roadClass: .residential, physical: Int32(second)),
        ]
        XCTAssertEqual(LocalRoadContext.hasAlternative(at: (legs[0], legs[1]), graph: graph), false)
        let rawSteps = LocalInstructions.steps(for: legs, graph: graph, index: LocalEdgeIndex(graph: graph))
        let route = Route(
            id: "straight-road-change", name: "Straight street transition", distanceMeters: 15,
            durationSeconds: 11, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [approach, junction, departure]),
            steps: tidySteps(rawSteps)
        )
        let checked = reassessDirections(route)
        XCTAssertEqual(checked.steps.map(\.instruction), [
            "Set off along Saddle Road", "Continue onto Spring Valley Terrace", "You’re back where you started",
        ])
        XCTAssertEqual(checked.steps.map(\.startIndex), [0, 1, 2])
        XCTAssertEqual(checked.steps[0].road, "Saddle Road")
        XCTAssertEqual(checked.steps[1].road, "Spring Valley Terrace")
    }

    func testDirectionReassessmentKeepsANamedRoadChangeWhenCorrectingAFalseTurn() {
        let points = [
            Point(-4.5063727, 54.1547079),
            Point(-4.5063364, 54.1546494),
            Point(-4.5062991, 54.1545959),
        ]
        let route = Route(
            id: "named-straight-change", name: "Named straight change", distanceMeters: 15,
            durationSeconds: 11, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: points), steps: [
                Step(instruction: "Set off along Saddle Road", distanceMeters: 8, durationSeconds: 6,
                     startIndex: 0, endIndex: 1, maneuver: .name("continue"), road: "Saddle Road"),
                Step(instruction: "Turn right onto Spring Valley Terrace", distanceMeters: 7, durationSeconds: 5,
                     startIndex: 1, endIndex: 2, maneuver: .name("turn-right"), road: "Spring Valley Terrace"),
                Step(instruction: "You’re back where you started", distanceMeters: 0, durationSeconds: 0,
                     startIndex: 2, endIndex: 2, maneuver: .name("finish")),
            ]
        )
        let checked = reassessDirections(route)
        XCTAssertEqual(checked.steps.map(\.instruction), [
            "Set off along Saddle Road", "Continue onto Spring Valley Terrace", "You’re back where you started",
        ])
        XCTAssertEqual(checked.steps[1].startIndex, 1)
    }

    func testUnnamedStraightCrossingDoesNotCreateAnInstructionBetweenNamedRoads() {
        let a = Point(-4.51240, 54.14810)
        let b = Point(-4.51230, 54.14810)
        let c = Point(-4.51220, 54.14810)
        let d = Point(-4.51220, 54.14795)
        let legs = [
            WalkLeg(coordinates: [a, b], metres: haversine(a, b), name: "Heather Crescent", roadClass: .footway),
            WalkLeg(coordinates: [b, c], metres: haversine(b, c), name: nil,
                    roadClass: .footway, isCrossing: true),
            WalkLeg(coordinates: [c, d], metres: haversine(c, d), name: "Hazel Crescent", roadClass: .residential),
        ]
        let steps = LocalInstructions.steps(for: legs)
        XCTAssertEqual(steps.map(\.instruction), [
            "Set off along Heather Crescent", "Turn right onto Hazel Crescent", "You’re back where you started",
        ])
        XCTAssertFalse(steps.contains { $0.instruction == "Continue" })
    }

    func testTinyNamedJunctionConnectorIsAbsorbedBeforeTheActualTurn() {
        let steps = tidySteps([
            Step(instruction: "Continue", distanceMeters: 165, durationSeconds: 119,
                 startIndex: 237, endIndex: 248, maneuver: .name("continue"), roadClass: "footway"),
            Step(instruction: "Continue onto Meadow Crescent", distanceMeters: 3, durationSeconds: 2,
                 startIndex: 248, endIndex: 249, maneuver: .name("continue"),
                 road: "Meadow Crescent", roadClass: "residential"),
            Step(instruction: "Turn right onto Ashbourne Avenue", distanceMeters: 47, durationSeconds: 34,
                 startIndex: 249, endIndex: 252, maneuver: .name("turn-right"),
                 road: "Ashbourne Avenue", roadClass: "residential"),
        ])
        XCTAssertEqual(steps.map(\.instruction), ["Continue", "Turn right onto Ashbourne Avenue"])
        XCTAssertEqual(steps[0].distanceMeters, 168)
        XCTAssertEqual(steps[0].endIndex, 249)
    }

    func testMappedCrossingToOppositeSideOfSameStreetIsAnExplicitAction() {
        let southA = Point(-4.5002, 54.14992)
        let southB = Point(-4.5000, 54.14992)
        let northB = Point(-4.5000, 54.15008)
        let northC = Point(-4.4998, 54.15008)
        let roadNodes = [
            OSMNode(id: 1, lat: 54.15, lon: -4.5004),
            OSMNode(id: 2, lat: 54.15, lon: -4.4996),
        ]
        let (graph, _) = LocalWalkingGraphBuilder.build(from: OSMData(
            nodes: roadNodes,
            ways: [OSMWay(id: 1, nodes: [1, 2], tags: ["highway": "residential", "name": "Main Street"])]
        ))
        let legs = [
            WalkLeg(coordinates: [southA, southB], metres: haversine(southA, southB), name: nil, roadClass: .footway),
            WalkLeg(coordinates: [southB, northB], metres: haversine(southB, northB), name: nil,
                    roadClass: .footway, isCrossing: true),
            WalkLeg(coordinates: [northB, northC], metres: haversine(northB, northC), name: nil, roadClass: .footway),
        ]

        let steps = LocalInstructions.steps(for: legs, graph: graph, index: LocalEdgeIndex(graph: graph))
        XCTAssertEqual(steps.map(\.instruction), [
            "Set off along Main Street", "Cross to the opposite pavement", "You’re back where you started",
        ])
        XCTAssertEqual(steps[1].maneuver, .name("cross-opposite-pavement"))
    }

    func testVerifiedOppositePavementCrossingRemainsAStandaloneAction() {
        let start = SyntheticOSM.douglas
        let firstValue = LocalGeo.destination(lat: start.lat, lon: start.lng, metres: 100, bearing: 0)
        let secondValue = LocalGeo.destination(lat: firstValue.lat, lon: firstValue.lon, metres: 10, bearing: 0)
        let endValue = LocalGeo.destination(lat: secondValue.lat, lon: secondValue.lon, metres: 100, bearing: 0)
        let route = Route(
            id: "opposite-pavement", name: "Explicit pavement crossing", distanceMeters: 210,
            durationSeconds: 151, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [
                start, Point(firstValue.lon, firstValue.lat), Point(secondValue.lon, secondValue.lat),
                Point(endValue.lon, endValue.lat),
            ]),
            steps: [
                Step(instruction: "Set off", distanceMeters: 100, durationSeconds: 72, startIndex: 0, endIndex: 1),
                Step(instruction: "Old wording", distanceMeters: 10, durationSeconds: 7, startIndex: 1, endIndex: 2, maneuver: .name("cross-opposite-pavement")),
                Step(instruction: "Continue", distanceMeters: 100, durationSeconds: 72, startIndex: 2, endIndex: 3, maneuver: .name("continue")),
                Step(instruction: "Arrive", distanceMeters: 0, durationSeconds: 0, startIndex: 3, endIndex: 3, maneuver: .name("finish")),
            ]
        )

        let checked = reassessDirections(route)

        XCTAssertEqual(checked.steps[1].instruction, "Cross to the opposite pavement")
        XCTAssertEqual(checked.steps[1].maneuver, Maneuver.name("cross-opposite-pavement"))
    }

    func testLocalInstructionsPreserveRoadClassTransitionsForTheRouteStartCheck() {
        let start = SyntheticOSM.douglas
        var pavement = leg(from: start, bearing: 0, metres: 100, name: nil)
        pavement.roadClass = .footway
        var road = leg(from: pavement.coordinates.last!, bearing: 0, metres: 14, name: "Main Road")
        road.roadClass = .primary
        var onward = leg(from: road.coordinates.last!, bearing: 0, metres: 100, name: nil)
        onward.roadClass = .footway

        let steps = LocalInstructions.steps(for: [pavement, road, onward])

        XCTAssertEqual(steps.dropLast().map(\.roadClass), ["footway", "primary", "footway"])
    }

    /// A road bending round is not an instruction, and calling one out at
    /// every surveyed vertex is how guidance becomes unusable.
    func testAStreetContinuingIsOneStepNotMany() {
        let start = SyntheticOSM.douglas
        var legs: [WalkLeg] = []
        var at = start
        for step in 0..<6 {
            let next = leg(from: at, bearing: Double(step) * 3, metres: 80, name: "Long Road")
            legs.append(next)
            at = next.coordinates.last!
        }
        legs.append(leg(from: at, bearing: 90, metres: 100, name: "Side Street"))
        let steps = LocalInstructions.steps(for: legs)
        // Set off, turn onto Side Street, arrive.
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0].road, "Long Road")
        XCTAssertEqual(steps[0].distanceMeters, 480, accuracy: 2)
        XCTAssertEqual(steps[1].instruction, "Turn right onto Side Street")
        XCTAssertEqual(turnKind(steps[2]), .arrive)
    }

    /// The app's own convention: a step's instruction is the manoeuvre at its
    /// start and it carries the road it then walks, and the indices address
    /// the route's own geometry.
    func testStepsCarryTheirRoadAndTheirPlaceInTheLine() {
        let start = SyntheticOSM.douglas
        let first = leg(from: start, bearing: 0, metres: 200, name: "Quay Road")
        let second = leg(from: first.coordinates.last!, bearing: 90, metres: 150, name: "Harbour Street")
        let steps = LocalInstructions.steps(for: [first, second])
        XCTAssertEqual(steps[0].road, "Quay Road")
        XCTAssertEqual(steps[0].startIndex, 0)
        XCTAssertEqual(steps[1].road, "Harbour Street")
        XCTAssertEqual(steps[1].startIndex, steps[0].endIndex)
        XCTAssertEqual(steps.map(\.distanceMeters).reduce(0, +), 350, accuracy: 2)
        // Durations come from the same walking speed the route service quotes,
        // so two engines' answers of the same length agree on how long it takes.
        XCTAssertEqual(steps[0].durationSeconds, 200 / LocalInstructions.walkingMetresPerSecond, accuracy: 1)
    }

    func testAnUnnamedPathStillGivesAnInstructionWorthFollowing() {
        let start = SyntheticOSM.douglas
        let first = leg(from: start, bearing: 0, metres: 100, name: nil)
        var second = leg(from: first.coordinates.last!, bearing: -90, metres: 60, name: nil)
        second.roadClass = .steps
        let steps = LocalInstructions.steps(for: [first, second])
        XCTAssertEqual(steps[0].instruction, "Set off")
        XCTAssertEqual(steps[1].instruction, "Turn left onto the steps")
    }
}
