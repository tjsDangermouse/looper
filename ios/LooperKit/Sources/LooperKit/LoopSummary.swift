import Foundation

/// How a loop actually ended. Deliberately independent of whether a Health
/// workout was recorded — an outing that was cut short is still cut short.
public enum LoopCompletionStatus: String, Codable, Equatable, Sendable {
    /// Enough of the planned loop was covered to call it done.
    case complete
    /// Ended by hand, part-way round.
    case endedEarly
    /// Ended while off the planned loop, with the loop unfinished.
    case routeIncomplete

    public var title: String {
        switch self {
        case .complete: return "Loop complete"
        case .endedEarly: return "Activity ended early"
        case .routeIncomplete: return "Route incomplete"
        }
    }
}

/// The share of the planned loop that counts as having completed it *when
/// there is no recorded arrival to go on*.
///
/// Completion is decided first by `LoopSessionRecord.arrivedAt` — the app's
/// own `hasArrived` condition, latched during the walk. That's the honest
/// answer when we have it, and it survives the walker carrying on past the
/// finish or straying off the loop afterwards, either of which can drag the
/// final `progressMeters` back below the line.
///
/// This threshold is the fallback for outings with no arrival recorded:
/// walks from before arrival was tracked, and ones that closed to within
/// touching distance without the turn list quite running out. It is
/// deliberately forgiving — GPS smoothing routinely leaves the last few tens
/// of metres of a loop unclaimed even when the walker is standing back at
/// their front door, and 5% of a 4 km loop is 200 m, short enough that only
/// a genuinely unfinished loop falls below it.
public let loopCompletionFraction: Double = 0.95

/// How a finished outing measured up against what was asked for.
public enum LoopTargetComparison: Equatable {
    /// A distance loop: the target, and how far over/under it the outing came.
    case distance(targetMeters: Double, deltaMeters: Double)
    /// A time loop: the target, and how far over/under it the outing came.
    case time(targetSeconds: Double, deltaSeconds: Double)
}

/// Everything the Loop Summary shows, derived once from a finished
/// `LoopSessionRecord`. Optional values are genuinely absent — the summary
/// hides a metric rather than inventing one.
public struct LoopSummary: Equatable {
    public var sessionID: String
    public var status: LoopCompletionStatus
    public var activity: Activity
    public var displayUnit: Unit
    public var routeName: String
    public var startedAt: Date
    public var endedAt: Date
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var plannedDistanceMeters: Double
    public var progressFraction: Double
    public var target: LoopTargetComparison?
    /// Seconds per kilometre. Absent when too little was covered to mean anything.
    public var paceSecondsPerKm: Double?
    /// Metres per second. Absent for the same reason.
    public var averageSpeedMetersPerSecond: Double?
    /// Absent unless the track carried enough trustworthy altitude data.
    public var elevationGainMeters: Double?
    /// Whether the recorded track is a fair picture of the outing. When it
    /// isn't, the summary map falls back to the planned loop and no route is
    /// sent to Apple Health — half a track is more misleading than none.
    public var hasReliableTrack: Bool
    public var plannedGeometry: [Point]
    public var track: [Point]
    public var health: HealthSaveState

    public var isDistanceTarget: Bool {
        if case .distance = target { return true }
        return false
    }
}

/// Faster than a sprint between two fixes means the fix jumped, not the
/// walker — a stale cached position from another city, or a fix that landed
/// badly wrong.
private let implausibleSpeedMetersPerSecond: Double = 12

/// The recorded track, reduced to the run of fixes that can actually have
/// come from one outing on foot.
///
/// Fixes CoreLocation couldn't place are dropped outright. What's left is cut
/// at every jump too fast to have been walked, and the longest surviving run
/// is the outing — so a stale fix from wherever the phone last had signal
/// can't drag a walk across the map. This is the one definition of "the
/// track": the distance, the summary map and the Apple Health route all read
/// from it, so none of them can disagree with the others.
public func plausibleTrack(_ track: [TrackPoint]) -> [TrackPoint] {
    let usable = track.filter(\.isUsable).sorted { $0.timestamp < $1.timestamp }
    guard usable.count > 1 else { return usable }
    var runs: [[TrackPoint]] = []
    var current: [TrackPoint] = [usable[0]]
    for index in 1..<usable.count {
        let previous = usable[index - 1], point = usable[index]
        let elapsed = point.timestamp.timeIntervalSince(previous.timestamp)
        let step = haversine(previous.point, point.point)
        if elapsed > 0, step / elapsed > implausibleSpeedMetersPerSecond {
            runs.append(current)
            current = [point]
        } else {
            current.append(point)
        }
    }
    runs.append(current)
    // Longest by ground covered, not by number of fixes: a stretch where the
    // phone sat still spitting out fixes isn't more of the outing than the
    // stretch that was actually walked.
    return runs.max { spanMeters($0) < spanMeters($1) } ?? []
}

private func spanMeters(_ points: [TrackPoint]) -> Double {
    guard points.count > 1 else { return 0 }
    return (1..<points.count).reduce(0) { $0 + haversine(points[$1 - 1].point, points[$1].point) }
}

/// Sums the recorded track, over the fixes that can have come from this
/// outing. Jitter while standing still is left out too, so this reads as the
/// distance actually travelled rather than the distance the noise wandered.
public func trackDistanceMeters(_ track: [TrackPoint]) -> Double {
    let points = plausibleTrack(track)
    guard points.count > 1 else { return 0 }
    var total = 0.0
    for index in 1..<points.count {
        let step = haversine(points[index - 1].point, points[index].point)
        // Below the noise floor of a consumer GPS standing still.
        if step < 2 { continue }
        total += step
    }
    return total
}

/// Total climb, in metres. Barometric/GPS altitude is noisy, so only rises
/// clearing a threshold count, and the whole figure is withheld unless the
/// track carried enough trustworthy altitude to be worth showing.
public func trackElevationGainMeters(_ track: [TrackPoint]) -> Double? {
    let usable = plausibleTrack(track)
    let measured = usable.filter { $0.altitude != nil && $0.verticalAccuracy > 0 && $0.verticalAccuracy <= 15 }
    guard measured.count >= 10, Double(measured.count) >= Double(usable.count) * 0.5 else { return nil }
    var gain = 0.0
    var reference = measured[0].altitude ?? 0
    for sample in measured.dropFirst() {
        guard let altitude = sample.altitude else { continue }
        let change = altitude - reference
        if change >= 3 {
            gain += change
            reference = altitude
        } else if change <= -3 {
            reference = altitude
        }
    }
    return gain
}

/// The distance target in metres, for a distance-based loop.
public func targetMeters(amount: Double, unit: Unit) -> Double {
    (unit == .mi ? milesToKm(amount) : amount) * 1000
}

/// Builds the summary. Distance comes from the recorded track, falling back
/// to route progress when the track is too thin to trust (a walk spent
/// mostly indoors, or one whose fixes never got accurate enough) — the
/// planned target is never used as a stand-in for what was actually done.
public func makeLoopSummary(_ record: LoopSessionRecord, now: Date = Date()) -> LoopSummary {
    let endedAt = record.endedAt ?? now
    // Paused stretches are not walking, and neither the pace nor the "24 min"
    // on the summary should count them.
    let duration = record.movingSeconds(now: now)
    let recorded = trackDistanceMeters(record.track)
    // The track speaks for the outing only if it covers a fair share of the
    // ground the walk is known to have covered. A walk spent mostly indoors,
    // or one whose fixes kept jumping, leaves a stub that would understate
    // the distance and draw a misleading map.
    let reliable = recorded >= 100 && (record.progressMeters <= 0 || recorded >= record.progressMeters * 0.5)
    let distance = reliable ? recorded : max(recorded, record.progressMeters)

    let fraction = record.plannedDistanceMeters > 0
        ? record.progressMeters / record.plannedDistanceMeters
        : 0
    let status: LoopCompletionStatus
    if record.arrivedAt != nil || fraction >= loopCompletionFraction {
        status = .complete
    } else if record.endedOffRoute {
        status = .routeIncomplete
    } else {
        status = .endedEarly
    }

    let target: LoopTargetComparison?
    switch record.mode {
    case .distance:
        let goal = targetMeters(amount: record.targetAmount, unit: record.targetUnit)
        target = goal > 0 ? .distance(targetMeters: goal, deltaMeters: distance - goal) : nil
    case .time:
        let goal = record.targetAmount * 60
        target = goal > 0 ? .time(targetSeconds: goal, deltaSeconds: duration - goal) : nil
    }

    // Under 100 m or without a real elapsed time, a pace figure is arithmetic
    // on noise rather than a measurement.
    let hasMeasurableEffort = distance >= 100 && duration >= 60
    let pace = hasMeasurableEffort ? duration / (distance / 1000) : nil
    let speed = hasMeasurableEffort ? distance / duration : nil

    return LoopSummary(
        sessionID: record.id,
        status: status,
        activity: record.activity,
        displayUnit: record.displayUnit,
        routeName: record.routeName,
        startedAt: record.startedAt,
        endedAt: endedAt,
        distanceMeters: distance,
        durationSeconds: duration,
        plannedDistanceMeters: record.plannedDistanceMeters,
        progressFraction: fraction,
        target: target,
        paceSecondsPerKm: pace,
        averageSpeedMetersPerSecond: speed,
        elevationGainMeters: reliable ? trackElevationGainMeters(record.track) : nil,
        hasReliableTrack: reliable,
        plannedGeometry: record.plannedGeometry,
        track: reliable ? plausibleTrack(record.track).map(\.point) : [],
        health: record.health
    )
}

/// The supporting line under the status — always describing what actually
/// happened, never the plan.
public func loopSummaryHeadline(_ summary: LoopSummary) -> String {
    let distance = formatDistance(summary.distanceMeters, unit: summary.displayUnit)
    switch summary.status {
    case .complete:
        return "A complete \(distance) loop, back where you started."
    case .endedEarly:
        let done = Int((summary.progressFraction * 100).rounded())
        if done >= 5 {
            return "\(distance) covered — about \(done)% of the way round."
        }
        return "\(distance) covered before you finished up."
    case .routeIncomplete:
        return "\(distance) covered before the loop was left behind."
    }
}
