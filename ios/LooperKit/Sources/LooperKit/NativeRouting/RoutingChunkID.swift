import Foundation

/// One square of the world's routing data, addressed the way map tiles are.
///
/// A deterministic grid rather than a per-request bounding box is the whole
/// point of the design: two requests from opposite ends of the same town ask
/// for overlapping ground, and a grid means the overlap is *the same objects*
/// rather than two nearly-identical downloads. It is also what lets a future
/// "download this area for offline use" feature populate exactly the same
/// store the automatic path fills — see `RoutingChunkStore.Retention`.
///
/// Web Mercator XYZ, so the grid is the one every map tool already speaks and
/// a chunk can be eyeballed on a tile server when something looks wrong.
public struct RoutingChunkID: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let z: Int
    public let x: Int
    public let y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    public var description: String { "\(z)/\(x)/\(y)" }

    /// Filename-safe and sortable, so a store directory can be read by eye.
    public var key: String { "\(z)-\(x)-\(y)" }

    public init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else { return nil }
        self.init(z: z, x: x, y: y)
    }

    public static func < (a: RoutingChunkID, b: RoutingChunkID) -> Bool {
        (a.z, a.y, a.x) < (b.z, b.y, b.x)
    }

    public var bounds: GeographicBounds {
        let count = Double(1 << z)
        let west = Double(x) / count * 360 - 180
        let east = Double(x + 1) / count * 360 - 180
        let north = RoutingChunkID.latitude(forTileY: Double(y), zoom: z)
        let south = RoutingChunkID.latitude(forTileY: Double(y + 1), zoom: z)
        return GeographicBounds(south: south, west: west, north: north, east: east)
    }

    private static func latitude(forTileY y: Double, zoom: Int) -> Double {
        let n = Double.pi - 2 * Double.pi * y / Double(1 << zoom)
        return LocalGeo.toDegrees(atan(0.5 * (exp(n) - exp(-n))))
    }
}

/// The grid itself: which chunks an area needs, and how much ground a chunk
/// covers at a given latitude.
///
/// The zoom is a constructor parameter rather than a constant so the choice
/// can be measured rather than argued about. Zoom 14 is the shipped default:
/// at Looper's own latitude a z14 chunk is about 1.4 km square, which puts a
/// 5 km loop's data need at roughly two dozen chunks — small enough that a
/// chunk is a useful unit of caching and eviction, large enough that the
/// per-chunk bookkeeping is not the dominant cost.
public struct RoutingChunkGrid: Sendable {
    public static let defaultZoom = 14
    public static let standard = RoutingChunkGrid(zoom: defaultZoom)

    public let zoom: Int

    public init(zoom: Int = RoutingChunkGrid.defaultZoom) {
        self.zoom = zoom
    }

    public func chunk(lat: Double, lon: Double) -> RoutingChunkID {
        let count = 1 << zoom
        let clampedLat = Swift.min(85.05112878, Swift.max(-85.05112878, lat))
        let normalisedLon = LocalGeo.normaliseLongitude(lon)
        let x = Int(floor((normalisedLon + 180) / 360 * Double(count)))
        let radians = LocalGeo.toRadians(clampedLat)
        let yFraction = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2
        let y = Int(floor(yFraction * Double(count)))
        return RoutingChunkID(z: zoom, x: Swift.min(count - 1, Swift.max(0, x)), y: Swift.min(count - 1, Swift.max(0, y)))
    }

    /// Every chunk the area touches, in a stable order.
    public func chunks(covering bounds: GeographicBounds) -> [RoutingChunkID] {
        let topLeft = chunk(lat: bounds.north, lon: bounds.west)
        let bottomRight = chunk(lat: bounds.south, lon: bounds.east)
        guard topLeft.x <= bottomRight.x, topLeft.y <= bottomRight.y else {
            // An area straddling the antimeridian. Looper has never needed it,
            // and silently returning half the tiles would be worse than saying
            // so plainly, so the two sides are taken separately.
            let count = 1 << zoom
            var out: [RoutingChunkID] = []
            for y in topLeft.y...Swift.max(topLeft.y, bottomRight.y) {
                for x in topLeft.x..<count { out.append(RoutingChunkID(z: zoom, x: x, y: y)) }
                for x in 0...bottomRight.x { out.append(RoutingChunkID(z: zoom, x: x, y: y)) }
            }
            return out
        }
        var out: [RoutingChunkID] = []
        out.reserveCapacity((bottomRight.x - topLeft.x + 1) * (bottomRight.y - topLeft.y + 1))
        for y in topLeft.y...bottomRight.y {
            for x in topLeft.x...bottomRight.x {
                out.append(RoutingChunkID(z: zoom, x: x, y: y))
            }
        }
        return out
    }

    /// Roughly how wide a chunk is on the ground here. Reported in the
    /// download audit so the size of what is being fetched is legible.
    public func chunkWidthMetres(atLatitude lat: Double) -> Double {
        let degrees = 360 / Double(1 << zoom)
        return degrees * LocalGeo.metresPerDegreeLatitude * Swift.max(0.01, cos(LocalGeo.toRadians(lat)))
    }
}

/// How much ground a closed walk of a given length can possibly need.
///
/// A route of target `D` is accepted at up to `D * (1 + MAX_DISTANCE_ERROR)`,
/// and a closed walk's furthest point from the door is at most half its own
/// length away along the network. So nothing admissible ever sits further than
/// `D * (1 + 0.12) / 2 = D * 0.56` of network distance from the start, and an
/// exploration bounded there loses nothing.
///
/// Graph *data*, though, is acquired in geographic space rather than network
/// space, and the two are not the same: a walker who must go round a harbour
/// covers more network metres than the crow flies. Fetching a geographic
/// radius equal to the network bound therefore over-fetches slightly, which is
/// the safe direction — the alternative is a graph that stops just short of
/// where the search wanted to turn round, which shows up as a missing route
/// rather than as an error.
public enum RoutingCoverage {
    /// `MAX_DISTANCE_ERROR` in the route service's quality gate.
    public static let maxDistanceError = 0.12
    /// The exploration bound as a share of the target.
    public static let explorationShare = (1 + maxDistanceError) / 2
    /// Slack for the fact that a chunk edge is not a network edge.
    public static let boundaryMarginMetres: Double = 300

    /// The network-distance bound the exploration runs to.
    public static func explorationRadiusMetres(targetMetres: Double) -> Double {
        targetMetres * explorationShare
    }

    /// The geographic area whose chunks must be present before a walk of this
    /// length can be searched for from this point.
    public static func requiredBounds(lat: Double, lon: Double, targetMetres: Double) -> GeographicBounds {
        LocalGeo.boundsAround(
            lat: lat,
            lon: lon,
            metres: explorationRadiusMetres(targetMetres: targetMetres) + boundaryMarginMetres
        )
    }

    public static func requiredChunks(
        lat: Double,
        lon: Double,
        targetMetres: Double,
        grid: RoutingChunkGrid = .standard
    ) -> [RoutingChunkID] {
        grid.chunks(covering: requiredBounds(lat: lat, lon: lon, targetMetres: targetMetres))
    }
}
