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
                closures=\(result.diagnostics.search.closures) band-]=\(result.diagnostics.search.closuresOutsideBand) shape-]=\(result.diagnostics.search.closuresTooShapeless) beam-]=\(result.diagnostics.search.prunedBeam) dom-]=\(result.diagnostics.search.prunedDominated) early=\(result.diagnostics.search.stoppedEarly) closed=\(result.diagnostics.closedWalks) shape-]=\(result.diagnostics.rejectedShape) turns-]=\(result.diagnostics.rejectedTurns) gate-]=\(result.diagnostics.gateRejected) passed=\(result.diagnostics.passedGate) \
                diverse-]=\(result.diagnostics.diversityRejected) noroom=\(result.diagnostics.diversityNoRoom) \
                stem=\(Int(result.diagnostics.stemMetres))m oct=\(result.diagnostics.shortlistOctants) offered=\(result.routes.count) \
                searchMs=\(Int(result.diagnostics.search.searchMs)) judgeMs=\(Int(result.diagnostics.judgeMs)) assembleMs=\(Int(result.diagnostics.assembleMs)) totalMs=\(Int(ms)) \
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
                    // Shape, not just length. `reach` is the number this run is
                    // actually about: how far the walk gets from the door
                    // against a circle of its own length, so 1.0 is a circle
                    // and anything well under it is a walk that never left.
                    // What we want to see across three offers is a spread,
                    // not a cluster.
                    let line = route.geometry.coordinates
                    // Measured here rather than called for, so that this run
                    // means the same thing against a tree that predates the
                    // reach work as against one that has it.
                    let frame = MetricFrame(
                        originLon: result.diagnostics.snappedLon, originLat: result.diagnostics.snappedLat
                    )
                    var radius = 0.0
                    for p in line {
                        let xy = frame.project(lon: p.lng, lat: p.lat)
                        radius = Swift.max(radius, (xy.x * xy.x + xy.y * xy.y).squareRoot())
                    }
                    let reach = route.distanceMeters > 0 ? radius / (route.distanceMeters / (2 * .pi)) : 0
                    let sides = RouteQuality.boundingBoxSides(line)
                    let bbox = sides.shortMetres > 0 ? sides.longMetres / sides.shortMetres : .infinity
                    print(String(
                        format: "   -> %@ %dm steps=%d compact=%.2f reach=%.2f bbox=%.1f",
                        route.name, Int(route.distanceMeters), route.steps.count,
                        RouteQuality.compactness(line), reach, bbox
                    ))
                }

                // The second press, which is the one a walker actually waits
                // on: everything already offered is handed back as `exclude`,
                // and every candidate in the pool is compared against every
                // one of them on the ground before the selector runs.
                let refreshBegan = Date()
                let refreshed = try router.findLoops(
                    .init(
                        lat: point.lat, lon: point.lng, targetMetres: target, variation: 7,
                        exclude: result.routes.map { $0.geometry.coordinates }
                    ),
                    in: graph, index: index
                )
                print("   refresh: offered=\(refreshed.routes.count) "
                    + "pool=\(refreshed.diagnostics.passedGate) seen-]=\(refreshed.diagnostics.excludedAsAlreadySeen) "
                    + "searchMs=\(Int(refreshed.diagnostics.search.searchMs)) "
                    + "totalMs=\(Int(refreshed.diagnostics.totalMs)) "
                    + "wallMs=\(Int(Date().timeIntervalSince(refreshBegan) * 1000))")

                if ProcessInfo.processInfo.environment["LOOPER_BEAM_SWEEP"] == "1" {
                    for (beam, perNode) in [(300, 3), WalkSearch.widthFor(targetMetres: target)] {
                        let sweepBegan = Date()
                        let search = WalkSearch.run(
                            WalkSearchGraph(
                                try LocalExploration.explore(
                                    graph: graph, index: index, lat: point.lat, lon: point.lng,
                                    limitMetres: RoutingCoverage.explorationRadiusMetres(targetMetres: target)
                                ).0
                            ),
                            options: .init(targetMetres: target, beam: beam, perNode: perNode)
                        )
                        let families = Set(search.walks.map(\.family)).count
                        print("   sweep beam=\(beam) perNode=\(perNode): closed=\(search.walks.count) "
                            + "octants=\(families) closures=\(search.stats.closures) "
                            + "early=\(search.stats.stoppedEarly) ms=\(Int(Date().timeIntervalSince(sweepBegan) * 1000))")
                    }
                }

                // A fresh ask at the same doorstep, the way a different walker
                // (or the same one tomorrow) arrives: a random variation and
                // nothing excluded. This is the question "do two people
                // standing in the same place get the same three walks".
                var distinctFirstOffers = Set<String>()
                for variation in [0, 51, 132, 264, 411, 663, 807] {
                    let fresh = try router.findLoops(
                        .init(lat: point.lat, lon: point.lng, targetMetres: target, variation: variation),
                        in: graph, index: index
                    )
                    distinctFirstOffers.insert(
                        fresh.routes.map { $0.geometry.coordinates.map { p in "\(p.lng),\(p.lat)" }.joined() }
                            .sorted().joined(separator: "|")
                    )
                }
                print("   fresh asks: 7 variations -> \(distinctFirstOffers.count) distinct offers")

                // Refresh, three times over, the way a walker leaning on the
                // button does it. Each round excludes everything seen so far.
                var seen = result.routes
                for round in 1...10 {
                    let next = try router.findLoops(
                        .init(
                            lat: point.lat, lon: point.lng, targetMetres: target,
                            variation: round * 3,
                            exclude: seen.map(\.geometry.coordinates)
                        ),
                        in: graph, index: index
                    )
                    let repeats = next.routes.filter { route in
                        seen.contains { RouteQuality.sharedCorridorMetres(
                            route.geometry.coordinates, $0.geometry.coordinates
                        ).fraction > RouteQuality.maxSharedFraction }
                    }
                    print("   refresh \(round): offered=\(next.routes.count) new=\(next.routes.count - repeats.count) "
                        + "seen-]=\(next.diagnostics.excludedAsAlreadySeen)"
                        + "\(next.diagnostics.excludeExhausted ? " EXHAUSTED" : "") "
                        + "running-distinct=\(seen.count + next.routes.count - repeats.count)")
                    seen.append(contentsOf: next.routes.filter { route in
                        !seen.contains { RouteQuality.sharedCorridorMetres(
                            route.geometry.coordinates, $0.geometry.coordinates
                        ).fraction > RouteQuality.maxSharedFraction }
                    })
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

    /// The same ground, asked to go somewhere.
    ///
    /// The measurement that matters for waypoints is not whether a walk comes
    /// back — a backbone always does — but whether it comes back the right
    /// length and the right shape. On real ground the service's own waypoint
    /// mode misses the requested distance by four times what its ring mode
    /// does, and `shapeless` was killing 18 of every 24 walks it assembled.
    /// Those are the numbers this run exists to put a figure on here.
    func testMeasureRealWaypointWalks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOOPER_LIVE_OVERPASS"] == "1")
        let douglas = Point(-4.4816, 54.1506)
        let target = 5000.0

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("looper-live-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = RoutingChunkStore(directory: directory)
        let manager = RoutingDataManager(
            store: store,
            source: OverpassRoutingDataSource(
                configuration: .init(serverTimeoutSeconds: 120, maxAttempts: 5, retryDelaySeconds: 15)
            )
        )
        // The pins are chosen from this graph below, so the area is fetched
        // for the ring alone. That is sound here and only here: a 5 km ring's
        // box reaches 3.1 km from the door and the pins are picked at one, so
        // nothing is outside it. The app passes its pins in — see
        // `RoutingCoverage.requiredBounds(start:waypoints:targetMetres:)`.
        _ = try await manager.ensureCoverage(lat: douglas.lat, lon: douglas.lng, targetMetres: target)
        let data = await manager.storedData(lat: douglas.lat, lon: douglas.lng, targetMetres: target)
        let (graph, build) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)

        // Two pins about a kilometre out on different bearings: a walk that
        // genuinely goes somewhere and comes back another way.
        //
        // Chosen from ground the door can actually reach rather than from a
        // bearing and a distance. Douglas is a coastal town and a bearing
        // taken blind lands in the bay or on a severed fragment — which the
        // engine correctly refuses, and which would make this a test of the
        // fixture rather than of the router.
        let (reachable, _) = try LocalExploration.explore(
            graph: graph, index: index, lat: douglas.lat, lon: douglas.lng, limitMetres: 3000
        )
        func pin(towards bearing: Double) throws -> Point {
            let aim = LocalGeo.destination(lat: douglas.lat, lon: douglas.lng, metres: 1000, bearing: bearing)
            let best = reachable.nodes
                .filter { $0.networkMetres > 600 && $0.networkMetres < 1600 }
                .min { LocalGeo.distance(lat1: $0.lat, lon1: $0.lon, lat2: aim.lat, lon2: aim.lon)
                     < LocalGeo.distance(lat1: $1.lat, lon1: $1.lon, lat2: aim.lat, lon2: aim.lon) }
            let node = try XCTUnwrap(best, "no reachable ground about a kilometre out towards \(Int(bearing))°")
            return Point(node.lon, node.lat)
        }
        let pins = [try pin(towards: 0), try pin(towards: 90)]
        for (which, place) in pins.enumerated() {
            print(String(format: "   pin %d: %.0fm from the door as the crow flies", which, haversine(douglas, place)))
        }

        let began = Date()
        let result = try LocalLoopRouter().findWaypointLoops(
            .init(start: douglas, waypoints: pins, targetMetres: target),
            in: graph, index: index
        )
        let ms = Date().timeIntervalSince(began) * 1000
        let d = result.diagnostics

        print("""
        [live] Douglas 5km via 2 pins \
        graph=\(build.graphNodes)n/\(build.graphEdges)e \
        stage=\(d.waypointStage ?? "backbone") backbone=\(Int(d.waypointBackboneMetres))m \
        joins-repaired=\(d.waypointJoinsRepaired) \
        options=\(d.waypointOptions) allocations=\(d.waypointAllocations) enclosing=\(d.waypointEnclosing) \
        assembled=\(d.closedWalks) gate-]=\(d.gateRejected) passed=\(d.passedGate) \
        offered=\(result.routes.count) totalMs=\(Int(ms)) \
        failure=\(d.failure ?? "-") warning=\(result.warning ?? "-")
        """)
        if !d.gateRejectionsByReason.isEmpty {
            print("   gate: " + d.gateRejectionsByReason.sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        for route in result.routes {
            let line = route.geometry.coordinates
            print(String(
                format: "   -> %@ %dm err=%+.1f%% compact=%.2f steps=%d",
                route.name, Int(route.distanceMeters),
                route.distanceMeters / target * 100 - 100,
                RouteQuality.compactness(line), route.steps.count
            ))
            XCTAssertTrue(
                LocalLoopRouter.route(line, hits: pins),
                "a waypoint walk that misses its pins is not the walk that was asked for"
            )
        }
        XCTAssertNil(result.minimumMetres, "two pins a kilometre out fit comfortably in a 5 km plan")
        XCTAssertGreaterThan(result.routes.count, 0, "no waypoint walk was offered on real ground")
    }

    /// How often a waypoint request actually produces a walk.
    ///
    /// One favourable pin pair proves nothing. This sweeps many of them and
    /// reports the offer rate and what refused the rest, which is the only
    /// number that says whether the feature works.
    func testMeasureWaypointOfferRate() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOOPER_LIVE_OVERPASS"] == "1")
        let douglas = Point(-4.4816, 54.1506)
        let target = 5000.0

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("looper-live-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = RoutingDataManager(
            store: RoutingChunkStore(directory: directory),
            source: OverpassRoutingDataSource(configuration: .init(serverTimeoutSeconds: 120, maxAttempts: 5, retryDelaySeconds: 15))
        )
        _ = try await manager.ensureCoverage(lat: douglas.lat, lon: douglas.lng, targetMetres: target)
        let data = await manager.storedData(lat: douglas.lat, lon: douglas.lng, targetMetres: target)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let (reachable, _) = try LocalExploration.explore(
            graph: graph, index: index, lat: douglas.lat, lon: douglas.lng, limitMetres: 3000
        )
        func pin(towards bearing: Double, metres: Double) -> Point? {
            let aim = LocalGeo.destination(lat: douglas.lat, lon: douglas.lng, metres: metres, bearing: bearing)
            let best = reachable.nodes
                .filter { $0.networkMetres > metres * 0.5 && $0.networkMetres < metres * 1.8 }
                .min { LocalGeo.distance(lat1: $0.lat, lon1: $0.lon, lat2: aim.lat, lon2: aim.lon)
                     < LocalGeo.distance(lat1: $1.lat, lon1: $1.lon, lat2: aim.lat, lon2: aim.lon) }
            return best.map { Point($0.lon, $0.lat) }
        }

        var asked = 0, offered = 0, empty = 0, hits = 0, misses = 0
        var errors: [Double] = [], shapes: [Double] = [], millis: [Double] = []
        var reasons: [String: Int] = [:]
        var failures: [String: Int] = [:]
        let router = LocalLoopRouter()
        for first in stride(from: 0.0, to: 360, by: 45) {
            for spread in [60.0, 120.0, 180.0] {
                for distance in [700.0, 1200.0] {
                    guard let a = pin(towards: first, metres: distance),
                          let b = pin(towards: first + spread, metres: distance) else { continue }
                    asked += 1
                    // Emitted so the very same questions can be put to the
                    // route service. A comparison against the remote engine is
                    // only worth anything if both are asked about the same
                    // ground.
                    print(String(format: "[case] %.6f,%.6f %.6f,%.6f", a.lng, a.lat, b.lng, b.lat))
                    let result = try router.findWaypointLoops(
                        .init(start: douglas, waypoints: [a, b], targetMetres: target),
                        in: graph, index: index
                    )
                    if result.routes.isEmpty {
                        empty += 1
                        failures[result.diagnostics.failure ?? "-", default: 0] += 1
                        for (reason, count) in result.diagnostics.gateRejectionsByReason { reasons[reason, default: 0] += count }
                    } else {
                        offered += result.routes.count
                        // Offer rate alone can be bought by relaxing what
                        // "through these places" means, so it is measured
                        // rather than assumed: does the walk still pass every
                        // pin, in order, within the tolerance the service uses?
                        for route in result.routes {
                            if LocalLoopRouter.route(route.geometry.coordinates, hits: [a, b]) { hits += 1 } else { misses += 1 }
                            errors.append(abs(route.distanceMeters - target) / target)
                            shapes.append(RouteQuality.compactness(route.geometry.coordinates))
                        }
                        millis.append(result.diagnostics.totalMs)
                    }
                }
            }
        }
        print("[rate] asked=\(asked) produced=\(asked - empty) empty=\(empty) "
            + "offerRate=\(asked > 0 ? (asked - empty) * 100 / asked : 0)% routes=\(offered)")
        func median(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }
        print(String(format: "   quality: medianDistanceError=%.1f%% worst=%.1f%% medianCompactness=%.2f medianMs=%d",
            median(errors) * 100, (errors.max() ?? 0) * 100, median(shapes), Int(median(millis))))
        print("   pins: hit=\(hits) missed=\(misses) "
            + "hitRate=\(hits + misses > 0 ? hits * 100 / (hits + misses) : 0)%")
        print("   failures: " + failures.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        print("   gate: " + reasons.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }

    /// Does a walk routed straight through the pins actually pass them?
    ///
    /// Isolates the hit test from everything built on top of it. If the plain
    /// backbone — legs that literally run pin to pin, untrimmed — does not
    /// register as passing its own pins, the measurement is wrong rather than
    /// the walks.
    func testMeasureBackboneHitsItsOwnPins() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOOPER_LIVE_OVERPASS"] == "1")
        let douglas = Point(-4.4816, 54.1506)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("looper-live-chunks", isDirectory: true)
        let manager = RoutingDataManager(
            store: RoutingChunkStore(directory: directory),
            source: OverpassRoutingDataSource(configuration: .init(serverTimeoutSeconds: 120))
        )
        let data = await manager.storedData(lat: douglas.lat, lon: douglas.lng, targetMetres: 5000)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: data)
        let index = LocalEdgeIndex(graph: graph)
        let (reachable, _) = try LocalExploration.explore(
            graph: graph, index: index, lat: douglas.lat, lon: douglas.lng, limitMetres: 3000
        )
        func pin(towards bearing: Double) -> Point? {
            let aim = LocalGeo.destination(lat: douglas.lat, lon: douglas.lng, metres: 1000, bearing: bearing)
            return reachable.nodes
                .filter { $0.networkMetres > 500 && $0.networkMetres < 1800 }
                .min { LocalGeo.distance(lat1: $0.lat, lon1: $0.lon, lat2: aim.lat, lon2: aim.lon)
                     < LocalGeo.distance(lat1: $1.lat, lon1: $1.lon, lat2: aim.lat, lon2: aim.lon) }
                .map { Point($0.lon, $0.lat) }
        }
        var raw = 0, trimmed = 0, protectedTrim = 0, total = 0
        for bearing in stride(from: 0.0, to: 360, by: 45) {
            guard let a = pin(towards: bearing), let b = pin(towards: bearing + 120) else { continue }
            guard let leg = try? LocalLegRouter.route(
                graph: graph, index: index, through: [douglas, a, b, douglas], protecting: [a, b]
            ) else { continue }
            total += 1
            if LocalLoopRouter.route(leg.coordinates, hits: [a, b]) { raw += 1 }
            let cut = LocalSpikeTrim.trimming(leg.legs, protecting: [])
            if LocalLoopRouter.route(LocalLegRouter.line(of: cut), hits: [a, b]) { trimmed += 1 }
            let kept = LocalSpikeTrim.trimming(leg.legs, protecting: [a, b])
            if LocalLoopRouter.route(LocalLegRouter.line(of: kept), hits: [a, b]) { protectedTrim += 1 }
        }
        print("[hits] backbones=\(total) untrimmed=\(raw) afterUnprotectedTrim=\(trimmed) afterProtectedTrim=\(protectedTrim)")
    }
}
