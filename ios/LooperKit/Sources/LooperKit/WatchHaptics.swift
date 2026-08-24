import Foundation

/// A tap on the wrist, and what it means. Nothing else in the app decides
/// when these fire — `TurnHapticPlanner` does, from the same state payload
/// the Watch is already drawing.
public enum TurnHapticCue: String, Equatable, Sendable {
    /// Far enough out to change lane, look up, or start slowing.
    case prepare
    /// The turn is here.
    case imminent
    /// The phone has decided the walk has left the loop. Fires once.
    case offRoute
}

/// Every distance the wrist taps depend on, in one struct. There are no turn
/// distances written into any view.
///
/// The lead is expressed in *seconds of travel* rather than metres, because
/// the useful warning for someone running 5 min/km is a very different
/// distance from the same warning for someone strolling. Metres are what
/// comes out, after clamping — a pace reading that has gone silly (a phone in
/// a pocket on a bus, a first fix after a tunnel) can't produce a warning
/// half a mile out or one that lands after the junction.
public struct TurnHapticConfig: Equatable, Sendable {
    /// Seconds before the turn for the first, gentler tap.
    public var prepareLeadSeconds: Double
    /// Seconds before the turn for the firmer one.
    public var imminentLeadSeconds: Double
    public var prepareRangeMeters: ClosedRange<Double>
    public var imminentRangeMeters: ClosedRange<Double>
    /// Below this, a turn is close enough that the early warning would land
    /// on top of the late one; only the firm tap plays.
    public var minimumSeparationMeters: Double

    public init(
        prepareLeadSeconds: Double,
        imminentLeadSeconds: Double,
        prepareRangeMeters: ClosedRange<Double>,
        imminentRangeMeters: ClosedRange<Double>,
        minimumSeparationMeters: Double
    ) {
        self.prepareLeadSeconds = prepareLeadSeconds
        self.imminentLeadSeconds = imminentLeadSeconds
        self.prepareRangeMeters = prepareRangeMeters
        self.imminentRangeMeters = imminentRangeMeters
        self.minimumSeparationMeters = minimumSeparationMeters
    }

    /// Walking: roughly 25 s of warning, then a firm tap about 8 s out —
    /// about 35 m and 11 m at a 12 min/km stroll.
    public static let walking = TurnHapticConfig(
        prepareLeadSeconds: 25,
        imminentLeadSeconds: 8,
        prepareRangeMeters: 25...90,
        imminentRangeMeters: 10...30,
        minimumSeparationMeters: 12
    )

    /// Running: the same seconds cover far more ground, and a runner needs
    /// longer to pick a line, so the floors and ceilings both rise.
    public static let running = TurnHapticConfig(
        prepareLeadSeconds: 30,
        imminentLeadSeconds: 10,
        prepareRangeMeters: 60...200,
        imminentRangeMeters: 20...60,
        minimumSeparationMeters: 20
    )

    public static func forActivity(_ activity: Activity) -> TurnHapticConfig {
        activity == .running ? .running : .walking
    }

    /// The distance the early tap should fire at, for the pace being walked.
    /// Falls back to the middle of the range when there is no pace to go on —
    /// the first minute of a walk, or a stretch with no usable fixes.
    public func prepareDistance(paceSecondsPerKm: Double?) -> Double {
        distance(seconds: prepareLeadSeconds, paceSecondsPerKm: paceSecondsPerKm, range: prepareRangeMeters)
    }

    public func imminentDistance(paceSecondsPerKm: Double?) -> Double {
        distance(seconds: imminentLeadSeconds, paceSecondsPerKm: paceSecondsPerKm, range: imminentRangeMeters)
    }

    private func distance(seconds: Double, paceSecondsPerKm: Double?, range: ClosedRange<Double>) -> Double {
        guard let pace = paceSecondsPerKm, pace.isFinite, pace > 0 else {
            return (range.lowerBound + range.upperBound) / 2
        }
        let metersPerSecond = 1000 / pace
        return min(max(seconds * metersPerSecond, range.lowerBound), range.upperBound)
    }
}

/// Decides which taps to play, from the state the Watch is already showing.
///
/// It is a plain value with no HealthKit, no WatchKit and no clock of its
/// own, so the rules can be walked through in tests rather than on a wrist:
/// each turn taps at most once for each of its two distances, a turn is
/// identified by its step index so closing on it doesn't re-fire, going off
/// route taps exactly once however long the walk stays off it, and nothing
/// taps at all while the outing is paused or already over.
public struct TurnHapticPlanner: Equatable, Sendable {
    private var config: TurnHapticConfig
    /// The step index each cue has already been played for.
    private var preparedStep: Int?
    private var imminentStep: Int?
    private var wasOffRoute = false

    public init(config: TurnHapticConfig) {
        self.config = config
    }

    public init(activity: Activity) {
        self.init(config: .forActivity(activity))
    }

    /// The taps this update calls for, in the order they should play. Usually
    /// empty — most updates change nothing worth feeling.
    public mutating func cues(for state: WorkoutStatePayload) -> [TurnHapticCue] {
        // Paused, ending and ended all mean the walker isn't about to walk
        // into a junction. Preparing hasn't started.
        guard state.phase == .active else {
            // A pause shouldn't lose the fact that we already warned about
            // the turn ahead, so the step memory is deliberately kept.
            return []
        }

        if state.offRoute {
            defer { wasOffRoute = true }
            // The turn ahead is meaningless while off the loop; clearing the
            // memory means rejoining warns about the next turn properly.
            preparedStep = nil
            imminentStep = nil
            return wasOffRoute ? [] : [.offRoute]
        }
        wasOffRoute = false

        guard let next = state.next else { return [] }
        // Arriving back at the start is not a manoeuvre to take; the Watch
        // says so on screen, and a wrist tap for it would only read as a turn.
        guard next.turnKind != .arrive else { return [] }

        let imminentAt = config.imminentDistance(paceSecondsPerKm: state.paceSecondsPerKm)
        let prepareAt = config.prepareDistance(paceSecondsPerKm: state.paceSecondsPerKm)
        var cues: [TurnHapticCue] = []

        // Checked in distance order so a first update that arrives already
        // inside both thresholds — coming back from a lost connection, say —
        // plays only the one that still helps.
        if next.distanceMeters <= imminentAt {
            if imminentStep != next.stepIndex {
                imminentStep = next.stepIndex
                // Anything closer than the early tap's own reason to exist is
                // covered by this one, so mark it done and stay quiet.
                preparedStep = next.stepIndex
                cues.append(.imminent)
            }
        } else if next.distanceMeters <= prepareAt, prepareAt - imminentAt >= config.minimumSeparationMeters {
            if preparedStep != next.stepIndex {
                preparedStep = next.stepIndex
                cues.append(.prepare)
            }
        }
        return cues
    }
}
