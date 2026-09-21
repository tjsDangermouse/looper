import Foundation

/// What walking-path data the routing stack asked Overpass providers for.
public actor RoutingAudit {
    public static let shared = RoutingAudit()

    public struct OverpassRequest: Sendable, Equatable {
        public var at: Date
        public var endpoint: String
        public var bounds: GeographicBounds
        public var requestBytes: Int
        public var responseBytes: Int
        public var ways: Int
        public var nodes: Int
        public var attempts: Int
        public var durationMs: Double
        public var failure: String?
    }

    public struct Snapshot: Sendable, Equatable {
        public var overpassRequests: [OverpassRequest]
        public var chunksPopulated: Int

        public var overpassCallCount: Int { overpassRequests.count }
        public var downloadedBytes: Int { overpassRequests.reduce(0) { $0 + $1.responseBytes } }
        public var waysReceived: Int { overpassRequests.reduce(0) { $0 + $1.ways } }
        public var nodesReceived: Int { overpassRequests.reduce(0) { $0 + $1.nodes } }
    }

    private var overpass: [OverpassRequest] = []
    private var chunksPopulated = 0
    /// Bounded: this is a development aid, not a telemetry pipeline, and an
    /// unbounded array in an app somebody walks around with all day is a leak.
    private let limit = 200

    public init() {}

    public func record(_ request: OverpassRequest) {
        overpass.append(request)
        if overpass.count > limit { overpass.removeFirst(overpass.count - limit) }
    }

    public func recordChunksPopulated(_ count: Int) {
        chunksPopulated += count
    }

    public func snapshot() -> Snapshot {
        Snapshot(overpassRequests: overpass, chunksPopulated: chunksPopulated)
    }

    public func reset() {
        overpass = []
        chunksPopulated = 0
    }
}
