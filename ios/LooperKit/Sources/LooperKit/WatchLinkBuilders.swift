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

private func maneuver(_ hit: TurnHit, route: Route) -> ManeuverPayload {
    let coordinate = hit.step.startIndex.flatMap { index in
        route.geometry.coordinates.indices.contains(index) ? route.geometry.coordinates[index] : nil
    }
    return ManeuverPayload(
        stepIndex: hit.index,
        turn: turnKind(hit.step),
        instruction: hit.instruction,
        distanceMeters: max(0, hit.distanceAway),
        coordinate: coordinate
    )
}

/// The complete, compact turn list sent once with a prepared Watch route.
/// Distances are measured from the start here; live state replaces them with
/// distance remaining before anything is displayed.
public func plannedManeuvers(_ route: Route) -> [ManeuverPayload] {
    var distance = 0.0
    return route.steps.enumerated().compactMap { index, step in
        defer { distance += step.distanceMeters }
        guard index > 0,
              turnKind(step) != .arrive,
              let coordinateIndex = step.startIndex,
              route.geometry.coordinates.indices.contains(coordinateIndex)
        else { return nil }
        return ManeuverPayload(
            stepIndex: index,
            turn: turnKind(step),
            instruction: step.instruction,
            distanceMeters: distance,
            coordinate: route.geometry.coordinates[coordinateIndex]
        )
    }
}

/// The complete guidance pack for a route: what the Watch follows when it is
/// the only device on the walk. Built here, on the phone's side, from the same
/// reassessed route the phone speaks from, so a turn the phone would never
/// announce is never on the wrist either.
///
/// Pass `alreadyReassessed` when the route has already been through
/// `reassessDirections` — the walk start does that itself, and a second pass
/// is not guaranteed to leave a route exactly as it found it.
public func makeLoopPlan(
    route: Route,
    sessionID: String = UUID().uuidString,
    activity: Activity,
    mode: LoopMode,
    targetAmount: Double,
    targetUnit: Unit,
    displayUnit: Unit,
    narration: NarrationSettings? = nil,
    alreadyReassessed: Bool = false,
    preparedAt: Date = Date()
) -> LoopPlanPayload {
    let route = alreadyReassessed ? route : reassessDirections(route)
    let maneuvers = plannedManeuvers(route)
    return LoopPlanPayload(
        sessionID: sessionID,
        routeID: route.id,
        routeName: route.name,
        activity: activity,
        mode: mode,
        targetAmount: targetAmount,
        targetUnit: targetUnit,
        displayUnit: displayUnit,
        plannedDistanceMeters: route.distanceMeters,
        plannedDurationSeconds: route.durationSeconds,
        plannedGeometry: route.geometry.coordinates,
        plannedManeuvers: maneuvers,
        guidance: .forActivity(activity),
        script: makeGuidanceScript(maneuvers: maneuvers, unit: displayUnit),
        narration: narration,
        preparedAt: preparedAt
    )
}

/// A saved route as a plan the Watch can offer: a distance target equal to the
/// route itself, since the route is what was chosen.
public func makeSavedRoutePlan(
    route: Route,
    activity: Activity,
    displayUnit: Unit,
    narration: NarrationSettings? = nil
) -> LoopPlanPayload {
    let metersPerUnit = displayUnit == .mi ? 1609.344 : 1000
    return makeLoopPlan(
        route: route,
        activity: activity,
        mode: .distance,
        targetAmount: (route.distanceMeters / metersPerUnit * 10).rounded() / 10,
        targetUnit: displayUnit,
        displayUnit: displayUnit,
        narration: narration
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
        plannedGeometry: record.plannedGeometry,
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
    let latestFix = record.track.last(where: { $0.isUsable })

    var then: ManeuverPayload?
    if let route, let hit, let following = turnAfter(route, hit),
       hit.distanceAway <= WatchNavigationConfig.thenVisibleWithinMeters,
       following.distanceAway - hit.distanceAway <= WatchNavigationConfig.thenGapMeters {
        then = maneuver(following, route: route)
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
        position: latestFix?.point,
        courseDegrees: latestFix?.course.flatMap { $0 >= 0 ? $0 : nil },
        next: route.flatMap { route in hit.map { maneuver($0, route: route) } },
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
