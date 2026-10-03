import XCTest
@testable import LooperKit

// A 600 m x 400 m rectangular loop with a vertex every 20 m and three turns.
private let originLat = 54.15
private let originLng = -4.5

private func point(east: Double, north: Double) -> Point {
    let lat = originLat + north / 111_320
    let lng = originLng + east / (111_320 * cos(originLat * Double.pi / 180))
    return Point(lng, lat)
}

private func loopGeometry() -> [Point] {
    var points: [Point] = []
    func side(from: (Double, Double), to: (Double, Double)) {
        let length = hypot(to.0 - from.0, to.1 - from.1)
        let count = Int(length / 20)
        for i in 0..<count {
            let t = Double(i) / Double(count)
            points.append(point(east: from.0 + (to.0 - from.0) * t, north: from.1 + (to.1 - from.1) * t))
        }
    }
    side(from: (0, 0), to: (600, 0))
    side(from: (600, 0), to: (600, 400))
    side(from: (600, 400), to: (0, 400))
    side(from: (0, 400), to: (0, 0))
    points.append(point(east: 0, north: 0))
    return points
}

private func loopRoute() -> Route {
    let geometry = loopGeometry()
    // Corners fall on vertices 30, 50 and 80 of the 100-vertex loop.
    let starts = [0, 30, 50, 80, 100]
    var steps: [Step] = []
    let instructions = [
        "Set off along Quay Road", "Turn left onto Harbour Road",
        "Turn left onto Mill Lane", "Turn left onto Quay Road", "You’re back where you started",
    ]
    let maneuvers: [Maneuver?] = [.name("continue"), .name("turn-left"), .name("turn-left"), .name("turn-left"), .name("finish")]
    for (i, start) in starts.enumerated() {
        let end = i + 1 < starts.count ? starts[i + 1] : start
        var length = 0.0
        if end > start { for j in start..<end { length += haversine(geometry[j], geometry[j + 1]) } }
        steps.append(Step(
            instruction: instructions[i], distanceMeters: length, durationSeconds: length / 1.4,
            startIndex: start, endIndex: end, maneuver: maneuvers[i]
        ))
    }
    return Route(
        id: "loop-1", name: "Harbour loop", distanceMeters: steps.reduce(0) { $0 + $1.distanceMeters },
        durationSeconds: 1_400, targetDifferencePercent: 0,
        geometry: LineGeometry(coordinates: geometry), steps: steps
    )
}

private func plan(for route: Route) -> LoopPlanPayload {
    makeLoopPlan(
        route: route, sessionID: "walk-1", activity: .walking, mode: .distance,
        targetAmount: 1.6, targetUnit: .km, displayUnit: .km,
        preparedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

/// Points along the route, every `step` metres, as the phone would see them.
private func fixes(along geometry: [Point], every step: Double) -> [Point] {
    var out: [Point] = []
    var carried = 0.0
    for (a, b) in zip(geometry, geometry.dropFirst()) {
        let length = haversine(a, b)
        var at = step - carried
        while at <= length {
            let t = at / length
            out.append(Point(a.lng + (b.lng - a.lng) * t, a.lat + (b.lat - a.lat) * t))
            at += step
        }
        carried = length - (at - step)
    }
    return out
}

final class GuidancePackTests: XCTestCase {
    func testThePackCarriesTheManeuversThePhoneWouldSpeak() {
        let route = loopRoute()
        let pack = plan(for: route)
        XCTAssertEqual(pack.plannedManeuvers, plannedManeuvers(reassessDirections(route)))
        XCTAssertEqual(pack.plannedGeometry, route.geometry.coordinates)
        XCTAssertNotNil(pack.guidance)
        XCTAssertFalse(pack.script?.cues.isEmpty ?? true)
    }

    func testAPlanBuiltFromAnAlreadyReassessedRouteIsNotReassessedAgain() {
        let route = reassessDirections(loopRoute())
        let pack = makeLoopPlan(
            route: route, activity: .walking, mode: .distance, targetAmount: 1, targetUnit: .km,
            displayUnit: .km, alreadyReassessed: true
        )
        XCTAssertEqual(pack.plannedManeuvers, plannedManeuvers(route))
    }

    func testASavedRouteIsOfferedAtItsOwnDistance() {
        let route = loopRoute()
        let saved = makeSavedRoutePlan(route: route, activity: .walking, displayUnit: .km)
        XCTAssertEqual(saved.routeID, route.id)
        XCTAssertEqual(saved.mode, .distance)
        XCTAssertEqual(saved.targetAmount, 2.0, accuracy: 0.05)
        XCTAssertNotNil(saved.plannedManeuvers)
    }

    func testThePackSurvivesTheWire() throws {
        let pack = plan(for: loopRoute())
        XCTAssertEqual(try WatchLinkCodec.decode(try WatchLinkCodec.encode(.plan(pack))), .plan(pack))
        let saved = SavedRoutesPayload(routes: [pack], sentAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try WatchLinkCodec.decode(try WatchLinkCodec.encode(.savedRoutes(saved))), .savedRoutes(saved))
    }

    func testAStartFromTheWristNamesItsRoute() throws {
        let command = WatchCommandPayload(
            kind: .start, sessionID: "s", routeID: "loop-1", issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            try WatchLinkCodec.decode(try WatchLinkCodec.encode(.command(command))),
            .command(command)
        )
    }

    func testAWatchWalkBecomesAPhoneSessionRecord() throws {
        let route = loopRoute()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let record = WatchWalkRecordPayload(
            sessionID: "walk-1", routeID: route.id, routeName: route.name, activity: .walking,
            mode: .distance, targetAmount: 1.6, targetUnit: .km, displayUnit: .km,
            plannedDistanceMeters: route.distanceMeters, plannedDurationSeconds: route.durationSeconds,
            plannedGeometry: route.geometry.coordinates, startedAt: start,
            endedAt: start.addingTimeInterval(1_200), progressMeters: 1_550,
            arrivedAt: start.addingTimeInterval(1_190),
            track: [TrackPoint(lng: -4.5, lat: 54.15, horizontalAccuracy: 5, timestamp: start)],
            workoutID: "hk-1"
        )
        XCTAssertEqual(try WatchLinkCodec.decode(try WatchLinkCodec.encode(.walkRecord(record))), .walkRecord(record))
        let session = record.sessionRecord()
        XCTAssertEqual(session.id, "walk-1")
        XCTAssertEqual(session.workoutOwner, .watch)
        XCTAssertEqual(session.health, .savedOnWatch(workoutID: "hk-1"))
        XCTAssertTrue(session.isFinished)
        XCTAssertFalse(session.canAttemptHealthSave)
    }
}

final class RouteTrackerTests: XCTestCase {
    func testTheWatchPicksTheSameNextTurnAsThePhone() throws {
        let route = reassessDirections(loopRoute())
        var tracker = try XCTUnwrap(RouteTracker(plan: plan(for: route)))
        var checked = 0
        var phoneProgress = 0.0
        for fix in fixes(along: route.geometry.coordinates, every: 9) {
            let match = nearestProgress(fix, route.geometry.coordinates, from: phoneProgress)
            phoneProgress = progressWithoutStartFinishJump(
                previous: phoneProgress, candidate: match.distanceAlong, routeLength: route.distanceMeters
            )
            let update = try XCTUnwrap(tracker.update(fix: fix, accuracy: 5))
            XCTAssertEqual(update.progressMeters, phoneProgress, accuracy: 0.001)

            let phoneNext = nextTurn(route, phoneProgress).flatMap { hit in
                turnKind(hit.step) == .arrive ? nil : hit
            }
            XCTAssertEqual(update.next?.stepIndex, phoneNext?.index)
            if let next = update.next, let phoneNext {
                XCTAssertEqual(next.distanceMeters, phoneNext.distanceAway, accuracy: 0.5)
                XCTAssertEqual(next.instruction, phoneNext.instruction)
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 150)
    }

    func testLeavingTheRouteIsNoticedAfterThreeFixesAndClearsOnReturn() throws {
        let route = loopRoute()
        var tracker = try XCTUnwrap(RouteTracker(plan: plan(for: route)))
        let onRoute = point(east: 100, north: 0)
        let away = point(east: 100, north: -150)

        XCTAssertEqual(tracker.update(fix: onRoute, accuracy: 5)?.offRoute, false)
        XCTAssertEqual(tracker.update(fix: away, accuracy: 5)?.offRoute, false)
        XCTAssertEqual(tracker.update(fix: away, accuracy: 5)?.offRoute, false)
        XCTAssertEqual(tracker.update(fix: away, accuracy: 5)?.offRoute, true)
        XCTAssertEqual(tracker.update(fix: onRoute, accuracy: 5)?.offRoute, false)
    }

    func testOffRouteMatchesThePhonesRuleFixForFix() {
        var shared = OffRouteTracker()
        var bad = 0
        for distance in [10.0, 80, 20, 90, 90, 90, 30, 60, 61, 62, 63, 5] {
            bad = distance > 55 ? bad + 1 : 0
            XCTAssertEqual(shared.record(distanceToRoute: distance), bad >= 3)
        }
    }

    func testAVagueFixDoesNotMoveTheWalker() throws {
        var tracker = try XCTUnwrap(RouteTracker(plan: plan(for: loopRoute())))
        XCTAssertNil(tracker.update(fix: point(east: 100, north: 0), accuracy: 150))
        XCTAssertNil(tracker.update(fix: point(east: 100, north: 0), accuracy: -1))
        XCTAssertEqual(tracker.progressMeters, 0)
    }

    func testReachingTheStartAfterSettingOffArrivesOnce() throws {
        let route = loopRoute()
        var tracker = try XCTUnwrap(RouteTracker(plan: plan(for: route)))
        var arrivals = 0
        var firstArrival: Double?
        for fix in fixes(along: route.geometry.coordinates, every: 9) {
            let update = try XCTUnwrap(tracker.update(fix: fix, accuracy: 5))
            if update.arrived, firstArrival == nil { firstArrival = update.progressMeters }
            if update.arrived { arrivals += 1 }
        }
        let arrived = try XCTUnwrap(firstArrival)
        XCTAssertGreaterThan(arrived, route.distanceMeters - 40)
        XCTAssertGreaterThan(arrivals, 0)
    }

    func testStandingAtTheStartDoesNotFinishTheWalk() throws {
        var tracker = try XCTUnwrap(RouteTracker(plan: plan(for: loopRoute())))
        XCTAssertEqual(tracker.update(fix: point(east: 2, north: 0), accuracy: 5)?.arrived, false)
    }

    func testAPlanWithNoRouteCannotBeFollowed() {
        let bare = LoopPlanPayload(
            sessionID: "s", routeID: "r", routeName: "n", activity: .walking, mode: .distance,
            targetAmount: 1, targetUnit: .km, displayUnit: .km,
            plannedDistanceMeters: 1_000, plannedDurationSeconds: 600
        )
        XCTAssertNil(RouteTracker(plan: bare))
    }

    func testTheTrackedStateIsTheSameShapeThePhoneSends() throws {
        let route = loopRoute()
        let pack = plan(for: route)
        var tracker = try XCTUnwrap(RouteTracker(plan: pack))
        let fix = point(east: 400, north: 0)
        let update = try XCTUnwrap(tracker.update(fix: fix, accuracy: 5))
        let state = makeTrackedState(
            plan: pack, update: update, position: fix, courseDegrees: 90, phase: .active,
            distanceMeters: 390, elapsedSeconds: 300
        )
        XCTAssertEqual(state.sessionID, "walk-1")
        XCTAssertEqual(state.next?.stepIndex, 1)
        XCTAssertEqual(state.progressFraction, update.progressMeters / pack.plannedDistanceMeters, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(state.paceSecondsPerKm), 300 / 0.4, accuracy: 20)
        XCTAssertEqual(state.courseDegrees, 90)
    }
}

final class GuidanceScriptTests: XCTestCase {
    func testTheScriptUsesThePhonesOwnWording() throws {
        let route = reassessDirections(loopRoute())
        let pack = plan(for: route)
        let maneuvers = try XCTUnwrap(pack.plannedManeuvers)
        let script = try XCTUnwrap(pack.script)
        let first = try XCTUnwrap(maneuvers.first)

        let preview = try XCTUnwrap(script.cues.first)
        XCTAssertEqual(preview.atProgressMeters, 0)
        XCTAssertEqual(
            preview.text,
            turnAnnouncement(
                TurnAnnouncementInput(index: first.stepIndex, instruction: first.instruction, distanceAway: first.distanceMeters),
                unit: .km
            )?.text
        )
        XCTAssertTrue(script.cues.contains { $0.text == first.instruction })
        XCTAssertEqual(script.offRouteText, guidanceOffRouteText)
        XCTAssertEqual(script.arrivalText, guidanceArrivalText)
    }

    func testCuesAreOrderedAlongTheRoute() throws {
        let script = try XCTUnwrap(plan(for: loopRoute()).script)
        let positions = script.cues.map(\.atProgressMeters)
        XCTAssertEqual(positions, positions.sorted())
    }

    func testWalkingTheRouteSpeaksEachCueOnceInOrder() throws {
        let route = reassessDirections(loopRoute())
        let pack = plan(for: route)
        var tracker = try XCTUnwrap(RouteTracker(plan: pack))
        var speaker = CueSpeaker(script: try XCTUnwrap(pack.script))
        var spoken: [String] = []
        for fix in fixes(along: route.geometry.coordinates, every: 1.4) {
            guard let update = tracker.update(fix: fix, accuracy: 5) else { continue }
            if let text = speaker.due(progressMeters: update.progressMeters, offRoute: update.offRoute) {
                spoken.append(text)
            }
        }
        XCTAssertEqual(Set(spoken).count, spoken.count, "no cue repeats")
        XCTAssertTrue(spoken.contains("Turn left onto Harbour Road"))
        XCTAssertTrue(spoken.contains("Turn left onto Mill Lane"))
        XCTAssertTrue(spoken.contains("Turn left onto Quay Road"))
        XCTAssertTrue(spoken.contains { $0.hasPrefix("In ") && $0.contains("Harbour Road") })
        let harbour = try XCTUnwrap(spoken.firstIndex { $0.contains("Harbour Road") })
        let mill = try XCTUnwrap(spoken.firstIndex { $0.contains("Mill Lane") })
        XCTAssertLessThan(harbour, mill)
    }

    func testGPSSteppingBackwardsNeverRepeatsACue() {
        var speaker = CueSpeaker(script: GuidanceScript(cues: [
            SpokenCue(atProgressMeters: 0, key: "a", text: "first"),
            SpokenCue(atProgressMeters: 100, key: "b", text: "second"),
        ]))
        XCTAssertEqual(speaker.due(progressMeters: 1, offRoute: false), "first")
        XCTAssertEqual(speaker.due(progressMeters: 120, offRoute: false), "second")
        XCTAssertNil(speaker.due(progressMeters: 90, offRoute: false))
        XCTAssertNil(speaker.due(progressMeters: 130, offRoute: false))
    }

    func testPassingSeveralCuesAtOnceSpeaksOnlyTheLatest() {
        var speaker = CueSpeaker(script: GuidanceScript(cues: [
            SpokenCue(atProgressMeters: 0, key: "a", text: "first"),
            SpokenCue(atProgressMeters: 10, key: "b", text: "second"),
            SpokenCue(atProgressMeters: 20, key: "c", text: "third"),
        ]))
        XCTAssertEqual(speaker.due(progressMeters: 25, offRoute: false), "third")
        XCTAssertNil(speaker.due(progressMeters: 30, offRoute: false))
    }

    func testOffRouteIsSaidOncePerEpisode() {
        var speaker = CueSpeaker(script: GuidanceScript(cues: []))
        XCTAssertEqual(speaker.due(progressMeters: 5, offRoute: true), guidanceOffRouteText)
        XCTAssertNil(speaker.due(progressMeters: 5, offRoute: true))
        XCTAssertNil(speaker.due(progressMeters: 6, offRoute: false))
        XCTAssertEqual(speaker.due(progressMeters: 7, offRoute: true), guidanceOffRouteText)
    }

    func testArrivalIsSaidOnce() {
        var speaker = CueSpeaker(script: GuidanceScript(cues: []))
        XCTAssertEqual(speaker.arrival(), guidanceArrivalText)
        XCTAssertNil(speaker.arrival())
    }

    func testTwoCloseTurnsDoNotGetAnApproachReminder() {
        let close = [
            ManeuverPayload(stepIndex: 1, turn: .left, instruction: "Turn left onto A", distanceMeters: 100),
            ManeuverPayload(stepIndex: 2, turn: .right, instruction: "Turn right onto B", distanceMeters: 130),
        ]
        let script = makeGuidanceScript(maneuvers: close, unit: .km)
        let keys = script.cues.map(\.key)
        XCTAssertTrue(keys.contains("1:approach"))
        XCTAssertFalse(keys.contains("2:approach"), "a 30 m gap folds the preview into the approach")
        XCTAssertTrue(keys.contains("2:now"))
    }
}

final class MapAnchorTests: XCTestCase {
    func testAnchorsRunAlongTheRouteEachPointingAtTheTurnAhead() throws {
        let pack = plan(for: reassessDirections(loopRoute()))
        let anchors = mapAnchors(
            geometry: try XCTUnwrap(pack.plannedGeometry),
            maneuvers: try XCTUnwrap(pack.plannedManeuvers)
        )
        XCTAssertGreaterThan(anchors.count, 10)
        XCTAssertEqual(Set(anchors.map(\.key)).count, anchors.count, "keys are unique")
        for anchor in anchors {
            XCTAssertGreaterThan(anchor.distanceToTurn, 0)
            XCTAssertNotNil(anchor.maneuver.coordinate)
        }
        // Turns are visited in order as the anchors advance.
        let steps = anchors.map(\.maneuver.stepIndex)
        XCTAssertEqual(steps, steps.sorted())
    }

    func testAnchorsAfterTheLastTurnPointAtTheFinish() throws {
        let pack = plan(for: loopRoute())
        let geometry = try XCTUnwrap(pack.plannedGeometry)
        let anchors = mapAnchors(geometry: geometry, maneuvers: try XCTUnwrap(pack.plannedManeuvers))
        let last = try XCTUnwrap(pack.plannedManeuvers?.map(\.distanceMeters).max())
        let beyond = anchors.filter { $0.maneuver.distanceMeters > last }
        XCTAssertFalse(beyond.isEmpty, "the last stretch still has maps")
        for anchor in beyond {
            XCTAssertEqual(anchor.maneuver.stepIndex, finishStepIndex)
            XCTAssertEqual(anchor.maneuver.coordinate, geometry.last)
            XCTAssertGreaterThan(anchor.distanceToTurn, 0)
        }
    }
}
