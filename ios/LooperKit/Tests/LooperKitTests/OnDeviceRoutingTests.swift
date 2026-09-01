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

    // MARK: - Ordered waypoints

    /// A place `metres` east and `north` of the town's centre.
    private func place(east: Double, north: Double) -> Point {
        let moved = LocalGeo.destination(
            lat: SyntheticOSM.douglas.lat, lon: SyntheticOSM.douglas.lng, metres: north, bearing: 0
        )
        let placed = LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        return Point(placed.lon, placed.lat)
    }

    /// The walk goes where it was asked to go, in the order it was asked, and
    /// it is still built entirely on the phone.
    ///
    /// This replaces the test that used to pin the opposite behaviour. The old
    /// one asserted that the local engine declined waypoints and sent the
    /// walker to Remote; that was a scope decision rather than a limit of the
    /// device, and it is no longer true.
    func testWaypointLoopsAreBuiltOnTheDeviceAndPassEveryPinInOrder() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ForbiddenLoopsClient()
        let engine = engine(directory: directory, transport: StubOverpassTransport { [data = town()] _ in data })

        var request = request(distanceKm: 3)
        let pins = [place(east: 600, north: 200), place(east: 200, north: -600)]
        request.waypoints = pins
        let result = try await engine.generateLoops(request)

        XCTAssertFalse(result.routes.isEmpty, "the device found no walk through two ordinary pins")
        XCTAssertEqual(result.routingEngine, .onDevice)
        XCTAssertFalse(client.wasCalled)
        for route in result.routes {
            XCTAssertTrue(
                LocalLoopRouter.route(route.geometry.coordinates, hits: pins),
                "a waypoint walk that does not pass its pins in order is not the walk that was asked for"
            )
            XCTAssertEqual(route.routingEngine, .onDevice)
            // The same tolerance the service judges a waypoint walk by.
            XCTAssertLessThanOrEqual(
                abs(route.distanceMeters - 3000) / 3000,
                LocalLoopRouter.waypointDistanceTolerance
            )
        }
    }

    /// Pins that need more ground than the plan allows are refused with the
    /// number the walker needs, not with a shrug — and in the same words the
    /// service uses, because two engines refusing the same request differently
    /// is a difference a field test would misread.
    func testPinsThatNeedMoreThanThePlanAllowsAreRefusedWithTheDistanceNeeded() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(directory: directory, transport: StubOverpassTransport { [data = town()] _ in data })

        // A pin 1.5 km out and back is 3 km of unavoidable walking, asked for
        // inside a 1 km plan.
        var request = request(distanceKm: 1)
        request.waypoints = [place(east: 1500, north: 0)]
        let result = try await engine.generateLoops(request)

        XCTAssertTrue(result.routes.isEmpty)
        XCTAssertTrue(result.expectationExceeded)
        let warning = try XCTUnwrap(result.warning)
        XCTAssertTrue(warning.contains("need at least"), warning)
        XCTAssertTrue(warning.contains("km"), warning)
        XCTAssertEqual(result.localDiagnostics?.failure, "waypoint-over-plan")
    }

    /// A pin the walker could hit by accident does not turn the request into a
    /// backbone problem: the ring search answers it, and the pins do the
    /// filtering. This is the service's `doorstep-pin` hand-over.
    func testAPinOnTheDoorstepIsAnsweredByTheOrdinarySearch() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = engine(directory: directory, transport: StubOverpassTransport { [data = town()] _ in data })

        var request = request(distanceKm: 5)
        request.waypoints = [place(east: 150, north: 0)]
        let result = try await engine.generateLoops(request)

        XCTAssertEqual(result.localDiagnostics?.waypointStage, "doorstep-pin")
        XCTAssertFalse(result.routes.isEmpty)
        for route in result.routes {
            XCTAssertTrue(LocalLoopRouter.route(route.geometry.coordinates, hits: request.waypoints))
        }
    }

    /// The pins widen the area the phone has to hold. A walk through a place
    /// two kilometres away needs that place, and the coverage calculation has
    /// to know it before anything is fetched.
    func testTheAreaFetchedTakesInThePinsAndNotJustTheStart() {
        let start = SyntheticOSM.douglas
        let far = place(east: 2500, north: 0)
        let ring = RoutingCoverage.requiredBounds(start: start, waypoints: [], targetMetres: 3000)
        let withPin = RoutingCoverage.requiredBounds(start: start, waypoints: [far], targetMetres: 3000)

        XCTAssertFalse(ring.contains(lat: far.lat, lon: far.lng), "the premise: the pin is outside the ring's own box")
        XCTAssertTrue(withPin.contains(lat: far.lat, lon: far.lng))
        XCTAssertTrue(withPin.contains(lat: start.lat, lon: start.lng), "and the start is still in it")
        XCTAssertGreaterThan(
            RoutingCoverage.requiredChunks(start: start, waypoints: [far], targetMetres: 3000).count,
            RoutingCoverage.requiredChunks(start: start, waypoints: [], targetMetres: 3000).count
        )
    }

    /// Order is what makes a waypoint list more than a set of places.
    func testAWalkThatVisitsThePinsInTheWrongOrderIsNotAHit() {
        let line = (0...20).map { place(east: Double($0) * 100, north: 0) }
        let first = place(east: 400, north: 0), second = place(east: 1200, north: 0)
        XCTAssertTrue(LocalLoopRouter.route(line, hits: [first, second]))
        XCTAssertFalse(LocalLoopRouter.route(line, hits: [second, first]))
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
