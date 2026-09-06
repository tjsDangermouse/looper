import XCTest
@testable import LooperKit

/// Keeping a walk on a separately-mapped pavement instead of hopping onto the
/// carriageway beside it block by block.
///
/// The on-device graph carries a pavement and its road as parallel edges
/// joined at every corner, so with no preference between them the search takes
/// whichever is a few metres shorter on each block — the walk the user sees
/// stepping on and off the kerb. Two things push back: the snapper prefers a
/// pedestrian way when a request point is nearly equidistant, and a weighted
/// leg pays a fixed cost each time it changes between the two ground classes.
final class PavementPreferenceTests: XCTestCase {

    /// A coordinate `east`/`north` metres from Douglas.
    private func at(east: Double, north: Double) -> (lat: Double, lon: Double) {
        let moved = LocalGeo.destination(
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: north, bearing: 0
        )
        let placed = LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        return (placed.lat, placed.lon)
    }

    /// A residential carriageway running east, and a footway parallel to it a
    /// few metres north, cross-connected at every one of `easts`. The footway
    /// node at `bulgeIndex` is pushed `bulgeNorth` metres further north, a
    /// pavement that detours round something the road does not.
    private func parallelStreet(
        easts: [Double] = [0, 100, 200, 300, 400],
        footwayNorth: Double = 8,
        bulgeIndex: Int? = nil,
        bulgeNorth: Double = 0
    ) -> OSMData {
        var nodes: [OSMNode] = []
        var ways: [OSMWay] = []
        for (i, east) in easts.enumerated() {
            let road = at(east: east, north: 0)
            nodes.append(OSMNode(id: Int64(10 + i), lat: road.lat, lon: road.lon))
            let north = (i == bulgeIndex) ? footwayNorth + bulgeNorth : footwayNorth
            let foot = at(east: east, north: north)
            nodes.append(OSMNode(id: Int64(20 + i), lat: foot.lat, lon: foot.lon))
            // The kerb between them.
            ways.append(OSMWay(
                id: Int64(30 + i), nodes: [Int64(10 + i), Int64(20 + i)],
                tags: ["highway": "footway", "footway": "crossing"]
            ))
        }
        ways.append(OSMWay(
            id: 1, nodes: easts.indices.map { Int64(10 + $0) },
            tags: ["highway": "residential", "name": "Main Road"]
        ))
        ways.append(OSMWay(
            id: 2, nodes: easts.indices.map { Int64(20 + $0) },
            tags: ["highway": "footway", "name": "Main Road pavement"]
        ))
        return OSMData(nodes: nodes, ways: ways)
    }

    private func nonPedestrianLegs(_ leg: LocalLegRouter.Leg) -> Int {
        leg.legs.filter { !$0.roadClass.isPedestrianWay }.count
    }

    // MARK: - Snapping

    func testANearlyEquidistantPointSnapsToThePavementNotTheCarriageway() throws {
        let (graph, _) = LocalWalkingGraphBuilder.build(from: parallelStreet())
        let index = LocalEdgeIndex(graph: graph)
        // 3 m from the road, 5 m from the footway: closer to the road, but
        // within the pedestrian snap bias.
        let point = at(east: 150, north: 3)
        let snap = try XCTUnwrap(index.snap(lat: point.lat, lon: point.lon, graph: graph))
        XCTAssertTrue(
            graph.roadClass(ofEdge: snap.edge).isPedestrianWay,
            "a walker standing between a pavement and its road should snap to the pavement"
        )
    }

    func testAPointPlainlyInTheRoadStillSnapsToTheRoad() throws {
        let (graph, _) = LocalWalkingGraphBuilder.build(from: parallelStreet())
        let index = LocalEdgeIndex(graph: graph)
        // On the carriageway, 8 m from the pavement: past the bias.
        let point = at(east: 150, north: 0)
        let snap = try XCTUnwrap(index.snap(lat: point.lat, lon: point.lon, graph: graph))
        XCTAssertEqual(graph.roadClass(ofEdge: snap.edge), .residential)
    }

    // MARK: - Leg routing

    func testAWeightedLegStaysOnThePavementPastABulgeAnUnweightedOneCutsAcross() throws {
        // The pavement detours ~57 m north around the middle node; cutting onto
        // the road for that block and back saves a little over a kerb's width
        // of walking.
        let data = parallelStreet(bulgeIndex: 2, bulgeNorth: 57)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let from = at(east: 0, north: 8)
        let to = at(east: 400, north: 8)

        let unweighted = try LocalLegRouter.route(
            graph: graph, index: index, from: Point(from.lon, from.lat), to: Point(to.lon, to.lat)
        )
        XCTAssertGreaterThan(
            nonPedestrianLegs(unweighted), 0,
            "with every metre equal the shortest path cuts onto the carriageway — the fixture has to offer that shortcut for the test to mean anything"
        )

        let weighted = try LocalLegRouter.route(
            graph: graph, index: index, from: Point(from.lon, from.lat), to: Point(to.lon, to.lat),
            weighted: true
        )
        XCTAssertEqual(
            nonPedestrianLegs(weighted), 0,
            "the weighted leg should stay on the pavement rather than hop the kerb for one block"
        )
    }

    func testAWeightedLegDoesNotFlipOntoTheRoadOnAPerfectlyParallelStreet() throws {
        let data = parallelStreet()
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let from = at(east: 0, north: 8)
        let to = at(east: 400, north: 8)
        let weighted = try LocalLegRouter.route(
            graph: graph, index: index, from: Point(from.lon, from.lat), to: Point(to.lon, to.lat),
            weighted: true
        )
        XCTAssertEqual(nonPedestrianLegs(weighted), 0)
    }

    /// A shared-use promenade — `highway=cycleway` a walker is explicitly
    /// welcome on — is walking ground, not a carriageway. The Douglas seafront
    /// promenades are all tagged this way; classing them `.cycleway` priced
    /// them like a road and lost half the seafront walk off "pavement".
    func testAFootDesignatedCyclewayIsADedicatedWalkingWay() {
        let policy = PedestrianAccessPolicy.standard
        for foot in ["designated", "yes"] {
            let decision = policy.decide(tags: [
                "highway": "cycleway", "foot": foot, "bicycle": "designated", "name": "Central Promenade",
            ])
            XCTAssertTrue(decision.isWalkable)
            XCTAssertTrue(decision.roadClass.isPedestrianWay, "foot=\(foot) cycleway should be a pedestrian way")
            XCTAssertEqual(decision.weight, 1, "and it should keep full priority, not the 1.25 a carriageway gets")
        }
        // A segregated shared path with foot unset is still one a walker uses.
        let segregated = policy.decide(tags: ["highway": "cycleway", "segregated": "yes"])
        XCTAssertTrue(segregated.roadClass.isPedestrianWay)
        // A bare cycleway with nothing said about feet stays refused.
        XCTAssertFalse(policy.decide(tags: ["highway": "cycleway"]).isWalkable)
    }
}
