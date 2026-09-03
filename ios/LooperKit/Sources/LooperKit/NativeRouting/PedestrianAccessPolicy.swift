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
        /// What a metre of this way costs a search, against a metre of the
        /// ground the walker would rather be on. Always at least 1, and 1 for
        /// a dedicated pedestrian way. See `weight(tags:roadClass:)`.
        public var weight: Double = 1

        public static func blocked(_ reason: String, _ roadClass: RoadClass = .other) -> Decision {
            Decision(isWalkable: false, forward: false, backward: false, reason: reason, roadClass: roadClass)
        }
    }

    /// The kind of way, kept on the edge for instructions and, later, for
    /// anything that wants to prefer a path over a main road.
    public enum RoadClass: UInt8, Codable, Sendable, CaseIterable {
        case footway, path, pedestrian, steps, track, service, living, residential
        case unclassified, tertiary, secondary, primary, trunk, cycleway, other
        /// Appended rather than slotted in beside `path`, because the raw value
        /// is what the graph stores on an edge.
        case bridleway

        public init(highway: String) {
            switch highway {
            case "footway": self = .footway
            case "path": self = .path
            case "bridleway": self = .bridleway
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
        /// instruction.
        public var isSteps: Bool { self == .steps }

        /// Somewhere a walker is meant to be, rather than a carriageway they
        /// are tolerated on. GraphHopper's FOOTWAY / PATH / PEDESTRIAN / STEPS,
        /// and the distinction `looper_foot.json`'s tie-break is drawn on.
        public var isPedestrianWay: Bool {
            self == .footway || self == .path || self == .pedestrian || self == .steps
        }
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
    /// Refusals that are really prices.
    ///
    /// GraphHopper does not refuse a walker a private way — `looper_foot.json`
    /// gives it a priority of 0.1, which is ten times the cost and not a wall.
    /// Refusing it here instead cost about a tenth of the graph and, with it,
    /// agreement with the golden oracle: a private drive is very often the only
    /// link between two streets, and deleting it cuts the network rather than
    /// avoiding the drive.
    static let pricedValues: Set<String> = ["private"]

    // MARK: - Weighting

    /// GraphHopper's `sac_scale`, as `hike_rating`. Anything at
    /// mountain-hiking or above is not a walk this app should offer.
    static let hikeRatings: [String: Int] = [
        "hiking": 1, "mountain_hiking": 2, "demanding_mountain_hiking": 3,
        "alpine_hiking": 4, "demanding_alpine_hiking": 5, "difficult_alpine_hiking": 6,
    ]

    /// What a metre of this way costs, against a metre of the ground a walker
    /// would rather be on.
    ///
    /// A port of the `priority` block of `route-service/graphhopper/looper_foot.json`,
    /// which is the profile the remote engine has always routed Looper's legs
    /// under. Priority *divides* weight there, so a priority of `p` is a cost
    /// multiplier of `1/p` here, and the rules multiply together exactly as
    /// GraphHopper multiplies them.
    ///
    /// The one that matters is the last. Where OSM maps a pavement as its own
    /// way, a pavement and its carriageway are near enough the same length that
    /// a router with no preference between them takes whichever is a few metres
    /// shorter, block by block, and the walk crosses and recrosses the road —
    /// confusing to follow, and a spoken turn every time. Measured on device
    /// before this existed: 41% of the offered walk on pavement at 4.3 crossings
    /// per kilometre, against the 97% the remote engine gets at Douglas.
    ///
    /// The 0.8 is not a guess and should not be retuned without reading the
    /// header of `looper_foot.json`, which records the sweep behind it: a
    /// *weaker* nudge is worse than none, because at 0.9 the route takes the
    /// pavement for some stretches and not others and alternates more than
    /// leaving it alone; and a stronger one is much worse, because priority
    /// divides, so 0.1 does not say "prefer a pavement", it says a pavement is
    /// worth walking ten times as far for. 0.8 is the knee.
    func weight(tags: [String: String], roadClass: RoadClass) -> Double {
        var priority = 1.0
        if let scale = tags["mtb:scale"], mtbRating(scale) > 3 { priority *= 0.7 }
        if isPriced(tags) { priority *= 0.1 }
        if !roadClass.isPedestrianWay { priority *= 0.8 }
        return 1 / priority
    }

    /// Whether this way is a walker crossing a carriageway, rather than a way
    /// running along one.
    ///
    /// Deliberately *not* a `RoadClass` case. A crossing genuinely is a footway
    /// as far as access and weighting are concerned — it is somewhere a walker
    /// is meant to be — and folding it into the class enum would silently move
    /// `isPedestrianWay` and `RouteQuality.pedestrianRoadClasses`, changing what
    /// the `pave=NN%` telemetry has been counting all along. Two orthogonal
    /// facts about an edge, kept as two fields.
    ///
    /// `footway=crossing` is the common tagging. `highway=crossing` is normally
    /// a node, but is occasionally used on a way. A bare `crossing=*` on a
    /// pedestrian way says the same thing in older data, so it is read too —
    /// but only on a pedestrian way, because `crossing=no` on a carriageway
    /// means "no crossing here", which is the opposite claim.
    public func isCrossing(tags: [String: String]) -> Bool {
        if tags["footway"] == "crossing" { return true }
        if tags["highway"] == "crossing" { return true }
        guard let highway = tags["highway"] else { return false }
        guard RoadClass(highway: highway).isPedestrianWay else { return false }
        guard let crossing = tags["crossing"] else { return false }
        return crossing != "no"
    }

    /// Whether the way is one GraphHopper would price rather than refuse.
    func isPriced(_ tags: [String: String]) -> Bool {
        if let foot = tags["foot"] { return PedestrianAccessPolicy.pricedValues.contains(foot) }
        if let access = tags["access"] { return PedestrianAccessPolicy.pricedValues.contains(access) }
        return false
    }

    /// `mtb:scale` is an integer, sometimes with a `+` or `-` suffix.
    func mtbRating(_ value: String) -> Int {
        Int(value.prefix { $0.isNumber }) ?? 0
    }
    static let yesValues: Set<String> = ["yes", "designated", "official", "permissive", "destination", "public", "use_sidepath"]

    // MARK: - Decisions

    public func decide(way: OSMWay) -> Decision { decide(tags: way.tags) }

    public func decide(tags: [String: String]) -> Decision {
        guard let highway = tags["highway"] else { return .blocked("no-highway-tag") }
        let roadClass = RoadClass(highway: highway)
        let cost = weight(tags: tags, roadClass: roadClass)

        // Terrain a walking app has no business offering. `hike_rating >= 2` is
        // mountain hiking and above, which `looper_foot.json` refuses outright
        // rather than prices.
        if let scale = tags["sac_scale"], (PedestrianAccessPolicy.hikeRatings[scale] ?? 0) >= 2 {
            return .blocked("sac-\(scale)", roadClass)
        }

        // A foot=designated pavement mapped onto a trunk road is the road, not
        // a pavement: the pedestrian way beside it is a separate OSM way and is
        // the one Looper wants. Motorway-class infrastructure is refused first
        // and unconditionally.
        if PedestrianAccessPolicy.forbiddenHighways.contains(highway) {
            // The one exception OSM tagging genuinely uses: a trunk road in a
            // country that permits walking, tagged to say so explicitly.
            if (highway == "trunk" || highway == "trunk_link"), foot(tags) == .allowed {
                return oneway(tags: tags, roadClass: roadClass, reason: "trunk-foot-allowed", weight: cost)
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

        // Explicit foot access has the last word in both directions — except
        // where the answer is "private", which is a price and not a refusal.
        // See `pricedValues`.
        switch foot(tags) {
        case .denied:
            if !isPriced(tags) { return .blocked("foot-no", roadClass) }
        case .allowed: return oneway(tags: tags, roadClass: roadClass, reason: "foot-yes", weight: cost)
        case .unset: break
        }

        // General access, which applies to everyone including walkers unless
        // foot said otherwise above.
        if let access = tags["access"], PedestrianAccessPolicy.noValues.contains(access) {
            if !PedestrianAccessPolicy.pricedValues.contains(access) {
                return .blocked("access-\(access)", roadClass)
            }
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

        return oneway(tags: tags, roadClass: roadClass, reason: "default", weight: cost)
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
    func oneway(tags: [String: String], roadClass: RoadClass, reason: String, weight: Double = 1) -> Decision {
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
        return Decision(
            isWalkable: forward || backward, forward: forward, backward: backward,
            reason: reason, roadClass: roadClass, weight: weight
        )
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
