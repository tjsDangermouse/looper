import Foundation

/// One stretch of the assembled walk: the ground covered by a single graph
/// edge, in the direction it was walked.
public struct WalkLeg {
    public var coordinates: [Point]
    public var metres: Double
    public var name: String?
    public var roadClass: PedestrianAccessPolicy.RoadClass

    public init(coordinates: [Point], metres: Double, name: String?, roadClass: PedestrianAccessPolicy.RoadClass) {
        self.coordinates = coordinates
        self.metres = metres
        self.name = name
        self.roadClass = roadClass
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
        var steps: [Step] = []
        var coordinateIndex = 0

        struct Pending {
            var maneuver: String
            var instruction: String
            var road: String?
            var metres: Double
            var startIndex: Int
        }

        var pending = Pending(
            maneuver: "continue",
            instruction: setOff(along: legs[0].name),
            road: legs[0].name,
            metres: legs[0].metres,
            startIndex: 0
        )
        coordinateIndex += Swift.max(0, legs[0].coordinates.count - 1)

        for index in 1..<legs.count {
            let previous = legs[index - 1], leg = legs[index]
            let turn = turnAngle(arriving: previous.coordinates, leaving: leg.coordinates)
            let maneuver = maneuverName(for: turn)
            let changedRoad = leg.name != previous.name
            if maneuver == "continue" && !changedRoad {
                // The road bending round is not an instruction.
                pending.metres += leg.metres
                coordinateIndex += Swift.max(0, leg.coordinates.count - 1)
                continue
            }
            steps.append(Step(
                instruction: pending.instruction,
                distanceMeters: pending.metres.rounded(),
                durationSeconds: (pending.metres / walkingMetresPerSecond).rounded(),
                startIndex: pending.startIndex,
                endIndex: coordinateIndex,
                maneuver: .name(pending.maneuver),
                road: pending.road
            ))
            pending = Pending(
                maneuver: maneuver,
                instruction: phrase(maneuver: maneuver, road: leg.name, roadClass: leg.roadClass),
                road: leg.name,
                metres: leg.metres,
                startIndex: coordinateIndex
            )
            coordinateIndex += Swift.max(0, leg.coordinates.count - 1)
        }

        steps.append(Step(
            instruction: pending.instruction,
            distanceMeters: pending.metres.rounded(),
            durationSeconds: (pending.metres / walkingMetresPerSecond).rounded(),
            startIndex: pending.startIndex,
            endIndex: coordinateIndex,
            maneuver: .name(pending.maneuver),
            road: pending.road
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
