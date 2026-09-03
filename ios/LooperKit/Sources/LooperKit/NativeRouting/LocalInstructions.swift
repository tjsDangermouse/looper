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

/// A bearing difference folded into ±180: negative to the left, positive to
/// the right.
func signedTurn(from: Double, to: Double) -> Double {
    var delta = to - from
    while delta > 180 { delta -= 360 }
    while delta < -180 { delta += 360 }
    return delta
}

/// The assembled walk as one polyline, with the index at which each leg begins.
///
/// Built exactly as `LocalLegRouter.line(of:)` builds the route's own geometry,
/// so an index into this is an index into the line the walk screen draws —
/// which is what a `Step`'s `startIndex` and `endIndex` promise. Shared rather
/// than rebuilt per caller because the guidance and the measurement must agree
/// about the shape of the walk, or they disagree about what happened on it.
public struct WalkOutline: Sendable {
    public let polyline: [Point]
    /// Where leg `i` begins in `polyline`.
    public let boundary: [Int]
    /// The last index in `polyline`.
    public let end: Int

    public init(legs: [WalkLeg]) {
        var line: [Point] = []
        var starts: [Int] = []
        for leg in legs {
            var placed = false
            for point in leg.coordinates {
                if line.last != point { line.append(point) }
                if !placed {
                    starts.append(Swift.max(0, line.count - 1))
                    placed = true
                }
            }
            if !placed { starts.append(Swift.max(0, line.count - 1)) }
        }
        polyline = line
        boundary = starts
        end = Swift.max(0, line.count - 1)
    }

    /// Where leg `i` ends: where the next one begins, or the end of the walk.
    public func legEnd(_ leg: Int) -> Int {
        leg + 1 < boundary.count ? boundary[leg + 1] : end
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
    public static let bearingWindowMetres: Double = 12

    /// The bearing of the walk on one side of `pivot`, measured over
    /// `windowMetres` of ground rather than over one survey vertex. Nil where
    /// there is no ground on that side at all.
    public func bearing(
        at pivot: Int, before: Bool, windowMetres: Double = bearingWindowMetres
    ) -> Double? {
        guard pivot >= 0, pivot < polyline.count else { return nil }
        var index = pivot
        var travelled = 0.0
        while before ? index > 0 : index < polyline.count - 1 {
            let next = before ? index - 1 : index + 1
            let a = polyline[index], b = polyline[next]
            travelled += LocalGeo.distance(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng)
            index = next
            if travelled >= windowMetres { break }
        }
        guard index != pivot else { return nil }
        let from = before ? polyline[index] : polyline[pivot]
        let to = before ? polyline[pivot] : polyline[index]
        return LocalGeo.bearing(lat1: from.lat, lon1: from.lng, lat2: to.lat, lon2: to.lng)
    }

    /// The straight line from one index to another — the direction a stretch
    /// *runs*, rather than the direction the walk holds around it.
    public func bearing(from: Int, to: Int) -> Double? {
        guard from >= 0, to >= 0, from < polyline.count, to < polyline.count else { return nil }
        let a = polyline[from], b = polyline[to]
        guard LocalGeo.distance(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng) > 0.5 else { return nil }
        return LocalGeo.bearing(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng)
    }

    /// Degrees from straight on at `pivot`: negative to the left, positive to
    /// the right.
    public func turn(at pivot: Int) -> Double {
        guard let incoming = bearing(at: pivot, before: true),
              let outgoing = bearing(at: pivot, before: false)
        else { return 0 }
        return signedTurn(from: incoming, to: outgoing)
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

    /// Below this a leg is too short to be a manoeuvre in its own right.
    ///
    /// Distinct from `microStepMetres` in `tidySteps`, and both are needed.
    /// That one folds a step away *after the fact*, on distance alone. This
    /// stops one being created, and only when the walk comes out of the leg
    /// pointing the way it went in — see `isKink`.
    static let kinkMetres: Double = 15

    /// A leg long enough to say where the walk is actually heading.
    static func isSubstantial(_ index: Int, legs: [WalkLeg]) -> Bool {
        guard index >= 0, index < legs.count else { return false }
        return !legs[index].isCrossing && legs[index].metres >= kinkMetres
    }

    /// The heading of the nearest substantial leg before `index`, and after it.
    ///
    /// A window on the polyline is no use around a junction, and this is the
    /// lesson the dog-leg taught: the twelve metres either side of a crossing
    /// can be *entirely* jut and crossing, so a window measures the very
    /// distortion it is being asked to see past. Two five-metre juts at sixty
    /// degrees were enough to swing a windowed heading by 22° and lose a
    /// straight crossing. Real ground, or nothing.
    static func headingBefore(_ index: Int, legs: [WalkLeg], outline: WalkOutline) -> Double? {
        var scan = index - 1
        while scan >= 0, !isSubstantial(scan, legs: legs) { scan -= 1 }
        guard scan >= 0 else { return nil }
        return outline.bearing(from: outline.boundary[scan], to: outline.legEnd(scan))
    }

    static func headingAfter(_ index: Int, legs: [WalkLeg], outline: WalkOutline) -> Double? {
        var scan = index + 1
        while scan < legs.count, !isSubstantial(scan, legs: legs) { scan += 1 }
        guard scan < legs.count else { return nil }
        return outline.bearing(from: outline.boundary[scan], to: outline.legEnd(scan))
    }

    /// Whether leg `index` is geometry rather than a manoeuvre.
    ///
    /// A pavement routinely juts sideways just before a junction to reach the
    /// dropped kerb, so the walk does not cross square: it jogs aside, crosses,
    /// and jogs back. Each jog is a corner, and each was being called out — a
    /// bare "Continue" and then, behind the crossing, a redundant "Continue
    /// onto the street you are already on".
    ///
    /// The test is deliberately two-sided: it asks where the walk is heading
    /// *before* the leg against where it heads *after* it, not how sharp the
    /// leg's own corners are. A jut leaves the walk going the way it was going,
    /// so it is absorbed; a genuine short turn onto a short street does not, so
    /// it survives. Distance alone would delete the second.
    static func isKink(_ index: Int, legs: [WalkLeg], outline: WalkOutline) -> Bool {
        guard index > 0, index < legs.count else { return false }
        let leg = legs[index]
        guard leg.metres < kinkMetres, !leg.isCrossing else { return false }
        guard let entering = headingBefore(index, legs: legs, outline: outline),
              let leaving = headingAfter(index, legs: legs, outline: outline)
        else { return false }
        return abs(signedTurn(from: entering, to: leaving)) < continueDegrees
    }

    public static func steps(for legs: [WalkLeg]) -> [Step] {
        guard !legs.isEmpty else { return [] }
        let outline = WalkOutline(legs: legs)
        let boundary = outline.boundary
        let endOfWalk = outline.end

        // Classified once, and by the same code that measures the finished
        // walk, so what is said and what is counted cannot drift apart.
        var runStartingAt: [Int: RouteQuality.CrossingRun] = [:]
        for run in RouteQuality.crossingRuns(in: legs, outline: outline) {
            runStartingAt[run.first] = run
        }

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

        /// The last leg that was not absorbed as geometry.
        ///
        /// A kink must never become the thing the next leg's road is compared
        /// against. It is unnamed, so `changedRoad` would be true and the very
        /// instruction the absorbing was meant to remove comes straight back —
        /// which is exactly how the dog-leg produced "Continue onto Main
        /// Street" while already on Main Street.
        var substantive = 0

        var index = 1
        while index < legs.count {
            // A crossing is one manoeuvre, however many edges the survey split
            // it into. A crossing way is cut *at* the carriageway it crosses,
            // because the node the two share is a junction, so a single
            // kerb-to-kerb crossing routinely arrives here as two legs.
            if let run = runStartingAt[index] {
                let after = run.last + 1
                guard after < legs.count else {
                    // The walk ends on the crossing, so there is no road on the
                    // far side to introduce and the ground belongs to the step
                    // already open.
                    pending.metres += run.metres
                    index = legs.count
                    break
                }
                // Look past a jut on the far side. The street the walker is
                // about to be on is the one beyond it, not the four metres of
                // unnamed dropped kerb they land on.
                var onward = after
                var carried = 0.0
                while onward < legs.count, isKink(onward, legs: legs, outline: outline) {
                    carried += legs[onward].metres
                    onward += 1
                }
                let arrivesOn = onward < legs.count ? legs[onward] : legs[after]
                // The crossing *is* the manoeuvre that begins the far side,
                // which is the app's own step convention: one instruction, and
                // it covers the crossing and the road it leads onto. Calling a
                // turn onto the crossing and another off it is what made a
                // crossing sound like two corners.
                steps.append(pending.step(endIndex: boundary[index]))
                pending = Pending(
                    maneuver: "cross",
                    instruction: crossingPhrase(run),
                    road: arrivesOn.name,
                    metres: run.metres + carried
                        + (onward < legs.count ? legs[onward].metres : 0),
                    startIndex: boundary[index]
                )
                substantive = Swift.min(onward, legs.count - 1)
                index = onward + 1
                continue
            }

            if isKink(index, legs: legs, outline: outline) {
                pending.metres += legs[index].metres
                index += 1
                continue
            }

            let leg = legs[index]
            let turn = outline.turn(at: boundary[index])
            let maneuver = maneuverName(for: turn)
            let changedRoad = leg.name != legs[substantive].name
            if maneuver == "continue" && !changedRoad {
                // The road bending round is not an instruction.
                pending.metres += leg.metres
                substantive = index
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
            substantive = index
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

    /// Crossing a side road on the way past it is a different event from
    /// crossing to the other side of the street being walked, and a walker acts
    /// on them differently. The first needs no decision at all — keep going —
    /// and saying so is worth more than naming the road.
    static func crossingPhrase(_ run: RouteQuality.CrossingRun) -> String {
        if run.kind == .junction && run.carriesStraightOn {
            return "Cross the junction and carry straight on"
        }
        return crossPhrase(road: run.crosses)
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
