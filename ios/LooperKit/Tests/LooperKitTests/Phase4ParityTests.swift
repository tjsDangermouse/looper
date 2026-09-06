import XCTest
@testable import LooperKit

/// Phase 4a of the iOS↔remote parity plan: measurement only.
///
/// One machine-readable `[parity-json]` line per fixture, describing what the
/// on-device engine offered for a request. `route-service/bench/parity.mjs`
/// puts the identical requests to the remote `/v1/loops` and emits the same
/// shape; `parity.mjs` then joins the two and writes the report. Nothing here
/// changes the engine — it reads it.
///
/// Skipped unless `LOOPER_LIVE_OVERPASS=1`, because it depends on a
/// volunteer-run Overpass instance. `LOOPER_OVERPASS_ENDPOINT` overrides the
/// server (public `overpass-api.de` is frequently a 504; `overpass.osm.ch`
/// has been reliable).
final class Phase4ParityTests: XCTestCase {

    /// Append one machine-readable line, either to `LOOPER_PARITY_OUT` or to
    /// stdout. A file avoids interleaving with the test runner's own output,
    /// which corrupts a 40 KB JSON line piped through `grep`.
    private func emit(_ tag: String, _ object: [String: Any]) throws {
        let blob = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let line = tag + " " + String(data: blob, encoding: .utf8)! + "\n"
        if let path = ProcessInfo.processInfo.environment["LOOPER_PARITY_OUT"] {
            let url = URL(fileURLWithPath: path)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        } else {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    private struct Fixture {
        let id: String
        let point: Point
        let targetKm: Double
        /// Empty for a ring fixture; otherwise the pins, in order — the same
        /// coordinates `parity.mjs` sends to the remote engine.
        var waypoints: [Point] = []
    }

    private let douglas = Point(-4.4816, 54.1506)
    private let peel = Point(-4.6997, 54.2246)
    private let onchan = Point(-4.4569, 54.1728)

    /// The fixed matrix. Kept small on purpose — every fixture is a burst of
    /// large bbox queries at a public endpoint. One case per thing that can
    /// differ between the engines, not one per code path.
    private var fixtures: [Fixture] {
        [
            Fixture(id: "douglas-3km", point: douglas, targetKm: 3),
            Fixture(id: "douglas-4km", point: douglas, targetKm: 4),
            Fixture(id: "douglas-5km", point: douglas, targetKm: 5),
            Fixture(id: "douglas-8km", point: douglas, targetKm: 8),
            Fixture(id: "peel-5km", point: peel, targetKm: 5),
            Fixture(id: "onchan-5km", point: onchan, targetKm: 5),
            // Pavement-dense start: the Douglas seafront promenade, pavements
            // mapped as their own ways on both sides of Loch Promenade.
            Fixture(id: "douglas-prom-4km", point: Point(-4.4739, 54.1517), targetKm: 4),
            // Waypoint walks — the exact pins `bench/probe-production.sh` uses.
            Fixture(id: "douglas-wp1-6km", point: douglas, targetKm: 6,
                    waypoints: [Point(-4.4746, 54.1566)]),
            Fixture(id: "douglas-wp2-8km", point: douglas, targetKm: 8,
                    waypoints: [Point(-4.4700, 54.1560), Point(-4.4900, 54.1600)]),
        ]
    }

    func testEmitParityLines() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOOPER_LIVE_OVERPASS"] == "1")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("looper-live-chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var endpoints = OverpassRoutingDataSource.Configuration.publicOverpassEndpoints
        if let override = ProcessInfo.processInfo.environment["LOOPER_OVERPASS_ENDPOINT"],
           let url = URL(string: override) {
            endpoints = [url] + endpoints
        }

        for fixture in fixtures {
            let manager = RoutingDataManager(
                store: RoutingChunkStore(directory: directory),
                source: OverpassRoutingDataSource(
                    configuration: .init(
                        endpoints: endpoints, serverTimeoutSeconds: 120,
                        maxAttempts: 4, retryDelaySeconds: 12, totalDeadlineSeconds: 400
                    )
                )
            )
            let target = fixture.targetKm * 1000
            _ = try await manager.ensureCoverage(
                lat: fixture.point.lat, lon: fixture.point.lng, targetMetres: target
            )
            let data = await manager.storedData(
                lat: fixture.point.lat, lon: fixture.point.lng, targetMetres: target
            )
            let (graph, build) = LocalWalkingGraphBuilder.build(
                from: data, minNetworkSize: LocalWalkingGraphBuilder.minNetworkSize
            )
            let index = LocalEdgeIndex(graph: graph)
            let router = LocalLoopRouter()

            let began = Date()
            let lines: [[Point]]
            let distances: [Double]
            let offered: Int
            var gateReasons: [String: Int] = [:]
            var paveShare: [Double] = []
            var paveHopsKm: [Double] = []
            var built = 0
            var passed = 0

            if fixture.waypoints.isEmpty {
                let result = try router.findRingLoops(
                    .init(lat: fixture.point.lat, lon: fixture.point.lng, targetMetres: target),
                    in: graph, index: index
                )
                lines = result.routes.map { $0.geometry.coordinates }
                distances = result.routes.map(\.distanceMeters)
                offered = result.routes.count
                gateReasons = result.diagnostics.gateRejectionsByReason
                paveShare = result.diagnostics.offeredPavement.map(\.share)
                paveHopsKm = result.diagnostics.offeredPavement.map(\.hopsPerKm)
                built = result.diagnostics.closedWalks
                passed = result.diagnostics.passedGate
            } else {
                let result = try router.findWaypointLoops(
                    .init(start: fixture.point, waypoints: fixture.waypoints, targetMetres: target),
                    in: graph, index: index
                )
                lines = result.routes.map { $0.geometry.coordinates }
                distances = result.routes.map(\.distanceMeters)
                offered = result.routes.count
                gateReasons = result.diagnostics.gateRejectionsByReason
            }
            let ms = Int(Date().timeIntervalSince(began) * 1000)

            let distErr = distances.isEmpty ? 0
                : distances.reduce(0.0) { $0 + abs($1 - target) / target } / Double(distances.count) * 100
            let uTurns = lines.reduce(0) { $0 + RouteQuality.countUTurns($1) }
            let compact = lines.isEmpty ? 0
                : lines.reduce(0.0) { $0 + RouteQuality.compactness($1) } / Double(lines.count)
            var worstOverlap = 0.0
            for a in 0..<lines.count {
                for b in (a + 1)..<lines.count {
                    worstOverlap = Swift.max(
                        worstOverlap,
                        RouteQuality.sharedCorridorMetres(lines[a], lines[b]).fraction
                    )
                }
            }
            let meanShare = paveShare.isEmpty ? nil : paveShare.reduce(0, +) / Double(paveShare.count) * 100
            let meanHops = paveHopsKm.isEmpty ? nil : paveHopsKm.reduce(0, +) / Double(paveHopsKm.count)

            var json: [String: Any] = [
                "id": fixture.id,
                "engine": "on-device",
                "kind": fixture.waypoints.isEmpty ? "ring" : "waypoint",
                "targetKm": fixture.targetKm,
                "offered": offered,
                "meanDistErrPct": round(distErr * 100) / 100,
                "uTurns": uTurns,
                "meanCompactness": round(compact * 1000) / 1000,
                "worstOverlapPct": round(worstOverlap * 1000) / 10,
                "graphNodes": build.graphNodes,
                "graphEdges": build.graphEdges,
                "closedWalks": built,
                "passedGate": passed,
                "ms": ms,
                "gateRejections": gateReasons,
                "routes": lines.map { line in
                    line.map { [ (($0.lng * 100000).rounded() / 100000), (($0.lat * 100000).rounded() / 100000) ] }
                },
            ]
            if let meanShare { json["meanPavePct"] = round(meanShare * 10) / 10 }
            if let meanHops { json["meanHopsPerKm"] = round(meanHops * 100) / 100 }

            try emit("[parity-json]", json)

            XCTAssertGreaterThan(offered, 0, "\(fixture.id): on-device offered nothing")
        }
    }

    /// The leg-routing ceiling. The same point-to-point legs the remote
    /// `bench/parity-legs.ts` puts to a local GraphHopper, routed here through
    /// `LocalLegRouter` on the Overpass graph. After C1 the two should be near
    /// identical; whatever remains is the tie-break/snapping residual plus the
    /// C2 graph difference.
    func testEmitLegParityLines() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOOPER_LIVE_OVERPASS"] == "1")

        let legs: [(id: String, from: Point, to: Point)] = [
            ("douglas-seafront", Point(-4.4816, 54.1506), Point(-4.4693, 54.1602)),
            ("douglas-inland", Point(-4.4750, 54.1550), Point(-4.4600, 54.1650)),
            ("onchan", Point(-4.4530, 54.1720), Point(-4.4400, 54.1800)),
            ("peel-control", Point(-4.7020, 54.2250), Point(-4.6900, 54.2320)),
            // The user's repro: Bucks Road A42, Douglas. `sidewalk:both=separate`,
            // pavements mapped as their own ways the whole length. GraphHopper
            // walks it at ~85% pavement; on-device puts the walk on the
            // carriageway.
            ("bucks-road", Point(-4.4818, 54.1512), Point(-4.4842, 54.1556)),
        ]

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("looper-live-chunks", isDirectory: true)
        var endpoints = OverpassRoutingDataSource.Configuration.publicOverpassEndpoints
        if let override = ProcessInfo.processInfo.environment["LOOPER_OVERPASS_ENDPOINT"],
           let url = URL(string: override) {
            endpoints = [url] + endpoints
        }

        for leg in legs {
            let mid = Point((leg.from.lng + leg.to.lng) / 2, (leg.from.lat + leg.to.lat) / 2)
            let manager = RoutingDataManager(
                store: RoutingChunkStore(directory: directory),
                source: OverpassRoutingDataSource(configuration: .init(
                    endpoints: endpoints, serverTimeoutSeconds: 120,
                    maxAttempts: 4, retryDelaySeconds: 12, totalDeadlineSeconds: 300
                ))
            )
            // A wider box than the leg needs — a leg near the edge of one is
            // the point-to-point analogue of a chunk seam.
            _ = try await manager.ensureCoverage(lat: mid.lat, lon: mid.lng, targetMetres: 6000)
            let data = await manager.storedData(lat: mid.lat, lon: mid.lng, targetMetres: 6000)
            let (graph, _) = LocalWalkingGraphBuilder.build(
                from: data, minNetworkSize: LocalWalkingGraphBuilder.minNetworkSize
            )
            let index = LocalEdgeIndex(graph: graph)

            let routed: LocalLegRouter.Leg
            do {
                routed = try LocalLegRouter.route(
                    graph: graph, index: index, from: leg.from, to: leg.to, weighted: true
                )
            } catch {
                try emit("[parity-leg-json]", [
                    "id": leg.id, "engine": "on-device",
                    "error": "\(error)", "coords": [[Double]](),
                ])
                continue
            }
            let total = routed.legs.reduce(0.0) { $0 + $1.metres }
            let onPavement = routed.legs.filter(\.roadClass.isPedestrianWay).reduce(0.0) { $0 + $1.metres }
            var hops = 0
            for i in 1..<max(1, routed.legs.count) where
                routed.legs[i].roadClass.isPedestrianWay != routed.legs[i - 1].roadClass.isPedestrianWay {
                hops += 1
            }
            let json: [String: Any] = [
                "id": leg.id,
                "engine": "on-device",
                "metres": Int(total.rounded()),
                "pavePct": total > 0 ? round(onPavement / total * 1000) / 10 : 0,
                "hopsPerKm": total > 0 ? round(Double(hops) / (total / 1000) * 100) / 100 : 0,
                "coords": routed.coordinates.map {
                    [ (($0.lng * 100000).rounded() / 100000), (($0.lat * 100000).rounded() / 100000) ]
                },
            ]
            try emit("[parity-leg-json]", json)
        }
    }

    /// Why the on-device seafront/inland legs lose pavement. Prints the build
    /// report, the routed legs with their road class, and the same leg routed
    /// with subnetwork pruning turned off — if the pavement comes back, the
    /// pruning is eating it.
    func testInvestigateSeafrontPavementGap() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOOPER_LIVE_OVERPASS"] == "1")
        let legs: [(id: String, from: Point, to: Point)] = [
            ("douglas-seafront", Point(-4.4816, 54.1506), Point(-4.4693, 54.1602)),
            ("douglas-inland", Point(-4.4750, 54.1550), Point(-4.4600, 54.1650)),
            ("bucks-road", Point(-4.4818, 54.1512), Point(-4.4842, 54.1556)),
        ]
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("looper-live-chunks", isDirectory: true)
        var endpoints = OverpassRoutingDataSource.Configuration.publicOverpassEndpoints
        if let override = ProcessInfo.processInfo.environment["LOOPER_OVERPASS_ENDPOINT"],
           let url = URL(string: override) { endpoints = [url] + endpoints }

        for leg in legs {
            let mid = Point((leg.from.lng + leg.to.lng) / 2, (leg.from.lat + leg.to.lat) / 2)
            let manager = RoutingDataManager(
                store: RoutingChunkStore(directory: directory),
                source: OverpassRoutingDataSource(configuration: .init(endpoints: endpoints, serverTimeoutSeconds: 120))
            )
            _ = try await manager.ensureCoverage(lat: mid.lat, lon: mid.lng, targetMetres: 6000)
            let data = await manager.storedData(lat: mid.lat, lon: mid.lng, targetMetres: 6000)

            let highwayHistogram = Dictionary(grouping: data.ways.compactMap { $0.tags["highway"] }, by: { $0 })
                .mapValues(\.count).sorted { $0.value > $1.value }
            let footwayCount = data.ways.filter { ($0.tags["highway"] == "footway" || $0.tags["highway"] == "pedestrian") }.count
            print("[inv] \(leg.id): ways=\(data.ways.count) nodes=\(data.nodes.count) footway+pedestrian=\(footwayCount)")
            print("[inv]   highways: \(highwayHistogram.prefix(12).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

            for prune in [0, LocalWalkingGraphBuilder.minNetworkSize] {
                let (graph, report) = LocalWalkingGraphBuilder.build(from: data, minNetworkSize: prune)
                let index = LocalEdgeIndex(graph: graph)
                let footEdges = (0..<graph.edgeCount).filter { graph.roadClass(ofEdge: $0).isPedestrianWay }.count
                guard let routed = try? LocalLegRouter.route(
                    graph: graph, index: index, from: leg.from, to: leg.to, weighted: true
                ) else { print("[inv]   prune=\(prune): leg unroutable"); continue }
                let total = routed.legs.reduce(0.0) { $0 + $1.metres }
                let pave = routed.legs.filter(\.roadClass.isPedestrianWay).reduce(0.0) { $0 + $1.metres }
                print("[inv]   prune=\(prune): graph=\(report.graphNodes)n/\(report.graphEdges)e "
                    + "footEdges=\(footEdges) dropped=\(report.subnetworkEdgesDropped) "
                    + "walkable=\(report.waysWalkable)/\(report.waysConsidered) "
                    + "-> leg \(Int(total))m pave=\(Int(pave / total * 100))%")
                if prune == 0 {
                    let byClass = Dictionary(grouping: routed.legs, by: { "\($0.roadClass)" })
                        .mapValues { $0.reduce(0.0) { $0 + $1.metres } }
                        .sorted { $0.value > $1.value }
                    print("[inv]   legs by class: " + byClass.map { "\($0.key)=\(Int($0.value))m" }.joined(separator: " "))
                    let waysByID = Dictionary(data.ways.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    var seen = Set<Int64>()
                    for walkLeg in routed.legs where walkLeg.physical >= 0 && !walkLeg.roadClass.isPedestrianWay {
                        let wayID = graph.edgeWayID[Int(walkLeg.physical)]
                        guard seen.insert(wayID).inserted, let way = waysByID[wayID] else { continue }
                        let tags = way.tags.sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                        print("[inv]   non-ped way \(wayID) [\(Int(graph.edgeMetres[Int(walkLeg.physical)]))m of this edge]: \(tags)")
                    }
                }
            }
        }
    }
}
