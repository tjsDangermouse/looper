import XCTest
@testable import LooperKit

final class RoutingEngineTests: XCTestCase {
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
