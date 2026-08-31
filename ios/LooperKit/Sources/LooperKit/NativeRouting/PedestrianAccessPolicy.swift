import Foundation

/// What Looper is prepared to walk on, in one place.
///
/// Overpass is a data source, not a router: it will happily return a motorway
/// and a private drive alongside the footpath next to them, and deciding
/// between the three is this app's job. Every such decision lives here rather
/// than being spread through the parser and the graph builder, because access
/// rules scattered across a pipeline are rules nobody can test and nobody can
/// change with confidence.
///
/// The semantics follow GraphHopper's `foot` behaviour, which is the reference
/// Looper's remote engine has always used, so a walk found on the phone is
/// judged walkable by the same rules as a walk found on the server. GraphHopper
/// itself is not required at runtime and is not consulted — only its published
/// treatment of ambiguous OSM tagging is.
public struct PedestrianAccessPolicy: Sendable {
    public static let standard = PedestrianAccessPolicy()

    public init() {}

    /// What the policy decided about a way, and why.
    public struct Decision: Equatable, Sendable {
        public var isWalkable: Bool
        /// Walkable in the way's own node order.
        public var forward: Bool
        /// Walkable against the way's node order.
        public var backward: Bool
        /// Machine-readable, for tests and the download audit. Never shown.
        public var reason: String
        public var roadClass: RoadClass

        public static func blocked(_ reason: String, _ roadClass: RoadClass = .other) -> Decision {
            Decision(isWalkable: false, forward: false, backward: false, reason: reason, roadClass: roadClass)
        }
    }

    /// The kind of way, kept on the edge for instructions and, later, for
    /// anything that wants to prefer a path over a main road.
    public enum RoadClass: UInt8, Codable, Sendable, CaseIterable {
        case footway, path, pedestrian, steps, track, service, living, residential
        case unclassified, tertiary, secondary, primary, trunk, cycleway, other

        public init(highway: String) {
            switch highway {
            case "footway": self = .footway
            case "path", "bridleway": self = .path
            case "pedestrian": self = .pedestrian
            case "steps": self = .steps
            case "track": self = .track
            case "service": self = .service
            case "living_street": self = .living
            case "residential": self = .residential
            case "unclassified", "road": self = .unclassified
            case "tertiary", "tertiary_link": self = .tertiary
            case "secondary", "secondary_link": self = .secondary
            case "primary", "primary_link": self = .primary
            case "trunk", "trunk_link": self = .trunk
            case "cycleway": self = .cycleway
            default: self = .other
            }
        }

        /// Steps are walkable but not on wheels, and are worth naming in an
        /// instruction; nothing else here branches on the class today.
        public var isSteps: Bool { self == .steps }
    }

    // MARK: - Highway classification

    /// Ways a walker may use unless something says otherwise.
    static let walkableHighways: Set<String> = [
        "footway", "path", "pedestrian", "steps", "residential", "living_street",
        "service", "track", "unclassified", "tertiary", "tertiary_link",
        "secondary", "secondary_link", "primary", "primary_link", "road",
        "bridleway", "cycleway", "corridor",
    ]

    /// Ways a walker may not use whatever else the tagging claims. A
    /// `foot=yes` on a motorway is a tagging error, not an invitation.
    static let forbiddenHighways: Set<String> = [
        "motorway", "motorway_link", "trunk", "trunk_link", "construction",
        "proposed", "raceway", "bus_guideway", "escape", "platform", "rest_area",
        "services", "busway",
    ]

    static let noValues: Set<String> = ["no", "private", "restricted", "military", "delivery", "customers"]
    static let yesValues: Set<String> = ["yes", "designated", "official", "permissive", "destination", "public", "use_sidepath"]

    // MARK: - Decisions

    public func decide(way: OSMWay) -> Decision { decide(tags: way.tags) }

    public func decide(tags: [String: String]) -> Decision {
        guard let highway = tags["highway"] else { return .blocked("no-highway-tag") }
        let roadClass = RoadClass(highway: highway)

        // A foot=designated pavement mapped onto a trunk road is the road, not
        // a pavement: the pedestrian way beside it is a separate OSM way and is
        // the one Looper wants. Motorway-class infrastructure is refused first
        // and unconditionally.
        if PedestrianAccessPolicy.forbiddenHighways.contains(highway) {
            // The one exception OSM tagging genuinely uses: a trunk road in a
            // country that permits walking, tagged to say so explicitly.
            if (highway == "trunk" || highway == "trunk_link"), foot(tags) == .allowed {
                return oneway(tags: tags, roadClass: roadClass, reason: "trunk-foot-allowed")
            }
            return .blocked("forbidden-highway", roadClass)
        }

        // Under construction or merely proposed is not ground anyone can walk.
        if tags["construction"] != nil && highway == "construction" { return .blocked("construction", roadClass) }

        // An indoor corridor or a mapped building area is not a route through
        // a town, and letting the search wander through a shopping centre's
        // floor plan produces walks nobody can follow.
        if tags["indoor"] == "yes" { return .blocked("indoor", roadClass) }
        if tags["area"] == "yes" { return .blocked("area", roadClass) }

        // Explicit foot access has the last word in both directions.
        switch foot(tags) {
        case .denied: return .blocked("foot-no", roadClass)
        case .allowed: return oneway(tags: tags, roadClass: roadClass, reason: "foot-yes")
        case .unset: break
        }

        // General access, which applies to everyone including walkers unless
        // foot said otherwise above.
        if let access = tags["access"] {
            if PedestrianAccessPolicy.noValues.contains(access) { return .blocked("access-\(access)", roadClass) }
        }

        guard PedestrianAccessPolicy.walkableHighways.contains(highway) else {
            return .blocked("unknown-highway", roadClass)
        }

        // A cycleway with nothing said about feet is not assumed walkable:
        // in much of Europe it genuinely is not, and GraphHopper's foot
        // profile treats it the same way.
        if highway == "cycleway" && foot(tags) == .unset && tags["segregated"] == nil {
            return .blocked("cycleway-no-foot", roadClass)
        }

        return oneway(tags: tags, roadClass: roadClass, reason: "default")
    }

    enum Access { case allowed, denied, unset }

    func foot(_ tags: [String: String]) -> Access {
        guard let value = tags["foot"] else { return .unset }
        if PedestrianAccessPolicy.noValues.contains(value) { return .denied }
        if PedestrianAccessPolicy.yesValues.contains(value) { return .allowed }
        return .unset
    }

    /// One-way rules for a walker.
    ///
    /// A `oneway=yes` on a street is a rule for traffic, not for feet: walkers
    /// use both pavements. Only `oneway:foot` restricts a walker, and it is
    /// rare enough that getting it wrong in the permissive direction would
    /// mean routing people the wrong way up a one-way escalator or a
    /// turnstile, which is exactly where OSM does tag it.
    func oneway(tags: [String: String], roadClass: RoadClass, reason: String) -> Decision {
        var forward = true, backward = true
        if let value = tags["oneway:foot"] {
            switch value {
            case "yes", "true", "1": backward = false
            case "-1", "reverse": forward = false
            default: break
            }
        } else if roadClass == .steps, let conveying = tags["conveying"] {
            // A moving escalator only goes one way; a stopped one is stairs.
            switch conveying {
            case "forward": backward = false
            case "backward": forward = false
            default: break
            }
        }
        return Decision(isWalkable: forward || backward, forward: forward, backward: backward, reason: reason, roadClass: roadClass)
    }

    // MARK: - Nodes

    /// Whether a walker can pass through a node. A locked gate or a wall
    /// mapped as a point genuinely cuts a path in two, and treating it as
    /// passable produces routes that cannot be walked.
    public func canPass(node: OSMNode) -> Bool { canPass(nodeTags: node.tags) }

    public func canPass(nodeTags tags: [String: String]) -> Bool {
        switch foot(tags) {
        case .allowed: return true
        case .denied: return false
        case .unset: break
        }
        if let access = tags["access"], PedestrianAccessPolicy.noValues.contains(access) { return false }
        guard let barrier = tags["barrier"] else { return true }
        switch barrier {
        case "gate", "lift_gate", "swing_gate", "hampshire_gate":
            // A gate with nothing said about it is assumed openable; a locked
            // one says so.
            return tags["locked"] != "yes"
        case "wall", "fence", "hedge", "ditch", "guard_rail", "retaining_wall", "kerb", "yes":
            return false
        default:
            // Stiles, kissing gates, bollards, cattle grids, chicanes: all
            // things a walker steps over or round.
            return true
        }
    }
}
