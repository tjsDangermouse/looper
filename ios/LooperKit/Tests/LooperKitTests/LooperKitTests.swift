import XCTest
@testable import LooperKit

private let sample = Route(
    id: "a", name: "A", distanceMeters: 200, durationSeconds: 120, targetDifferencePercent: 0,
    geometry: LineGeometry(coordinates: [Point(0, 0), Point(0.001, 0), Point(0.002, 0)]),
    steps: [
        Step(instruction: "Head along Main Street", distanceMeters: 100, durationSeconds: 60, maneuver: .code(11), road: "Main Street"),
        Step(instruction: "Turn left onto Quay Road", distanceMeters: 100, durationSeconds: 60, maneuver: .code(0), road: "Quay Road"),
        Step(instruction: "Arrive", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10)),
    ]
)

final class WalkingMathsTests: XCTestCase {
    func testConvertsUnits() {
        XCTAssertEqual(milesToKm(kmToMiles(5)), 5, accuracy: 0.0001)
    }

    func testEstimatesTarget() {
        XCTAssertEqual(estimateKmFromMinutes(60), 5)
    }

    func testMeasuresDistance() {
        XCTAssertGreaterThan(haversine(Point(0, 0), Point(0.001, 0)), 100)
    }

    func testCalculatesProgress() {
        XCTAssertEqual(nearestProgress(Point(0.001, 0), sample.geometry.coordinates).index, 1)
    }

    func testMeasuresHowFarAlongTheWalkHasCome() {
        let progress = nearestProgress(Point(0.0015, 0), sample.geometry.coordinates)
        XCTAssertEqual(progress.distanceAlong, haversine(Point(0, 0), Point(0.0015, 0)), accuracy: 1)
    }

    func testStaysOnTheLoopItHasAlreadyWalked() {
        let loop = [Point(0, 0), Point(0.001, 0), Point(0.001, 0.001), Point(0, 0)]
        XCTAssertGreaterThan(nearestProgress(Point(0.00001, 0.00001), loop, from: 300).distanceAlong, 300)
    }

    func testDoesNotMistakeTheSharedStartAndFinishForACompletedLoop() {
        XCTAssertEqual(
            progressWithoutStartFinishJump(previous: 0, candidate: 3_995, routeLength: 4_000),
            0
        )
    }

    func testAcceptsTheFinishOnceTheLoopIsUnderway() {
        XCTAssertEqual(
            progressWithoutStartFinishJump(previous: 2_000, candidate: 3_995, routeLength: 4_000),
            3_995
        )
    }

    func testAcceptsOrdinaryProgressAtTheBeginning() {
        XCTAssertEqual(
            progressWithoutStartFinishJump(previous: 0, candidate: 40, routeLength: 4_000),
            40
        )
    }

    func testReadsANumberedTurnFromORS() {
        let step = Step(instruction: "Turn left", distanceMeters: 0, durationSeconds: 0, maneuver: .code(0))
        XCTAssertEqual(turnKind(step), .left)
    }

    func testReadsANamedTurnFromTheLoopService() {
        let step = Step(instruction: "Keep right", distanceMeters: 0, durationSeconds: 0, maneuver: .name("keep-right"))
        XCTAssertEqual(turnKind(step), .slightRight)
    }

    func testFallsBackToTheWording() {
        let step = Step(instruction: "Turn sharp left onto Quay Road", distanceMeters: 0, durationSeconds: 0)
        XCTAssertEqual(turnKind(step), .sharpLeft)
    }

    func testKnowsTheWalkIsOver() {
        XCTAssertEqual(turnKind(nil), .arrive)
    }

    func testMirrorsATurn() {
        XCTAssertEqual(mirrorTurn(.sharpLeft), .sharpRight)
    }

    func testFoldsAwayAClipIntoASideRoad() {
        let steps = tidySteps([
            Step(instruction: "Head along Main Street", distanceMeters: 200, durationSeconds: 150, road: "Main Street"),
            Step(instruction: "Turn right onto Mill Lane", distanceMeters: 1, durationSeconds: 1, road: "Mill Lane"),
            Step(instruction: "Turn left onto Main Street", distanceMeters: 150, durationSeconds: 110, road: "Main Street"),
            Step(instruction: "Turn left onto Quay Road", distanceMeters: 90, durationSeconds: 70, road: "Quay Road"),
            Step(instruction: "Arrive", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10)),
        ])
        XCTAssertEqual(steps.map(\.instruction), ["Head along Main Street", "Turn left onto Quay Road", "Arrive"])
        XCTAssertEqual(steps.map(\.distanceMeters), [351, 90, 0])
    }

    func testNeverFoldsAwayArriving() {
        let steps = tidySteps([
            Step(instruction: "Head along Main Street", distanceMeters: 200, durationSeconds: 150, road: "Main Street"),
            Step(instruction: "Arrive", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10)),
        ])
        XCTAssertEqual(steps.count, 2)
    }

    func testKeepsARealTurnBetweenTwoShortSteps() {
        let steps = tidySteps([
            Step(instruction: "Head along Main Street", distanceMeters: 60, durationSeconds: 40, road: "Main Street"),
            Step(instruction: "Turn left onto Quay Road", distanceMeters: 40, durationSeconds: 30, road: "Quay Road"),
        ])
        XCTAssertEqual(steps.count, 2)
    }

    func testSelectsNextTurn() {
        XCTAssertEqual(nextTurn(sample, 110)?.instruction, "Arrive")
    }

    func testCallsTheTurnOntoTheRoadAheadNotTheOneUnderfoot() {
        let ahead = nextTurn(sample, 40)
        XCTAssertEqual(ahead?.instruction, "Turn left onto Quay Road")
        XCTAssertEqual(ahead?.distanceAway, 60)
    }

    func testNeverCallsSettingOffATurn() {
        XCTAssertEqual(nextTurn(sample, 0)?.instruction, "Turn left onto Quay Road")
    }

    func testRunsOutOfTurnsAtTheEnd() {
        XCTAssertNil(nextTurn(sample, 200))
    }

    func testStaysSilentFarFromATurn() {
        let turn = TurnAnnouncementInput(index: 0, instruction: "Turn left", distanceAway: 900)
        XCTAssertNil(turnAnnouncement(turn, unit: .km))
    }

    func testLeadsInAtTheDistanceActuallyLeft() {
        let turn = TurnAnnouncementInput(index: 0, instruction: "Turn left", distanceAway: 300)
        XCTAssertEqual(turnAnnouncement(turn, unit: .km)?.text, "In 300 metres, turn left")
    }

    func testCallsATurnPickedUpPartWayIntoABandAtItsRealDistance() {
        let turn = TurnAnnouncementInput(index: 0, instruction: "Turn left", distanceAway: 45)
        XCTAssertEqual(turnAnnouncement(turn, unit: .km)?.text, "In 50 metres, turn left")
    }

    func testWaitsUntilFiveMetresToSpeakTheBareTurn() {
        let approaching = TurnAnnouncementInput(index: 0, instruction: "Turn left", distanceAway: 10)
        XCTAssertEqual(turnAnnouncement(approaching, unit: .km)?.text, "In 10 metres, turn left")

        let turn = TurnAnnouncementInput(index: 0, instruction: "Turn left", distanceAway: 5)
        XCTAssertEqual(turnAnnouncement(turn, unit: .km)?.text, "Turn left")
    }

    func testKeysEachBandOnce() {
        let turn = TurnAnnouncementInput(index: 2, instruction: "Turn left", distanceAway: 80)
        XCTAssertEqual(turnAnnouncement(turn, unit: .km)?.key, "2:near")
    }

    func testGuidanceHistoryNeverMovesBackToAnEarlierBand() {
        var history = GuidanceAnnouncementHistory()
        XCTAssertTrue(history.shouldAnnounce(TurnAnnouncementInput(index: 2, instruction: "Turn left", distanceAway: 80)))
        XCTAssertTrue(history.shouldAnnounce(TurnAnnouncementInput(index: 2, instruction: "Turn left", distanceAway: 4)))
        XCTAssertFalse(history.shouldAnnounce(TurnAnnouncementInput(index: 2, instruction: "Turn left", distanceAway: 6)))
        XCTAssertFalse(history.shouldAnnounce(TurnAnnouncementInput(index: 2, instruction: "Turn left", distanceAway: 3)))
    }

    func testGuidanceHistoryKeepsAdjacentTurnsIndependent() {
        var history = GuidanceAnnouncementHistory()
        XCTAssertTrue(history.shouldAnnounce(TurnAnnouncementInput(index: 2, instruction: "Turn left", distanceAway: 4)))
        XCTAssertTrue(history.shouldAnnounce(TurnAnnouncementInput(index: 3, instruction: "Turn right", distanceAway: 80)))
    }

    func testSpeaksImperial() {
        let turn = TurnAnnouncementInput(index: 0, instruction: "Turn left", distanceAway: 80)
        XCTAssertEqual(turnAnnouncement(turn, unit: .mi)?.text, "In 90 yards, turn left")
    }

    func testReversesTheLoop() {
        var forward = sample
        forward.steps = [
            Step(instruction: "Head along Main Street", distanceMeters: 100, durationSeconds: 60, maneuver: .code(11), road: "Main Street"),
            Step(instruction: "Turn right onto Quay Road", distanceMeters: 80, durationSeconds: 50, maneuver: .code(1), road: "Quay Road"),
            Step(instruction: "Arrive", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10)),
        ]
        let back = reverseRoute(forward)
        XCTAssertEqual(back.geometry.coordinates[0], Point(0.002, 0))
        XCTAssertEqual(back.steps.map(\.instruction), ["Head along Quay Road", "Turn left onto Main Street", "Arrive at your starting point"])
        XCTAssertEqual(back.steps.map(\.distanceMeters), [80, 100, 0])
        XCTAssertEqual(back.steps.map { turnKind($0) }, [.straight, .left, .arrive])
        XCTAssertEqual(back.reversed, true)
    }

    func testCallsTheReversedTurnWhereTheRoadActuallyForks() {
        var forward = sample
        forward.steps = [
            Step(instruction: "Head along Main Street", distanceMeters: 100, durationSeconds: 60, maneuver: .code(11), road: "Main Street"),
            Step(instruction: "Turn right onto Quay Road", distanceMeters: 80, durationSeconds: 50, maneuver: .code(1), road: "Quay Road"),
            Step(instruction: "Arrive", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10)),
        ]
        let back = reverseRoute(forward)
        XCTAssertEqual(nextTurn(back, 10)?.instruction, "Turn left onto Main Street")
        XCTAssertEqual(nextTurn(back, 10)?.distanceAway, 70)
    }

    func testReadsAnIOSCompassHeading() {
        XCTAssertEqual(headingFrom(HeadingReading(trueHeading: 90)), 90)
    }

    func testAddsTheScreenRotation() {
        XCTAssertEqual(headingFrom(HeadingReading(trueHeading: 350), angle: 90), 80)
    }

    func testFlipsAnEarthFramedAlpha() {
        XCTAssertEqual(headingFrom(HeadingReading(alpha: 90)), 270)
    }

    func testIgnoresAReadingWithNoHeadingInIt() {
        XCTAssertNil(headingFrom(HeadingReading(alpha: nil)))
    }

    func testTakesTheFirstHeadingWhole() {
        XCTAssertEqual(smoothHeading(nil, 120), 120)
    }

    func testEasesTheShortWayRoundZero() {
        XCTAssertEqual(smoothHeading(350, 10, weight: 0.5), 0)
    }

    func testMeasuresTheGapTheShortWay() {
        XCTAssertEqual(headingGap(350, 10), 20)
    }
}
