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
    /// The map is a junction preview, not the whole loop. These distances
    /// leave enough approach to read the shape without zooming the turn down
    /// to a speck on a 40 mm screen.
    public static let previewApproachMeters: Double = 350
    public static let previewExitMeters: Double = 180
    /// A hard wire-size bound. Forty-eight points preserve street-scale bends
    /// while keeping a one-second state update comfortably below the limit.
    public static let previewPointLimit = 48
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

/// Selects a street-scale window around the next junction. Step indices are
/// the phone router's geometry anchors, so no turn position is inferred on
/// the Watch.
public func makeRoutePreview(_ route: Route, _ hit: TurnHit, currentPosition: Point? = nil) -> RoutePreviewPayload? {
    let points = route.geometry.coordinates
    guard points.count >= 2,
          let rawTurnIndex = hit.step.startIndex,
          points.indices.contains(rawTurnIndex) else { return nil }

    let turnIndex = rawTurnIndex
    var startIndex = turnIndex
    var approach = 0.0
    while startIndex > 0 && approach < WatchNavigationConfig.previewApproachMeters {
        approach += haversine(points[startIndex - 1], points[startIndex])
        startIndex -= 1
    }

    var endIndex = turnIndex
    var exit = 0.0
    while endIndex + 1 < points.count && exit < WatchNavigationConfig.previewExitMeters {
        exit += haversine(points[endIndex], points[endIndex + 1])
        endIndex += 1
    }

    let window = Array(points[startIndex...endIndex])
    guard window.count >= 2 else { return nil }
    let compact = compactPreview(
        window,
        preserving: turnIndex - startIndex,
        limit: WatchNavigationConfig.previewPointLimit
    )
    let visiblePosition = hit.distanceAway <= WatchNavigationConfig.previewApproachMeters ? currentPosition : nil
    return RoutePreviewPayload(
        coordinates: compact,
        maneuver: points[turnIndex],
        currentPosition: visiblePosition
    )
}

private func compactPreview(_ points: [Point], preserving requiredIndex: Int, limit: Int) -> [Point] {
    guard points.count > limit, limit >= 2 else { return points }
    var indices: Set<Int> = [0, points.count - 1, requiredIndex]
    if limit > 3 {
        for index in 1...(limit - 3) {
            indices.insert(Int((Double(index) * Double(points.count - 1) / Double(limit - 2)).rounded()))
        }
    }
    return indices.sorted().prefix(limit).map { points[$0] }
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
    let currentPosition = record.track.last(where: \.isUsable)?.point

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
        routePreview: route.flatMap { route in hit.flatMap { makeRoutePreview(route, $0, currentPosition: currentPosition) } },
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
