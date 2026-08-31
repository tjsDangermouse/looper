import XCTest
@testable import LooperKit

/// The data foundation, end to end: pick a coordinate, work out the area,
/// query the source, parse, filter, build a graph, store it, reload it, and
/// traverse it with the network taken away.
///
/// This is deliberately the first thing proved. A sophisticated loop search
/// over a graph the phone does not actually own is not an offline router.
final class LocalRoutingDataTests: XCTestCase {

    // MARK: - Coverage arithmetic

    func testCoverageRadiusFollowsTheDistanceTolerance() {
        // D * (1 + 0.12) / 2 — no point on an admissible closed walk is
        // further than this from the door.
        XCTAssertEqual(RoutingCoverage.explorationRadiusMetres(targetMetres: 2000), 1120, accuracy: 0.5)
        XCTAssertEqual(RoutingCoverage.explorationRadiusMetres(targetMetres: 5000), 2800, accuracy: 0.5)
        XCTAssertEqual(RoutingCoverage.explorationRadiusMetres(targetMetres: 10000), 5600, accuracy: 0.5)
    }

    /// The whole premise: a 5 km walk needs a town's worth of chunks, not an
    /// island's. If this number ever reaches the hundreds, the design has
    /// stopped doing what it exists to do.
    func testFiveKilometresNeedsASmallNumberOfChunks() {
        let chunks = RoutingCoverage.requiredChunks(
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 5000
        )
        XCTAssertGreaterThan(chunks.count, 4)
        XCTAssertLessThan(chunks.count, 40)
        // And every one of them is genuinely near Douglas.
        let bounds = RoutingDataManager.bounds(of: chunks)
        XCTAssertLessThan(
            LocalGeo.distance(lat1: bounds.centre.lat, lon1: bounds.centre.lng,
                              lat2: SyntheticOSM.douglas.lat, lon2: SyntheticOSM.douglas.lng),
            2000
        )
    }

    func testChunkGridIsDeterministicAndTilesTheArea() {
        let grid = RoutingChunkGrid.standard
        let chunk = grid.chunk(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng)
        XCTAssertEqual(chunk, grid.chunk(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng))
        XCTAssertTrue(chunk.bounds.contains(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng))
        XCTAssertEqual(RoutingChunkID(key: chunk.key), chunk)
        // A z14 chunk near 54°N is about 1.4 km across; the number the whole
        // sizing argument rests on.
        XCTAssertEqual(grid.chunkWidthMetres(atLatitude: 54.15), 1437, accuracy: 60)
    }

    // MARK: - Overpass

    func testTheQueryAsksForHighwayWaysAndTheirNodes() {
        let bounds = GeographicBounds(south: 54.1, west: -4.5, north: 54.2, east: -4.4)
        let query = OverpassRoutingDataSource.query(for: bounds, timeoutSeconds: 90)
        XCTAssertTrue(query.contains("[out:json][timeout:90]"))
        XCTAssertTrue(query.contains(#"way["highway"](54.100000,-4.500000,54.200000,-4.400000)"#))
        // The recursion is what brings back nodes outside the box, so a way
        // leaving the area is not cut in half at its edge.
        XCTAssertTrue(query.contains("(._;>;)"))
        XCTAssertTrue(query.contains("out body qt"))
    }

    func testParsingKeepsOnlyHighwayWaysAndTheTagsThePolicyReads() throws {
        let json = """
        {"elements":[
          {"type":"node","id":1,"lat":54.15,"lon":-4.48},
          {"type":"node","id":2,"lat":54.151,"lon":-4.48,"tags":{"barrier":"gate","source":"survey"}},
          {"type":"way","id":10,"nodes":[1,2],"tags":{"highway":"footway","name":"Quay Walk","source":"bing"}},
          {"type":"way","id":11,"nodes":[1,2],"tags":{"building":"yes"}}
        ]}
        """
        let parsed = try OverpassJSON.parse(Data(json.utf8))
        XCTAssertEqual(parsed.ways.count, 1)
        XCTAssertEqual(parsed.ways[0].tags["name"], "Quay Walk")
        XCTAssertNil(parsed.ways[0].tags["source"], "an unread tag is not worth storing on every way in a town")
        XCTAssertEqual(parsed.nodes.count, 2)
        XCTAssertEqual(parsed.nodes[1].tags["barrier"], "gate")
        XCTAssertNil(parsed.nodes[1].tags["source"])
    }

    /// A truncated answer stored as though it were complete is the one cache
    /// failure that would not show up until somebody was standing in the rain.
    func testATimedOutOverpassAnswerIsAnErrorRatherThanAnEmptyArea() {
        let json = #"{"elements":[],"remark":"runtime error: Query timed out in \"query\" at line 2"}"#
        XCTAssertThrowsError(try OverpassJSON.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? OverpassParseError, .remarkedFailure("runtime error: Query timed out in \"query\" at line 2"))
        }
    }

    // MARK: - Pedestrian access

    func testPedestrianAccessPolicy() {
        let policy = PedestrianAccessPolicy.standard
        for highway in ["footway", "path", "pedestrian", "residential", "living_street",
                        "service", "track", "steps", "unclassified", "tertiary", "secondary", "primary"] {
            XCTAssertTrue(policy.decide(tags: ["highway": highway]).isWalkable, "\(highway) should be walkable")
        }
        for highway in ["motorway", "motorway_link", "trunk", "raceway", "proposed"] {
            XCTAssertFalse(policy.decide(tags: ["highway": highway]).isWalkable, "\(highway) must not be walkable")
        }
        // Explicit tags beat the default in both directions...
        XCTAssertFalse(policy.decide(tags: ["highway": "footway", "foot": "no"]).isWalkable)
        XCTAssertFalse(policy.decide(tags: ["highway": "service", "access": "private"]).isWalkable)
        XCTAssertTrue(policy.decide(tags: ["highway": "service", "access": "private", "foot": "yes"]).isWalkable)
        XCTAssertTrue(policy.decide(tags: ["highway": "track", "access": "permissive"]).isWalkable)
        XCTAssertTrue(policy.decide(tags: ["highway": "service", "access": "destination"]).isWalkable)
        // ...except on a motorway, where foot=yes is a tagging error.
        XCTAssertFalse(policy.decide(tags: ["highway": "motorway", "foot": "yes"]).isWalkable)
        // A trunk road in a country that permits walking, tagged to say so.
        XCTAssertTrue(policy.decide(tags: ["highway": "trunk", "foot": "yes"]).isWalkable)
    }

    func testOnewayIsATrafficRuleNotAWalkingRule() {
        let policy = PedestrianAccessPolicy.standard
        let street = policy.decide(tags: ["highway": "residential", "oneway": "yes"])
        XCTAssertTrue(street.forward)
        XCTAssertTrue(street.backward, "walkers use both pavements of a one-way street")

        let turnstile = policy.decide(tags: ["highway": "footway", "oneway:foot": "yes"])
        XCTAssertTrue(turnstile.forward)
        XCTAssertFalse(turnstile.backward)

        let escalator = policy.decide(tags: ["highway": "steps", "conveying": "forward"])
        XCTAssertTrue(escalator.forward)
        XCTAssertFalse(escalator.backward)
    }

    func testBarrierNodes() {
        let policy = PedestrianAccessPolicy.standard
        XCTAssertTrue(policy.canPass(nodeTags: [:]))
        XCTAssertTrue(policy.canPass(nodeTags: ["barrier": "gate"]))
        XCTAssertFalse(policy.canPass(nodeTags: ["barrier": "gate", "locked": "yes"]))
        XCTAssertFalse(policy.canPass(nodeTags: ["barrier": "wall"]))
        XCTAssertTrue(policy.canPass(nodeTags: ["barrier": "stile"]))
        XCTAssertTrue(policy.canPass(nodeTags: ["barrier": "kissing_gate"]))
        XCTAssertFalse(policy.canPass(nodeTags: ["access": "private"]))
    }

    // MARK: - Graph building

    func testTheGridBecomesAJunctionGraph() {
        let (graph, report) = LocalWalkingGraphBuilder.build(from: SyntheticOSM.grid(size: 4, spacingMetres: 200))
        // Every lattice point is on two ways, so every one is a junction.
        XCTAssertEqual(graph.nodeCount, 16)
        // 4 rows × 3 spans + 4 columns × 3 spans.
        XCTAssertEqual(graph.edgeCount, 24)
        XCTAssertEqual(report.waysWalkable, 8)
        // Two-way streets: an arc each way per edge.
        XCTAssertEqual(graph.arcCount, 48)
        XCTAssertEqual(graph.edgeMetres[0], 200, accuracy: 1)
        XCTAssertNotNil(graph.name(ofEdge: 0))
    }

    func testInterveningVerticesAreGeometryRatherThanNodes() {
        // One footway with five vertices and no side turnings: one edge.
        let (graph, _) = LocalWalkingGraphBuilder.build(
            from: SyntheticOSM.line(from: SyntheticOSM.douglas, size: 5, spacingMetres: 100)
        )
        XCTAssertEqual(graph.nodeCount, 2)
        XCTAssertEqual(graph.edgeCount, 1)
        XCTAssertEqual(graph.line(ofEdge: 0).count, 10, "all five vertices are kept as geometry")
        XCTAssertEqual(graph.edgeMetres[0], 400, accuracy: 2)
    }

    func testALockedGateSeversTheWay() {
        var data = SyntheticOSM.line(from: SyntheticOSM.douglas, size: 5, spacingMetres: 100)
        data.nodes[2].tags = ["barrier": "gate", "locked": "yes"]
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        // Two stubs meeting at nothing: no route may pass through the gate.
        XCTAssertEqual(graph.edgeCount, 2)
        let reachable = Set(graph.edgeFrom.map { Int($0) } + graph.edgeTo.map { Int($0) })
        XCTAssertEqual(reachable.count, 4, "the two halves must not share a node")
    }

    func testMotorwaysAreLeftOutOfTheGraph() {
        var data = SyntheticOSM.grid(size: 3, spacingMetres: 200)
        data.ways.append(OSMWay(id: 500, nodes: [1, 2, 3], tags: ["highway": "motorway", "name": "Bypass"]))
        let (graph, report) = LocalWalkingGraphBuilder.build(from: data)
        XCTAssertEqual(report.waysConsidered, 7)
        XCTAssertEqual(report.waysWalkable, 6)
        XCTAssertFalse(graph.names.contains("Bypass"))
    }

    // MARK: - Snapping

    func testSnappingReachesTheInteriorOfAnEdge() {
        let (graph, _) = LocalWalkingGraphBuilder.build(
            from: SyntheticOSM.line(from: SyntheticOSM.douglas, size: 2, spacingMetres: 400)
        )
        let index = LocalEdgeIndex(graph: graph)
        // A point 30 m north of the middle of the only street.
        let middle = LocalGeo.destination(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: 200, bearing: 90)
        let offset = LocalGeo.destination(lat: middle.lat, lon: middle.lon, metres: 30, bearing: 0)
        let snap = try? XCTUnwrap(index.snap(lat: offset.lat, lon: offset.lon, graph: graph))
        XCTAssertEqual(snap?.distanceMetres ?? 0, 30, accuracy: 2)
        XCTAssertEqual(snap?.metresFromStart ?? 0, 200, accuracy: 3)
        XCTAssertFalse(snap?.isAtNode ?? true, "the middle of a 400 m street is not a junction")
    }

    func testSnappingFindsTheNearestOfManyEdges() {
        let (graph, _) = LocalWalkingGraphBuilder.build(from: SyntheticOSM.grid(size: 8, spacingMetres: 200))
        let index = LocalEdgeIndex(graph: graph)
        let snap = index.snap(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, graph: graph)
        XCTAssertNotNil(snap)
        XCTAssertLessThan(snap!.distanceMetres, 105, "the centre of the lattice is at most half a block from a street")
    }

    // MARK: - Store, and the round trip through it

    func testAChunkSurvivesEncodingAndReloading() throws {
        let data = SyntheticOSM.grid(size: 6, spacingMetres: 150)
        let decoded = try RoutingChunkCodec.decode(RoutingChunkCodec.encode(data))
        XCTAssertEqual(decoded.ways.count, data.ways.count)
        XCTAssertEqual(decoded.nodes.count, data.nodes.count)
        let original = data.nodes.sorted { $0.id < $1.id }
        let reloaded = decoded.nodes.sorted { $0.id < $1.id }
        for (a, b) in zip(original, reloaded) {
            XCTAssertEqual(a.id, b.id)
            XCTAssertEqual(a.lat, b.lat, accuracy: 1e-6)
            XCTAssertEqual(a.lon, b.lon, accuracy: 1e-6)
        }
        XCTAssertEqual(decoded.ways.sorted { $0.id < $1.id }.first?.nodes, data.ways.sorted { $0.id < $1.id }.first?.nodes)
    }

    func testTheStoreKeepsChunksAcrossInstances() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = RoutingChunkID(z: 14, x: 100, y: 200)
        let data = SyntheticOSM.grid(size: 4, spacingMetres: 200)

        let first = RoutingChunkStore(directory: directory)
        let entry = await first.save(data, for: id)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.retention, .automatic)

        // A second store over the same directory is the app after a restart.
        let second = RoutingChunkStore(directory: directory)
        let present = await second.contains(id)
        XCTAssertTrue(present)
        let reloaded = await second.chunk(id)
        XCTAssertEqual(reloaded?.ways.count, data.ways.count)
        let missing = await second.missing(from: [id, RoutingChunkID(z: 14, x: 101, y: 200)])
        XCTAssertEqual(missing.count, 1)
    }

    /// The distinction the future Offline Areas feature rests on, tested now
    /// so that feature is a screen rather than a redesign.
    func testPinnedChunksSurviveEvictionAndAutomaticOnesDoNot() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoutingChunkStore(directory: directory)
        let keep = RoutingChunkID(z: 14, x: 1, y: 1)
        let drop = RoutingChunkID(z: 14, x: 2, y: 1)
        let data = SyntheticOSM.grid(size: 6, spacingMetres: 200)
        await store.save(data, for: keep, retention: .pinned)
        await store.save(data, for: drop, retention: .automatic)

        let evicted = await store.evictIfNeeded(budget: 1)
        XCTAssertEqual(evicted, [drop])
        let keptSurvives = await store.contains(keep)
        let droppedGone = await store.contains(drop)
        XCTAssertTrue(keptSurvives)
        XCTAssertFalse(droppedGone)
        let pinnedBytes = await store.pinnedBytes()
        let automaticBytes = await store.automaticBytes()
        XCTAssertGreaterThan(pinnedBytes, 0)
        XCTAssertEqual(automaticBytes, 0)

        // And an automatic refetch of a pinned chunk must not quietly demote it.
        await store.save(data, for: keep, retention: .automatic)
        let retention = await store.metadata(for: keep)?.retention
        XCTAssertEqual(retention, .pinned)
    }
}
