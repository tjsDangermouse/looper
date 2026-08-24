import XCTest
@testable import LooperKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

/// A straight east-west line of fixes, one per `interval` seconds, each
/// `stepMeters` apart — enough to exercise the distance and pace maths without
/// depending on a real GPS trace.
private func track(
    count: Int,
    stepMeters: Double = 10,
    interval: TimeInterval = 5,
    altitudes: [Double]? = nil,
    accuracy: Double = 5
) -> [TrackPoint] {
    // ~111,320 m per degree of longitude at the equator.
    let degreesPerMetre = 1 / 111_320.0
    return (0..<count).map { index in
        TrackPoint(
            lng: Double(index) * stepMeters * degreesPerMetre,
            lat: 0,
            altitude: altitudes.map { $0[index % $0.count] },
            horizontalAccuracy: accuracy,
            verticalAccuracy: altitudes == nil ? -1 : 4,
            timestamp: epoch.addingTimeInterval(Double(index) * interval)
        )
    }
}

private func session(
    plannedMeters: Double = 4000,
    progressMeters: Double = 4000,
    endedOffRoute: Bool = false,
    mode: LoopMode = .distance,
    targetAmount: Double = 4,
    targetUnit: LooperKit.Unit = .km,
    durationSeconds: TimeInterval = 2400,
    arrivedAt: Date? = nil,
    track points: [TrackPoint] = track(count: 401),
    health: HealthSaveState = .notAttempted,
    ended: Bool = true
) -> LoopSessionRecord {
    LoopSessionRecord(
        id: "session-1",
        activity: .walking,
        mode: mode,
        targetAmount: targetAmount,
        targetUnit: targetUnit,
        displayUnit: .km,
        routeID: "route-1",
        routeName: "Riverside loop",
        plannedDistanceMeters: plannedMeters,
        plannedDurationSeconds: 2400,
        plannedGeometry: [Point(0, 0), Point(0.01, 0), Point(0, 0)],
        startedAt: epoch,
        endedAt: ended ? epoch.addingTimeInterval(durationSeconds) : nil,
        progressMeters: progressMeters,
        arrivedAt: arrivedAt,
        endedOffRoute: endedOffRoute,
        track: points,
        health: health
    )
}

final class LoopSummaryDerivationTests: XCTestCase {
    func testMeasuresDistanceFromTheRecordedTrackNotTheTarget() {
        // 401 fixes 10 m apart is 4000 m walked, against a 10 km target.
        let summary = makeLoopSummary(session(targetAmount: 10))
        XCTAssertEqual(summary.distanceMeters, 4000, accuracy: 5)
    }

    /// A cached fix from wherever the phone last had signal must not become
    /// the first leg of the walk — not in the distance, and not on the map.
    func testDropsAStaleFixFromSomewhereElse() {
        let walk = track(count: 20, stepMeters: 10, interval: 5)
        let stale = TrackPoint(
            lng: 40, lat: 40, horizontalAccuracy: 5,
            timestamp: walk[0].timestamp.addingTimeInterval(-5)
        )
        let recorded = [stale] + walk
        XCTAssertEqual(plausibleTrack(recorded).count, walk.count)
        XCTAssertEqual(trackDistanceMeters(recorded), 190, accuracy: 2)
    }

    func testIgnoresJitterAndImpossibleJumps() {
        var points = track(count: 3, stepMeters: 100, interval: 60)
        // Standing still: a 1 m wobble a second later.
        points.append(TrackPoint(lng: points[2].lng + 1 / 111_320.0, lat: 0, horizontalAccuracy: 5, timestamp: points[2].timestamp.addingTimeInterval(1)))
        // A fix that teleports a kilometre in one second.
        points.append(TrackPoint(lng: points[2].lng + 1000 / 111_320.0, lat: 0, horizontalAccuracy: 5, timestamp: points[2].timestamp.addingTimeInterval(2)))
        XCTAssertEqual(trackDistanceMeters(points), 200, accuracy: 2)
    }

    func testDiscardsUnusableFixes() {
        let vague = track(count: 10, accuracy: 250)
        XCTAssertEqual(trackDistanceMeters(vague), 0)
    }

    func testCallsAFinishedLoopComplete() {
        XCTAssertEqual(makeLoopSummary(session()).status, .complete)
    }

    func testTreatsTheThresholdAsTheBoundary() {
        let justOver = session(progressMeters: 4000 * loopCompletionFraction)
        XCTAssertEqual(makeLoopSummary(justOver).status, .complete)
        let justUnder = session(progressMeters: 4000 * loopCompletionFraction - 1)
        XCTAssertEqual(makeLoopSummary(justUnder).status, .endedEarly)
    }

    /// A recorded arrival is the honest answer and outranks the fallback
    /// threshold: carrying on past the finish, or straying off the loop
    /// afterwards, drags the final progress down but can't un-walk the loop.
    func testTrustsARecordedArrivalOverTheFinalProgress() {
        let wandered = session(progressMeters: 400, arrivedAt: epoch.addingTimeInterval(2000))
        XCTAssertEqual(makeLoopSummary(wandered).status, .complete)
    }

    func testARecordedArrivalOutranksEndingOffRoute() {
        let strayed = session(
            progressMeters: 300, endedOffRoute: true, arrivedAt: epoch.addingTimeInterval(2000)
        )
        XCTAssertEqual(makeLoopSummary(strayed).status, .complete)
    }

    func testCallsAManuallyEndedLoopEndedEarly() {
        let summary = makeLoopSummary(session(progressMeters: 1200))
        XCTAssertEqual(summary.status, .endedEarly)
        XCTAssertTrue(loopSummaryHeadline(summary).contains("30%"))
    }

    func testCallsALoopLeftBehindIncomplete() {
        XCTAssertEqual(makeLoopSummary(session(progressMeters: 1200, endedOffRoute: true)).status, .routeIncomplete)
    }

    /// A recorded workout must never talk an early finish into a completed loop.
    func testAnEarlyFinishStaysEarlyEvenWhenSavedToHealth() {
        let saved = session(progressMeters: 900, health: .saved(workoutID: "abc"))
        XCTAssertEqual(makeLoopSummary(saved).status, .endedEarly)
    }

    func testComparesAgainstADistanceTarget() {
        let summary = makeLoopSummary(session(targetAmount: 3))
        guard case .distance(let target, let delta) = summary.target else { return XCTFail("expected a distance target") }
        XCTAssertEqual(target, 3000, accuracy: 1)
        XCTAssertEqual(delta, 1000, accuracy: 5)
    }

    func testComparesAgainstATimeTarget() {
        let summary = makeLoopSummary(session(mode: .time, targetAmount: 30, durationSeconds: 2400))
        guard case .time(let target, let delta) = summary.target else { return XCTFail("expected a time target") }
        XCTAssertEqual(target, 1800)
        XCTAssertEqual(delta, 600)
    }

    func testConvertsAMilesTarget() {
        XCTAssertEqual(targetMeters(amount: 3, unit: .mi), 4828, accuracy: 1)
    }

    func testDerivesPaceAndSpeedFromTheActualOuting() {
        // 4 km in 40 minutes is 10 min/km and 1.667 m/s.
        let summary = makeLoopSummary(session(durationSeconds: 2400))
        XCTAssertEqual(summary.paceSecondsPerKm ?? 0, 600, accuracy: 2)
        XCTAssertEqual(summary.averageSpeedMetersPerSecond ?? 0, 1.667, accuracy: 0.01)
    }

    func testWithholdsPaceWhenThereIsTooLittleToMeasure() {
        let summary = makeLoopSummary(session(progressMeters: 20, durationSeconds: 20, track: track(count: 3)))
        XCTAssertNil(summary.paceSecondsPerKm)
        XCTAssertNil(summary.averageSpeedMetersPerSecond)
    }

    func testWithholdsElevationWithoutTrustworthyAltitude() {
        XCTAssertNil(makeLoopSummary(session()).elevationGainMeters)
    }

    func testCountsOnlyRealClimb() {
        // Two 10 m climbs and a descent back down. The 1 m wobbles along the
        // way are noise and must not be counted as climb.
        let altitudes: [Double] = [0, 1, 0, 10, 11, 10, 20, 21, 20, 10, 0, 0]
        let gain = trackElevationGainMeters(track(count: altitudes.count, altitudes: altitudes))
        XCTAssertEqual(gain ?? 0, 20, accuracy: 0.5)
    }

    func testFormatsPaceInThePersonsOwnUnit() {
        XCTAssertEqual(formatPace(600, unit: .km), "10:00 /km")
        XCTAssertEqual(formatPace(600, unit: .mi), "16:06 /mi")
        XCTAssertEqual(formatDuration(2400), "40:00")
        XCTAssertEqual(formatDuration(3725), "1:02:05")
        XCTAssertEqual(formatDistanceDelta(-320, unit: .km), "-0.3 km")
    }

    func testFallsBackToRouteProgressWhenTheTrackIsUnusable() {
        let summary = makeLoopSummary(session(progressMeters: 3800, track: track(count: 10, accuracy: 300)))
        XCTAssertEqual(summary.distanceMeters, 3800, accuracy: 1)
        XCTAssertFalse(summary.hasReliableTrack)
    }

    /// A stub of a track would understate the distance and draw a map of a
    /// walk that didn't happen, so it is set aside rather than shown.
    func testSetsAsideATrackTooShortToStandForTheOuting() {
        let stub = track(count: 30, stepMeters: 10, interval: 5)
        let summary = makeLoopSummary(session(progressMeters: 3000, track: stub))
        XCTAssertFalse(summary.hasReliableTrack)
        XCTAssertTrue(summary.track.isEmpty)
        XCTAssertEqual(summary.distanceMeters, 3000, accuracy: 1)
    }

    func testKeepsATrackThatMatchesTheGroundCovered() {
        let summary = makeLoopSummary(session(progressMeters: 4000))
        XCTAssertTrue(summary.hasReliableTrack)
        XCTAssertEqual(summary.track.count, 401)
    }

    /// Fixes piling up while the phone sits still must not out-vote the
    /// stretch that was actually walked.
    func testPrefersTheRunThatCoveredTheMostGround() {
        let walked = track(count: 20, stepMeters: 20, interval: 5)
        let last = walked[walked.count - 1]
        // A cluster of 60 near-identical fixes somewhere else entirely.
        let stationary = (0..<60).map { index in
            TrackPoint(
                lng: 30, lat: 30, horizontalAccuracy: 5,
                timestamp: last.timestamp.addingTimeInterval(Double(index) + 5)
            )
        }
        XCTAssertEqual(plausibleTrack(walked + stationary).count, walked.count)
    }
}

final class HealthSaveGuardTests: XCTestCase {
    func testWillNotSaveAnOutingThatIsStillRunning() {
        XCTAssertFalse(session(ended: false).canAttemptHealthSave)
    }

    func testWillSaveAFinishedOutingOnce() {
        XCTAssertTrue(session().canAttemptHealthSave)
    }

    /// Repeated completion callbacks, a reopened summary, or a manual retry
    /// must never produce a second workout.
    func testWillNotSaveALoopThatIsAlreadySaved() {
        let saved = session(health: .saved(workoutID: "abc"))
        XCTAssertFalse(saved.canAttemptHealthSave)
        XCTAssertEqual(saved.savedWorkoutID, "abc")
    }

    func testWillNotStartASecondSaveWhileOneIsInFlight() {
        XCTAssertFalse(session(health: .saving).canAttemptHealthSave)
    }

    func testAllowsAManualRetryAfterAFailure() {
        XCTAssertTrue(session(health: .failed(message: "no")).canAttemptHealthSave)
    }

    func testAllowsSavingAfterConnectingLater() {
        XCTAssertTrue(session(health: .skipped(reason: "not connected")).canAttemptHealthSave)
    }

    /// A save cut short by the app being killed shouldn't block saving forever.
    func testTurnsAnInterruptedSaveIntoARetryableFailure() {
        let restored = session(health: .saving).reconciledAfterRestore()
        guard case .failed = restored.health else { return XCTFail("expected a retryable failure") }
        XCTAssertTrue(restored.canAttemptHealthSave)
    }

    func testLeavesASavedLoopAloneOnRestore() {
        let restored = session(health: .saved(workoutID: "abc")).reconciledAfterRestore()
        XCTAssertEqual(restored.savedWorkoutID, "abc")
        XCTAssertFalse(restored.canAttemptHealthSave)
    }

    func testSurvivesARoundTripThroughStorage() throws {
        let original = session(health: .saved(workoutID: "abc"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LoopSessionRecord.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.canAttemptHealthSave)
    }
}

/// The condition the walk screen already uses to say "You're back where you
/// started", now shared with the summary.
final class ArrivalTests: XCTestCase {
    private let loop = Route(
        id: "r", name: "Loop", distanceMeters: 300, durationSeconds: 240, targetDifferencePercent: 0,
        geometry: LineGeometry(coordinates: [Point(0, 0), Point(0.001, 0), Point(0, 0)]),
        steps: [
            Step(instruction: "Head along Main Street", distanceMeters: 100, durationSeconds: 80),
            Step(instruction: "Turn left onto Quay Road", distanceMeters: 200, durationSeconds: 160, maneuver: .code(0)),
            Step(instruction: "Arrive at your starting point", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10)),
        ]
    )

    func testHasNotArrivedAtTheStart() {
        XCTAssertFalse(hasArrived(loop, progressMeters: 0))
    }

    func testHasNotArrivedPartWayRound() {
        XCTAssertFalse(hasArrived(loop, progressMeters: 250))
    }

    /// Matches `nextTurn` running out of steps — the same moment the walk
    /// screen stops showing a turn.
    func testHasArrivedOnceTheTurnsRunOut() {
        XCTAssertNil(nextTurn(loop, 300))
        XCTAssertTrue(hasArrived(loop, progressMeters: 300))
        XCTAssertTrue(hasArrived(loop, progressMeters: 420))
    }

    /// A route with nothing to walk must not read as finished the instant it
    /// starts, even though its turn list is empty from the outset.
    func testARouteWithNothingToWalkIsNeverArrivedAt() {
        let empty = Route(
            id: "e", name: "Empty", distanceMeters: 0, durationSeconds: 0, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [Point(0, 0)]), steps: []
        )
        XCTAssertFalse(hasArrived(empty, progressMeters: 0))
        let markerOnly = Route(
            id: "m", name: "Marker", distanceMeters: 0, durationSeconds: 0, targetDifferencePercent: 0,
            geometry: LineGeometry(coordinates: [Point(0, 0)]),
            steps: [Step(instruction: "Arrive", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10))]
        )
        XCTAssertFalse(hasArrived(markerOnly, progressMeters: 0))
    }

    func testArrivalSurvivesStorage() throws {
        var record = LoopSessionRecord(
            activity: .walking, mode: .distance, targetAmount: 4, targetUnit: .km, displayUnit: .km,
            routeID: "r", routeName: "Loop", plannedDistanceMeters: 300, plannedDurationSeconds: 240,
            plannedGeometry: loop.geometry.coordinates, startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        record.arrivedAt = Date(timeIntervalSince1970: 1_700_002_000)
        let decoded = try JSONDecoder().decode(
            LoopSessionRecord.self, from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.arrivedAt, record.arrivedAt)
    }
}
