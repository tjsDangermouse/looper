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

private final class MockLoopsHTTPClient: LoopsHTTPClient {
    private(set) var lastURL: URL?
    private(set) var lastBody: [String: Any] = [:]
    private let responseData: Data
    private let statusCode: Int

    init(responseJSON: [String: Any], statusCode: Int = 200) {
        self.responseData = try! JSONSerialization.data(withJSONObject: responseJSON)
        self.statusCode = statusCode
    }

    init(malformedResponseWithStatusCode statusCode: Int) {
        self.responseData = Data("not json".utf8)
        self.statusCode = statusCode
    }

    func post(url: URL, body: Data) async throws -> (data: Data, statusCode: Int) {
        lastURL = url
        lastBody = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        return (responseData, statusCode)
    }
}

final class AskingLooperForLoopsTests: XCTestCase {
    private let start = Point(-4.4816, 54.1506)

    func testSendsTheWalkersOwnNumbersToLooperAndNowhereElse() async throws {
        let client = MockLoopsHTTPClient(responseJSON: ["routes": []])
        _ = try await requestLoops(start: start, mode: .distance, distanceKm: 4, unit: .km, variation: 0, apiBase: "", client: client)
        XCTAssertEqual(client.lastURL?.path, "/v1/loops")
        let body = client.lastBody
        XCTAssertEqual(body["mode"] as? String, "distance")
        XCTAssertEqual(body["distanceKm"] as? Double, 4)
        XCTAssertNil(body["durationMinutes"])
        XCTAssertEqual(body["units"] as? String, "km")
        XCTAssertEqual(body["variation"] as? Int, 0)
        let startBody = body["start"] as? [String: Double]
        XCTAssertEqual(startBody?["lng"], -4.4816)
        XCTAssertEqual(startBody?["lat"], 54.1506)
    }

    func testSendsMinutesInTimeModeAndNoDistance() async throws {
        let client = MockLoopsHTTPClient(responseJSON: ["routes": []])
        _ = try await requestLoops(start: start, mode: .time, durationMinutes: 45, unit: .mi, variation: 2, apiBase: "", client: client)
        let body = client.lastBody
        XCTAssertEqual(body["mode"] as? String, "time")
        XCTAssertEqual(body["durationMinutes"] as? Double, 45)
        XCTAssertNil(body["distanceKm"])
        XCTAssertEqual(body["units"] as? String, "mi")
    }

    func testSendsDisplayedLoopsAsRefreshExclusions() async throws {
        let client = MockLoopsHTTPClient(responseJSON: ["routes": []])
        let route = Route(id: "r1", name: "North loop", distanceMeters: 100, durationSeconds: 60, targetDifferencePercent: 0, geometry: LineGeometry(coordinates: [Point(0, 0), Point(0.001, 0)]), steps: [])
        _ = try await requestLoops(start: start, mode: .distance, distanceKm: 4, unit: .km, variation: 3, excludeRoutes: [route], apiBase: "", client: client)
        let excluded = client.lastBody["exclude"] as? [[[Double]]]
        XCTAssertEqual(excluded, [[[0, 0], [0.001, 0]]])
    }

    func testSendsWaypointsInTheirMapOrder() async throws {
        let client = MockLoopsHTTPClient(responseJSON: ["routes": []])
        let waypoints = [Point(-4.47, 54.16), Point(-4.46, 54.15)]
        _ = try await requestLoops(start: start, mode: .distance, distanceKm: 4, unit: .km, variation: 0, waypoints: waypoints, apiBase: "", client: client)
        let sent = client.lastBody["waypoints"] as? [[String: Double]]
        XCTAssertEqual(sent?[0]["lng"], -4.47)
        XCTAssertEqual(sent?[1]["lat"], 54.15)
    }

    func testCarriesTheExpectationWarningFlag() async throws {
        let client = MockLoopsHTTPClient(responseJSON: [
            "routes": [],
            "warning": "Increase your plan or remove a waypoint.",
            "expectationExceeded": true,
        ])
        let result = try await requestLoops(start: start, mode: .distance, distanceKm: 4, unit: .km, variation: 0, apiBase: "", client: client)
        XCTAssertTrue(result.expectationExceeded)
    }

    func testNamesEachLoopForTheWalker() async throws {
        let route: [String: Any] = [
            "id": "r1", "label": "North loop", "distanceMeters": 4000, "durationSeconds": 2880,
            "targetDifferencePercent": 0,
            "geometry": ["type": "LineString", "coordinates": [[0, 0], [0.001, 0]]],
            "steps": [],
        ]
        let client = MockLoopsHTTPClient(responseJSON: ["routes": [route]])
        let result = try await requestLoops(start: start, mode: .distance, distanceKm: 4, unit: .km, variation: 0, apiBase: "", client: client)
        XCTAssertEqual(result.routes.first?.name, "North loop")
        XCTAssertEqual(result.routes.first?.geometry.coordinates.count, 2)
    }

    func testPassesOnTheMessageWhenThereIsNoCleanLoop() async throws {
        let warning = "We couldn't find a clean loop of that length from here. Try a different distance or move the start point."
        let client = MockLoopsHTTPClient(responseJSON: ["routes": [], "warning": warning])
        let result = try await requestLoops(start: start, mode: .distance, distanceKm: 4, unit: .km, variation: 0, apiBase: "", client: client)
        XCTAssertEqual(result.routes.count, 0)
        XCTAssertEqual(result.warning, warning)
    }

    func testShowsTheServicesOwnWordsWhenItRefuses() async throws {
        let client = MockLoopsHTTPClient(responseJSON: ["error": "Please wait a moment before finding more loops."], statusCode: 429)
        do {
            _ = try await requestLoops(start: start, mode: .distance, distanceKm: 4, unit: .km, variation: 0, apiBase: "", client: client)
            XCTFail("expected requestLoops to throw")
        } catch let LooperAPIError.message(text) {
            XCTAssertEqual(text, "Please wait a moment before finding more loops.")
        }
    }

    func testSaysSomethingPlainWhenTheAnswerIsNotReadable() async throws {
        let client = MockLoopsHTTPClient(malformedResponseWithStatusCode: 500)
        do {
            _ = try await requestLoops(start: start, mode: .distance, distanceKm: 4, unit: .km, variation: 0, apiBase: "", client: client)
            XCTFail("expected requestLoops to throw")
        } catch let LooperAPIError.message(text) {
            XCTAssertEqual(text, "Routes are unavailable right now.")
        }
    }
}
