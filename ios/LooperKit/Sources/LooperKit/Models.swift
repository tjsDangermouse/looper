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

/// Which routing implementation should find the walk.
///
/// A developer/testing choice rather than a walker's: both engines answer the
/// same question and return the same kind of route, so nothing in the map, the
/// walk screen or the spoken guidance branches on this. It exists so that the
/// two can be compared on real ground.
///
/// Ordered waypoints are answered by both implementations, each in its own
/// way; the on-device engine builds them from the backbone out — see
/// `LocalWaypointRouter`.
public enum RoutingEngine: String, Codable, Hashable, Sendable, CaseIterable {
    case remote
    case onDevice

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        // Test builds briefly persisted the abandoned remote "direct"
        // generator on routes. It was still remote routing, so preserve those
        // saved routes by migrating their provenance as they are read.
        self = value == "onDevice" ? .onDevice : .remote
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// What to show a tester. Deliberately short enough for a badge.
    public var badge: String {
        switch self {
        case .remote: return "REMOTE"
        case .onDevice: return "ON-DEVICE"
        }
    }

    public var title: String {
        switch self {
        case .remote: return "Remote / Current"
        case .onDevice: return "On-device / New"
        }
    }
}

/// What the service said about how an answer was produced. Developer-facing.
public struct RoutingEngineReport: Codable, Equatable, Sendable {
    public var routingEngine: RoutingEngine
    public var generationMs: Double?
    public var searchClosedWalks: Int?
    public var searchStates: Int?
    public var searchMs: Double?

    public init(
        routingEngine: RoutingEngine,
        generationMs: Double? = nil,
        searchClosedWalks: Int? = nil,
        searchStates: Int? = nil,
        searchMs: Double? = nil
    ) {
        self.routingEngine = routingEngine
        self.generationMs = generationMs
        self.searchClosedWalks = searchClosedWalks
        self.searchStates = searchStates
        self.searchMs = searchMs
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
