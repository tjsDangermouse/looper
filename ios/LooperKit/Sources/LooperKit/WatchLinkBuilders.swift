import Foundation

/// The few numbers that decide what the Watch's navigation page shows.
/// Configuration rather than literals buried in a view, for the same reason
/// the haptic distances are.
public enum WatchNavigationConfig {
    /// A "Then" line only earns its place on a screen this small when the
    /// manoeuvre after next follows closely enough to plan for. Two turns
    /// half a mile apart are two separate instructions, not one pair.
    public static let thenGapMeters: Double = 400
    /// …and only once the first of the pair is actually coming up.
    public static let thenVisibleWithinMeters: Double = 300
}

/// The turn after `hit`, if the loop has one. The walk screen only ever needs
/// the next turn; the Watch shows a "Then" line as well, and works it out
/// from the same step list rather than from a second idea of progress.
public func turnAfter(_ route: Route, _ hit: TurnHit) -> TurnHit? {
    let following = hit.index + 1
    guard following < route.steps.count else { return nil }
    return TurnHit(
        step: route.steps[following],
        index: following,
        distanceAway: hit.distanceAway + route.steps[hit.index].distanceMeters
    )
}

private func maneuver(_ hit: TurnHit) -> ManeuverPayload {
    ManeuverPayload(
        stepIndex: hit.index,
        turn: turnKind(hit.step),
        instruction: hit.instruction,
        distanceMeters: max(0, hit.distanceAway)
    )
}

/// What the Watch should show before an outing starts.
public func makeLoopPlanPayload(_ record: LoopSessionRecord, preparedAt: Date = Date()) -> LoopPlanPayload {
    LoopPlanPayload(
        sessionID: record.id,
        routeID: record.routeID,
        routeName: record.routeName,
        activity: record.activity,
        mode: record.mode,
        targetAmount: record.targetAmount,
        targetUnit: record.targetUnit,
        displayUnit: record.displayUnit,
        plannedDistanceMeters: record.plannedDistanceMeters,
        plannedDurationSeconds: record.plannedDurationSeconds,
        preparedAt: preparedAt
    )
}

/// The live update the Watch draws, built from the phone's own navigation
/// state. Every figure here already exists on the phone — nothing is
/// recalculated for the Watch, and nothing is invented for it.
public func makeWorkoutState(
    record: LoopSessionRecord,
    route: Route?,
    phase: WorkoutPhase,
    offRoute: Bool,
    now: Date = Date()
) -> WorkoutStatePayload {
    let distance = max(trackDistanceMeters(record.track), record.progressMeters)
    let elapsed = record.movingSeconds(now: now)
    // Same gate the Loop Summary uses: under 100 m or a minute, a pace figure
    // is arithmetic on noise, and the Watch shows a dash instead.
    let pace = (distance >= 100 && elapsed >= 60) ? elapsed / (distance / 1000) : nil
    let planned = record.plannedDistanceMeters
    let hit = route.flatMap { nextTurn($0, record.progressMeters) }

    var then: ManeuverPayload?
    if let route, let hit, let following = turnAfter(route, hit),
       hit.distanceAway <= WatchNavigationConfig.thenVisibleWithinMeters,
       following.distanceAway - hit.distanceAway <= WatchNavigationConfig.thenGapMeters {
        then = maneuver(following)
    }

    return WorkoutStatePayload(
        sessionID: record.id,
        phase: phase,
        distanceMeters: distance,
        elapsedSeconds: elapsed,
        paceSecondsPerKm: pace,
        progressFraction: planned > 0 ? min(1, max(0, record.progressMeters / planned)) : 0,
        remainingMeters: max(0, planned - record.progressMeters),
        offRoute: offRoute,
        next: hit.map(maneuver),
        then: then,
        updatedAt: now
    )
}

/// The compact result the Watch shows after finishing. Heart rate is passed
/// in from the Watch's own workout — the phone has none, and never guesses.
public func makeWorkoutResult(_ summary: LoopSummary, averageHeartRate: Double? = nil) -> WorkoutResultPayload {
    WorkoutResultPayload(
        sessionID: summary.sessionID,
        status: summary.status,
        activity: summary.activity,
        displayUnit: summary.displayUnit,
        distanceMeters: summary.distanceMeters,
        durationSeconds: summary.durationSeconds,
        paceSecondsPerKm: summary.paceSecondsPerKm,
        averageHeartRate: averageHeartRate
    )
}
