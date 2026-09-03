import Foundation

/// One stretch of the assembled walk: the ground covered by a single graph
/// edge, in the direction it was walked.
public struct WalkLeg: Sendable {
    public var coordinates: [Point]
    public var metres: Double
    public var name: String?
    public var roadClass: PedestrianAccessPolicy.RoadClass
    /// The base-graph edge this leg ran along, so retracing can be asked of the
    /// network. `-1` where the caller does not track it.
    public var physical: Int32
    /// Whether this stretch is a walker crossing a carriageway rather than
    /// walking along one. See `PedestrianAccessPolicy.isCrossing(tags:)`.
    public var isCrossing: Bool
    /// The carriageway a crossing crosses, where the graph could name one.
    public var crosses: String?

    public init(
        coordinates: [Point], metres: Double, name: String?,
        roadClass: PedestrianAccessPolicy.RoadClass, physical: Int32 = -1,
        isCrossing: Bool = false, crosses: String? = nil
    ) {
        self.coordinates = coordinates
        self.metres = metres
        self.name = name
        self.roadClass = roadClass
        self.physical = physical
        self.isCrossing = isCrossing
        self.crosses = crosses
    }
}

/// Turning a sequence of edges into something a walker can follow.
///
/// Deliberately modest. Field testing decides what guidance actually needs to
/// say, and instructions elaborated before anybody has walked behind them tend
/// to be elaborate in the wrong places. So this covers the manoeuvres the app
/// already draws and speaks — continue, the three grades of left and right,
/// turn around, arrive — and nothing more.
///
/// The step convention is the app's existing one, which the walk screen and
/// the Watch both depend on: a step's instruction is the manoeuvre at its
/// *start*, and the step carries the name of the road it then walks.
public enum LocalInstructions {
    /// GraphHopper's foot profile speed, so a locally-found walk and a
    /// remotely-found one of the same length quote the same duration.
    public static let walkingMetresPerSecond = 5000.0 / 3600.0

    /// Below this a junction is the road bending, not a turn to call out.
    static let continueDegrees: Double = 20
    static let slightDegrees: Double = 45
    static let turnDegrees: Double = 120
    static let sharpDegrees: Double = 160

    public static func steps(for legs: [WalkLeg]) -> [Step] {
        guard !legs.isEmpty else { return [] }

        // The assembled walk, built exactly as `LocalLegRouter.line(of:)` builds
        // the route's own geometry, so a step's `startIndex` and `endIndex`
        // address the very array the walk screen draws. `boundary[i]` is where
        // leg `i` begins in it.
        var polyline: [Point] = []
        var boundary: [Int] = []
        for leg in legs {
            var placed = false
            for point in leg.coordinates {
                if polyline.last != point { polyline.append(point) }
                if !placed {
                    boundary.append(Swift.max(0, polyline.count - 1))
                    placed = true
                }
            }
            if !placed { boundary.append(Swift.max(0, polyline.count - 1)) }
        }
        let endOfWalk = Swift.max(0, polyline.count - 1)

        struct Pending {
            var maneuver: String
            var instruction: String
            var road: String?
            var metres: Double
            var startIndex: Int

            func step(endIndex: Int) -> Step {
                Step(
                    instruction: instruction,
                    distanceMeters: metres.rounded(),
                    durationSeconds: (metres / LocalInstructions.walkingMetresPerSecond).rounded(),
                    startIndex: startIndex,
                    endIndex: endIndex,
                    maneuver: .name(maneuver),
                    road: road
                )
            }
        }

        var steps: [Step] = []
        var pending = Pending(
            maneuver: "continue",
            instruction: setOff(along: legs[0].name),
            road: legs[0].name,
            metres: legs[0].metres,
            startIndex: 0
        )

        var index = 1
        while index < legs.count {
            // A crossing is one manoeuvre, however many edges the survey split
            // it into. A crossing way is cut *at* the carriageway it crosses,
            // because the node the two share is a junction, so a single
            // kerb-to-kerb crossing routinely arrives here as two legs.
            if legs[index].isCrossing {
                var runEnd = index
                var runMetres = 0.0
                var crossed: String?
                while runEnd < legs.count, legs[runEnd].isCrossing {
                    runMetres += legs[runEnd].metres
                    if crossed == nil { crossed = legs[runEnd].crosses }
                    runEnd += 1
                }
                guard runEnd < legs.count else {
                    // The walk ends on the crossing, so there is no road on the
                    // far side to introduce and the ground belongs to the step
                    // already open.
                    pending.metres += runMetres
                    index = runEnd
                    break
                }
                // The crossing *is* the manoeuvre that begins the far side,
                // which is the app's own step convention: one instruction, and
                // it covers the crossing and the road it leads onto. Calling a
                // turn onto the crossing and another off it is what made a
                // crossing sound like two corners.
                let onward = legs[runEnd]
                steps.append(pending.step(endIndex: boundary[index]))
                pending = Pending(
                    maneuver: "cross",
                    instruction: crossPhrase(road: crossed),
                    road: onward.name,
                    metres: runMetres + onward.metres,
                    startIndex: boundary[index]
                )
                index = runEnd + 1
                continue
            }

            let previous = legs[index - 1], leg = legs[index]
            let turn = turnAngle(polyline, at: boundary[index])
            let maneuver = maneuverName(for: turn)
            let changedRoad = leg.name != previous.name
            if maneuver == "continue" && !changedRoad {
                // The road bending round is not an instruction.
                pending.metres += leg.metres
                index += 1
                continue
            }
            steps.append(pending.step(endIndex: boundary[index]))
            pending = Pending(
                maneuver: maneuver,
                instruction: phrase(maneuver: maneuver, road: leg.name, roadClass: leg.roadClass),
                road: leg.name,
                metres: leg.metres,
                startIndex: boundary[index]
            )
            index += 1
        }

        steps.append(pending.step(endIndex: endOfWalk))
        steps.append(Step(
            instruction: "You’re back where you started",
            distanceMeters: 0,
            durationSeconds: 0,
            startIndex: endOfWalk,
            endIndex: endOfWalk,
            maneuver: .name("finish"),
            road: nil
        ))
        return steps
    }

    /// How much geometry a manoeuvre is judged over, either side of the
    /// junction.
    ///
    /// One coordinate pair is not enough, and crossings are why. A crossing
    /// leaves the pavement at right angles, so its first two coordinates read
    /// as a square turn however straight the walk through them actually is —
    /// which is how "cross the road" came out as "turn right" and then "turn
    /// left". Twelve metres is far enough to see past the kerb and short
    /// enough not to smooth away a corner that is really there.
    static let bearingWindowMetres: Double = 12

    /// The bearing of the walk on one side of `pivot`, measured over
    /// `bearingWindowMetres` of ground rather than over one survey vertex.
    /// Nil where there is no ground on that side at all.
    static func windowBearing(_ coordinates: [Point], at pivot: Int, before: Bool) -> Double? {
        guard pivot >= 0, pivot < coordinates.count else { return nil }
        var index = pivot
        var travelled = 0.0
        while before ? index > 0 : index < coordinates.count - 1 {
            let next = before ? index - 1 : index + 1
            let a = coordinates[index], b = coordinates[next]
            travelled += LocalGeo.distance(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng)
            index = next
            if travelled >= bearingWindowMetres { break }
        }
        guard index != pivot else { return nil }
        let from = before ? coordinates[index] : coordinates[pivot]
        let to = before ? coordinates[pivot] : coordinates[index]
        return LocalGeo.bearing(lat1: from.lat, lon1: from.lng, lat2: to.lat, lon2: to.lng)
    }

    /// Degrees from straight on at a junction: negative to the left, positive
    /// to the right.
    static func turnAngle(_ coordinates: [Point], at pivot: Int) -> Double {
        guard let incoming = windowBearing(coordinates, at: pivot, before: true),
              let outgoing = windowBearing(coordinates, at: pivot, before: false)
        else { return 0 }
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

    /// Naming the road being crossed is the whole point: "Turn right" at a
    /// crossing tells a walker to look for a turning that is not there.
    static func crossPhrase(road: String?) -> String {
        guard let road else { return "Cross the road" }
        return "Cross \(road)"
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
