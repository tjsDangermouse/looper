import Foundation

/// A coordinate in `[lng, lat]` order, matching the GeoJSON convention the
/// route service and MapLibre both use — encodes/decodes as a 2-element array.
public struct Point: Equatable, Hashable, Sendable {
    public var lng: Double
    public var lat: Double

    public init(_ lng: Double, _ lat: Double) {
        self.lng = lng
        self.lat = lat
    }
}

extension Point: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        lng = try container.decode(Double.self)
        lat = try container.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(lng)
        try container.encode(lat)
    }
}

public enum LoopMode: String, Codable, Hashable, Sendable {
    case distance
    case time
}

public enum Unit: String, Codable, Hashable, Sendable {
    case km
    case mi
}

public enum Activity: String, Codable, Hashable, Sendable {
    case walking
    case running
}

/// Which generator the route service should use.
///
/// A developer/testing choice rather than a walker's: both engines answer the
/// same question and return the same kind of route, so nothing in the map, the
/// walk screen or the spoken guidance branches on this. It exists so that the
/// two can be compared on real ground.
///
/// - `remote`: the current hosted generator — candidate bearings, legs routed
///   one at a time.
/// - `direct`: the closed-walk search, which searches the walk itself over the
///   routing graph and returns the exact edges it walked.
///
/// Ordered waypoints are answered by `remote` and by `onDevice`, each in its
/// own way. The service's `direct` generator has no representation for them and
/// falls back to `remote`, which it says so in the answer; the on-device engine
/// builds them itself, from the backbone out — see `LocalWaypointRouter`.
public enum RoutingEngine: String, Codable, Hashable, Sendable, CaseIterable {
    case remote
    case direct
    case onDevice

    /// What to show a tester. Deliberately short enough for a badge.
    public var badge: String {
        switch self {
        case .remote: return "REMOTE"
        case .direct: return "DIRECT"
        case .onDevice: return "ON-DEVICE"
        }
    }

    public var title: String {
        switch self {
        case .remote: return "Remote / Current"
        case .direct: return "Direct Search / New"
        case .onDevice: return "On-device / New"
        }
    }

    /// What may be named in a request to the route service.
    ///
    /// `onDevice` is not a generator the service has, and asking it for one
    /// would be both meaningless and a change to a contract this work is not
    /// allowed to touch. It is a fact about where an answer came from, which
    /// is why it exists on `Route` but never on a request.
    public var serverValue: RoutingEngine? {
        self == .onDevice ? nil : self
    }

    /// The two engines a tester chooses between: the existing hosted one and
    /// the new local one. `direct` is the service's own second generator and
    /// is selected within Remote, not alongside it.
    public static let selectableOnDevice: [RoutingEngine] = [.remote, .onDevice]
}

/// What the service said about how an answer was produced. Developer-facing.
public struct RoutingEngineReport: Codable, Equatable, Sendable {
    public var routingEngine: RoutingEngine
    public var requestedEngine: RoutingEngine?
    public var engineReason: String?
    public var generationMs: Double?
    public var fallbackReason: String?
    public var searchClosedWalks: Int?
    public var searchStates: Int?
    public var searchMs: Double?

    public init(
        routingEngine: RoutingEngine,
        requestedEngine: RoutingEngine? = nil,
        engineReason: String? = nil,
        generationMs: Double? = nil,
        fallbackReason: String? = nil,
        searchClosedWalks: Int? = nil,
        searchStates: Int? = nil,
        searchMs: Double? = nil
    ) {
        self.routingEngine = routingEngine
        self.requestedEngine = requestedEngine
        self.engineReason = engineReason
        self.generationMs = generationMs
        self.fallbackReason = fallbackReason
        self.searchClosedWalks = searchClosedWalks
        self.searchStates = searchStates
        self.searchMs = searchMs
    }

    /// True when Direct Search was asked for and something else answered.
    public var didFallBack: Bool {
        requestedEngine != nil && requestedEngine != routingEngine
    }
}

/// A step's maneuver comes back as either GraphHopper/ORS's numeric code or
/// the loop service's own named string — both routers describe the same turn
/// differently, so this holds either.
public enum Maneuver: Codable, Equatable, Sendable {
    case code(Int)
    case name(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .code(value)
        } else {
            self = .name(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .code(let value): try container.encode(value)
        case .name(let value): try container.encode(value)
        }
    }
}

public struct Step: Codable, Equatable, Sendable {
    public var instruction: String
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var startIndex: Int?
    public var endIndex: Int?
    public var maneuver: Maneuver?
    public var road: String?

    public init(
        instruction: String,
        distanceMeters: Double,
        durationSeconds: Double,
        startIndex: Int? = nil,
        endIndex: Int? = nil,
        maneuver: Maneuver? = nil,
        road: String? = nil
    ) {
        self.instruction = instruction
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.maneuver = maneuver
        self.road = road
    }
}

public struct LineGeometry: Codable, Equatable, Sendable {
    public var type: String
    public var coordinates: [Point]

    public init(coordinates: [Point], type: String = "LineString") {
        self.type = type
        self.coordinates = coordinates
    }
}

public struct Route: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var targetDifferencePercent: Double
    public var geometry: LineGeometry
    public var steps: [Step]
    public var reversed: Bool?
    /// Which engine produced this route. Stamped by `requestLoops` from the
    /// answer's own report, so a route carries its provenance into the walk
    /// screen and into a saved favourite. Nothing about the route's meaning
    /// depends on it.
    public var routingEngine: RoutingEngine?

    public init(
        id: String,
        name: String,
        distanceMeters: Double,
        durationSeconds: Double,
        targetDifferencePercent: Double,
        geometry: LineGeometry,
        steps: [Step],
        reversed: Bool? = nil,
        routingEngine: RoutingEngine? = nil
    ) {
        self.id = id
        self.name = name
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.targetDifferencePercent = targetDifferencePercent
        self.geometry = geometry
        self.steps = steps
        self.reversed = reversed
        self.routingEngine = routingEngine
    }
}
