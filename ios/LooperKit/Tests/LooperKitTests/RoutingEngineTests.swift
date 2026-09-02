import XCTest
@testable import LooperKit

/// A stand-in for the network, so the production request body can be asserted
/// without contacting the route service.
private final class StubClient: LoopsHTTPClient, @unchecked Sendable {
    var lastBody: [String: Any] = [:]
    let response: String

    init(response: String) { self.response = response }

    func post(url: URL, body: Data) async throws -> (data: Data, statusCode: Int) {
        lastBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        return (Data(response.utf8), 200)
    }
}

private let oneRoute = """
{"routes":[{"id":"a","label":"North loop","distanceMeters":5012,"durationSeconds":3600,
 "targetDifferencePercent":0,"geometry":{"type":"LineString","coordinates":[[0,0],[0.001,0]]},"steps":[]}]}
"""

final class RoutingEngineTests: XCTestCase {
    /// Choosing between Remote and On-device happens in the app. A remote
    /// request remains field-compatible with the production API.
    func testRemoteRequestDoesNotContainAnEngineSelector() async throws {
        let client = StubClient(response: oneRoute)
        _ = try await requestLoops(
            start: Point(-4.4816, 54.1506), mode: .distance, distanceKm: 5,
            unit: .km, variation: 0, apiBase: "https://example.test", client: client
        )
        XCTAssertNil(client.lastBody["routingEngine"])
    }

    func testRoutesSurviveEncodingWithOnDeviceProvenance() throws {
        let route = Route(
            id: "a", name: "North loop", distanceMeters: 5012, durationSeconds: 3600,
            targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [Point(0, 0), Point(0.001, 0)]),
            steps: [], routingEngine: .onDevice
        )
        let decoded = try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded.routingEngine, .onDevice)
    }

    func testSavedDirectPrototypeRoutesMigrateToRemote() throws {
        let data = Data(#"{"routingEngine":"direct"}"#.utf8)
        struct Saved: Decodable { let routingEngine: RoutingEngine }
        XCTAssertEqual(try JSONDecoder().decode(Saved.self, from: data).routingEngine, .remote)
    }
}
