import Foundation

// The guidance pack and the small amount of code that follows it.
//
// The iPhone's navigation engine is the only thing that plans a route or
// decides what the walker is told. Everything it decides travels to the Watch
// in the `LoopPlanPayload` — the geometry, every manoeuvre and its wording,
// the spoken script, the thresholds. What lives here is the Watch's side of
// that bargain: working out how far along the route a GPS fix is, picking the
// next manoeuvre *from the pack*, noticing when the walker has left the route,
// and replaying the phone's spoken cues. Nothing in this file creates an
// instruction, rewords one or re-plans.

/// Every number the Watch needs to follow a route, set once on the phone.
public struct GuidanceConfig: Codable, Equatable, Sendable {
    /// How far from the route a fix has to be to count as off it.
    public var offRouteMeters: Double
    /// How many fixes in a row have to be that far out before the walker is
    /// told. One stray fix is GPS noise, not a wrong turn.
    public var offRouteFixCount: Int
    /// Fixes vaguer than this don't move the walker along the route.
    public var maxFixAccuracyMeters: Double
    public var arrivalRadiusMeters: Double
    public var arrivalDepartureBufferMeters: Double
    public var completionFraction: Double
    public var haptics: TurnHapticConfig

    public init(
        offRouteMeters: Double = 55,
        offRouteFixCount: Int = 3,
        maxFixAccuracyMeters: Double = TrackPoint.accuracyLimitMeters,
        arrivalRadiusMeters: Double = loopArrivalRadiusMeters,
        arrivalDepartureBufferMeters: Double = loopArrivalDepartureBufferMeters,
        completionFraction: Double = loopCompletionFraction,
        haptics: TurnHapticConfig = .walking
    ) {
        self.offRouteMeters = offRouteMeters
        self.offRouteFixCount = offRouteFixCount
        self.maxFixAccuracyMeters = maxFixAccuracyMeters
        self.arrivalRadiusMeters = arrivalRadiusMeters
        self.arrivalDepartureBufferMeters = arrivalDepartureBufferMeters
        self.completionFraction = completionFraction
        self.haptics = haptics
    }

    public static func forActivity(_ activity: Activity) -> GuidanceConfig {
        GuidanceConfig(haptics: .forActivity(activity))
    }
}

/// Decides when a walker has left the route. The phone and the Watch both use
/// this one type, so the two can never disagree on what "off route" means.
public struct OffRouteTracker: Equatable, Sendable {
    public private(set) var badFixes = 0
    public private(set) var isOffRoute = false
    private let radiusMeters: Double
    private let fixCount: Int

    public init(radiusMeters: Double = 55, fixCount: Int = 3) {
        self.radiusMeters = radiusMeters
        self.fixCount = fixCount
    }

    public init(_ config: GuidanceConfig) {
        self.init(radiusMeters: config.offRouteMeters, fixCount: config.offRouteFixCount)
    }

    /// Feeds one accepted fix's distance from the route and returns whether
    /// the walker is now off it.
    @discardableResult
    public mutating func record(distanceToRoute: Double) -> Bool {
        badFixes = distanceToRoute > radiusMeters ? badFixes + 1 : 0
        isOffRoute = badFixes >= fixCount
        return isOffRoute
    }

    public mutating func reset() {
        badFixes = 0
        isOffRoute = false
    }
}

/// One thing to say aloud, and where along the route to say it.
public struct SpokenCue: Codable, Equatable, Sendable {
    public var atProgressMeters: Double
    public var key: String
    public var text: String

    public init(atProgressMeters: Double, key: String, text: String) {
        self.atProgressMeters = atProgressMeters
        self.key = key
        self.text = text
    }
}

/// The phone's narration for the whole route, written in advance with the same
/// wording code the phone itself speaks with.
public struct GuidanceScript: Codable, Equatable, Sendable {
    public var cues: [SpokenCue]
    public var offRouteText: String
    public var arrivalText: String

    public init(
        cues: [SpokenCue],
        offRouteText: String = guidanceOffRouteText,
        arrivalText: String = guidanceArrivalText
    ) {
        self.cues = cues
        self.offRouteText = offRouteText
        self.arrivalText = arrivalText
    }
}

public let guidanceOffRouteText = "You are off the planned loop. Head back to the route."
public let guidanceArrivalText = "You are back where you started."

/// Narration settings that belong to the person, not the route.
public struct NarrationSettings: Codable, Equatable, Sendable {
    public var voiceIdentifier: String?

    public init(voiceIdentifier: String? = nil) {
        self.voiceIdentifier = voiceIdentifier
    }
}

/// How far ahead of a turn the approach reminder fires, and the distance its
/// wording assumes — a fix lands somewhere between 25 and 20 metres out, which
/// the phone's own rounding reads as "20 metres".
private let approachCueDistance = 25.0
private let approachCueSpokenDistance = 22.0
private let nowCueDistance = 5.0

/// Writes the spoken script for a list of manoeuvres. Runs on the phone when a
/// plan is built; the Watch only plays the result.
///
/// It follows the phone's live staging: a preview as a turn becomes the next
/// one, an approach reminder at 25 m, and the instruction itself at 5 m. A turn
/// that follows closely on the last one skips the approach, the same way the
/// live announcer folds a close preview into it.
public func makeGuidanceScript(maneuvers: [ManeuverPayload], unit: Unit) -> GuidanceScript {
    var cues: [SpokenCue] = []
    var previous = 0.0
    for maneuver in maneuvers.sorted(by: { $0.distanceMeters < $1.distanceMeters }) {
        defer { previous = maneuver.distanceMeters }
        guard maneuver.turnKind != .arrive else { continue }
        let gap = maneuver.distanceMeters - previous
        guard gap > 0 else { continue }

        func input(_ distance: Double) -> TurnAnnouncementInput {
            TurnAnnouncementInput(index: maneuver.stepIndex, instruction: maneuver.instruction, distanceAway: distance)
        }

        if let preview = turnAnnouncement(input(gap), unit: unit) {
            cues.append(SpokenCue(atProgressMeters: previous, key: preview.key, text: preview.text))
        }
        if gap > 50, let approach = turnAnnouncement(input(approachCueSpokenDistance), unit: unit) {
            cues.append(SpokenCue(
                atProgressMeters: maneuver.distanceMeters - approachCueDistance,
                key: approach.key,
                text: approach.text
            ))
        }
        if gap > nowCueDistance, let now = turnAnnouncement(input(0), unit: unit) {
            cues.append(SpokenCue(
                atProgressMeters: maneuver.distanceMeters - nowCueDistance,
                key: now.key,
                text: now.text
            ))
        }
    }
    return GuidanceScript(cues: cues)
}

/// Plays a script as progress crosses it. A replay guard and nothing more:
/// every cue is spoken at most once, and GPS stepping backwards can't bring one
/// back. Where several cues have been passed at once the latest wins, like the
/// phone, which only ever speaks for the turn it is on.
public struct CueSpeaker: Equatable, Sendable {
    private let script: GuidanceScript
    private var lastCue = -1
    private var spokeOffRoute = false
    private var spokeArrival = false

    public init(script: GuidanceScript) {
        self.script = script
    }

    public mutating func due(progressMeters: Double, offRoute: Bool) -> String? {
        if offRoute {
            guard !spokeOffRoute else { return nil }
            spokeOffRoute = true
            return script.offRouteText
        }
        spokeOffRoute = false

        var latest: Int?
        for (index, cue) in script.cues.enumerated() where index > lastCue && cue.atProgressMeters <= progressMeters {
            latest = index
        }
        guard let latest else { return nil }
        lastCue = latest
        return script.cues[latest].text
    }

    public mutating func arrival() -> String? {
        guard !spokeArrival else { return nil }
        spokeArrival = true
        return script.arrivalText
    }
}

/// What following the route produced for one fix.
public struct TrackerUpdate: Equatable, Sendable {
    public var progressMeters: Double
    public var distanceToRoute: Double
    public var offRoute: Bool
    /// Back in the finish zone after setting off. Latches true once reached.
    public var arrived: Bool
    public var next: ManeuverPayload?
    public var then: ManeuverPayload?
}

/// Follows a prepared route with the Watch's own GPS. It matches fixes to the
/// pack's geometry and looks the next manoeuvre up in the pack's list.
public struct RouteTracker: Sendable {
    public let geometry: [Point]
    public let maneuvers: [ManeuverPayload]
    public let plannedDistanceMeters: Double
    public let config: GuidanceConfig
    public private(set) var progressMeters = 0.0
    public private(set) var hasArrived = false
    private var offRoute: OffRouteTracker

    public init(
        geometry: [Point],
        maneuvers: [ManeuverPayload],
        plannedDistanceMeters: Double,
        config: GuidanceConfig
    ) {
        self.geometry = geometry
        self.maneuvers = maneuvers.sorted { $0.distanceMeters < $1.distanceMeters }
        self.plannedDistanceMeters = plannedDistanceMeters
        self.config = config
        self.offRoute = OffRouteTracker(config)
    }

    /// Nil when the plan carries no route to follow — one from an older phone.
    public init?(plan: LoopPlanPayload) {
        guard let geometry = plan.plannedGeometry, geometry.count > 1 else { return nil }
        self.init(
            geometry: geometry,
            maneuvers: plan.plannedManeuvers ?? [],
            plannedDistanceMeters: plan.plannedDistanceMeters,
            config: plan.guidance ?? .forActivity(plan.activity)
        )
    }

    /// Picks up where a relaunched app left off, so a walker near the end of
    /// the loop isn't mistaken for one at the start.
    public mutating func restore(progressMeters: Double, hasArrived: Bool) {
        self.progressMeters = max(0, progressMeters)
        self.hasArrived = hasArrived
    }

    /// Nil when the fix is too vague to move anybody along the route.
    public mutating func update(fix: Point, accuracy: Double) -> TrackerUpdate? {
        guard accuracy > 0, accuracy <= config.maxFixAccuracyMeters else { return nil }
        let match = nearestProgress(fix, geometry, from: progressMeters)
        progressMeters = progressWithoutStartFinishJump(
            previous: progressMeters,
            candidate: match.distanceAlong,
            routeLength: plannedDistanceMeters
        )
        let isOff = offRoute.record(distanceToRoute: match.distanceToRoute)

        if !hasArrived,
           plannedDistanceMeters > 0,
           progressMeters >= config.arrivalDepartureBufferMeters,
           let start = geometry.first,
           haversine(fix, start) <= config.arrivalRadiusMeters {
            hasArrived = true
        }

        let (next, then) = upcoming()
        return TrackerUpdate(
            progressMeters: progressMeters,
            distanceToRoute: match.distanceToRoute,
            offRoute: isOff,
            arrived: hasArrived,
            next: next,
            then: then
        )
    }

    /// The first manoeuvre beyond the walker, and the one after it if it
    /// follows closely enough to be worth showing.
    private func upcoming() -> (ManeuverPayload?, ManeuverPayload?) {
        guard let index = maneuvers.firstIndex(where: { $0.distanceMeters > progressMeters }) else { return (nil, nil) }
        var next = maneuvers[index]
        let ahead = next.distanceMeters - progressMeters
        next.distanceMeters = max(0, ahead)

        var then: ManeuverPayload?
        if index + 1 < maneuvers.count, ahead <= WatchNavigationConfig.thenVisibleWithinMeters {
            var following = maneuvers[index + 1]
            let gap = following.distanceMeters - maneuvers[index].distanceMeters
            if gap <= WatchNavigationConfig.thenGapMeters {
                following.distanceMeters = max(0, following.distanceMeters - progressMeters)
                then = following
            }
        }
        return (next, then)
    }
}

/// The state the Watch draws, from its own tracking. Same type, same pace
/// rule, same completion maths as the phone's `makeWorkoutState`.
public func makeTrackedState(
    plan: LoopPlanPayload,
    update: TrackerUpdate,
    position: Point?,
    courseDegrees: Double?,
    phase: WorkoutPhase,
    distanceMeters: Double,
    elapsedSeconds: Double,
    now: Date = Date()
) -> WorkoutStatePayload {
    let distance = max(distanceMeters, update.progressMeters)
    let pace = (distance >= 100 && elapsedSeconds >= 60) ? elapsedSeconds / (distance / 1000) : nil
    let planned = plan.plannedDistanceMeters
    return WorkoutStatePayload(
        sessionID: plan.sessionID,
        phase: phase,
        distanceMeters: distance,
        elapsedSeconds: elapsedSeconds,
        paceSecondsPerKm: pace,
        progressFraction: planned > 0 ? min(1, max(0, update.progressMeters / planned)) : 0,
        remainingMeters: max(0, planned - update.progressMeters),
        offRoute: update.offRoute,
        position: position,
        courseDegrees: courseDegrees.flatMap { $0 >= 0 ? $0 : nil },
        next: update.next,
        then: update.then,
        updatedAt: now
    )
}

/// A place along the route to save a map for, so the Watch can show a map that
/// follows the walker with no connection. Each is the picture the live map
/// would have asked for from that spot: the position, the turn ahead and how
/// far away it is.
public struct MapAnchor: Equatable, Sendable {
    public var key: String
    public var position: Point
    public var maneuver: ManeuverPayload
    public var distanceToTurn: Double
}

/// Anchors every `spacingMeters` along the route, each paired with the next
/// manoeuvre beyond it. The same list is computed when the maps are saved and
/// when one is looked up, so the two always agree.
public func mapAnchors(
    geometry: [Point],
    maneuvers: [ManeuverPayload],
    spacingMeters: Double = 100
) -> [MapAnchor] {
    guard geometry.count > 1, spacingMeters > 0 else { return [] }
    let ordered = maneuvers.filter { $0.coordinate != nil }.sorted { $0.distanceMeters < $1.distanceMeters }
    var anchors: [MapAnchor] = []
    var nextAt = 0.0
    var travelled = 0.0
    for (a, b) in zip(geometry, geometry.dropFirst()) {
        let length = haversine(a, b)
        while length > 0, nextAt <= travelled + length {
            let t = (nextAt - travelled) / length
            let position = Point(a.lng + (b.lng - a.lng) * t, a.lat + (b.lat - a.lat) * t)
            if let maneuver = ordered.first(where: { $0.distanceMeters > nextAt }) {
                anchors.append(MapAnchor(
                    key: "a\(Int(nextAt.rounded()))",
                    position: position,
                    maneuver: maneuver,
                    distanceToTurn: maneuver.distanceMeters - nextAt
                ))
            }
            nextAt += spacingMeters
        }
        travelled += length
    }
    return anchors
}
