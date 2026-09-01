import XCTest
@testable import LooperKit

/// The A-to-B router the waypoint path is built on.
///
/// A lattice with 200 m spacing makes every correct answer arithmetic: the
/// shortest way from one junction to another is the Manhattan distance,
/// because there are no diagonals. That is exactly what a router this new
/// needs — a set of answers that can be worked out rather than eyeballed.
final class LocalLegRouterTests: XCTestCase {

    private let spacing = 200.0

    private func lattice(size: Int = 9) -> (LocalWalkingGraph, LocalEdgeIndex) {
        let data = SyntheticOSM.grid(size: size, spacingMetres: spacing)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        return (graph, LocalEdgeIndex(graph: graph))
    }

    /// The lattice node at `row`/`column`, as a coordinate. Row 0 is the
    /// southernmost and column 0 the westernmost, matching `SyntheticOSM.grid`.
    private func junction(row: Int, column: Int, size: Int = 9) -> Point {
        let half = Double(size - 1) / 2
        let north = (Double(row) - half) * spacing
        let east = (Double(column) - half) * spacing
        let moved = LocalGeo.destination(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: north, bearing: 0)
        let placed = LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        return Point(placed.lon, placed.lat)
    }

    // MARK: - The length is the arithmetic

    func testTheShortestWayAcrossTheLatticeIsTheManhattanDistance() throws {
        let (graph, index) = lattice()
        let leg = try LocalLegRouter.route(
            graph: graph, index: index,
            from: junction(row: 2, column: 2), to: junction(row: 5, column: 6)
        )
        // Three blocks north and four east, in any order: seven blocks.
        XCTAssertEqual(leg.metres, 7 * spacing, accuracy: 2)
    }

    func testRoutingToWhereYouAlreadyAreCostsNothing() throws {
        let (graph, index) = lattice()
        let leg = try LocalLegRouter.route(
            graph: graph, index: index,
            from: junction(row: 4, column: 4), to: junction(row: 4, column: 4)
        )
        XCTAssertEqual(leg.metres, 0, accuracy: 1)
    }

    /// The whole reason `LocalEdgeIndex` addresses a point along an edge rather
    /// than the nearest junction: a pin halfway down a street is halfway down
    /// that street, and the leg is half a block shorter than the junction
    /// answer would be.
    func testAPinHalfwayDownAStreetIsRoutedToHalfwayDownIt() throws {
        let (graph, index) = lattice()
        let from = junction(row: 4, column: 2)
        let toJunction = junction(row: 4, column: 5)
        let midpoint = midway(junction(row: 4, column: 4), toJunction)

        let toMid = try LocalLegRouter.route(graph: graph, index: index, from: from, to: midpoint)
        XCTAssertEqual(toMid.metres, 2.5 * spacing, accuracy: 3)
        // And it genuinely ends there, not at the junction beyond.
        let end = try XCTUnwrap(toMid.coordinates.last)
        XCTAssertLessThan(haversine(end, midpoint), 3)
    }

    /// Both ends mid-edge, on two different streets: the case the exploration
    /// never has to handle, because it only ever splits its start.
    func testBothEndsMayBeHalfwayDownAStreet() throws {
        let (graph, index) = lattice()
        let from = midway(junction(row: 2, column: 2), junction(row: 2, column: 3))
        let to = midway(junction(row: 6, column: 2), junction(row: 6, column: 3))
        let leg = try LocalLegRouter.route(graph: graph, index: index, from: from, to: to)
        // Four blocks north, plus half a block at each end to reach a column
        // and to come off it again — the lattice has no diagonals, so the two
        // half-blocks are walked rather than cancelling.
        XCTAssertEqual(leg.metres, 5 * spacing, accuracy: 5)
    }

    /// Two pins on the same street, with no junction between them, is the one
    /// case a node graph cannot express at all.
    func testTwoPinsOnOneStreetAreWalkedAlongIt() throws {
        let (graph, index) = lattice()
        let a = junction(row: 3, column: 3), b = junction(row: 3, column: 4)
        let leg = try LocalLegRouter.route(
            graph: graph, index: index,
            from: pointBetween(a, b, fraction: 0.25), to: pointBetween(a, b, fraction: 0.75)
        )
        XCTAssertEqual(leg.metres, spacing / 2, accuracy: 3)
        XCTAssertEqual(leg.legs.count, 1, "one edge, walked along part of itself")
    }

    // MARK: - What the graph allows

    /// A path a walker may only take one way — a one-way footbridge, an
    /// escalator — is walked that way and no other.
    ///
    /// Note the tag: plain `oneway` is a rule for vehicles and the access
    /// policy correctly ignores it, so a lattice of one-way streets is a
    /// lattice a walker moves freely on. `oneway:foot` is the one that binds.
    func testAOneWayPathIsNotWalkedTheWrongWay() throws {
        var data = SyntheticOSM.line(from: SyntheticOSM.douglas, size: 5, spacingMetres: 200, id: 555)
        data = OSMData(
            nodes: data.nodes,
            ways: data.ways.map { way in
                OSMWay(id: way.id, nodes: way.nodes, tags: way.tags.merging(["oneway:foot": "yes"]) { _, new in new })
            }
        )
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let west = SyntheticOSM.douglas
        let moved = LocalGeo.destination(lat: west.lat, lon: west.lng, metres: 600, bearing: 90)
        let east = Point(moved.lon, moved.lat)

        let allowed = try LocalLegRouter.route(graph: graph, index: index, from: west, to: east)
        XCTAssertEqual(allowed.metres, 600, accuracy: 3)

        XCTAssertThrowsError(try LocalLegRouter.route(graph: graph, index: index, from: east, to: west)) { error in
            guard case LocalLegRouter.Failure.unreachable = error else {
                return XCTFail("expected the wrong way up a one-way path to be unreachable, got \(error)")
            }
        }
    }

    func testAPlaceWithNoPathNearItIsReportedRatherThanSnappedToAnyway() throws {
        let (graph, index) = lattice()
        // Well outside the lattice: nothing within the snap radius.
        let far = LocalGeo.destination(
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: 20_000, bearing: 90
        )
        XCTAssertThrowsError(try LocalLegRouter.route(
            graph: graph, index: index, from: junction(row: 4, column: 4), to: Point(far.lon, far.lat)
        )) { error in
            guard case LocalLegRouter.Failure.nothingToSnapTo = error else {
                return XCTFail("expected a snapping failure, got \(error)")
            }
        }
    }

    func testAPlaceThatCannotBeReachedOnFootIsReportedAsSuch() throws {
        // Two lattices far enough apart to share no ground and no way between.
        var data = SyntheticOSM.grid(size: 5, spacingMetres: spacing)
        let elsewhere = LocalGeo.destination(
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: 3000, bearing: 90
        )
        let island = SyntheticOSM.line(from: Point(elsewhere.lon, elsewhere.lat), size: 4, spacingMetres: 100, id: 777)
        data = OSMData(nodes: data.nodes + island.nodes, ways: data.ways + island.ways)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)

        XCTAssertThrowsError(try LocalLegRouter.route(
            graph: graph, index: index,
            from: SyntheticOSM.douglas, to: Point(elsewhere.lon, elsewhere.lat)
        )) { error in
            guard case LocalLegRouter.Failure.unreachable = error else {
                return XCTFail("expected an unreachable failure, got \(error)")
            }
        }
    }

    // MARK: - Keeping a later leg off an earlier one's ground

    /// The Swift stand-in for the remote engine's avoidance model. A penalty is
    /// not a wall — the leg is still allowed down a penalised street when
    /// nothing else will do — but where a parallel street exists it is taken.
    func testAPenalisedStreetIsAvoidedWhereThereIsAnAlternative() throws {
        let (graph, index) = lattice()
        let from = junction(row: 4, column: 2), to = junction(row: 4, column: 5)
        let direct = try LocalLegRouter.route(graph: graph, index: index, from: from, to: to)
        let walked = Set(direct.legs.map(\.physical))

        let detoured = try LocalLegRouter.route(
            graph: graph, index: index, from: from, to: to, penalising: walked, penalty: 4
        )
        XCTAssertGreaterThan(detoured.metres, direct.metres, "it went another way")
        XCTAssertTrue(
            detoured.legs.allSatisfy { !walked.contains($0.physical) },
            "with a whole lattice to choose from, none of the penalised ground is needed"
        )
    }

    /// A penalty is a cost, not a prohibition. On a corridor with one way
    /// through, penalising it must still leave a walk rather than no walk.
    func testAPenaltyStillLeavesAWalkWhereThereIsOnlyOneWayThrough() throws {
        let data = SyntheticOSM.line(from: SyntheticOSM.douglas, size: 6, spacingMetres: 150)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let ends = (SyntheticOSM.douglas, LocalGeo.destination(
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: 750, bearing: 90
        ))
        let everything = Set((0..<graph.edgeCount).map(Int32.init))
        let leg = try LocalLegRouter.route(
            graph: graph, index: index, from: ends.0, to: Point(ends.1.lon, ends.1.lat),
            penalising: everything, penalty: 10
        )
        XCTAssertEqual(leg.metres, 750, accuracy: 5, "the reported length is the true one, never the penalised cost")
    }

    // MARK: - Guides, and the spikes they cause

    /// Routing through a shaping point makes the walk longer, which is the
    /// whole purpose of one.
    func testRoutingThroughAGuideLengthensTheLeg() throws {
        let (graph, index) = lattice()
        let from = junction(row: 4, column: 2), to = junction(row: 4, column: 6)
        let direct = try LocalLegRouter.route(graph: graph, index: index, from: from, to: to)
        let viaGuide = try LocalLegRouter.route(
            graph: graph, index: index, through: [from, junction(row: 7, column: 4), to]
        )
        XCTAssertGreaterThan(viaGuide.metres, direct.metres)
        XCTAssertEqual(viaGuide.metres, direct.metres + 6 * spacing, accuracy: 5)
    }

    /// The exact replacement for the remote engine's geometric spike trim: the
    /// same edge, immediately again, the other way, is not part of the walk.
    func testWalkingOntoAPieceOfGroundAndStraightOffItIsCutOut() {
        let out = WalkLeg(
            coordinates: [Point(0, 0), Point(0.001, 0)], metres: 100, name: "Dead End", roadClass: .residential, physical: 7
        )
        let back = WalkLeg(
            coordinates: [Point(0.001, 0), Point(0, 0)], metres: 100, name: "Dead End", roadClass: .residential, physical: 7
        )
        let onward = WalkLeg(
            coordinates: [Point(0, 0), Point(0, 0.001)], metres: 100, name: "Main Street", roadClass: .residential, physical: 8
        )
        XCTAssertEqual(LocalLegRouter.cancellingReversals([out, back, onward]).map(\.physical), [8])
    }

    /// And it does not cut out ground the walk merely passes twice in the same
    /// direction, or two different edges that happen to meet.
    func testGroundWalkedTwiceTheSameWayIsNotCutOut() {
        let first = WalkLeg(
            coordinates: [Point(0, 0), Point(0.001, 0)], metres: 100, name: nil, roadClass: .residential, physical: 7
        )
        XCTAssertEqual(LocalLegRouter.cancellingReversals([first, first]).count, 2)
    }

    /// A pin at the tip of a dead end is visited by walking in and out again,
    /// and that pair of legs is exactly what the reversal cancelling removes.
    /// Run across a pin it deletes the visit and hands back a tidy loop that
    /// never goes where it was asked — measured on real ground, that cost half
    /// the walks their own pins.
    func testAPinIsNotCancelledAwayByTheAntiSpikeRule() throws {
        // A lattice with one lane hanging off it, and a pin at the tip.
        var data = SyntheticOSM.grid(size: 7, spacingMetres: spacing)
        let anchor = junction(row: 3, column: 3, size: 7)
        // Diagonally, and short. Diagonally because the lattice already has a
        // street running every compass direction a lane could take, and a lane
        // drawn on top of one is not a dead end at all; short so the tip is
        // nowhere near the next street across, or a walk that skipped the lane
        // still passes within the hit tolerance by accident.
        let out = LocalGeo.destination(lat: anchor.lat, lon: anchor.lng, metres: 60, bearing: 45)
        let tip = LocalGeo.destination(lat: out.lat, lon: out.lon, metres: 60, bearing: 45)
        let lane = [
            OSMNode(id: 90001, lat: out.lat, lon: out.lon),
            OSMNode(id: 90002, lat: tip.lat, lon: tip.lon),
        ]
        data = OSMData(
            nodes: data.nodes + lane,
            ways: data.ways + [OSMWay(
                id: 9100, nodes: [Int64(3 * 1000 + 3 + 1), 90001, 90002],
                tags: ["highway": "residential", "name": "Dead Lane"]
            )]
        )
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let pin = Point(tip.lon, tip.lat)
        let start = junction(row: 1, column: 1, size: 7)
        let chain = [start, pin, junction(row: 5, column: 5, size: 7), start]

        let protected = try LocalLegRouter.route(graph: graph, index: index, through: chain, protecting: [pin])
        XCTAssertTrue(
            LocalLoopRouter.route(protected.coordinates, hits: [pin]),
            "a walk routed through a pin has to pass it"
        )
        // The property underneath that: the lane is walked in and walked out,
        // and both traversals survive. Cancelling them is what deletes the
        // visit, so their presence is the thing worth pinning — the coordinate
        // check above can be satisfied by a walk that merely passes nearby.
        let laneEdge = try XCTUnwrap(protected.legs.first { $0.name == "Dead Lane" }).physical
        XCTAssertEqual(
            protected.legs.filter { $0.physical == laneEdge }.count, 2,
            "the approach to the pin and the retreat from it are both part of the walk"
        )
    }

    // MARK: - Helpers

    private func midway(_ a: Point, _ b: Point) -> Point { pointBetween(a, b, fraction: 0.5) }

    private func pointBetween(_ a: Point, _ b: Point, fraction: Double) -> Point {
        let bearing = LocalGeo.bearing(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng)
        let moved = LocalGeo.destination(lat: a.lat, lon: a.lng, metres: haversine(a, b) * fraction, bearing: bearing)
        return Point(moved.lon, moved.lat)
    }
}
