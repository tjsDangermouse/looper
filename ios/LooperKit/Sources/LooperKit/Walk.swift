import Foundation

/// A step's instruction is the manoeuvre at its *start* — the turn onto the road
/// that step then walks, which is why the step carries that road's name. So the
/// turn being called out is the first step that starts further along the loop
/// than the walker has come, and step 0 (setting off) is never it.
public struct TurnHit {
    public var step: Step
    public var index: Int
    public var distanceAway: Double

    public var instruction: String { step.instruction }
    public var maneuver: Maneuver? { step.maneuver }
}

public func nextTurn(_ route: Route, _ progressMeters: Double) -> TurnHit? {
    var start = 0.0
    for i in 0..<route.steps.count {
        if start > progressMeters {
            return TurnHit(step: route.steps[i], index: i, distanceAway: start - progressMeters)
        }
        start += route.steps[i].distanceMeters
    }
    return nil
}
