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
