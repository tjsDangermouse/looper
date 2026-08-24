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

/// Whether the walker has reached the end of the planned loop, by the app's
/// own reckoning: the turn list has run out. This is exactly the condition
/// the walk screen already uses to show "You're back where you started" and
/// to say it aloud — named here so the summary can share it rather than
/// inventing a second, differently-behaved idea of finishing.
///
/// A route whose steps carry no distance (nothing to walk) can't be arrived
/// at, and is excluded so it doesn't read as finished the moment it starts.
public func hasArrived(_ route: Route, progressMeters: Double) -> Bool {
    guard route.steps.contains(where: { $0.distanceMeters > 0 }) else { return false }
    return nextTurn(route, progressMeters) == nil
}
