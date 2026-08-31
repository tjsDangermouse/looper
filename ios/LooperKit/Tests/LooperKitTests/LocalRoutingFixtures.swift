import Foundation
@testable import LooperKit

/// A synthetic street grid, so the local routing stack can be tested without a
/// network and without a checked-in megabyte of real OSM data.
///
/// A lattice is not a town, and nothing here pretends otherwise — the shape
/// tests that matter run against real Douglas data in the field. What a
/// lattice is good for is exactly what these tests need: a network whose
/// correct answers can be worked out by hand, where "did the graph join across
/// a chunk boundary" has an arithmetic answer rather than an eyeballed one.
enum SyntheticOSM {
    /// Douglas, Isle of Man — the same start the route service's own fixtures
    /// use, so figures here are comparable with the remote engine's.
    static let douglas = Point(-4.4816, 54.1506)

    /// A `size` × `size` lattice of streets `spacingMetres` apart, centred on
    /// `centre`. Node ids are `row * 1000 + column + 1`, so a test can name a
    /// junction directly.
    static func grid(
        centre: Point = douglas,
        size: Int = 8,
        spacingMetres: Double = 200,
        highway: String = "residential",
        extraWayTags: [String: String] = [:]
    ) -> OSMData {
        var nodes: [OSMNode] = []
        var ways: [OSMWay] = []
        let half = Double(size - 1) / 2

        for row in 0..<size {
            for column in 0..<size {
                let north = (Double(row) - half) * spacingMetres
                let east = (Double(column) - half) * spacingMetres
                let moved = LocalGeo.destination(lat: centre.lat, lon: centre.lng, metres: north, bearing: 0)
                let placed = LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
                nodes.append(OSMNode(id: Int64(row * 1000 + column + 1), lat: placed.lat, lon: placed.lon))
            }
        }

        var tags = ["highway": highway]
        tags.merge(extraWayTags) { _, new in new }

        var wayID: Int64 = 1
        for row in 0..<size {
            let ids = (0..<size).map { Int64(row * 1000 + $0 + 1) }
            var named = tags
            named["name"] = "Row \(row) Street"
            ways.append(OSMWay(id: wayID, nodes: ids, tags: named))
            wayID += 1
        }
        for column in 0..<size {
            let ids = (0..<size).map { Int64($0 * 1000 + column + 1) }
            var named = tags
            named["name"] = "Column \(column) Avenue"
            ways.append(OSMWay(id: wayID, nodes: ids, tags: named))
            wayID += 1
        }
        return OSMData(nodes: nodes, ways: ways)
    }

    /// One way running east through `size` nodes: the simplest thing that can
    /// straddle a chunk boundary.
    static func line(from: Point, size: Int, spacingMetres: Double, id: Int64 = 9001) -> OSMData {
        var nodes: [OSMNode] = []
        var lat = from.lat, lon = from.lng
        for index in 0..<size {
            nodes.append(OSMNode(id: id * 100 + Int64(index), lat: lat, lon: lon))
            let next = LocalGeo.destination(lat: lat, lon: lon, metres: spacingMetres, bearing: 90)
            lat = next.lat
            lon = next.lon
        }
        let way = OSMWay(id: id, nodes: nodes.map(\.id), tags: ["highway": "footway", "name": "Long Lane"])
        return OSMData(nodes: nodes, ways: [way])
    }
}

/// An Overpass transport that serves prepared data and counts what it was
/// asked for. No network, and a test can assert the exact number of requests
/// the grouping logic decided to make.
final class StubOverpassTransport: OverpassTransport, @unchecked Sendable {
    private(set) var requests: [GeographicBounds] = []
    private(set) var bodies: [String] = []
    var responder: @Sendable (GeographicBounds) -> OSMData
    var statusCode = 200
    var failure: Error?
    private let queue = DispatchQueue(label: "stub-overpass")

    init(responder: @escaping @Sendable (GeographicBounds) -> OSMData) {
        self.responder = responder
    }

    var requestCount: Int { queue.sync { requests.count } }

    func post(url: URL, body: Data, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        if let failure { throw failure }
        let text = String(decoding: body, as: UTF8.self).removingPercentEncoding ?? ""
        let bounds = StubOverpassTransport.parseBounds(text) ?? GeographicBounds(south: 0, west: 0, north: 0, east: 0)
        queue.sync {
            requests.append(bounds)
            bodies.append(text)
        }
        let data = responder(bounds)
        return (StubOverpassTransport.encodeOverpassJSON(data), statusCode)
    }

    /// Reads the bbox back out of the query, which also asserts in passing
    /// that the query really does carry one in south,west,north,east order.
    static func parseBounds(_ query: String) -> GeographicBounds? {
        guard let open = query.range(of: "]("), let close = query.range(of: ")", range: open.upperBound..<query.endIndex) else { return nil }
        let numbers = query[open.upperBound..<close.lowerBound].split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return GeographicBounds(south: numbers[0], west: numbers[1], north: numbers[2], east: numbers[3])
    }

    static func encodeOverpassJSON(_ data: OSMData) -> Data {
        var elements: [[String: Any]] = []
        for node in data.nodes {
            var element: [String: Any] = ["type": "node", "id": node.id, "lat": node.lat, "lon": node.lon]
            if !node.tags.isEmpty { element["tags"] = node.tags }
            elements.append(element)
        }
        for way in data.ways {
            elements.append(["type": "way", "id": way.id, "nodes": way.nodes, "tags": way.tags])
        }
        return (try? JSONSerialization.data(withJSONObject: ["version": 0.6, "elements": elements])) ?? Data()
    }
}

/// Somewhere to put a store that vanishes with the test.
func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("looper-chunks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
