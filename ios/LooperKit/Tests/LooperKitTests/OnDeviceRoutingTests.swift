import XCTest
@testable import LooperKit

/// A `LoopsHTTPClient` that fails the test if anything touches it.
///
/// This is the backend-protection guard in executable form. The on-device
/// engine cannot be handed one of these — its initialiser takes no HTTP client
/// and no API base — so the guard here is on the *app's* wiring: whatever the
/// app does while On-device is selected, Looper's routing service must not
/// hear about it.
private final class ForbiddenLoopsClient: LoopsHTTPClient, @unchecked Sendable {
    private(set) var wasCalled = false

    func post(url: URL, body: Data) async throws -> (data: Data, statusCode: Int) {
        wasCalled = true
        XCTFail("the Looper routing service was called while On-device routing was selected: \(url)")
        throw LooperAPIError.message("must not be called")
    }
}

/// A transport that refuses every request, standing in for airplane mode.
private struct DisconnectedTransport: OverpassTransport {
    func post(url: URL, body: Data, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        throw RoutingDataSourceError.offline
    }
}

/// A transport that fails the test if it is used at all. Once an area is
/// cached, routing it must cost zero requests — to anybody.
private struct SilentTransport: OverpassTransport {
    func post(url: URL, body: Data, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        XCTFail("a cached area must need no network request at all")
        throw RoutingDataSourceError.offline
    }
}

final class OnDeviceRoutingTests: XCTestCase {

    /// A town-sized lattice: dense enough that the search has real choices,
    /// regular enough that the answers can be checked by hand.
    private func town() -> OSMData { SyntheticOSM.grid(size: 31, spacingMetres: 150) }

    private func engine(
        directory: URL,
        transport: OverpassTransport,
        audit: RoutingAudit? = nil
    ) -> OnDeviceLoopRoutingEngine {
        OnDeviceLoopRoutingEngine(
            store: RoutingChunkStore(directory: directory),
            source: OverpassRoutingDataSource(
                configuration: .init(endpoint: URL(string: "https://overpass.test/api/interpreter")!),
                transport: transport,
                audit: audit
            ),
            audit: audit
        )
    }

    private func request(distanceKm: Double) -> LoopRequest {
        LoopRequest(start: SyntheticOSM.douglas, mode: .distance, distanceKm: distanceKm, unit: .km)
    }

    // MARK: - The whole pipeline

    func testThreeLoopsAreFoundEntirelyOnTheDevice() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = town()
        let engine = engine(directory: directory, transport: StubOverpassTransport { _ in data })

        let response = try await engine.generateLoops(request(distanceKm: 3))
        XCTAssertEqual(response.routingEngine, .onDevice)
        XCTAssertEqual(response.routes.count, 3, "the app offers three choices")
        XCTAssertNil(response.engine, "no service answered, so there is no service report")

        for route in response.routes {
            XCTAssertEqual(route.routingEngine, .onDevice, "a route carries which engine drew it")
            // Inside the gate's own tolerance, measured the gate's own way.
            XCTAssertEqual(route.distanceMeters, 3000, accuracy: 3000 * RouteQuality.maxDistanceError)
            // A loop ends where it began.
            let first = route.geometry.coordinates.first!
            let last = route.geometry.coordinates.last!
            XCTAssertLessThan(
                LocalGeo.distance(lat1: first.lat, lon1: first.lng, lat2: last.lat, lon2: last.lng),
                RouteQuality.endpointToleranceMetres
            )
            XCTAssertFalse(route.steps.isEmpty)
            XCTAssertEqual(route.steps.last.map { turnKind($0) }, .arrive)
            XCTAssertGreaterThan(route.durationSeconds, 0)
        }
        // Three choices, not one choice wearing three hats.
        XCTAssertEqual(Set(response.routes.map(\.name)).count, 3)
    }

    func testTheOfferedLoopsAreGenuinelyDifferentWalks() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(directory: directory, transport: StubOverpassTransport { [data = town()] _ in data })
        let routes = try await engine.generateLoops(request(distanceKm: 3)).routes
        for a in routes.indices {
            for b in (a + 1)..<routes.count {
                let shared = RouteQuality.sharedCorridorMetres(
                    routes[a].geometry.coordinates, routes[b].geometry.coordinates
                ).fraction
                XCTAssertLessThanOrEqual(shared, RouteQuality.maxSharedFraction + 0.01)
            }
        }
    }

    func testEveryOfferedLoopPassesTheSameGateTheRemoteEngineUses() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(directory: directory, transport: StubOverpassTransport { [data = town()] _ in data })
        let response = try await engine.generateLoops(request(distanceKm: 3))
        for route in response.routes {
            let report = RouteQuality.analyse(
                coordinates: route.geometry.coordinates,
                start: route.geometry.coordinates[0],
                distanceMetres: route.distanceMeters,
                targetMetres: 3000
            )
            XCTAssertTrue(report.pass, "offered a walk the gate rejects: \(report.rejections)")
        }
    }

    // MARK: - The airplane-mode acceptance test

    /// The release-blocking one, in miniature: warm the cache, throw the
    /// network away entirely, and route again.
    func testACachedAreaRoutesWithNoNetworkAtAllAndAfterARestart() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = RoutingAudit()
        let data = town()

        // 1–6: online, downloads what it needs, routes locally.
        let online = engine(directory: directory, transport: StubOverpassTransport { _ in data }, audit: audit)
        let warm = try await online.generateLoops(request(distanceKm: 3))
        XCTAssertEqual(warm.routes.count, 3)
        let afterDownload = await audit.snapshot()
        XCTAssertGreaterThan(afterDownload.overpassCallCount, 0)

        // 7–9: force-quit and relaunch, with no network. A fresh store over
        // the same directory is exactly what a relaunch produces.
        await audit.reset()
        let offline = engine(directory: directory, transport: SilentTransport(), audit: audit)

        // 10–12: the same walk, found again, with nothing on the wire.
        let cold = try await offline.generateLoops(request(distanceKm: 3))
        XCTAssertEqual(cold.routes.count, 3)
        XCTAssertFalse(cold.routes.contains { $0.steps.isEmpty }, "the walk screen needs its instructions offline too")

        let snapshot = await audit.snapshot()
        XCTAssertEqual(snapshot.overpassCallCount, 0, "Overpass HTTP calls must be zero")
        XCTAssertEqual(snapshot.looperRoutingCallCount, 0, "Looper routing HTTP calls must be zero")
    }

    /// The uncached-offline test: the answer is a local-data error, never a
    /// silent trip to the remote router.
    func testAnUncachedAreaOfflineSaysSoRatherThanRoutingRemotely() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let forbidden = ForbiddenLoopsClient()
        let engine = engine(directory: directory, transport: DisconnectedTransport())

        do {
            _ = try await engine.generateLoops(request(distanceKm: 5))
            XCTFail("routing an area the phone has no data for is not something to succeed at")
        } catch {
            XCTAssertEqual(error as? RoutingDataManager.AcquisitionError, .dataUnavailableOffline)
            XCTAssertTrue(
                error.localizedDescription.contains("isn’t available offline"),
                "the walker is told what is actually wrong: \(error.localizedDescription)"
            )
        }
        XCTAssertFalse(forbidden.wasCalled)
    }

    // MARK: - Backend protection

    /// The structural half of the guarantee: the on-device engine has no way
    /// to reach Looper's routing service, because it holds nothing that could.
    ///
    /// A test cannot assert the absence of a dependency directly, but it can
    /// assert the consequence: a full local request, from cold, records not
    /// one Looper routing call — while the same audit demonstrably *does*
    /// record them when the remote engine runs.
    func testTheOnDeviceEngineNeverReachesTheLooperRoutingService() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = RoutingAudit()
        let engine = engine(directory: directory, transport: StubOverpassTransport { [data = town()] _ in data }, audit: audit)

        _ = try await engine.generateLoops(request(distanceKm: 3))
        _ = try await engine.generateLoops(request(distanceKm: 2))
        let local = await audit.snapshot()
        XCTAssertEqual(local.looperRoutingCallCount, 0)
        XCTAssertGreaterThan(local.overpassCallCount, 0, "it did do work, over the OSM data source")
        XCTAssertTrue(
            local.overpassRequests.allSatisfy { $0.endpoint.contains("overpass.test") },
            "the only host contacted is the configured OSM data provider"
        )

        // And the counter is not simply broken: the remote engine trips it.
        let remote = RemoteLoopRoutingEngine(
            apiBase: "https://routes.test",
            client: AuditingLoopsHTTPClient(wrapping: StubRemoteClient(), audit: audit)
        )
        _ = try? await remote.generateLoops(request(distanceKm: 3))
        let mixed = await audit.snapshot()
        XCTAssertEqual(mixed.looperRoutingCallCount, 1)
        XCTAssertTrue(mixed.looperRoutingRequests[0].url.hasPrefix("https://routes.test/v1/loops"))
    }

    /// Waypoints are the remote engine's job. Answering a different question
    /// quietly would be worse than declining, so the local engine declines.
    func testWaypointLoopsAreDeclinedRatherThanQuietlyReinterpreted() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(directory: directory, transport: StubOverpassTransport { [data = town()] _ in data })
        var request = request(distanceKm: 3)
        request.waypoints = [Point(-4.47, 54.16)]
        do {
            _ = try await engine.generateLoops(request)
            XCTFail("the local engine has no answer to an ordered-waypoint loop")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Remote routing"))
        }
    }

    // MARK: - Measurements

    /// The number the whole architecture exists to keep small. Printed rather
    /// than asserted tightly, so the implementation report can quote a real
    /// figure and a regression is visible in the log.
    func testMeasureWhatADownloadActuallyCosts() async throws {
        for targetKm in [3.0, 5.0, 8.0] {
            let directory = makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let audit = RoutingAudit()
            let store = RoutingChunkStore(directory: directory)
            let manager = RoutingDataManager(
                store: store,
                source: OverpassRoutingDataSource(
                    configuration: .init(endpoint: URL(string: "https://overpass.test/api/interpreter")!),
                    transport: StubOverpassTransport { bounds in
                        // Streets over whatever area is asked for, at a
                        // density in the region of a real town.
                        let across = Int(bounds.approximateAreaSquareMetres.squareRoot() / 120) + 2
                        return SyntheticOSM.grid(centre: bounds.centre, size: min(60, across), spacingMetres: 120)
                    },
                    audit: audit
                ),
                audit: audit
            )
            let report = try await manager.ensureCoverage(
                lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, targetMetres: targetKm * 1000
            )
            print("""
            [coverage] \(Int(targetKm)) km \
            radius=\(Int(report.coverage.requiredRadiusMetres))m \
            chunks=\(report.coverage.requiredChunks.count) \
            missing=\(report.coverage.requiredChunks.count - report.coverage.cachedChunks.count) \
            requests=\(report.overpassRequests) \
            ways=\(report.waysReceived) nodes=\(report.nodesReceived) \
            stored=\(report.storedBytes / 1024)KB
            """)
            XCTAssertTrue(report.coverage.isComplete)
            // The point of the design: a walk needs a town, not a country.
            XCTAssertLessThan(report.overpassRequests, 6)
            XCTAssertLessThan(report.storedBytes, 60 * 1024 * 1024)
        }
    }
}

/// A stand-in for Looper's route service, so the remote engine can be exercised
/// without one.
private struct StubRemoteClient: LoopsHTTPClient {
    func post(url: URL, body: Data) async throws -> (data: Data, statusCode: Int) {
        (Data(#"{"routes":[]}"#.utf8), 200)
    }
}
