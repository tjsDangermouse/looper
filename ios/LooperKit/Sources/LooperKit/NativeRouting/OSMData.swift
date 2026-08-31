import Foundation

/// A node as OpenStreetMap holds it. The id is global and stable, which is
/// what makes cross-chunk graph continuity possible without any geometric
/// stitching: the same junction stored in two chunks is the same integer in
/// both, so merging two chunks joins their ways automatically.
public struct OSMNode: Equatable, Sendable {
    public var id: Int64
    public var lat: Double
    public var lon: Double
    /// Only the tags the pedestrian-access policy reads; see `OSMTags`.
    public var tags: [String: String]

    public init(id: Int64, lat: Double, lon: Double, tags: [String: String] = [:]) {
        self.id = id
        self.lat = lat
        self.lon = lon
        self.tags = tags
    }
}

/// A way as OpenStreetMap holds it: an ordered list of node ids and its tags.
/// No coordinates — those live on the nodes, and duplicating them here is how
/// a chunk store ends up several times the size it needs to be.
public struct OSMWay: Equatable, Sendable {
    public var id: Int64
    public var nodes: [Int64]
    public var tags: [String: String]

    public init(id: Int64, nodes: [Int64], tags: [String: String]) {
        self.id = id
        self.nodes = nodes
        self.tags = tags
    }
}

/// Raw OSM path data for an area: highway ways, and every node they reference.
///
/// Explicitly *raw*. No walking rules have been applied at this point — that
/// is `PedestrianAccessPolicy`'s job and it happens when the graph is built,
/// not when the data arrives, so that a change to what Looper considers
/// walkable does not invalidate a single stored byte.
public struct OSMData: Equatable, Sendable {
    public var nodes: [OSMNode]
    public var ways: [OSMWay]

    public init(nodes: [OSMNode] = [], ways: [OSMWay] = []) {
        self.nodes = nodes
        self.ways = ways
    }

    public var isEmpty: Bool { nodes.isEmpty && ways.isEmpty }

    /// Merge, keeping one copy of anything present in both. Chunks overlap at
    /// their boundaries by design (see `RoutingChunkStore`), so this runs on
    /// every graph build.
    public static func merged(_ parts: [OSMData]) -> OSMData {
        var nodeIndex: [Int64: OSMNode] = [:]
        var wayIndex: [Int64: OSMWay] = [:]
        var total = 0
        for part in parts { total += part.nodes.count }
        nodeIndex.reserveCapacity(total)
        for part in parts {
            for node in part.nodes where nodeIndex[node.id] == nil { nodeIndex[node.id] = node }
            for way in part.ways where wayIndex[way.id] == nil { wayIndex[way.id] = way }
        }
        return OSMData(nodes: Array(nodeIndex.values), ways: Array(wayIndex.values))
    }
}

/// The tags Looper keeps.
///
/// Storing every tag OSM carries would multiply the size of a chunk for data
/// no part of this app reads; storing only a pre-computed "walkable: yes/no"
/// would mean re-downloading the world the first time the access rules are
/// corrected. So what is kept is exactly the input the access policy and the
/// instruction generator read, and both of those can then change freely
/// against data already on the phone.
public enum OSMTags {
    public static let wayKeys: Set<String> = [
        "highway", "foot", "access", "service", "motor_vehicle", "motorcar", "vehicle",
        "bicycle", "oneway", "oneway:foot", "sidewalk", "footway", "path", "area",
        "indoor", "tunnel", "bridge", "name", "ref", "surface", "informal",
        "crossing", "junction", "public_transport", "construction", "proposed",
        "conveying", "tracktype", "designation", "toll", "step_count", "incline",
    ]

    public static let nodeKeys: Set<String> = [
        "barrier", "access", "foot", "locked", "highway", "crossing",
    ]

    public static func keep(_ tags: [String: String], allowed: Set<String>) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(Swift.min(tags.count, allowed.count))
        for (key, value) in tags where allowed.contains(key) { out[key] = value }
        return out
    }
}

// MARK: - Overpass JSON

public enum OverpassParseError: Error, LocalizedError, Equatable {
    case notJSON
    case remarkedFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON: return "The routing data provider returned something that isn't OSM data."
        case .remarkedFailure(let remark): return "The routing data provider refused the request: \(remark)"
        }
    }
}

/// Reads an Overpass `[out:json]` body into `OSMData`.
///
/// Two things here are not incidental. Nodes carrying no interesting tag keep
/// no tag dictionary at all, because in a typical extract 95% of nodes are
/// pure geometry and an empty dictionary each is most of the parse cost. And
/// an Overpass `remark` naming a timeout or a memory limit is turned into an
/// error rather than being read as "this area has no paths" — a truncated
/// answer stored as if it were complete is the one failure mode that would
/// poison the cache and not show up until someone is standing in the rain.
public enum OverpassJSON {
    public static func parse(_ data: Data) throws -> OSMData {
        let decoder = JSONDecoder()
        guard let body = try? decoder.decode(Body.self, from: data) else { throw OverpassParseError.notJSON }
        if let remark = body.remark, isFailure(remark) { throw OverpassParseError.remarkedFailure(remark) }

        var nodes: [OSMNode] = []
        var ways: [OSMWay] = []
        nodes.reserveCapacity(body.elements.count)
        for element in body.elements {
            switch element.type {
            case "node":
                guard let lat = element.lat, let lon = element.lon else { continue }
                let tags = element.tags.map { OSMTags.keep($0, allowed: OSMTags.nodeKeys) } ?? [:]
                nodes.append(OSMNode(id: element.id, lat: lat, lon: lon, tags: tags))
            case "way":
                guard let refs = element.nodes, refs.count >= 2 else { continue }
                let tags = OSMTags.keep(element.tags ?? [:], allowed: OSMTags.wayKeys)
                guard tags["highway"] != nil else { continue }
                ways.append(OSMWay(id: element.id, nodes: refs, tags: tags))
            default:
                continue
            }
        }
        return OSMData(nodes: nodes, ways: ways)
    }

    /// Overpass says "runtime error" or names the limit it hit. A remark that
    /// mentions neither is informational and the body with it is complete.
    static func isFailure(_ remark: String) -> Bool {
        let lowered = remark.lowercased()
        return lowered.contains("runtime error") || lowered.contains("timed out")
            || lowered.contains("out of memory") || lowered.contains("query timeout")
    }

    private struct Body: Decodable {
        var elements: [Element]
        var remark: String?
    }

    private struct Element: Decodable {
        var type: String
        var id: Int64
        var lat: Double?
        var lon: Double?
        var nodes: [Int64]?
        var tags: [String: String]?
    }
}
