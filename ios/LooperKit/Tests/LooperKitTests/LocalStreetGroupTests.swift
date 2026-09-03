import XCTest
@testable import LooperKit

/// The two pavements and their carriageway, as one street — and the two cost
/// rules that only become expressible once they are.
final class LocalStreetGroupTests: XCTestCase {

    /// A street running east for `metres`, with a pavement `offset` metres to
    /// each side. `northEnds` cuts the north pavement short, which is the case
    /// the crossing rule has to get right.
    private func street(
        metres: Double = 400,
        offset: Double = 8,
        northEnds: Double? = nil,
        southPavement: Bool = true,
        crossingsEvery: Double? = nil
    ) -> OSMData {
        let centre = SyntheticOSM.douglas
        func place(east: Double, north: Double) -> (lat: Double, lon: Double) {
            let moved = LocalGeo.destination(lat: centre.lat, lon: centre.lng, metres: north, bearing: 0)
            return LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        }
        var nodes: [OSMNode] = []
        var ways: [OSMWay] = []
        var nextNode: Int64 = 1
        var nextWay: Int64 = 1

        /// A chain of nodes 50 m apart along the street, at a given offset.
        func chain(north: Double, from: Double, to: Double) -> [Int64] {
            var easts: [Double] = []
            var east = from
            while east < to - 0.01 { easts.append(east); east += 50 }
            easts.append(to)
            var ids: [Int64] = []
            for spot in easts {
                let at = place(east: spot, north: north)
                nodes.append(OSMNode(id: nextNode, lat: at.lat, lon: at.lon))
                ids.append(nextNode)
                nextNode += 1
            }
            return ids
        }

        let road = chain(north: 0, from: 0, to: metres)
        ways.append(OSMWay(id: nextWay, nodes: road, tags: ["highway": "residential", "name": "Main Street"]))
        nextWay += 1

        let northTo = northEnds ?? metres
        let north = chain(north: offset, from: 0, to: northTo)
        ways.append(OSMWay(id: nextWay, nodes: north, tags: ["highway": "footway", "footway": "sidewalk"]))
        nextWay += 1

        var south: [Int64] = []
        if southPavement {
            south = chain(north: -offset, from: 0, to: metres)
            ways.append(OSMWay(id: nextWay, nodes: south, tags: ["highway": "footway", "footway": "sidewalk"]))
            nextWay += 1
        }

        // Crossings link north pavement → carriageway node → south pavement,
        // which is how OSM joins them and why the graph cuts them in half.
        if let spacing = crossingsEvery, southPavement {
            var east = 0.0
            while east <= Swift.min(northTo, metres) + 0.01 {
                let step = Int(east / 50)
                if step < north.count, step < road.count, step < south.count, east > 0 || spacing == 0 {
                    ways.append(OSMWay(
                        id: nextWay,
                        nodes: [north[step], road[step], south[step]],
                        tags: ["highway": "footway", "footway": "crossing"]
                    ))
                    nextWay += 1
                }
                east += spacing
            }
        }
        return OSMData(nodes: nodes, ways: ways)
    }

    private func build(_ data: OSMData) -> LocalWalkingGraph {
        LocalWalkingGraphBuilder.build(from: data).graph
    }

    // MARK: - One street, not three paths

    func testAPavementAndItsCarriagewayAreTheSameStreet() {
        let graph = build(street(crossingsEvery: 200))
        var pavements = 0
        for edge in 0..<graph.edgeCount
        where graph.roadClass(ofEdge: edge).isPedestrianWay && !graph.isCrossing(ofEdge: edge) {
            pavements += 1
            XCTAssertEqual(
                graph.street(ofEdge: edge), "Main Street",
                "a pavement belongs to the street it runs along, though OSM never says so"
            )
        }
        XCTAssertGreaterThanOrEqual(pavements, 4, "the fixture has pavement both sides")
    }

    func testACarriagewayWithAPavementBesideItIsDearer() {
        let withPavement = build(street())
        let bare = build(street(offset: 8, southPavement: false, crossingsEvery: nil))

        func carriagewayWeight(_ graph: LocalWalkingGraph) -> Double {
            for edge in 0..<graph.edgeCount where !graph.roadClass(ofEdge: edge).isPedestrianWay {
                return graph.edgeWeight[edge]
            }
            return .nan
        }
        // 1.25 from the existing class tie-break, doubled because an
        // alternative exists eight metres away.
        XCTAssertEqual(carriagewayWeight(withPavement), 2.5, accuracy: 0.01)
        // Still has its north pavement, so still dearer — the rule asks whether
        // a pavement exists alongside, not whether one exists on both sides.
        XCTAssertEqual(carriagewayWeight(bare), 2.5, accuracy: 0.01)
    }

    /// The reporter's own rule: a road is not punished for having no pavement.
    func testARoadWithNoPavementIsNotPenalisedAtAll() {
        let lane = build(SyntheticOSM.grid(size: 4, spacingMetres: 200))
        for edge in 0..<lane.edgeCount {
            XCTAssertFalse(lane.edgeHasParallelPavement[edge])
            XCTAssertEqual(
                lane.edgeWeight[edge], 1.25, accuracy: 0.01,
                "a lane with no pavement keeps exactly the tie-break it always had"
            )
        }
    }

    // MARK: - Which crossings cost

    func testASideSwapIsChargedAndAJunctionCrossingIsNot() {
        let graph = build(street(crossingsEvery: 200))
        var charged = 0, free = 0
        for edge in 0..<graph.edgeCount where graph.isCrossing(ofEdge: edge) {
            if graph.edgeSurcharge[edge] > 0 { charged += 1 } else { free += 1 }
        }
        XCTAssertGreaterThan(charged, 0, "crossing Main Street between its own pavements is a side-swap")
        XCTAssertEqual(free, 0, "there is no side road in this fixture to cross")

        // A crossing cut at the carriageway is two edges and must be charged
        // once, or the commonest tagging in OSM pays double.
        var byWay: [Int64: Double] = [:]
        for edge in 0..<graph.edgeCount where graph.isCrossing(ofEdge: edge) {
            byWay[graph.edgeWayID[edge], default: 0] += graph.edgeSurcharge[edge]
        }
        for (_, total) in byWay {
            XCTAssertEqual(
                total, LocalStreetGroups.sideSwapSurchargeMetres, accuracy: 0.01,
                "one crossing, charged once, however the survey split it"
            )
        }
    }

    func testAnUnknownStreetIsNeverCharged() {
        // No name on the carriageway, so nothing can be said about whether a
        // crossing returns to the street it left.
        let centre = SyntheticOSM.douglas
        func place(east: Double, north: Double) -> (lat: Double, lon: Double) {
            let moved = LocalGeo.destination(lat: centre.lat, lon: centre.lng, metres: north, bearing: 0)
            return LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        }
        var nodes: [OSMNode] = []
        for (index, spot) in [(0.0, 8.0), (0.0, 0.0), (0.0, -8.0), (100.0, 8.0), (100.0, 0.0), (100.0, -8.0)].enumerated() {
            let at = place(east: spot.0, north: spot.1)
            nodes.append(OSMNode(id: Int64(index + 1), lat: at.lat, lon: at.lon))
        }
        let data = OSMData(nodes: nodes, ways: [
            OSMWay(id: 1, nodes: [2, 5], tags: ["highway": "residential"]),
            OSMWay(id: 2, nodes: [1, 4], tags: ["highway": "footway", "footway": "sidewalk"]),
            OSMWay(id: 3, nodes: [3, 6], tags: ["highway": "footway", "footway": "sidewalk"]),
            OSMWay(id: 4, nodes: [1, 2, 3], tags: ["highway": "footway", "footway": "crossing"]),
        ])
        let graph = build(data)
        for edge in 0..<graph.edgeCount where graph.isCrossing(ofEdge: edge) {
            XCTAssertEqual(graph.edgeSurcharge[edge], 0, "a rule that cannot tell what it sees must not charge")
        }
    }

    // MARK: - What the walker gets

    /// A street where the north pavement runs out and drops the walker onto
    /// the carriageway, which is what actually happens on the ground. The south
    /// pavement carries on, and crossings link the two.
    private func pavementRunsOut(remaining: Double) -> OSMData {
        let centre = SyntheticOSM.douglas
        func place(east: Double, north: Double) -> (lat: Double, lon: Double) {
            let moved = LocalGeo.destination(lat: centre.lat, lon: centre.lng, metres: north, bearing: 0)
            return LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        }
        var nodes: [OSMNode] = []
        var id: Int64 = 0
        func node(east: Double, north: Double) -> Int64 {
            id += 1
            let at = place(east: east, north: north)
            nodes.append(OSMNode(id: id, lat: at.lat, lon: at.lon))
            return id
        }
        let ends = 100.0
        let far = ends + remaining
        let road0 = node(east: 0, north: 0)
        let roadEnds = node(east: ends, north: 0)
        let roadFar = node(east: far, north: 0)
        let north0 = node(east: 0, north: 8)
        let northMid = node(east: 50, north: 8)
        let south0 = node(east: 0, north: -8)
        let southEnds = node(east: ends, north: -8)
        let southFar = node(east: far, north: -8)

        return OSMData(nodes: nodes, ways: [
            OSMWay(id: 1, nodes: [road0, roadEnds, roadFar], tags: ["highway": "residential", "name": "Main Street"]),
            // The north pavement ends *on* the carriageway: you step into the road.
            OSMWay(id: 2, nodes: [north0, northMid, roadEnds], tags: ["highway": "footway", "footway": "sidewalk"]),
            OSMWay(id: 3, nodes: [south0, southEnds, southFar], tags: ["highway": "footway", "footway": "sidewalk"]),
            OSMWay(id: 4, nodes: [north0, road0, south0], tags: ["highway": "footway", "footway": "crossing"]),
            OSMWay(id: 5, nodes: [roadEnds, southEnds], tags: ["highway": "footway", "footway": "crossing"]),
            OSMWay(id: 6, nodes: [roadFar, southFar], tags: ["highway": "footway", "footway": "crossing"]),
        ])
    }

    private func point(east: Double, north: Double) -> Point {
        let centre = SyntheticOSM.douglas
        let moved = LocalGeo.destination(lat: centre.lat, lon: centre.lng, metres: north, bearing: 0)
        let placed = LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        return Point(placed.lon, placed.lat)
    }

    private func walk(_ data: OSMData, from: Point, to: Point) -> LocalLegRouter.Leg? {
        let graph = build(data)
        return try? LocalLegRouter.route(
            graph: graph, index: LocalEdgeIndex(graph: graph), from: from, to: to, weighted: true
        )
    }

    /// Issue 1, directly. Both pavements run the whole street and crossings
    /// link them every hundred metres. Walking one side end to end, the router
    /// must not hop across and back — which is exactly what it used to do, for
    /// the sake of a few metres.
    func testAWalkAlongOneSideDoesNotHopAcrossAndBack() {
        let leg = walk(
            street(metres: 400, crossingsEvery: 100),
            from: point(east: 0, north: 8), to: point(east: 400, north: 8)
        )
        let crossings = leg?.legs.filter(\.isCrossing).count ?? -1
        XCTAssertEqual(crossings, 0, "nothing was to be gained by changing side")
    }

    /// The reporter's other rule: where a pavement ends, cross to the pavement
    /// on the other side rather than walking the carriageway.
    func testWhenThePavementEndsTheWalkCrossesRatherThanTakingTheRoad() {
        let leg = walk(
            pavementRunsOut(remaining: 200),
            from: point(east: 0, north: 8), to: point(east: 300, north: -8)
        )
        let onRoad = leg?.legs.filter { !$0.roadClass.isPedestrianWay }.reduce(0) { $0 + $1.metres } ?? .infinity
        XCTAssertLessThan(onRoad, 20, "two hundred metres of pavement is worth one crossing")
        XCTAssertGreaterThan(leg?.legs.filter(\.isCrossing).count ?? 0, 0)
    }

    /// And it does not cross for the sake of twenty metres it would only have
    /// to cross straight back from. This is the far-side lookahead, and it is
    /// not a rule anybody had to write: it falls out of the two costs.
    func testItDoesNotCrossForAStretchItWouldHaveToCrossBackFrom() {
        let leg = walk(
            pavementRunsOut(remaining: 20),
            from: point(east: 0, north: 8), to: point(east: 120, north: 0)
        )
        XCTAssertEqual(
            leg?.legs.filter(\.isCrossing).count, 0,
            "crossing and recrossing costs 80 m to save 20 m of carriageway"
        )
    }

    /// The surcharge has to lose to a genuinely needed crossing and beat a
    /// pointless one. Both follow from the same number because the *alternative*
    /// costs differ, which is the whole argument for it.
    func testTheSurchargeIsPricedAgainstWalkingTheRoad() {
        let surcharge = LocalStreetGroups.sideSwapSurchargeMetres
        let carriageway = 1.25 * LocalStreetGroups.parallelPavementPenalty

        // Pointless: the pavement underfoot continues, so staying costs nothing.
        let stay = 200.0
        let swap = surcharge + 10 + 200.0
        XCTAssertGreaterThan(swap, stay, "a side-swap is never worth it when the pavement continues")

        // Needed: the pavement ended, so the alternative is the carriageway.
        let road = 200.0 * carriageway
        XCTAssertLessThan(swap, road, "crossing beats trudging two hundred metres of carriageway")

        // Two crossovers, because which applies depends on the walk. Crossing
        // once — the destination was across the street anyway — breaks even at
        // about 35 m, which is the number the constants were chosen for.
        // Having to cross back doubles the surcharge and breaks even at about
        // 67 m, so the router is the more reluctant exactly where it should be.
        XCTAssertEqual((surcharge + 10) / (carriageway - 1), 33, accuracy: 3)
        XCTAssertEqual((2 * surcharge + 20) / (carriageway - 1), 67, accuracy: 3)
    }

    // MARK: - Cost and shape

    func testGroupingDoesNotBreakTheHeuristicsLowerBound() {
        let graph = build(street(crossingsEvery: 100))
        for edge in 0..<graph.edgeCount {
            XCTAssertGreaterThanOrEqual(
                graph.edgeMetres[edge] * graph.edgeWeight[edge] + graph.edgeSurcharge[edge],
                graph.edgeMetres[edge],
                "no edge may ever cost less than its own length, or A* stops finding shortest paths"
            )
        }
    }

    /// Peel is the control in the remote engine's own sweep: almost no
    /// separately-mapped pavement, so the rule should have nothing to bite on.
    /// A lattice of bare streets stands in for it.
    func testAGraphWithNoMappedPavementIsUntouched() {
        let (graph, report) = LocalWalkingGraphBuilder.build(from: SyntheticOSM.grid(size: 6))
        XCTAssertEqual(report.pavedCarriageways, 0)
        XCTAssertTrue(graph.edgeSurcharge.allSatisfy { $0 == 0 })
    }

    func testTheBuildReportsWhatItGrouped() {
        let (_, report) = LocalWalkingGraphBuilder.build(from: street(crossingsEvery: 200))
        XCTAssertGreaterThan(report.groupedEdges, 0)
        XCTAssertGreaterThan(report.pavedCarriageways, 0)
        XCTAssertLessThan(report.buildMs, 2000, "grouping sits on the path of the first walk in a new area")
    }
}

extension LocalStreetGroupTests {
    /// Grouping runs once per area, but it runs on the path of the first walk
    /// somewhere new — so its cost is a walker waiting, not a background job.
    /// A 40×40 lattice is about 3,200 edges, the order of a town centre.
    func testGroupingCostAtTownScale() {
        let data = SyntheticOSM.grid(size: 40, spacingMetres: 60)
        let (graph, report) = LocalWalkingGraphBuilder.build(from: data)
        print("[grouping] edges=\(report.graphEdges) grouped=\(report.groupedEdges) buildMs=\(Int(report.buildMs))")
        XCTAssertGreaterThan(graph.edgeCount, 2000)
        XCTAssertLessThan(report.buildMs, 3000, "a walker is waiting for this")
    }
}
