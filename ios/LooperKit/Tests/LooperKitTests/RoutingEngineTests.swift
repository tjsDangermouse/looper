import XCTest
@testable import LooperKit

/// A stand-in for the network, so the request the app sends and the answer it
/// makes of what comes back can both be asserted without a service.
private final class StubClient: LoopsHTTPClient, @unchecked Sendable {
    var lastBody: [String: Any] = [:]
    var response: String
    var status = 200

    init(response: String) { self.response = response }

    func post(url: URL, body: Data) async throws -> (data: Data, statusCode: Int) {
        lastBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) as? [String: Any] ?? [:]
        return (Data(response.utf8), status)
    }
}

private let oneRoute = """
{"routes":[{"id":"a","label":"North loop","distanceMeters":5012,"durationSeconds":3600,
 "targetDifferencePercent":0,"geometry":{"type":"LineString","coordinates":[[0,0],[0.001,0]]},"steps":[]}]
"""

final class RoutingEngineTests: XCTestCase {

    func testSendsTheSelectedEngine() async throws {
        let client = StubClient(response: oneRoute + ",\"engine\":{\"routingEngine\":\"direct\"}}")
        _ = try await requestLoops(
            start: Point(-4.4816, 54.1506), mode: .distance, distanceKm: 5, unit: .km,
            variation: 0, routingEngine: .direct, apiBase: "https://example.test", client: client
        )
        XCTAssertEqual(client.lastBody["routingEngine"] as? String, "direct")
    }

    /// Absent rather than null: a service that does not know the field must
    /// see a request identical to the one it has always been sent.
    func testOmitsTheEngineWhenNoneIsChosen() async throws {
        let client = StubClient(response: oneRoute + "}")
        _ = try await requestLoops(
            start: Point(-4.4816, 54.1506), mode: .distance, distanceKm: 5, unit: .km,
            variation: 0, apiBase: "https://example.test", client: client
        )
        XCTAssertNil(client.lastBody["routingEngine"])
    }

    func testReadsTheEngineTheServiceUsed() async throws {
        let client = StubClient(response: oneRoute + """
        ,"engine":{"routingEngine":"direct","requestedEngine":"direct","engineReason":"requested",
        "generationMs":208,"searchClosedWalks":153,"searchStates":276347,"searchMs":144.1}}
        """)
        let result = try await requestLoops(
            start: Point(-4.4816, 54.1506), mode: .distance, distanceKm: 5, unit: .km,
            variation: 0, routingEngine: .direct, apiBase: "https://example.test", client: client
        )
        XCTAssertEqual(result.engine?.routingEngine, .direct)
        XCTAssertEqual(result.engine?.searchClosedWalks, 153)
        XCTAssertFalse(result.engine?.didFallBack ?? true)
        // A route carries its provenance, so the badge and a saved favourite
        // both know which engine drew it.
        XCTAssertEqual(result.routes.first?.routingEngine, .direct)
    }

    /// Asking for Direct Search on a waypoint loop is answered, not refused —
    /// the service says which engine actually ran and the app can say so too.
    func testSurfacesAWaypointFallback() async throws {
        let client = StubClient(response: oneRoute + """
        ,"engine":{"routingEngine":"remote","requestedEngine":"direct","engineReason":"waypoint-fallback",
        "generationMs":1420}}
        """)
        let result = try await requestLoops(
            start: Point(-4.4816, 54.1506), mode: .distance, distanceKm: 5, unit: .km,
            variation: 0, waypoints: [Point(-4.47, 54.16)], routingEngine: .direct,
            apiBase: "https://example.test", client: client
        )
        XCTAssertEqual(result.engine?.routingEngine, .remote)
        XCTAssertTrue(result.engine?.didFallBack ?? false)
        XCTAssertEqual(result.engine?.engineReason, "waypoint-fallback")
        XCTAssertEqual(result.routes.first?.routingEngine, .remote)
    }

    /// The service in production today reports no engine at all. That has to
    /// keep working, and be read as the engine it is.
    func testToleratesAServiceThatReportsNoEngine() async throws {
        let client = StubClient(response: oneRoute + "}")
        let result = try await requestLoops(
            start: Point(-4.4816, 54.1506), mode: .distance, distanceKm: 5, unit: .km,
            variation: 0, routingEngine: .direct, apiBase: "https://example.test", client: client
        )
        XCTAssertNil(result.engine)
        XCTAssertEqual(result.routes.count, 1)
        XCTAssertNil(result.routes.first?.routingEngine)
    }

    func testRoutesSurviveEncodingWithTheirEngine() throws {
        let route = Route(
            id: "a", name: "North loop", distanceMeters: 5012, durationSeconds: 3600,
            targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [Point(0, 0), Point(0.001, 0)]),
            steps: [], routingEngine: .direct
        )
        let decoded = try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded.routingEngine, .direct)
    }
}
