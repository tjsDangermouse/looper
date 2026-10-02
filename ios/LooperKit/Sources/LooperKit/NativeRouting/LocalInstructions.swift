import Foundation

/// One stretch of the assembled walk: the ground covered by a single graph
/// edge, in the direction it was walked.
public struct WalkLeg: Sendable, Equatable {
    public var coordinates: [Point]
    public var metres: Double
    public var name: String?
    public var roadClass: PedestrianAccessPolicy.RoadClass
    /// True for an OSM way explicitly mapped as a pedestrian road crossing.
    public var isCrossing: Bool
    /// The base-graph edge this leg ran along, so retracing can be asked of the
    /// network. `-1` where the caller does not track it.
    public var physical: Int32
    /// Inputs to the search cost, retained so an offered route can explain why
    /// this edge beat the pavement beside it.
    public var baseWeight: Double
    public var avoidancePenalty: Double

    public init(
        coordinates: [Point], metres: Double, name: String?,
        roadClass: PedestrianAccessPolicy.RoadClass, physical: Int32 = -1,
        baseWeight: Double = 1, avoidancePenalty: Double = 1,
        isCrossing: Bool = false
    ) {
        self.coordinates = coordinates
        self.metres = metres
        self.name = name
        self.roadClass = roadClass
        self.isCrossing = isCrossing
        self.physical = physical
        self.baseWeight = baseWeight
        self.avoidancePenalty = avoidancePenalty
    }
}

/// Turning a sequence of edges into something a walker can follow.
///
/// Uses the chosen route and its surrounding graph while they are both in
/// memory. The graph supplies road context and real route choices; the route
/// supplies the movement the walker will make. Crossing speech requires an
/// explicit change to the opposite pavement of the same mapped street.
///
/// The step convention is the app's existing one, which the walk screen and
/// the Watch both depend on: a step's instruction is the manoeuvre at its
/// *start*, and the step carries the name of the road it then walks.
public enum LocalInstructions {
    /// The 5 km/h the fixed estimate assumed — 12 min/km. Kept as the default
    /// wherever a pace is not threaded through yet.
    public static let walkingMetresPerSecond = 5000.0 / 3600.0

    /// Metres per second for a walker's own pace. `walkingPaceMinutesPerKm` in
    /// the reference's `durationFor`; the quoted duration is
    /// `distanceKm * paceMinutesPerKm * 60`.
    public static func metresPerSecond(paceMinutesPerKm: Double) -> Double {
        paceMinutesPerKm > 0 ? 1000 / (paceMinutesPerKm * 60) : walkingMetresPerSecond
    }

    /// Below this a junction is the road bending, not a turn to call out.
    static let continueDegrees: Double = 20
    static let slightDegrees: Double = 45
    static let turnDegrees: Double = 120
    static let sharpDegrees: Double = 160

    public static func steps(
        for legs: [WalkLeg], paceMinutesPerKm: Double = 12,
        graph: LocalWalkingGraph? = nil, index: LocalEdgeIndex? = nil
    ) -> [Step] {
        let mps = metresPerSecond(paceMinutesPerKm: paceMinutesPerKm)
        guard !legs.isEmpty else { return [] }
        let legs = coalescingCrossingRuns(legs)
        let roadContext: LocalRoadContext.Resolved
        if let graph, let index {
            roadContext = LocalRoadContext.resolve(legs: legs, graph: graph, index: index)
        } else {
            roadContext = .init(names: legs.map(\.name), oppositePavementCrossings: [])
        }
        let roadNames = roadContext.names
        var steps: [Step] = []
        var coordinateIndex = 0

        struct Pending {
            var maneuver: String
            var instruction: String
            var road: String?
            var roadClass: PedestrianAccessPolicy.RoadClass
            var metres: Double
            var startIndex: Int
        }

        var pending = Pending(
            maneuver: "continue",
            instruction: setOff(along: roadNames[0]),
            road: roadNames[0],
            roadClass: legs[0].roadClass,
            metres: legs[0].metres,
            startIndex: 0
        )
        coordinateIndex += Swift.max(0, legs[0].coordinates.count - 1)

        for index in 1..<legs.count {
            let previous = legs[index - 1], leg = legs[index]
            let turn = leg.isCrossing
                ? broadTurnAngle(arriving: previous.coordinates, leaving: leg.coordinates)
                : turnAngle(arriving: previous.coordinates, leaving: leg.coordinates)
            // A mapped crossing describes the ground, not an action the walker
            // must take. Directional guidance still comes from the geometry.
            var maneuver = roadContext.oppositePavementCrossings.contains(index)
                ? "cross-opposite-pavement" : maneuverName(for: turn)
            if previous.isCrossing, let before = legs.indices.prefix(index).reversed().first(where: { !legs[$0].isCrossing }),
               roadNames[before] != nil, roadNames[before] == roadNames[index],
               maneuver != "cross-opposite-pavement" {
                // The same street corridor continues beyond the crossing.
                // Its kerb geometry is not a fresh decision at a junction.
                maneuver = "continue"
            }
            let changedRoad = roadNames[index] != roadNames[index - 1]
            let changedWalkingSurface = leg.roadClass.isPedestrianWay != previous.roadClass.isPedestrianWay
            if leg.isCrossing, maneuver == "continue" {
                // The crossing way's missing name is not a road change. Keep
                // straight crossing ground in the current instruction; the
                // named road joined at the far side gets its own instruction.
                pending.metres += leg.metres
                coordinateIndex += Swift.max(0, leg.coordinates.count - 1)
                continue
            }
            if let graph, LocalRoadContext.hasAlternative(at: (previous, leg), graph: graph) == false,
               !changedRoad, !changedWalkingSurface, maneuver != "cross-opposite-pavement" {
                // A degree-two bend needs no direction. A change of street
                // still needs an announcement, even when this is the only
                // walkable path through a larger road junction.
                maneuver = "continue"
                pending.metres += leg.metres
                pending.roadClass = leg.roadClass
                coordinateIndex += Swift.max(0, leg.coordinates.count - 1)
                continue
            }
            if maneuver == "continue" && !changedRoad && !changedWalkingSurface {
                // The road bending round is not an instruction.
                pending.metres += leg.metres
                coordinateIndex += Swift.max(0, leg.coordinates.count - 1)
                continue
            }
            steps.append(Step(
                instruction: pending.instruction,
                distanceMeters: pending.metres.rounded(),
                durationSeconds: (pending.metres / mps).rounded(),
                startIndex: pending.startIndex,
                endIndex: coordinateIndex,
                maneuver: .name(pending.maneuver),
                road: pending.road,
                roadClass: String(describing: pending.roadClass)
            ))
            pending = Pending(
                maneuver: maneuver,
                instruction: maneuver == "cross-opposite-pavement"
                    ? "Cross to the opposite pavement"
                    : phrase(maneuver: maneuver, road: roadNames[index], roadClass: leg.roadClass),
                road: roadNames[index],
                roadClass: leg.roadClass,
                metres: leg.metres,
                startIndex: coordinateIndex
            )
            coordinateIndex += Swift.max(0, leg.coordinates.count - 1)
        }

        steps.append(Step(
            instruction: pending.instruction,
            distanceMeters: pending.metres.rounded(),
            durationSeconds: (pending.metres / mps).rounded(),
            startIndex: pending.startIndex,
            endIndex: coordinateIndex,
            maneuver: .name(pending.maneuver),
            road: pending.road,
            roadClass: String(describing: pending.roadClass)
        ))
        steps.append(Step(
            instruction: "You’re back where you started",
            distanceMeters: 0,
            durationSeconds: 0,
            startIndex: coordinateIndex,
            endIndex: coordinateIndex,
            maneuver: .name("finish"),
            road: nil
        ))
        return steps
    }

    /// Degrees from straight on: negative to the left, positive to the right.
    static func turnAngle(arriving: [Point], leaving: [Point]) -> Double {
        guard arriving.count >= 2, leaving.count >= 2 else { return 0 }
        let a = arriving[arriving.count - 2], b = arriving[arriving.count - 1]
        let c = leaving[0], d = leaving[1]
        let incoming = LocalGeo.bearing(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng)
        let outgoing = LocalGeo.bearing(lat1: c.lat, lon1: c.lng, lat2: d.lat, lon2: d.lng)
        var delta = outgoing - incoming
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    /// Crossing ways are often split at kerb and refuge nodes. Judge the run
    /// as one piece of ground so those surveyed vertices cannot invent turns.
    private static func coalescingCrossingRuns(_ legs: [WalkLeg]) -> [WalkLeg] {
        var result: [WalkLeg] = []
        for leg in legs {
            if leg.isCrossing, var previous = result.last, previous.isCrossing,
               previous.name == leg.name, previous.roadClass == leg.roadClass {
                previous.coordinates.append(contentsOf: leg.coordinates.dropFirst())
                previous.metres += leg.metres
                result[result.count - 1] = previous
            } else {
                result.append(leg)
            }
        }
        return result
    }

    private static func broadTurnAngle(arriving: [Point], leaving: [Point]) -> Double {
        guard let a = arriving.first, let b = arriving.last,
              let c = leaving.first, let d = leaving.last,
              arriving.count >= 2, leaving.count >= 2 else { return 0 }
        let incoming = LocalGeo.bearing(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng)
        let outgoing = LocalGeo.bearing(lat1: c.lat, lon1: c.lng, lat2: d.lat, lon2: d.lng)
        var delta = outgoing - incoming
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    static func maneuverName(for angle: Double) -> String {
        let magnitude = abs(angle)
        let left = angle < 0
        if magnitude < continueDegrees { return "continue" }
        if magnitude < slightDegrees { return left ? "keep-left" : "keep-right" }
        if magnitude < turnDegrees { return left ? "turn-left" : "turn-right" }
        if magnitude < sharpDegrees { return left ? "sharp-left" : "sharp-right" }
        return left ? "u-turn-left" : "u-turn-right"
    }

    static func setOff(along road: String?) -> String {
        guard let road else { return "Set off" }
        return "Set off along \(road)"
    }

    static func phrase(maneuver: String, road: String?, roadClass: PedestrianAccessPolicy.RoadClass) -> String {
        let verb: String
        switch maneuver {
        case "continue": verb = "Continue"
        case "keep-left": verb = "Bear left"
        case "keep-right": verb = "Bear right"
        case "turn-left": verb = "Turn left"
        case "turn-right": verb = "Turn right"
        case "sharp-left": verb = "Sharp left"
        case "sharp-right": verb = "Sharp right"
        default: verb = "Turn around"
        }
        // Steps are worth naming: a walker looking for a turning wants to know
        // they are about to be looking for stairs instead.
        let destination = road ?? (roadClass.isSteps ? "the steps" : nil)
        guard let destination else { return verb }
        return "\(verb) onto \(destination)"
    }
}
