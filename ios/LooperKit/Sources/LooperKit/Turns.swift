import Foundation

/// The turn a step ends on, as a shape the walk screen can draw. The two
/// routers disagree on how to say it — ORS numbers its instruction types, the
/// loop service names them — and a walk saved by an older build carries no
/// maneuver at all, so the wording is read as a last resort.
public enum Turn: String, Equatable, Sendable {
    case left
    case slightLeft = "slight-left"
    case sharpLeft = "sharp-left"
    case right
    case slightRight = "slight-right"
    case sharpRight = "sharp-right"
    case straight
    case uTurn = "u-turn"
    case arrive
}

private let orsTurns: [Int: Turn] = [
    0: .left, 1: .right, 2: .sharpLeft, 3: .sharpRight, 4: .slightLeft, 5: .slightRight,
    6: .straight, 7: .straight, 8: .straight, 9: .uTurn, 10: .arrive, 11: .straight,
    12: .slightLeft, 13: .slightRight,
]

private let namedTurns: [String: Turn] = [
    "turn-left": .left, "turn-right": .right, "keep-left": .slightLeft, "keep-right": .slightRight,
    "u-turn-left": .uTurn, "u-turn-right": .uTurn, "continue": .straight, "roundabout": .straight,
    "cross-road": .straight, "finish": .arrive, "waypoint": .arrive,
]

private func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

/// Sharp and slight are looked for before the bare side, so "slight left" does
/// not read as a square left turn.
private func turnFromWords(_ instruction: String) -> Turn {
    let text = instruction.lowercased()
    if matches(text, "u-?turn|turn around") { return .uTurn }
    if matches(text, "arrive|arrived|destination|back where you started") { return .arrive }
    for side in ["left", "right"] {
        if matches(text, "sharp\\s+\(side)") { return side == "left" ? .sharpLeft : .sharpRight }
        if matches(text, "(slight(ly)?|bear|keep)\\s+\(side)") { return side == "left" ? .slightLeft : .slightRight }
        if matches(text, "\\b\(side)\\b") { return side == "left" ? .left : .right }
    }
    return .straight
}

public func turnKind(_ step: Step?) -> Turn {
    guard let step else { return .arrive }
    if let maneuver = step.maneuver {
        switch maneuver {
        case .code(let code):
            return orsTurns[code] ?? .straight
        case .name(let name):
            if let named = namedTurns[name] { return named }
            if let known = Turn(rawValue: name) { return known }
        }
    }
    return turnFromWords(step.instruction)
}

public func mirrorTurn(_ turn: Turn) -> Turn {
    let raw = turn.rawValue
    if let range = raw.range(of: "left") {
        return Turn(rawValue: raw.replacingCharacters(in: range, with: "right")) ?? turn
    }
    if let range = raw.range(of: "right") {
        return Turn(rawValue: raw.replacingCharacters(in: range, with: "left")) ?? turn
    }
    return turn
}

private func replacingRegex(_ input: String, pattern: String, with template: String, caseInsensitive: Bool = false) -> String {
    var options: NSRegularExpression.Options = []
    if caseInsensitive { options.insert(.caseInsensitive) }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
    let range = NSRange(input.startIndex..., in: input)
    return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
}

/// Walking the loop the other way round. The same roads come in the opposite
/// order, so each reversed step walks the road its forward counterpart walked
/// and is introduced by the *next* forward turn, mirrored: a right off Main
/// Street onto Quay Road going out is a left off Quay Road onto Main Street
/// coming back. The walk sets off along the last road and ends where it began.
private func mirrorInstruction(_ instruction: String) -> String {
    let placeholder = "\u{0}"
    var result = replacingRegex(instruction, pattern: "\\bleft\\b", with: placeholder, caseInsensitive: true)
    result = replacingRegex(result, pattern: "\\bright\\b", with: "left", caseInsensitive: true)
    return result.replacingOccurrences(of: placeholder, with: "right")
}

private func onto(_ instruction: String, road: String?) -> String {
    let bare = replacingRegex(instruction, pattern: "\\s+onto\\s+.+$", with: "", caseInsensitive: true)
    guard let road else { return bare }
    return "\(bare) onto \(road)"
}

/// Routers occasionally clip a metre into a side road and straight back out. A
/// walker cannot act on that: it calls a turn onto the road already underfoot
/// and hides the turn that genuinely comes next. Steps too short to walk are
/// folded into the one before, as is any step that rejoins the road already
/// being walked — you cannot turn onto the road you are on. The ground covered
/// is kept, so the distances still add up to the length of the loop.
private let microStepMetres = 10.0

private func isRoadCrossing(_ step: Step) -> Bool {
    if case .name("cross-road")? = step.maneuver { return true }
    return false
}

public func tidySteps(_ steps: [Step]) -> [Step] {
    var out: [Step] = []
    for step in steps {
        if var last = out.last {
            let rejoins = last.road != nil && last.road == step.road
            if turnKind(step) != .arrive && !isRoadCrossing(step)
                && (step.distanceMeters < microStepMetres || rejoins) {
                last.distanceMeters += step.distanceMeters
                last.durationSeconds += step.durationSeconds
                last.endIndex = step.endIndex
                out[out.count - 1] = last
                continue
            }
        }
        out.append(step)
    }
    return out
}

/// Last check before a route becomes live guidance. An OSM junction can begin
/// with a tiny sideways kerb or crossing segment that looks like a turn in
/// isolation, even though the route carries straight on. Reassess every
/// proposed change against sustained geometry on both sides and fold false
/// turns into the stretch already being walked. This is deliberately applied
/// to a complete `Route`, so local, remote and restored routes get the same
/// answer on the phone, Watch and speech system.
public func reassessDirections(_ route: Route) -> Route {
    let coordinates = route.geometry.coordinates
    let crossings = Set(route.steps.indices.filter {
        isStraightRoadCrossing(route.steps, at: $0, coordinates: coordinates)
    })
    let crossingExits = Set(crossings.map { $0 + 1 })
    var steps: [Step] = []
    for (index, original) in route.steps.enumerated() {
        var step = original
        var wasFalseTurn = false
        if crossings.contains(index) {
            step.maneuver = .name("cross-road")
            step.instruction = "Cross the road and continue straight"
        } else if crossingExits.contains(index) {
            // Leaving the carriageway is the second half of the same crossing,
            // not another instruction. Keep its distance in the crossing step.
            wasFalseTurn = true
        } else if turnKind(step) != .straight, turnKind(step) != .arrive,
           let pivot = step.startIndex,
           let angle = sustainedDirectionAngle(coordinates, pivot: pivot),
           abs(angle) < 20 {
            step.maneuver = .name("continue")
            step.instruction = step.road.map { "Continue onto \($0)" } ?? "Continue"
            wasFalseTurn = true
        }
        if wasFalseTurn, var previous = steps.last {
            previous.distanceMeters += step.distanceMeters
            previous.durationSeconds += step.durationSeconds
            previous.endIndex = step.endIndex
            steps[steps.count - 1] = previous
        } else {
            steps.append(step)
        }
    }
    var checked = route
    checked.steps = tidySteps(steps)
    return checked
}

private let pedestrianRoadClasses: Set<String> = ["footway", "path", "pedestrian", "steps"]
private let crossingRoadClasses: Set<String> = [
    "living", "living_street", "residential", "unclassified", "road",
    "tertiary", "secondary", "primary", "trunk",
]
private let maximumCrossingMetres = 40.0

/// A crossing is a short carriageway between two pedestrian ways whose
/// approach and departure keep the same sustained heading. Service ways and
/// tracks are deliberately excluded so driveways and path-surface changes do
/// not generate safety messages.
private func isStraightRoadCrossing(_ steps: [Step], at index: Int, coordinates: [Point]) -> Bool {
    guard index > 0, index + 1 < steps.count else { return false }
    let previous = steps[index - 1], crossing = steps[index], next = steps[index + 1]
    guard let previousClass = previous.roadClass?.lowercased(),
          let crossingClass = crossing.roadClass?.lowercased(),
          let nextClass = next.roadClass?.lowercased(),
          pedestrianRoadClasses.contains(previousClass),
          crossingRoadClasses.contains(crossingClass),
          pedestrianRoadClasses.contains(nextClass),
          crossing.distanceMeters <= maximumCrossingMetres,
          let entry = crossing.startIndex,
          let exit = next.startIndex ?? crossing.endIndex,
          let angle = sustainedCrossingAngle(coordinates, entry: entry, exit: exit)
    else { return false }
    return abs(angle) < 20
}

private func sustainedCrossingAngle(_ coordinates: [Point], entry: Int, exit: Int) -> Double? {
    guard entry > 0, exit >= entry, exit < coordinates.count - 1 else { return nil }
    var before = entry, after = exit
    var travelled = 0.0
    while before > 0, travelled < directionCheckMetres {
        travelled += haversine(coordinates[before], coordinates[before - 1])
        before -= 1
    }
    travelled = 0
    while after < coordinates.count - 1, travelled < directionCheckMetres {
        travelled += haversine(coordinates[after], coordinates[after + 1])
        after += 1
    }
    guard before < entry, after > exit else { return nil }
    let incoming = LocalGeo.bearing(
        lat1: coordinates[before].lat, lon1: coordinates[before].lng,
        lat2: coordinates[entry].lat, lon2: coordinates[entry].lng
    )
    let outgoing = LocalGeo.bearing(
        lat1: coordinates[exit].lat, lon1: coordinates[exit].lng,
        lat2: coordinates[after].lat, lon2: coordinates[after].lng
    )
    var delta = outgoing - incoming
    while delta > 180 { delta -= 360 }
    while delta < -180 { delta += 360 }
    return delta
}

private let directionCheckMetres = 12.0

/// Degrees from straight ahead after looking far enough past tiny surveyed
/// segments to see the direction the walker will actually maintain.
private func sustainedDirectionAngle(_ coordinates: [Point], pivot: Int) -> Double? {
    guard pivot > 0, pivot < coordinates.count - 1 else { return nil }
    var before = pivot, after = pivot
    var travelled = 0.0
    while before > 0, travelled < directionCheckMetres {
        travelled += haversine(coordinates[before], coordinates[before - 1])
        before -= 1
    }
    travelled = 0
    while after < coordinates.count - 1, travelled < directionCheckMetres {
        travelled += haversine(coordinates[after], coordinates[after + 1])
        after += 1
    }
    guard before < pivot, after > pivot else { return nil }
    let point = coordinates[pivot]
    let incoming = LocalGeo.bearing(
        lat1: coordinates[before].lat, lon1: coordinates[before].lng,
        lat2: point.lat, lon2: point.lng
    )
    let outgoing = LocalGeo.bearing(
        lat1: point.lat, lon1: point.lng,
        lat2: coordinates[after].lat, lon2: coordinates[after].lng
    )
    var delta = outgoing - incoming
    while delta > 180 { delta -= 360 }
    while delta < -180 { delta += 360 }
    return delta
}

public func reverseRoute(_ route: Route) -> Route {
    // Zero-length steps — arriving, and the odd roundabout marker — name no road
    // to walk, so the roads of the walk are the steps that cover ground.
    let walked = route.steps.filter { $0.distanceMeters > 0 }
    let lastCoordinateIndex = route.geometry.coordinates.count - 1
    func facingBack(_ original: Step) -> Step {
        var reversed = original
        if let start = original.startIndex, let end = original.endIndex, lastCoordinateIndex >= 0 {
            reversed.startIndex = lastCoordinateIndex - end
            reversed.endIndex = lastCoordinateIndex - start
        }
        return reversed
    }
    var steps: [Step] = []
    for j in 0..<walked.count {
        let road = facingBack(walked[walked.count - 1 - j])
        let joinsIndex = walked.count - j
        if joinsIndex >= walked.count {
            var setOff = road
            setOff.maneuver = .name("straight")
            setOff.instruction = road.road.map { "Head along \($0)" } ?? "Set off along the loop"
            steps.append(setOff)
        } else {
            let joins = walked[joinsIndex]
            var turned = road
            turned.maneuver = .name(mirrorTurn(turnKind(joins)).rawValue)
            turned.instruction = onto(mirrorInstruction(joins.instruction), road: road.road)
            steps.append(turned)
        }
    }
    steps.append(Step(instruction: "Arrive at your starting point", distanceMeters: 0, durationSeconds: 0, maneuver: .name("arrive")))
    var result = route
    result.reversed = !(route.reversed ?? false)
    result.steps = tidySteps(steps)
    result.geometry = LineGeometry(coordinates: route.geometry.coordinates.reversed())
    return result
}
