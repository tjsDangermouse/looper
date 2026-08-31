import XCTest
@testable import LooperKit

/// What happens when the OSM data provider stops answering.
///
/// These exist because of a real failure: `overpass-api.de` stopped responding
/// to this machine entirely — a public instance that has heard enough from an
/// address drops connections rather than refusing politely — and the app's only
/// visible symptom was that no routing data appeared. With one endpoint
/// configured there was nowhere to go, and the error the walker saw told them
/// to connect to a network they were already on.
final class RoutingProviderFailoverTests: XCTestCase {

    /// Records which hosts were tried, and answers according to a script.
    private final class ScriptedTransport: OverpassTransport, @unchecked Sendable {
        enum Reply {
            case data(OSMData)
            case status(Int)
            case failure(RoutingDataSourceError)
        }

        private let queue = DispatchQueue(label: "scripted")
        private var _hosts: [String] = []
        let replies: [String: Reply]

        init(replies: [String: Reply]) { self.replies = replies }

        var hosts: [String] { queue.sync { _hosts } }

        func post(url: URL, body: Data, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
            let host = url.host ?? "?"
            queue.sync { _hosts.append(host) }
            switch replies[host] ?? .failure(.providerUnavailable("no script")) {
            case .data(let data): return (StubOverpassTransport.encodeOverpassJSON(data), 200)
            case .status(let code): return (Data(), code)
            case .failure(let error): throw error
            }
        }
    }

    /// Fails slowly, the way an unreachable host does.
    private final class SlowFailingTransport: OverpassTransport, @unchecked Sendable {
        private let queue = DispatchQueue(label: "slow")
        private var _calls = 0
        let delay: Double

        init(delay: Double) { self.delay = delay }
        var calls: Int { queue.sync { _calls } }

        func post(url: URL, body: Data, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
            queue.sync { _calls += 1 }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            throw RoutingDataSourceError.providerUnavailable("The request timed out.")
        }
    }

    private func endpoints(_ hosts: [String]) -> [URL] {
        hosts.map { URL(string: "https://\($0)/api/interpreter")! }
    }

    // MARK: - Failover

    /// The fix for the reported failure: a dead primary must not take
    /// on-device routing down with it.
    func testASilentPrimaryFallsThroughToTheNextProvider() async throws {
        let town = SyntheticOSM.grid(size: 10, spacingMetres: 200)
        let transport = ScriptedTransport(replies: [
            // Exactly how a blocked address is treated: connections time out.
            "dead.test": .failure(.providerUnavailable("The request timed out.")),
            "alive.test": .data(town),
        ])
        let source = OverpassRoutingDataSource(
            configuration: .init(endpoints: endpoints(["dead.test", "alive.test"]), maxAttempts: 2, retryDelaySeconds: 0),
            transport: transport,
            audit: nil
        )
        let data = try await source.fetchArea(LocalGeo.boundsAround(lat: 54.15, lon: -4.48, metres: 800))
        XCTAssertEqual(data.ways.count, town.ways.count)
        // Both attempts on the dead one, then the live one.
        XCTAssertEqual(transport.hosts, ["dead.test", "dead.test", "alive.test"])
    }

    func testRateLimitingAndServerErrorsAlsoMoveOn() async throws {
        let town = SyntheticOSM.grid(size: 6, spacingMetres: 200)
        let transport = ScriptedTransport(replies: [
            "busy.test": .status(429),
            "broken.test": .status(504),
            "alive.test": .data(town),
        ])
        let source = OverpassRoutingDataSource(
            configuration: .init(endpoints: endpoints(["busy.test", "broken.test", "alive.test"]), maxAttempts: 1, retryDelaySeconds: 0),
            transport: transport,
            audit: nil
        )
        _ = try await source.fetchArea(LocalGeo.boundsAround(lat: 54.15, lon: -4.48, metres: 500))
        XCTAssertEqual(transport.hosts, ["busy.test", "broken.test", "alive.test"])
    }

    /// A dropped socket is one provider's problem, not the device's.
    ///
    /// Reading `networkConnectionLost` as "offline" abandoned the whole search
    /// on the first host that dropped a connection — which defeated the
    /// endpoint list entirely, and did it silently.
    func testADroppedConnectionMovesOnRatherThanDeclaringTheDeviceOffline() async throws {
        let town = SyntheticOSM.grid(size: 6, spacingMetres: 200)
        let transport = ScriptedTransport(replies: [
            "flaky.test": .failure(.providerUnavailable("The network connection was lost.")),
            "alive.test": .data(town),
        ])
        let source = OverpassRoutingDataSource(
            configuration: .init(endpoints: endpoints(["flaky.test", "alive.test"]), maxAttempts: 1, retryDelaySeconds: 0),
            transport: transport,
            audit: nil
        )
        _ = try await source.fetchArea(LocalGeo.boundsAround(lat: 54.15, lon: -4.48, metres: 500))
        XCTAssertEqual(transport.hosts, ["flaky.test", "alive.test"])
    }

    /// No network is not another provider's problem, and trying five of them
    /// wastes a walker's time and battery to reach the same answer.
    func testBeingOfflineStopsImmediatelyRatherThanTouringTheProviders() async {
        let transport = ScriptedTransport(replies: ["a.test": .failure(.offline), "b.test": .failure(.offline)])
        let source = OverpassRoutingDataSource(
            configuration: .init(endpoints: endpoints(["a.test", "b.test"]), maxAttempts: 3, retryDelaySeconds: 0),
            transport: transport,
            audit: nil
        )
        do {
            _ = try await source.fetchArea(LocalGeo.boundsAround(lat: 54.15, lon: -4.48, metres: 500))
            XCTFail("expected to fail")
        } catch {
            XCTAssertEqual(error as? RoutingDataSourceError, .offline)
        }
        XCTAssertEqual(transport.hosts, ["a.test"], "one attempt, one host")
    }

    // MARK: - Saying the right thing

    /// The misleading message that made the original failure hard to read: a
    /// walker with a working connection was told to connect to one.
    func testAProviderOutageIsNotReportedAsBeingOffline() async {
        let transport = ScriptedTransport(replies: ["dead.test": .failure(.providerUnavailable("The request timed out."))])
        let engine = OnDeviceLoopRoutingEngine(
            store: RoutingChunkStore(directory: makeTemporaryDirectory()),
            source: OverpassRoutingDataSource(
                configuration: .init(endpoints: endpoints(["dead.test"]), maxAttempts: 1, retryDelaySeconds: 0),
                transport: transport,
                audit: nil
            ),
            audit: nil
        )
        do {
            _ = try await engine.generateLoops(
                LoopRequest(start: SyntheticOSM.douglas, mode: .distance, distanceKm: 3, unit: .km)
            )
            XCTFail("expected to fail")
        } catch {
            XCTAssertNotEqual(
                error as? RoutingDataManager.AcquisitionError, .dataUnavailableOffline,
                "a provider outage must not be reported as the walker being offline"
            )
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("map data service isn’t responding"), "unhelpful message: \(message)")
            XCTAssertTrue(message.contains("timed out"), "the actual cause is not named: \(message)")
            XCTAssertEqual(message.components(separatedBy: "map data service").count - 1, 1, "the message quotes itself: \(message)")
            XCTAssertFalse(message.contains("Connect to download it"), "told to connect while connected: \(message)")
        }
    }

    /// And the genuinely-offline case still says the offline thing, because
    /// that one *is* actionable.
    func testBeingTrulyOfflineStillSaysSo() async {
        let transport = ScriptedTransport(replies: ["a.test": .failure(.offline)])
        let engine = OnDeviceLoopRoutingEngine(
            store: RoutingChunkStore(directory: makeTemporaryDirectory()),
            source: OverpassRoutingDataSource(
                configuration: .init(endpoints: endpoints(["a.test"]), maxAttempts: 1, retryDelaySeconds: 0),
                transport: transport,
                audit: nil
            ),
            audit: nil
        )
        do {
            _ = try await engine.generateLoops(
                LoopRequest(start: SyntheticOSM.douglas, mode: .distance, distanceKm: 3, unit: .km)
            )
            XCTFail("expected to fail")
        } catch {
            XCTAssertEqual(error as? RoutingDataManager.AcquisitionError, .dataUnavailableOffline)
            XCTAssertTrue(error.localizedDescription.contains("isn’t available offline"))
        }
    }

    /// The failure is recorded rather than lost, so "why is nothing
    /// downloading" has an answer that does not require a debugger.
    func testAFailedFetchIsStillAudited() async throws {
        let audit = RoutingAudit()
        let transport = ScriptedTransport(replies: ["dead.test": .failure(.providerUnavailable("The request timed out."))])
        let source = OverpassRoutingDataSource(
            configuration: .init(endpoints: endpoints(["dead.test"]), maxAttempts: 1, retryDelaySeconds: 0),
            transport: transport,
            audit: audit
        )
        _ = try? await source.fetchArea(LocalGeo.boundsAround(lat: 54.15, lon: -4.48, metres: 500))
        let snapshot = await audit.snapshot()
        XCTAssertEqual(snapshot.overpassRequests.count, 1)
        XCTAssertNotNil(snapshot.overpassRequests[0].failure)
        XCTAssertEqual(snapshot.overpassRequests[0].responseBytes, 0)
        XCTAssertEqual(snapshot.looperRoutingCallCount, 0, "a failed download must not reach for the remote router")
    }

    /// A walker staring at "Downloading walking paths for this area…" while
    /// the app works through providers that are all broken reads it as the app
    /// being stuck, and they are not wrong. Failure has to be prompt.
    func testGivingUpIsBoundedRatherThanTouringEveryProviderTwice() async {
        let slow = SlowFailingTransport(delay: 0.3)
        let source = OverpassRoutingDataSource(
            configuration: .init(
                endpoints: endpoints(["a.test", "b.test", "c.test", "d.test", "e.test"]),
                maxAttempts: 3, retryDelaySeconds: 0, totalDeadlineSeconds: 0.5
            ),
            transport: slow,
            audit: nil
        )
        let began = Date()
        do {
            _ = try await source.fetchArea(LocalGeo.boundsAround(lat: 54.15, lon: -4.48, metres: 500))
            XCTFail("expected to fail")
        } catch {
            guard case .providerUnavailable = (error as? RoutingDataSourceError) else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(began)
        // 5 providers × 3 attempts × 0.3 s would be 4.5 s without a deadline.
        XCTAssertLessThan(elapsed, 2.0, "took \(elapsed)s; the deadline is not being honoured")
        XCTAssertLessThan(slow.calls, 15)
    }

    /// A single commercial endpoint is still a one-line configuration, which
    /// is the property the whole abstraction exists to preserve.
    func testASingleEndpointIsStillOneLineOfConfiguration() {
        let configuration = OverpassRoutingDataSource.Configuration(
            endpoint: URL(string: "https://overpass.example.com/api/interpreter")!
        )
        XCTAssertEqual(configuration.endpoints.count, 1)
        XCTAssertEqual(configuration.primaryEndpoint.host, "overpass.example.com")
    }
}
