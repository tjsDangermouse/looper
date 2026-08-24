import Foundation

/// One recorded GPS fix from a walk or run. This is the app's own persisted
/// copy of the track: `CLLocation` isn't `Codable`, and the summary and the
/// Health save both need the outing to survive a force-quit or a restore
/// from the background, not just live in memory.
public struct TrackPoint: Codable, Equatable {
    public var lng: Double
    public var lat: Double
    public var altitude: Double?
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    public var speed: Double?
    public var course: Double?
    public var timestamp: Date

    public init(
        lng: Double,
        lat: Double,
        altitude: Double? = nil,
        horizontalAccuracy: Double,
        verticalAccuracy: Double = -1,
        speed: Double? = nil,
        course: Double? = nil,
        timestamp: Date
    ) {
        self.lng = lng
        self.lat = lat
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }

    public var point: Point { Point(lng, lat) }

    /// A fix good enough to draw, measure and hand to Apple Health. A
    /// negative accuracy means CoreLocation couldn't fix the position at all.
    public var isUsable: Bool { horizontalAccuracy > 0 && horizontalAccuracy <= TrackPoint.accuracyLimitMeters }

    /// Matches the 100 m gate the walk screen already uses to decide a fix is
    /// too vague to advance route progress with.
    public static let accuracyLimitMeters: Double = 100
}

/// Where a Health save has got to for one loop. Persisted with the session so
/// a save can't be attempted twice across a relaunch, and so a failure can be
/// retried by hand without producing a second workout.
public enum HealthSaveState: Codable, Equatable {
    /// Nothing tried yet — either the outing is still going, or Health saving
    /// hasn't been switched on.
    case notAttempted
    /// A save is running right now.
    case saving
    /// Saved. The HKWorkout's UUID is kept so a retry can never duplicate it.
    case saved(workoutID: String)
    /// The outing was recorded by the Apple Watch, and the Watch's own
    /// workout *is* the Health record for it. The phone deliberately writes
    /// nothing: one outing, one workout. The UUID is absent until the Watch
    /// reports it, which it may never manage if it goes out of range before
    /// the save finishes — the workout still exists on the Watch and syncs
    /// on its own, so a missing id is not a failure to retry.
    case savedOnWatch(workoutID: String?)
    /// Tried and failed; retryable by hand.
    case failed(message: String)
    /// Deliberately not saved (HealthKit unavailable, permission denied, or
    /// the integration is off). Not an error to show as one.
    case skipped(reason: String)
}

/// A recorded outing, from tapping Start to tapping End. Everything the Loop
/// Summary and the Health save need is derived from this one record, rather
/// than each of them recalculating from live app state.
public struct LoopSessionRecord: Codable, Equatable {
    public var id: String
    public var activity: Activity
    public var mode: LoopMode
    /// The target exactly as it was asked for — km/mi for a distance loop,
    /// minutes for a time loop.
    public var targetAmount: Double
    public var targetUnit: Unit
    /// The unit the person reads distances in.
    public var displayUnit: Unit
    public var routeID: String
    public var routeName: String
    public var plannedDistanceMeters: Double
    public var plannedDurationSeconds: Double
    public var plannedGeometry: [Point]
    public var startedAt: Date
    public var endedAt: Date?
    /// How far round the planned loop the walker got, from the existing
    /// route-progress model.
    public var progressMeters: Double
    /// When the walker first reached the end of the planned loop, if they
    /// did. Latched once and never cleared: wandering on past the finish, or
    /// straying off the loop afterwards, can pull `progressMeters` back down,
    /// but it can't un-walk the loop.
    public var arrivedAt: Date?
    /// Whether the walk was off the planned loop at the moment it ended.
    public var endedOffRoute: Bool
    public var track: [TrackPoint]
    public var health: HealthSaveState
    /// Whether the walker has seen and dismissed the Loop Summary for this
    /// outing. Keeps a finished loop's summary from reappearing on every
    /// launch, while still letting one survive a force-quit unseen.
    public var summaryAcknowledged: Bool
    /// Which device is writing this outing to Apple Health. Set the moment a
    /// Watch workout is confirmed as running, and persisted straight away —
    /// a phone killed mid-walk that came back not knowing the Watch owned the
    /// workout would save a second one.
    public var healthOwner: HealthWorkoutOwner?
    /// Total seconds spent paused. Optional so records from before pausing
    /// existed read back unchanged.
    public var pausedSeconds: Double?

    public init(
        id: String = UUID().uuidString,
        activity: Activity,
        mode: LoopMode,
        targetAmount: Double,
        targetUnit: Unit,
        displayUnit: Unit,
        routeID: String,
        routeName: String,
        plannedDistanceMeters: Double,
        plannedDurationSeconds: Double,
        plannedGeometry: [Point],
        startedAt: Date,
        endedAt: Date? = nil,
        progressMeters: Double = 0,
        arrivedAt: Date? = nil,
        endedOffRoute: Bool = false,
        track: [TrackPoint] = [],
        health: HealthSaveState = .notAttempted,
        summaryAcknowledged: Bool = false,
        healthOwner: HealthWorkoutOwner? = nil,
        pausedSeconds: Double? = nil
    ) {
        self.id = id
        self.activity = activity
        self.mode = mode
        self.targetAmount = targetAmount
        self.targetUnit = targetUnit
        self.displayUnit = displayUnit
        self.routeID = routeID
        self.routeName = routeName
        self.plannedDistanceMeters = plannedDistanceMeters
        self.plannedDurationSeconds = plannedDurationSeconds
        self.plannedGeometry = plannedGeometry
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.progressMeters = progressMeters
        self.arrivedAt = arrivedAt
        self.endedOffRoute = endedOffRoute
        self.track = track
        self.health = health
        self.summaryAcknowledged = summaryAcknowledged
        self.healthOwner = healthOwner
        self.pausedSeconds = pausedSeconds
    }

    public var isFinished: Bool { endedAt != nil }

    /// The single gate every Health save goes through. A loop that is already
    /// saved, or has a save in flight, can never start another one — which is
    /// what stops a repeated completion callback, a reopened summary, or a
    /// manual retry from writing a second workout.
    public var canAttemptHealthSave: Bool {
        guard isFinished else { return false }
        switch health {
        case .saved, .saving, .savedOnWatch: return false
        case .notAttempted, .failed, .skipped: return true
        }
    }

    public var savedWorkoutID: String? {
        switch health {
        case .saved(let id): return id
        case .savedOnWatch(let id): return id
        default: return nil
        }
    }

    /// The device that owns this outing's one Health workout. Absent on
    /// records written before the Watch app existed, which were all the
    /// phone's.
    public var workoutOwner: HealthWorkoutOwner { healthOwner ?? .phone }

    /// Elapsed time with paused stretches taken off — what the Watch shows,
    /// and what the summary calls the duration. Falls back to wall-clock for
    /// an outing that was never paused.
    public func movingSeconds(now: Date = Date()) -> Double {
        let end = endedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - (pausedSeconds ?? 0))
    }

    /// A `.saving` state read back from disk means the app went away
    /// mid-save; nothing is still running, so it becomes a retryable failure
    /// rather than a state that blocks saving forever.
    public func reconciledAfterRestore() -> LoopSessionRecord {
        guard case .saving = health else { return self }
        var restored = self
        restored.health = .failed(message: "The save was interrupted.")
        return restored
    }
}
