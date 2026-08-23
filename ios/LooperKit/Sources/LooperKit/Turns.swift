import Foundation

/// The turn a step ends on, as a shape the walk screen can draw. The two
/// routers disagree on how to say it — ORS numbers its instruction types, the
/// loop service names them — and a walk saved by an older build carries no
/// maneuver at all, so the wording is read as a last resort.
public enum Turn: String, Equatable {
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
    "finish": .arrive, "waypoint": .arrive,
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

public func tidySteps(_ steps: [Step]) -> [Step] {
    var out: [Step] = []
    for step in steps {
        if var last = out.last {
            let rejoins = last.road != nil && last.road == step.road
            if turnKind(step) != .arrive && (step.distanceMeters < microStepMetres || rejoins) {
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

public func reverseRoute(_ route: Route) -> Route {
    // Zero-length steps — arriving, and the odd roundabout marker — name no road
    // to walk, so the roads of the walk are the steps that cover ground.
    let walked = route.steps.filter { $0.distanceMeters > 0 }
    var steps: [Step] = []
    for j in 0..<walked.count {
        let road = walked[walked.count - 1 - j]
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
