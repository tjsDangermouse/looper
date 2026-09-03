import XCTest
@testable import LooperKit

/// Crossing a road, as data and as something said out loud.
///
/// The complaint these cover is one a walker made in the field: told to "turn
/// right" where there was no turning, because the route was crossing the road
/// and the router had described the crossing as two corners — a right onto ten
/// metres of unnamed tarmac and a left off it again.
final class LocalCrossingTests: XCTestCase {

    // MARK: - Reading the tags

    func testACrossingIsRecognisedFromTheWaysOwnTags() {
        let policy = PedestrianAccessPolicy.standard
        XCTAssertTrue(policy.isCrossing(tags: ["highway": "footway", "footway": "crossing"]))
        XCTAssertTrue(policy.isCrossing(tags: ["highway": "crossing"]))
        // Older data says it with a bare `crossing=*` on the pedestrian way.
        XCTAssertTrue(policy.isCrossing(tags: ["highway": "footway", "crossing": "marked"]))
        XCTAssertTrue(policy.isCrossing(tags: ["highway": "path", "crossing": "traffic_signals"]))

        XCTAssertFalse(policy.isCrossing(tags: ["highway": "footway", "footway": "sidewalk"]))
        XCTAssertFalse(policy.isCrossing(tags: ["highway": "footway"]))
        // `crossing=no` is the opposite claim, and on a carriageway it is a
        // statement about the road rather than about a way across it.
        XCTAssertFalse(policy.isCrossing(tags: ["highway": "footway", "crossing": "no"]))
        XCTAssertFalse(policy.isCrossing(tags: ["highway": "residential", "crossing": "no"]))
        XCTAssertFalse(policy.isCrossing(tags: ["highway": "residential", "crossing": "marked"]))
    }

    /// Nothing in the cost model may read the crossing flag yet: Phase A
    /// changes what is *said* about a route and must not change the route.
    func testMarkingACrossingDoesNotChangeWhatItCostsToWalk() {
        let policy = PedestrianAccessPolicy.standard
        let crossing = policy.decide(tags: ["highway": "footway", "footway": "crossing"])
        let pavement = policy.decide(tags: ["highway": "footway", "footway": "sidewalk"])
        XCTAssertEqual(crossing.weight, pavement.weight, accuracy: 0.0001)
        XCTAssertEqual(crossing.roadClass, .footway)
    }

    // MARK: - A street with a pavement each side

    /// Main Street running east, a pavement eight metres either side of it, and
    /// one crossing joining the two. The crossing way runs through the node it
    /// shares with the carriageway, which is how OSM connects the two and why
    /// the graph cuts the crossing in half there.
    private func streetWithPavements(roadName: String? = "Main Street") -> OSMData {
        let centre = SyntheticOSM.douglas
        func at(east: Double, north: Double) -> (lat: Double, lon: Double) {
            let moved = LocalGeo.destination(lat: centre.lat, lon: centre.lng, metres: north, bearing: 0)
            return LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        }
        var nodes: [OSMNode] = []
        func node(_ id: Int64, east: Double, north: Double) {
            let placed = at(east: east, north: north)
            nodes.append(OSMNode(id: id, lat: placed.lat, lon: placed.lon))
        }
        // Carriageway
        node(1, east: -100, north: 0); node(2, east: 0, north: 0); node(3, east: 100, north: 0)
        // North pavement
        node(11, east: -100, north: 8); node(12, east: 0, north: 8); node(13, east: 100, north: 8)
        // South pavement
        node(21, east: -100, north: -8); node(22, east: 0, north: -8); node(23, east: 100, north: -8)

        var road = ["highway": "residential"]
        if let roadName { road["name"] = roadName }
        let ways = [
            OSMWay(id: 1, nodes: [1, 2, 3], tags: road),
            OSMWay(id: 2, nodes: [11, 12, 13], tags: ["highway": "footway", "footway": "sidewalk"]),
            OSMWay(id: 3, nodes: [21, 22, 23], tags: ["highway": "footway", "footway": "sidewalk"]),
            OSMWay(id: 4, nodes: [12, 2, 22], tags: ["highway": "footway", "footway": "crossing"]),
        ]
        return OSMData(nodes: nodes, ways: ways)
    }

    func testTheGraphKnowsWhichEdgesAreCrossingsAndWhatTheyCross() {
        let (graph, _) = LocalWalkingGraphBuilder.build(from: streetWithPavements())
        var crossings = 0
        for edge in 0..<graph.edgeCount {
            guard graph.isCrossing(ofEdge: edge) else {
                XCTAssertNil(graph.crossedRoad(ofEdge: edge), "only a crossing crosses something")
                continue
            }
            crossings += 1
            XCTAssertEqual(
                graph.crossedRoad(ofEdge: edge), "Main Street",
                "the carriageway is incident to the crossing's own endpoint, so its name is readable"
            )
        }
        // Cut at the carriageway node it shares: kerb to road, road to far kerb.
        XCTAssertEqual(crossings, 2, "one kerb-to-kerb crossing, as two graph edges")
    }

    func testAnUnnamedCarriagewayLeavesTheCrossingUnnamed() {
        let (graph, _) = LocalWalkingGraphBuilder.build(from: streetWithPavements(roadName: nil))
        let crossings = (0..<graph.edgeCount).filter { graph.isCrossing(ofEdge: $0) }
        XCTAssertFalse(crossings.isEmpty)
        for edge in crossings { XCTAssertNil(graph.crossedRoad(ofEdge: edge)) }
    }

    // MARK: - What it says

    private func leg(
        from: Point, bearing: Double, metres: Double, name: String?,
        roadClass: PedestrianAccessPolicy.RoadClass = .footway,
        isCrossing: Bool = false, crosses: String? = nil
    ) -> WalkLeg {
        let end = LocalGeo.destination(lat: from.lat, lon: from.lng, metres: metres, bearing: bearing)
        return WalkLeg(
            coordinates: [from, Point(end.lon, end.lat)], metres: metres, name: name,
            roadClass: roadClass, physical: -1, isCrossing: isCrossing, crosses: crosses
        )
    }

    /// The headline. A crossing is one instruction that names the road, not a
    /// right turn followed by a left.
    func testCrossingTheRoadIsOneInstructionAndNamesTheRoad() {
        let start = SyntheticOSM.douglas
        let pavement = leg(from: start, bearing: 90, metres: 120, name: nil)
        let crossing = leg(
            from: pavement.coordinates.last!, bearing: 180, metres: 16, name: nil,
            isCrossing: true, crosses: "Main Street"
        )
        let onward = leg(from: crossing.coordinates.last!, bearing: 90, metres: 120, name: nil)

        let steps = tidySteps(LocalInstructions.steps(for: [pavement, crossing, onward]))
        XCTAssertEqual(steps.count, 3, "set off, cross, arrive — and no turns")
        XCTAssertEqual(steps[1].instruction, "Cross Main Street")
        XCTAssertEqual(turnKind(steps[1]), .straight, "a crossing draws as straight ahead")
        XCTAssertEqual(steps[1].distanceMeters, 136, accuracy: 1, "the crossing and the road it leads onto")
        XCTAssertFalse(
            steps.contains { $0.instruction.contains("Turn") },
            "no turning was ever there to take"
        )
        // The ground still adds up to the walk.
        XCTAssertEqual(steps.map(\.distanceMeters).reduce(0, +), 256, accuracy: 2)
    }

    /// A crossing way is cut at the carriageway, so the common case arrives as
    /// two legs and must still be one instruction.
    func testACrossingSplitInTwoIsStillOneInstruction() {
        let start = SyntheticOSM.douglas
        let pavement = leg(from: start, bearing: 90, metres: 100, name: "Main Street")
        let toRoad = leg(
            from: pavement.coordinates.last!, bearing: 180, metres: 8, name: nil,
            isCrossing: true, crosses: "Main Street"
        )
        let fromRoad = leg(
            from: toRoad.coordinates.last!, bearing: 180, metres: 8, name: nil,
            isCrossing: true, crosses: "Main Street"
        )
        let onward = leg(from: fromRoad.coordinates.last!, bearing: 90, metres: 100, name: "Main Street")

        let steps = tidySteps(LocalInstructions.steps(for: [pavement, toRoad, fromRoad, onward]))
        XCTAssertEqual(steps.filter { $0.instruction.hasPrefix("Cross") }.count, 1)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[1].instruction, "Cross Main Street")
    }

    func testAnUnnamedRoadIsCrossedAllTheSame() {
        let start = SyntheticOSM.douglas
        let pavement = leg(from: start, bearing: 90, metres: 100, name: nil)
        let crossing = leg(
            from: pavement.coordinates.last!, bearing: 180, metres: 14, name: nil, isCrossing: true
        )
        let onward = leg(from: crossing.coordinates.last!, bearing: 90, metres: 100, name: nil)
        let steps = LocalInstructions.steps(for: [pavement, crossing, onward])
        XCTAssertEqual(steps[1].instruction, "Cross the road")
    }

    /// Both pavements of one street carry the street's name, so `tidySteps`'s
    /// "you cannot turn onto the road you are already on" rule would fold the
    /// crossing away — deleting the one instruction the walker cannot infer.
    func testACrossingSurvivesTidyingEvenBetweenTwoPavementsOfOneStreet() {
        let steps = tidySteps([
            Step(instruction: "Set off along Main Street", distanceMeters: 100, durationSeconds: 72,
                 maneuver: .name("continue"), road: "Main Street"),
            Step(instruction: "Cross Main Street", distanceMeters: 8, durationSeconds: 6,
                 maneuver: .name("cross"), road: "Main Street"),
            Step(instruction: "Turn left onto Quay Road", distanceMeters: 90, durationSeconds: 65,
                 maneuver: .name("turn-left"), road: "Quay Road"),
        ])
        XCTAssertEqual(
            steps.map(\.instruction),
            ["Set off along Main Street", "Cross Main Street", "Turn left onto Quay Road"]
        )
        // Short enough for the micro-step rule and same-named enough for the
        // rejoin rule, and neither may touch it.
        XCTAssertEqual(steps.map(\.distanceMeters).reduce(0, +), 198)
    }

    // MARK: - Judging a turn over ground rather than over one vertex

    /// A crossing leaves the kerb at right angles. Judged on its first two
    /// coordinates it is a square turn; judged over twelve metres of the walk
    /// either side of the junction it is what it is — straight on.
    func testAManoeuvreIsJudgedOverGroundNotOverOneVertex() {
        let start = SyntheticOSM.douglas
        // Straight east, a two-metre jink south, then straight east again.
        let before = leg(from: start, bearing: 90, metres: 100, name: "Main Street")
        let jink = leg(from: before.coordinates.last!, bearing: 180, metres: 2, name: "Main Street")
        let after = leg(from: jink.coordinates.last!, bearing: 90, metres: 100, name: "Main Street")
        let steps = LocalInstructions.steps(for: [before, jink, after])
        XCTAssertEqual(steps.count, 2, "one road walked, and arriving")
        XCTAssertFalse(steps[0].instruction.contains("Turn"))
    }

    /// And the window must not smooth away a corner that is really there.
    func testARealCornerIsStillCalled() {
        let start = SyntheticOSM.douglas
        let first = leg(from: start, bearing: 0, metres: 80, name: "First Street", roadClass: .residential)
        let second = leg(
            from: first.coordinates.last!, bearing: 90, metres: 80, name: "Second Street",
            roadClass: .residential
        )
        let steps = LocalInstructions.steps(for: [first, second])
        XCTAssertEqual(steps[1].instruction, "Turn right onto Second Street")
    }

    // MARK: - Counting what happens

    private func sideSwap() -> [WalkLeg] {
        let start = SyntheticOSM.douglas
        let north = leg(from: start, bearing: 90, metres: 40, name: "Main Street")
        let over = leg(
            from: north.coordinates.last!, bearing: 180, metres: 10, name: nil,
            isCrossing: true, crosses: "Main Street"
        )
        let south = leg(from: over.coordinates.last!, bearing: 90, metres: 30, name: "Main Street")
        let back = leg(
            from: south.coordinates.last!, bearing: 0, metres: 10, name: nil,
            isCrossing: true, crosses: "Main Street"
        )
        let onward = leg(from: back.coordinates.last!, bearing: 90, metres: 40, name: "Main Street")
        return [north, over, south, back, onward]
    }

    func testCrossingsAreCountedAndACrossBackIsSpotted() {
        let report = RouteQuality.pavement(of: sideSwap())
        XCTAssertEqual(report.crossings, 2)
        XCTAssertEqual(report.crossBacks, 1, "thirty metres later is a change of mind, not a second road")
        XCTAssertGreaterThan(report.crossingsPerKm, 0)
    }

    func testConsecutiveCrossingLegsAreOneCrossing() {
        let start = SyntheticOSM.douglas
        let pavement = leg(from: start, bearing: 90, metres: 100, name: "Main Street")
        let toRoad = leg(from: pavement.coordinates.last!, bearing: 180, metres: 8, name: nil, isCrossing: true)
        let fromRoad = leg(from: toRoad.coordinates.last!, bearing: 180, metres: 8, name: nil, isCrossing: true)
        let onward = leg(from: fromRoad.coordinates.last!, bearing: 90, metres: 100, name: "Main Street")
        let report = RouteQuality.pavement(of: [pavement, toRoad, fromRoad, onward])
        XCTAssertEqual(report.crossings, 1)
        XCTAssertEqual(report.crossBacks, 0)
    }

    /// Deliberate, and the reason the new counters had to exist.
    ///
    /// `hops` counts pavement-to-carriageway transitions, and a walk that hops
    /// from one pavement to the other and back never leaves pedestrian ground.
    /// So it scores zero — which is why every measurement taken before this,
    /// including the sweep that chose the profile's multiplier, was blind to
    /// the swapping the walker actually complained about. `hops` is left alone
    /// so the old series stays comparable; this pins that decision down.
    func testTheOldPavementHopCountIsBlindToASideSwap() {
        let report = RouteQuality.pavement(of: sideSwap())
        XCTAssertEqual(report.hops, 0)
        XCTAssertEqual(report.share, 1, accuracy: 0.0001, "all of it is pavement, and all of it is a mess")
        XCTAssertEqual(report.crossBacks, 1, "which only the new counter can see")
    }

    // MARK: - Walking the loop the other way round

    func testReversingTheLoopKeepsTheCrossing() {
        let route = Route(
            id: "r", name: "n", distanceMeters: 208, durationSeconds: 150, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [Point(0, 0), Point(0.001, 0), Point(0.002, 0)]),
            steps: [
                Step(instruction: "Set off along Main Street", distanceMeters: 100, durationSeconds: 72,
                     maneuver: .name("continue"), road: "Main Street"),
                Step(instruction: "Cross Quay Road", distanceMeters: 108, durationSeconds: 78,
                     maneuver: .name("cross"), road: "Quay Road"),
                Step(instruction: "You’re back where you started", distanceMeters: 0, durationSeconds: 0,
                     maneuver: .name("finish"), road: nil),
            ]
        )
        let back = reverseRoute(route)
        XCTAssertTrue(
            back.steps.contains { $0.instruction == "Cross Quay Road" },
            "the same road is crossed at the same place whichever way round the loop is walked"
        )
        XCTAssertFalse(back.steps.contains { $0.instruction.contains("Cross Quay Road onto") })
    }
}
