import XCTest
@testable import LooperKit

/// Real data, real measurements. Skipped unless LOOPER_LIVE_OVERPASS is set,
/// because a unit suite that depends on a volunteer-run public service is a
/// unit suite that fails on a train.
final class LiveOverpassMeasurementTests: XCTestCase {
    private let places: [(String, Point)] = [
        ("Douglas", Point(-4.4816, 54.1506)),
        ("Peel", Point(-4.6997, 54.2246)),
        ("Onchan", Point(-4.4569, 54.1728)),
    ]

    func testMeasureRealAreas() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOOPER_LIVE_OVERPASS"] == "1")
        for (name, point) in places {
            for targetKm in [3.0, 4.0, 5.0, 8.0] where name == "Douglas" || targetKm == 5 {
                // A cache that survives between runs, so re-measuring costs
                // the public endpoint nothing. Being able to re-run this
                // without re-downloading is the same property the app relies
                // on, exercised for the same reason.
                let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("looper-live-chunks", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let audit = RoutingAudit()
                let store = RoutingChunkStore(directory: directory)
                // Patient on purpose. The public endpoint is volunteer-run
                // and answers a burst of large bbox queries with 504s; a
                // measurement run is exactly the kind of traffic that should
                // wait rather than hammer.
                let source = OverpassRoutingDataSource(
                    configuration: .init(serverTimeoutSeconds: 120, maxAttempts: 5, retryDelaySeconds: 15),
                    audit: audit
                )
                let manager = RoutingDataManager(store: store, source: source, audit: audit)
                let target = targetKm * 1000

                let before = await manager.coverage(lat: point.lat, lon: point.lng, targetMetres: target)
                let report = try await manager.ensureCoverage(lat: point.lat, lon: point.lng, targetMetres: target)
                let snapshot = await audit.snapshot()

                let data = await manager.storedData(lat: point.lat, lon: point.lng, targetMetres: target)
                let (graph, build) = LocalWalkingGraphBuilder.build(from: data)
                let index = LocalEdgeIndex(graph: graph)
                let router = LocalLoopRouter()
                let began = Date()
                let result = try router.findLoops(
                    .init(lat: point.lat, lon: point.lng, targetMetres: target), in: graph, index: index
                )
                let ms = Date().timeIntervalSince(began) * 1000

                print("""
                [live] \(name) \(Int(targetKm))km \
                radius=\(Int(before.requiredRadiusMetres))m chunks=\(before.requiredChunks.count) \
                cached=\(before.cachedChunks.count) missing=\(before.missingChunks.count) \
                requests=\(snapshot.overpassCallCount) download=\(snapshot.downloadedBytes / 1024)KB \
                ways=\(snapshot.waysReceived) nodes=\(snapshot.nodesReceived) \
                stored=\(report.storedBytes / 1024)KB \
                graph=\(build.graphNodes)n/\(build.graphEdges)e \
                walkable=\(build.waysWalkable)/\(build.waysConsidered) \
                explored=\(result.diagnostics.exploration.nodesReached)n \
                super=\(result.diagnostics.searchGraph.superEdges) \
                closed=\(result.diagnostics.closedWalks) shape-]=\(result.diagnostics.rejectedShape) turns-]=\(result.diagnostics.rejectedTurns) gate-]=\(result.diagnostics.gateRejected) passed=\(result.diagnostics.passedGate) \
                diverse-]=\(result.diagnostics.diversityRejected) noroom=\(result.diagnostics.diversityNoRoom) \
                stem=\(Int(result.diagnostics.stemMetres))m oct=\(result.diagnostics.shortlistOctants) offered=\(result.routes.count) \
                searchMs=\(Int(result.diagnostics.search.searchMs)) totalMs=\(Int(ms)) \
                peakKB=\(result.diagnostics.search.peakStoreBytes / 1024)
                """)
                if !result.diagnostics.gateRejectionsByReason.isEmpty {
                    let byReason = result.diagnostics.gateRejectionsByReason
                        .sorted { $0.value > $1.value }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: " ")
                    print("   gate: \(byReason)")
                }
                for route in result.routes {
                    print("   -> \(route.name) \(Int(route.distanceMeters))m steps=\(route.steps.count)")
                }

                let silent = RoutingDataManager(
                    store: RoutingChunkStore(directory: directory),
                    source: OverpassRoutingDataSource(
                        configuration: .init(endpoint: URL(string: "https://must.not.be.called.invalid/")!),
                        audit: nil
                    ),
                    audit: nil
                )
                let warm = try await silent.ensureCoverage(
                    lat: point.lat, lon: point.lng, targetMetres: target, allowDownload: false
                )
                XCTAssertEqual(warm.overpassRequests, 0)
                XCTAssertTrue(warm.coverage.isComplete)
                XCTAssertGreaterThan(result.routes.count, 0, "\(name) \(targetKm)km found no loops")
            }
        }
    }
}
