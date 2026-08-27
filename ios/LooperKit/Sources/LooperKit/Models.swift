import Foundation

/// A coordinate in `[lng, lat]` order, matching the GeoJSON convention the
/// route service and MapLibre both use — encodes/decodes as a 2-element array.
public struct Point: Equatable, Hashable {
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

/// A step's maneuver comes back as either GraphHopper/ORS's numeric code or
/// the loop service's own named string — both routers describe the same turn
/// differently, so this holds either.
public enum Maneuver: Codable, Equatable {
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

public struct Step: Codable, Equatable {
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

public struct LineGeometry: Codable, Equatable {
    public var type: String
    public var coordinates: [Point]

    public init(coordinates: [Point], type: String = "LineString") {
        self.type = type
        self.coordinates = coordinates
    }
}

public struct Route: Codable, Equatable {
    public var id: String
    public var name: String
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var targetDifferencePercent: Double
    public var geometry: LineGeometry
    public var steps: [Step]
    public var reversed: Bool?

    public init(
        id: String,
        name: String,
        distanceMeters: Double,
        durationSeconds: Double,
        targetDifferencePercent: Double,
        geometry: LineGeometry,
        steps: [Step],
        reversed: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.targetDifferencePercent = targetDifferencePercent
        self.geometry = geometry
        self.steps = steps
        self.reversed = reversed
    }
}
