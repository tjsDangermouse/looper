import XCTest
@testable import LooperKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func plan(activity: Activity = .walking) -> LoopPlanPayload {
    LoopPlanPayload(
        sessionID: "session-1",
        routeID: "route-1",
        routeName: "Harbour loop",
        activity: activity,
        mode: .distance,
        targetAmount: 4,
        targetUnit: .km,
        displayUnit: .km,
        plannedDistanceMeters: 4_000,
        plannedDurationSeconds: 2_880,
        preparedAt: epoch
    )
}

private func state(
    phase: WorkoutPhase = .active,
    offRoute: Bool = false,
    next: ManeuverPayload? = nil,
    pace: Double? = 600
) -> WorkoutStatePayload {
    WorkoutStatePayload(
        sessionID: "session-1",
        phase: phase,
        distanceMeters: 1_200,
        elapsedSeconds: 720,
        paceSecondsPerKm: pace,
        progressFraction: 0.3,
        remainingMeters: 2_800,
        offRoute: offRoute,
        next: next,
        routePreview: RoutePreviewPayload(
            coordinates: [Point(-4.48, 54.15), Point(-4.479, 54.151)],
            maneuver: Point(-4.479, 54.151),
            currentPosition: Point(-4.48, 54.15)
        ),
        updatedAt: epoch
    )
}

private func turn(at meters: Double, step: Int = 2, kind: Turn = .left) -> ManeuverPayload {
    ManeuverPayload(stepIndex: step, turn: kind, instruction: "Turn left onto Harbour Road", distanceMeters: meters)
}

// MARK: The wire format

final class WatchLinkCodecTests: XCTestCase {
    func testPlanSurvivesTheRoundTrip() throws {
        let decoded = try WatchLinkCodec.decode(try WatchLinkCodec.encode(.plan(plan())))
        XCTAssertEqual(decoded, .plan(plan()))
    }

    func testStateSurvivesTheRoundTrip() throws {
        let sent = state(next: turn(at: 80))
        let decoded = try WatchLinkCodec.decode(try WatchLinkCodec.encode(.state(sent)))
        XCTAssertEqual(decoded, .state(sent))
    }

    func testResultSurvivesTheRoundTrip() throws {
        let sent = WorkoutResultPayload(
            sessionID: "session-1", status: .complete, activity: .running, displayUnit: .mi,
            distanceMeters: 4_120, durationSeconds: 1_500, paceSecondsPerKm: 364, averageHeartRate: 142
        )
        let decoded = try WatchLinkCodec.decode(try WatchLinkCodec.encode(.result(sent)))
        XCTAssertEqual(decoded, .result(sent))
    }

    func testCommandKeepsItsIdentitySoItCanBeDeduplicated() throws {
        let sent = WatchCommandPayload(kind: .end, sessionID: "session-1", id: "command-1", issuedAt: epoch)
        guard case .command(let decoded) = try WatchLinkCodec.decode(try WatchLinkCodec.encode(.command(sent))) else {
            return XCTFail("expected a command")
        }
        XCTAssertEqual(decoded.id, "command-1")
        XCTAssertEqual(decoded.kind, .end)
        XCTAssertEqual(decoded.sessionID, "session-1")
    }

    func testWorkoutStatusSurvivesTheRoundTrip() throws {
        let sent = WatchWorkoutStatusPayload(sessionID: "session-1", state: .saved, workoutID: "workout-9")
        let decoded = try WatchLinkCodec.decode(try WatchLinkCodec.encode(.workoutStatus(sent)))
        XCTAssertEqual(decoded, .workoutStatus(sent))
    }

    func testTheDictionaryFormUsedByWatchConnectivityRoundTrips() throws {
        let dictionary = try WatchLinkCodec.dictionary(for: .plan(plan()))
        XCTAssertEqual(try WatchLinkCodec.message(from: dictionary), .plan(plan()))
    }

    /// One device updated and the other not is the case this protects: the
    /// message is refused with a reason, rather than half-decoded.
    func testAPayloadFromAnotherVersionIsRefused() throws {
        let envelope = WatchEnvelope(message: .plan(plan()), version: WatchLink.version + 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(envelope)
        XCTAssertThrowsError(try WatchLinkCodec.decode(data)) { error in
            XCTAssertEqual(error as? WatchLinkError, .unsupportedVersion(WatchLink.version + 1))
        }
    }

    func testRubbishIsRefusedRatherThanCrashing() {
        XCTAssertThrowsError(try WatchLinkCodec.decode(Data("not a message".utf8)))
        XCTAssertThrowsError(try WatchLinkCodec.message(from: ["something": "else"]))
    }

    /// An unknown manoeuvre from a newer phone must draw *something*, not
    /// fail to decode.
    func testAnUnknownTurnFallsBackToStraightAhead() throws {
        var payload = turn(at: 50)
        payload.turn = "spiral-staircase"
        XCTAssertEqual(payload.turnKind, .straight)
    }
}

// MARK: Wrist taps

final class TurnHapticPlannerTests: XCTestCase {
    func testATurnWarnsOnceEarlyAndOnceLate() {
        var planner = TurnHapticPlanner(activity: .walking)
        // 10 min/km: the early tap lands at 25 s (~41 m), the firm one at 8 s
        // (~13 m, floored to the range's 10 m).
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 200))), [])
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 40))), [.prepare])
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 30))), [], "closing on the same turn mustn't buzz again")
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 12))), [.imminent])
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 6))), [])
    }

    func testTheNextTurnGetsItsOwnWarnings() {
        var planner = TurnHapticPlanner(activity: .walking)
        _ = planner.cues(for: state(next: turn(at: 40, step: 2)))
        _ = planner.cues(for: state(next: turn(at: 10, step: 2)))
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 40, step: 3))), [.prepare])
    }

    /// Coming back from a lost connection already close to a turn should play
    /// the tap that still helps, not both.
    func testArrivingAlreadyInsideBothThresholdsPlaysOnlyTheCloseOne() {
        var planner = TurnHapticPlanner(activity: .walking)
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 8))), [.imminent])
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 5))), [])
    }

    func testRunningWarnsFurtherOut() {
        var planner = TurnHapticPlanner(activity: .running)
        // 5 min/km over 30 s is 100 m of warning; a walker would still be silent.
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 95), pace: 300)), [.prepare])
    }

    func testGoingOffRouteTapsExactlyOnceHoweverLongItLasts() {
        var planner = TurnHapticPlanner(activity: .walking)
        XCTAssertEqual(planner.cues(for: state(offRoute: true)), [.offRoute])
        XCTAssertEqual(planner.cues(for: state(offRoute: true)), [])
        XCTAssertEqual(planner.cues(for: state(offRoute: true)), [])
    }

    func testComingBackOnRouteAndStrayingAgainTapsAgain() {
        var planner = TurnHapticPlanner(activity: .walking)
        XCTAssertEqual(planner.cues(for: state(offRoute: true)), [.offRoute])
        XCTAssertEqual(planner.cues(for: state(offRoute: false, next: turn(at: 500))), [])
        XCTAssertEqual(planner.cues(for: state(offRoute: true)), [.offRoute])
    }

    func testNothingTapsWhilePausedOrEnded() {
        var planner = TurnHapticPlanner(activity: .walking)
        XCTAssertEqual(planner.cues(for: state(phase: .paused, next: turn(at: 12))), [])
        XCTAssertEqual(planner.cues(for: state(phase: .ended, offRoute: true)), [])
    }

    /// Arriving back at the start is not a manoeuvre to take.
    func testArrivingHomeDoesNotTap() {
        var planner = TurnHapticPlanner(activity: .walking)
        XCTAssertEqual(planner.cues(for: state(next: turn(at: 10, kind: .arrive))), [])
    }

    func testWithNoPaceTheDistancesStayInsideTheirRange() {
        let config = TurnHapticConfig.walking
        XCTAssertTrue(config.prepareRangeMeters.contains(config.prepareDistance(paceSecondsPerKm: nil)))
        XCTAssertTrue(config.imminentRangeMeters.contains(config.imminentDistance(paceSecondsPerKm: nil)))
        // A nonsense pace — a phone on a bus — can't push the warning miles out.
        XCTAssertEqual(config.prepareDistance(paceSecondsPerKm: 30), config.prepareRangeMeters.upperBound)
        XCTAssertEqual(config.prepareDistance(paceSecondsPerKm: 6_000), config.prepareRangeMeters.lowerBound)
    }
}

// MARK: One outing, one workout

final class WorkoutOwnershipTests: XCTestCase {
    private func record(health: HealthSaveState, owner: HealthWorkoutOwner? = nil) -> LoopSessionRecord {
        var record = LoopSessionRecord(
            activity: .walking, mode: .distance, targetAmount: 4, targetUnit: .km, displayUnit: .km,
            routeID: "route-1", routeName: "Harbour loop",
            plannedDistanceMeters: 4_000, plannedDurationSeconds: 2_880, plannedGeometry: [],
            startedAt: epoch, endedAt: epoch.addingTimeInterval(1_800),
            healthOwner: owner
        )
        record.health = health
        return record
    }

    func testAWatchRecordedOutingIsNeverSavedAgainByThePhone() {
        XCTAssertFalse(record(health: .savedOnWatch(workoutID: "workout-1"), owner: .watch).canAttemptHealthSave)
        // Even before the Watch has managed to send the workout's id back.
        XCTAssertFalse(record(health: .savedOnWatch(workoutID: nil), owner: .watch).canAttemptHealthSave)
    }

    func testASavedOrInFlightWorkoutIsNeverSavedTwice() {
        XCTAssertFalse(record(health: .saved(workoutID: "workout-1")).canAttemptHealthSave)
        XCTAssertFalse(record(health: .saving).canAttemptHealthSave)
    }

    func testAFailedOrSkippedSaveCanStillBeRetried() {
        XCTAssertTrue(record(health: .failed(message: "no")).canAttemptHealthSave)
        XCTAssertTrue(record(health: .skipped(reason: "off")).canAttemptHealthSave)
        XCTAssertTrue(record(health: .notAttempted).canAttemptHealthSave)
    }

    func testAnUnfinishedOutingIsNeverSaved() {
        var live = record(health: .notAttempted)
        live.endedAt = nil
        XCTAssertFalse(live.canAttemptHealthSave)
    }

    func testTheWatchsWorkoutIdIsKeptWhereTheSummaryLooksForIt() {
        XCTAssertEqual(record(health: .savedOnWatch(workoutID: "workout-7"), owner: .watch).savedWorkoutID, "workout-7")
    }

    func testRecordsFromBeforeTheWatchAppBelongToThePhone() {
        XCTAssertEqual(record(health: .notAttempted).workoutOwner, .phone)
    }

    /// A save interrupted by the app going away is retryable, not stuck.
    func testAnInterruptedSaveComesBackRetryable() {
        let restored = record(health: .saving).reconciledAfterRestore()
        XCTAssertTrue(restored.canAttemptHealthSave)
    }

    func testPausedTimeIsNotWalkedTime() {
        var record = record(health: .notAttempted)
        record.pausedSeconds = 300
        XCTAssertEqual(record.movingSeconds(), 1_500)
        XCTAssertEqual(makeLoopSummary(record).durationSeconds, 1_500)
    }
}

// MARK: What the Watch is told

final class WorkoutStatePayloadTests: XCTestCase {
    private let route = Route(
        id: "route-1", name: "Harbour loop", distanceMeters: 1_000, durationSeconds: 720,
        targetDifferencePercent: 0,
        geometry: LineGeometry(coordinates: [Point(0, 0), Point(0.01, 0)]),
        steps: [
            Step(instruction: "Head along Peel Road", distanceMeters: 400, durationSeconds: 300),
            Step(instruction: "Turn left onto Harbour Road", distanceMeters: 100, durationSeconds: 70, maneuver: .code(0)),
            Step(instruction: "Turn right onto Quay Street", distanceMeters: 500, durationSeconds: 350, maneuver: .code(1)),
            Step(instruction: "Arrive at your starting point", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10)),
        ]
    )

    private func record(progress: Double) -> LoopSessionRecord {
        var record = LoopSessionRecord(
            activity: .walking, mode: .distance, targetAmount: 1, targetUnit: .km, displayUnit: .km,
            routeID: "route-1", routeName: "Harbour loop",
            plannedDistanceMeters: 1_000, plannedDurationSeconds: 720, plannedGeometry: [],
            startedAt: epoch
        )
        record.progressMeters = progress
        return record
    }

    func testTheNextManoeuvreIsThePhonesAndItsDistanceIsMeasuredFromProgress() {
        let payload = makeWorkoutState(
            record: record(progress: 350), route: route, phase: .active, offRoute: false,
            now: epoch.addingTimeInterval(600)
        )
        XCTAssertEqual(payload.next?.instruction, "Turn left onto Harbour Road")
        XCTAssertEqual(payload.next?.distanceMeters, 50)
        XCTAssertEqual(payload.next?.turnKind, .left)
    }

    func testRoutePreviewUsesTheStepGeometryAnchorForTheTurn() {
        let points = (0..<80).map { index in
            Point(-4.50 + Double(index) * 0.00005, 54.15 + (index < 40 ? 0 : Double(index - 40) * 0.00004))
        }
        var mapped = route
        mapped.geometry = LineGeometry(coordinates: points)
        mapped.steps[1].startIndex = 40
        mapped.steps[1].endIndex = 65

        let preview = makeRoutePreview(
            mapped,
            TurnHit(step: mapped.steps[1], index: 1, distanceAway: 50),
            currentPosition: points[34]
        )

        XCTAssertEqual(preview?.maneuver, points[40])
        XCTAssertEqual(preview?.currentPosition, points[34])
        XCTAssertTrue((preview?.coordinates.count ?? 0) <= WatchNavigationConfig.previewPointLimit)
        XCTAssertTrue(preview?.coordinates.contains(points[40]) == true)
    }

    func testFarAwayPositionDoesNotZoomTheJunctionPreviewOut() {
        var mapped = route
        mapped.geometry = LineGeometry(coordinates: [
            Point(-4.50, 54.15), Point(-4.499, 54.15), Point(-4.498, 54.151), Point(-4.497, 54.151)
        ])
        mapped.steps[1].startIndex = 2
        let preview = makeRoutePreview(
            mapped,
            TurnHit(step: mapped.steps[1], index: 1, distanceAway: 800),
            currentPosition: Point(-4.51, 54.14)
        )
        XCTAssertNil(preview?.currentPosition)
    }

    func testRoutePreviewIsAbsentWhenRouterProvidesNoGeometryAnchor() {
        let payload = makeWorkoutState(
            record: record(progress: 350), route: route, phase: .active, offRoute: false,
            now: epoch.addingTimeInterval(600)
        )
        XCTAssertNil(payload.routePreview)
    }

    /// Two turns half a kilometre apart are two separate instructions, and
    /// the second has no business on a screen this small yet.
    func testAFarOffFollowingTurnIsLeftOffTheWatch() {
        var spreadOut = route
        spreadOut.steps[1].distanceMeters = 600
        let payload = makeWorkoutState(
            record: record(progress: 350), route: spreadOut, phase: .active, offRoute: false,
            now: epoch.addingTimeInterval(600)
        )
        XCTAssertEqual(payload.next?.instruction, "Turn left onto Harbour Road")
        XCTAssertNil(payload.then, "a Then line only earns its place when the pair are close together")
    }

    /// …and a turn still 400 m off is not yet coming up, however close the
    /// one behind it follows.
    func testAFollowingTurnIsHeldBackUntilTheFirstIsActuallyComingUp() {
        let payload = makeWorkoutState(
            record: record(progress: 0), route: route, phase: .active, offRoute: false,
            now: epoch.addingTimeInterval(600)
        )
        XCTAssertEqual(payload.next?.distanceMeters, 400)
        XCTAssertNil(payload.then)
    }

    func testACloseFollowingTurnIsSentAsThen() {
        // 50 m from the left, with the right only 100 m beyond it.
        let payload = makeWorkoutState(
            record: record(progress: 350), route: route, phase: .active, offRoute: false,
            now: epoch.addingTimeInterval(600)
        )
        XCTAssertEqual(payload.then?.instruction, "Turn right onto Quay Street")
        XCTAssertEqual(payload.then?.distanceMeters, 150)
    }

    func testProgressAndRemainingComeFromThePlannedLoop() {
        let payload = makeWorkoutState(
            record: record(progress: 250), route: route, phase: .active, offRoute: false,
            now: epoch.addingTimeInterval(600)
        )
        XCTAssertEqual(payload.progressFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(payload.remainingMeters, 750, accuracy: 0.0001)
    }

    func testPaceIsWithheldUntilThereIsEnoughToMeasure() {
        let early = makeWorkoutState(
            record: record(progress: 50), route: route, phase: .active, offRoute: false,
            now: epoch.addingTimeInterval(30)
        )
        XCTAssertNil(early.paceSecondsPerKm, "a pace off 50 m in 30 s is arithmetic on noise")

        let later = makeWorkoutState(
            record: record(progress: 600), route: route, phase: .active, offRoute: false,
            now: epoch.addingTimeInterval(360)
        )
        XCTAssertEqual(later.paceSecondsPerKm ?? 0, 600, accuracy: 0.001)
    }

    func testTheOffRouteVerdictIsThePhonesAndIsPassedStraightThrough() {
        let payload = makeWorkoutState(
            record: record(progress: 250), route: route, phase: .paused, offRoute: true,
            now: epoch.addingTimeInterval(600)
        )
        XCTAssertTrue(payload.offRoute)
        XCTAssertEqual(payload.phase, .paused)
    }

    func testAPlanCarriesTheTargetTheWalkerAskedFor() {
        XCTAssertEqual(plan().targetDescription, "4.0 km")
    }
}
