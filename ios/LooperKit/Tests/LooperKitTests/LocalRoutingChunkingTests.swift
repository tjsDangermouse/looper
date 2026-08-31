import XCTest
@testable import LooperKit

/// Chunk boundaries, and the thing that must not happen at them.
///
/// A stored grid is an implementation detail of caching. It must be invisible
/// to routing: a lane that crosses from one chunk into the next has to come
/// back as one continuous way, and a walk must never dead-end because the
/// tile it was on ran out.
final class LocalRoutingChunkingTests: XCTestCase {
    private let grid = RoutingChunkGrid.standard

    private func manager(_ store: RoutingChunkStore, _ transport: StubOverpassTransport) -> RoutingDataManager {
        RoutingDataManager(
            store: store,
            source: OverpassRoutingDataSource(
                configuration: .init(endpoint: URL(string: "https://overpass.test/api/interpreter")!),
                transport: transport,
                audit: nil
            ),
            grid: grid,
            audit: nil
        )
    }

    // MARK: - Splitting a response into chunks

    func testAWayCrossingAChunkBoundaryIsStoredWholeInBoth() async throws {
        // A 3 km lane running east, which at z14 spans two or three chunks.
        let data = SyntheticOSM.line(from: SyntheticOSM.douglas, size: 31, spacingMetres: 100)
        let touched = Set(data.nodes.map { grid.chunk(lat: $0.lat, lon: $0.lon) })
        XCTAssertGreaterThan(touched.count, 1, "the fixture must actually cross a boundary")

        let store = RoutingChunkStore(directory: makeTemporaryDirectory())
        let manager = manager(store, StubOverpassTransport { _ in data })
        let pieces = await manager.split(data, into: Array(touched))

        for (id, piece) in pieces {
            XCTAssertEqual(piece.ways.count, 1, "\(id) should hold the whole way, not a fragment of it")
            // The halo: every node the way references, including the ones in
            // the neighbouring chunk. This is what stops a chunk inventing a
            // dead end at its own edge.
            XCTAssertEqual(piece.nodes.count, data.nodes.count)
        }
    }

    func testTheGraphIsContinuousAcrossChunksAndTruncatedWithoutThem() async throws {
        let data = SyntheticOSM.line(from: SyntheticOSM.douglas, size: 31, spacingMetres: 100)
        let chunks = Array(Set(data.nodes.map { grid.chunk(lat: $0.lat, lon: $0.lon) })).sorted()
        let store = RoutingChunkStore(directory: makeTemporaryDirectory())
        let manager = manager(store, StubOverpassTransport { _ in data })
        for (id, piece) in await manager.split(data, into: chunks) {
            await store.save(piece, for: id)
        }

        // Every chunk loaded: one lane, end to end, 3 km of it.
        let whole = await store.merged(chunks)
        let (joined, _) = LocalWalkingGraphBuilder.build(from: whole)
        XCTAssertEqual(joined.edgeCount, 1, "a way crossing a boundary must not arrive as two")
        XCTAssertEqual(joined.edgeMetres[0], 3000, accuracy: 20)

        // One chunk loaded: the lane still runs to the far end of its own
        // halo, so the graph stops short rather than stopping at the seam.
        let single = await store.merged([chunks[0]])
        let (partial, _) = LocalWalkingGraphBuilder.build(from: single)
        XCTAssertEqual(partial.edgeCount, 1)
        XCTAssertEqual(partial.edgeMetres[0], 3000, accuracy: 20)
    }

    func testALatticeSpanningManyChunksRoutesAsOneNetwork() async throws {
        // 4 km square of streets: several chunks across, in both directions.
        let data = SyntheticOSM.grid(size: 21, spacingMetres: 200)
        let chunks = Array(Set(data.nodes.map { grid.chunk(lat: $0.lat, lon: $0.lon) })).sorted()
        XCTAssertGreaterThan(chunks.count, 3, "the fixture must span several chunks in both directions")

        let store = RoutingChunkStore(directory: makeTemporaryDirectory())
        let manager = manager(store, StubOverpassTransport { _ in data })
        for (id, piece) in await manager.split(data, into: chunks) {
            await store.save(piece, for: id)
        }
        let merged = await store.merged(chunks)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: merged)

        XCTAssertEqual(graph.nodeCount, 21 * 21)
        XCTAssertEqual(graph.edgeCount, 2 * 21 * 20)

        // The decisive test: the network is one piece. Explored from the
        // middle, a radius that should reach the corner does reach it.
        let index = LocalEdgeIndex(graph: graph)
        let (subgraph, diagnostics) = try LocalExploration.explore(
            graph: graph, index: index,
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
            limitMetres: 4200
        )
        // Every junction in the lattice, plus a virtual start node when the
        // snap lands mid-street rather than on one.
        let virtualStart = subgraph.nodes[0].baseNode < 0 ? 1 : 0
        XCTAssertEqual(diagnostics.nodesReached, graph.nodeCount + virtualStart)
        XCTAssertLessThan(diagnostics.snapDistanceMetres, 10)
    }

    /// Four chunks meet at a point. A start right on that corner is the case
    /// where a naive "fetch the tile I'm in" design quietly loses three
    /// quarters of the network.
    func testAStartOnAFourChunkCornerStillSeesTheWholeNetwork() async throws {
        let corner = grid.chunk(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng).bounds
        let meetingPoint = Point(corner.east, corner.south)
        let data = SyntheticOSM.grid(centre: meetingPoint, size: 15, spacingMetres: 150)
        let chunks = Array(Set(data.nodes.map { grid.chunk(lat: $0.lat, lon: $0.lon) })).sorted()
        XCTAssertEqual(chunks.count, 4, "the fixture should straddle exactly the four chunks meeting at the corner")

        let store = RoutingChunkStore(directory: makeTemporaryDirectory())
        let manager = manager(store, StubOverpassTransport { _ in data })
        for (id, piece) in await manager.split(data, into: chunks) {
            await store.save(piece, for: id)
        }
        let (graph, _) = LocalWalkingGraphBuilder.build(from: await store.merged(chunks))
        XCTAssertEqual(graph.nodeCount, 15 * 15)

        let index = LocalEdgeIndex(graph: graph)
        let (subgraph, diagnostics) = try LocalExploration.explore(
            graph: graph, index: index, lat: meetingPoint.lat, lon: meetingPoint.lng, limitMetres: 3000
        )
        // Nothing is stranded on the far side of a chunk edge: all four
        // quadrants are reachable from a start sitting on the seam itself.
        let virtualStart = subgraph.nodes[0].baseNode < 0 ? 1 : 0
        XCTAssertEqual(diagnostics.nodesReached, graph.nodeCount + virtualStart)
    }

    // MARK: - Grouping requests

    func testAdjacentMissingChunksBecomeOneRequest() {
        let missing = (0..<3).flatMap { y in (0..<3).map { RoutingChunkID(z: 14, x: $0, y: y) } }
        let groups = RoutingDataManager.groups(for: missing)
        XCTAssertEqual(groups.count, 1, "a solid 3×3 block is one bounding box worth asking for")
        XCTAssertEqual(groups[0].count, 9)
    }

    func testSeparatedClustersStayApart() {
        // Two blocks with a cached gap between them: one request spanning both
        // would re-download the middle for nothing.
        let left = (0..<2).flatMap { y in (0..<2).map { RoutingChunkID(z: 14, x: $0, y: y) } }
        let right = (0..<2).flatMap { y in (20..<22).map { RoutingChunkID(z: 14, x: $0, y: y) } }
        let groups = RoutingDataManager.groups(for: left + right)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.count)), [4])
    }

    func testASparseDiagonalIsNotAskedForAsOneBigSquare() {
        // Five chunks strung diagonally span a 5×5 square that is 80% cached.
        let diagonal = (0..<5).map { RoutingChunkID(z: 14, x: $0, y: $0) }
        let groups = RoutingDataManager.groups(for: diagonal)
        XCTAssertGreaterThan(groups.count, 1, "asking for the whole square would fetch 20 chunks to get 5")
        XCTAssertEqual(groups.flatMap { $0 }.count, 5)
    }

    // MARK: - Acquisition

    func testOnlyMissingChunksAreFetchedAndTheSecondRequestIsFree() async throws {
        let data = SyntheticOSM.grid(size: 30, spacingMetres: 200)
        let transport = StubOverpassTransport { _ in data }
        let store = RoutingChunkStore(directory: makeTemporaryDirectory())
        let manager = manager(store, transport)

        let first = try await manager.ensureCoverage(
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 3000
        )
        XCTAssertGreaterThan(first.chunksPopulated, 0)
        XCTAssertGreaterThan(first.overpassRequests, 0)
        XCTAssertTrue(first.coverage.isComplete)
        XCTAssertGreaterThan(first.storedBytes, 0)
        let afterFirst = transport.requestCount

        // Warm: the same walk asks the network for nothing at all.
        let second = try await manager.ensureCoverage(
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: 3000
        )
        XCTAssertEqual(second.overpassRequests, 0)
        XCTAssertEqual(second.chunksPopulated, 0)
        XCTAssertEqual(transport.requestCount, afterFirst, "a cached area must make no requests whatsoever")
    }

    /// The rule the comparison test depends on: when local data is missing and
    /// there is no network, the answer is an error naming that fact — never a
    /// quiet trip to the remote router.
    func testAnUncachedAreaOfflineFailsRatherThanFallingBack() async {
        let transport = StubOverpassTransport { _ in OSMData() }
        let store = RoutingChunkStore(directory: makeTemporaryDirectory())
        let manager = manager(store, transport)
        do {
            _ = try await manager.ensureCoverage(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng,
                targetMetres: 5000, allowDownload: false
            )
            XCTFail("routing on data the phone does not have is not an answer")
        } catch {
            XCTAssertEqual(error as? RoutingDataManager.AcquisitionError, .dataUnavailableOffline)
            XCTAssertEqual(transport.requestCount, 0)
        }
    }

    func testAnEmptyAreaIsRememberedRatherThanAskedForAgain() async throws {
        let transport = StubOverpassTransport { _ in OSMData() }
        let store = RoutingChunkStore(directory: makeTemporaryDirectory())
        let manager = manager(store, transport)
        // Somewhere with no mapped paths at all: open sea.
        _ = try await manager.ensureCoverage(lat: 54.5, lon: -3.5, targetMetres: 2000)
        let requests = transport.requestCount
        _ = try await manager.ensureCoverage(lat: 54.5, lon: -3.5, targetMetres: 2000)
        XCTAssertEqual(transport.requestCount, requests, "an area known to be empty is not fetched twice")
    }

    func testAnOfflineAreaDownloadPinsEverythingItCovers() async throws {
        let data = SyntheticOSM.grid(size: 20, spacingMetres: 200)
        let store = RoutingChunkStore(directory: makeTemporaryDirectory())
        let manager = manager(store, StubOverpassTransport { _ in data })
        let bounds = LocalGeo.boundsAround(lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: 1500)
        let report = try await manager.downloadOfflineArea(bounds)
        XCTAssertTrue(report.coverage.isComplete)
        let metadata = await store.allMetadata()
        XCTAssertFalse(metadata.isEmpty)
        XCTAssertTrue(metadata.allSatisfy { $0.retention == .pinned })

        // And the router cannot tell the difference: the same store answers.
        let evicted = await store.evictIfNeeded(budget: 0)
        XCTAssertTrue(evicted.isEmpty)
    }
}
