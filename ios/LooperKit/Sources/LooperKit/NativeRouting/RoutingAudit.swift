import Foundation

/// What the routing stack asked the network for, and of whom.
///
/// This exists to answer one question that field testing cannot answer by
/// eye: when the walker has chosen On-device routing, did anything at all go
/// to Looper's own routing service? The two counters are kept separately and
/// deliberately at different layers — Overpass requests are recorded by the
/// data source, Looper routing requests by the remote engine's HTTP client —
/// so "zero Looper routing calls" is a measurement rather than an assurance.
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

    public struct LooperRoutingRequest: Sendable, Equatable {
        public var at: Date
        public var url: String
    }

    public struct Snapshot: Sendable, Equatable {
        public var overpassRequests: [OverpassRequest]
        public var looperRoutingRequests: [LooperRoutingRequest]
        public var chunksPopulated: Int

        public var overpassCallCount: Int { overpassRequests.count }
        public var looperRoutingCallCount: Int { looperRoutingRequests.count }
        public var downloadedBytes: Int { overpassRequests.reduce(0) { $0 + $1.responseBytes } }
        public var waysReceived: Int { overpassRequests.reduce(0) { $0 + $1.ways } }
        public var nodesReceived: Int { overpassRequests.reduce(0) { $0 + $1.nodes } }
    }

    private var overpass: [OverpassRequest] = []
    private var looper: [LooperRoutingRequest] = []
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

    /// Called by the *remote* engine's HTTP client on every routing call. In
    /// On-device mode this must never fire, and a test asserts exactly that.
    public func recordLooperRoutingRequest(url: String) {
        looper.append(LooperRoutingRequest(at: Date(), url: url))
        if looper.count > limit { looper.removeFirst(looper.count - limit) }
    }

    public func snapshot() -> Snapshot {
        Snapshot(overpassRequests: overpass, looperRoutingRequests: looper, chunksPopulated: chunksPopulated)
    }

    public func reset() {
        overpass = []
        looper = []
        chunksPopulated = 0
    }
}
