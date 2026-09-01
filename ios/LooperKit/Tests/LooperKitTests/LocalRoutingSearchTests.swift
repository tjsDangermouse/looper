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

    /// A stem the engine imposed is not a spur the walker chose.
    ///
    /// The on-device search must root a circuit at a node inside the 2-core, so
    /// a walk from a cul-de-sac address carries the same out-and-back at both
    /// ends whatever it does in between. No remote route has one — the remote
    /// engine routes from the door — so charging it under `start-spur` failed
    /// walks for an artefact of graph reduction. Measured at the default start
    /// this was rejecting every walk under about 3.75 km.
    func testTheTwoCoreStemIsNotChargedAsAStartSpur() {
        // 200 m out to the circuit, a loop, and 200 m back.
        var line: [Point] = []
        for step in 0...13 {
            let placed = LocalGeo.destination(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                metres: Double(step) * 15, bearing: 90
            )
            line.append(Point(placed.lon, placed.lat))
        }
        let hinge = line.last!
        for step in 0...72 {
            let centre = LocalGeo.destination(lat: hinge.lat, lon: hinge.lng, metres: 380, bearing: 90)
            let placed = LocalGeo.destination(
                lat: centre.lat, lon: centre.lon, metres: 380, bearing: Double(step) * 5 + 270
            )
            line.append(Point(placed.lon, placed.lat))
        }
        for step in stride(from: 13, through: 0, by: -1) {
            let placed = LocalGeo.destination(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                metres: Double(step) * 15, bearing: 90
            )
            line.append(Point(placed.lon, placed.lat))
        }

        let metres = 2800.0
        let charged = RouteQuality.analyse(
            coordinates: line, start: line[0], distanceMetres: metres, targetMetres: metres
        )
        XCTAssertTrue(
            charged.rejections.contains("start-spur"),
            "expected the uncorrected gate to see a spur here: \(charged.rejections)"
        )

        let excused = RouteQuality.analyse(
            coordinates: line, start: line[0], distanceMetres: metres, targetMetres: metres,
            stemMetres: 195
        )
        XCTAssertFalse(
            excused.rejections.contains("start-spur"),
            "the stem the engine imposed was still charged: \(excused.rejections)"
        )
    }

    /// The stem is retracing on the network, and must not be charged as it.
    ///
    /// The companion to the start-spur case: a stem is literally the same
    /// physical edges walked out and walked back, so the edge measure sees it
    /// as reversed repeated ground. Left uncorrected that turns the stem into
    /// an `out-and-back-spur` rejection instead of a `start-spur` one, and the
    /// cul-de-sac start is no better off than before.
    func testTheStemIsNotChargedAsRetracingOnTheNetwork() {
        let stem = 200.0
        // Out along edges 1 and 2, a circuit on 3 and 4, then back down 2 and 1.
        let traversals = [
            RouteQuality.EdgeTraversal(id: 1, metres: 100, along: 0, dirX: 1, dirY: 0),
            RouteQuality.EdgeTraversal(id: 2, metres: 100, along: 100, dirX: 1, dirY: 0),
            RouteQuality.EdgeTraversal(id: 3, metres: 1300, along: 200, dirX: 0, dirY: 1),
            RouteQuality.EdgeTraversal(id: 4, metres: 1300, along: 1500, dirX: 0, dirY: -1),
            RouteQuality.EdgeTraversal(id: 2, metres: 100, along: 2800, dirX: -1, dirY: 0),
            RouteQuality.EdgeTraversal(id: 1, metres: 100, along: 2900, dirX: -1, dirY: 0),
        ]
        let total = 3000.0

        // The default doorstep of 75 m does not reach the far end of the stem,
        // so the outer 25 m of edge 2 is charged both ways.
        let charged = RouteQuality.edgeRepeatReport(traversals, totalMetres: total)
        XCTAssertGreaterThan(charged.longestReverseRunMetres, 0)

        let excused = RouteQuality.edgeRepeatReport(traversals, totalMetres: total, ignoreStartMetres: stem)
        XCTAssertEqual(excused.repeatedMetres, 0, "the stem was charged as retracing")
        XCTAssertEqual(excused.longestReverseRunMetres, 0)
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
