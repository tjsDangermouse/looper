import Foundation

/// A latitude/longitude rectangle, in the order the Overpass API asks for it.
///
/// Deliberately plain: everything downstream — the chunk grid, the data
/// manager, the store — talks about areas in this one type, so there is a
/// single place where "which corner is which" is decided.
public struct GeographicBounds: Equatable, Hashable, Codable, Sendable {
    public var south: Double
    public var west: Double
    public var north: Double
    public var east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }

    public var centre: Point { Point((west + east) / 2, (south + north) / 2) }

    public func contains(lat: Double, lon: Double) -> Bool {
        lat >= south && lat <= north && lon >= west && lon <= east
    }

    public func intersects(_ other: GeographicBounds) -> Bool {
        !(other.south > north || other.north < south || other.west > east || other.east < west)
    }

    public func union(_ other: GeographicBounds) -> GeographicBounds {
        GeographicBounds(
            south: Swift.min(south, other.south),
            west: Swift.min(west, other.west),
            north: Swift.max(north, other.north),
            east: Swift.max(east, other.east)
        )
    }

    /// Grown by `metres` on every side. Used for the chunk-boundary safety
    /// margin, where a few hundred metres of slack costs one more tile and
    /// buys a graph that does not end just short of where the search wants
    /// to turn round.
    public func expanded(byMetres metres: Double) -> GeographicBounds {
        let latDelta = metres / LocalGeo.metresPerDegreeLatitude
        let scale = Swift.max(0.01, cos((centre.lat) * .pi / 180))
        let lonDelta = metres / (LocalGeo.metresPerDegreeLatitude * scale)
        return GeographicBounds(
            south: Swift.max(-85, south - latDelta),
            west: west - lonDelta,
            north: Swift.min(85, north + latDelta),
            east: east + lonDelta
        )
    }

    /// Rough ground area, for deciding whether one Overpass request covering a
    /// group of chunks is a sensible trade against several smaller ones.
    public var approximateAreaSquareMetres: Double {
        let scale = Swift.max(0.01, cos(centre.lat * .pi / 180))
        let height = (north - south) * LocalGeo.metresPerDegreeLatitude
        let width = (east - west) * LocalGeo.metresPerDegreeLatitude * scale
        return Swift.max(0, height) * Swift.max(0, width)
    }
}

/// Geometry for the on-device router.
///
/// A separate namespace from the app's existing `haversine`/`nearestProgress`
/// helpers on purpose: those measure a walker's progress along a finished
/// route, these measure a graph. Sharing one loose set of free functions
/// between the two is how a change made for guidance quietly moves a routing
/// threshold.
public enum LocalGeo {
    public static let earthRadiusMetres = 6371008.8
    /// One degree of latitude, near enough anywhere Looper runs.
    public static let metresPerDegreeLatitude = earthRadiusMetres * .pi / 180

    public static func toRadians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    public static func toDegrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Wrap to (-180, 180].
    public static func normaliseLongitude(_ degrees: Double) -> Double {
        ((degrees + 540).truncatingRemainder(dividingBy: 360)) - 180
    }

    /// Wrap to [0, 360).
    public static func normaliseBearing(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    public static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let a1 = toRadians(lat1), a2 = toRadians(lat2)
        let dLat = a2 - a1
        let dLon = toRadians(lon2 - lon1)
        let h = pow(sin(dLat / 2), 2) + cos(a1) * cos(a2) * pow(sin(dLon / 2), 2)
        return 2 * earthRadiusMetres * asin(Swift.min(1, h.squareRoot()))
    }

    /// Initial great-circle bearing, degrees clockwise from north.
    public static func bearing(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let a1 = toRadians(lat1), a2 = toRadians(lat2)
        let dLon = toRadians(lon2 - lon1)
        let y = sin(dLon) * cos(a2)
        let x = cos(a1) * sin(a2) - sin(a1) * cos(a2) * cos(dLon)
        return normaliseBearing(toDegrees(atan2(y, x)))
    }

    /// The compass octant a bearing falls in: 0 = north, 1 = north-east, and
    /// round. The diversity axis, both in the search and in what is offered.
    public static func bearingOctant(_ bearing: Double) -> Int {
        Int((normaliseBearing(bearing) / 45).rounded()) % 8
    }

    /// Where you end up walking `metres` from a point on a constant bearing.
    public static func destination(lat: Double, lon: Double, metres: Double, bearing: Double) -> (lat: Double, lon: Double) {
        let angular = metres / earthRadiusMetres
        let theta = toRadians(bearing)
        let lat1 = toRadians(lat), lon1 = toRadians(lon)
        let sinLat2 = sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(theta)
        let lat2 = asin(Swift.min(1, Swift.max(-1, sinLat2)))
        let lon2 = lon1 + atan2(sin(theta) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sinLat2)
        return (toDegrees(lat2), normaliseLongitude(toDegrees(lon2)))
    }

    /// A square-ish bounding box `metres` in every direction from a point.
    public static func boundsAround(lat: Double, lon: Double, metres: Double) -> GeographicBounds {
        let latDelta = metres / metresPerDegreeLatitude
        let scale = Swift.max(0.01, cos(toRadians(lat)))
        let lonDelta = metres / (metresPerDegreeLatitude * scale)
        return GeographicBounds(
            south: Swift.max(-85, lat - latDelta),
            west: normaliseLongitude(lon - lonDelta),
            north: Swift.min(85, lat + latDelta),
            east: normaliseLongitude(lon + lonDelta)
        )
    }
}

/// Metres east/north of an origin. Loops are a few kilometres across, so a
/// local equirectangular frame is exact enough for every shape term the
/// search and the quality gate compute, and plane geometry is both faster and
/// easier to reason about than doing it on the sphere.
public struct MetricFrame: Sendable {
    public let originLon: Double
    public let originLat: Double
    public let scale: Double

    public init(originLon: Double, originLat: Double) {
        self.originLon = originLon
        self.originLat = originLat
        self.scale = cos(LocalGeo.toRadians(originLat))
    }

    @inline(__always)
    public func project(lon: Double, lat: Double) -> (x: Double, y: Double) {
        (
            LocalGeo.earthRadiusMetres * LocalGeo.toRadians(LocalGeo.normaliseLongitude(lon - originLon)) * scale,
            LocalGeo.earthRadiusMetres * LocalGeo.toRadians(lat - originLat)
        )
    }

    /// A flat lon/lat pair list projected into the frame, in place order.
    public func project(line: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: line.count)
        var i = 0
        while i + 1 < line.count {
            let point = project(lon: line[i], lat: line[i + 1])
            out[i] = point.x
            out[i + 1] = point.y
            i += 2
        }
        return out
    }
}
