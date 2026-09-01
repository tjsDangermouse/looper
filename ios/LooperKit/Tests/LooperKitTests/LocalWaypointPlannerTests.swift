import XCTest
@testable import LooperKit

/// The waypoint planner, judged against the route service's own suite.
///
/// This is `route-service/test/waypoints.test.ts` case for case. That is the
/// point of it: the two engines are meant to spread a walker's slack the same
/// way, and the only way to know they do is to ask them the same questions and
/// require the same answers. Every case here is pure arithmetic — no graph, no
/// network, no router — which is what made the port possible and what makes
/// this suite fast enough to run on every change.
final class LocalWaypointPlannerTests: XCTestCase {

    /// The route service's fixture origin, so the numbers below are the same
    /// numbers its suite works with.
    private let origin = SyntheticOSM.douglas

    /// Metres east and north of the origin.
    private func at(east: Double, north: Double) -> Point {
        let moved = LocalGeo.destination(lat: origin.lat, lon: origin.lng, metres: north, bearing: 0)
        let placed = LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        return Point(placed.lon, placed.lat)
    }

    private func option(
        _ gap: Int, _ id: String, _ metres: Double, seconds: Double? = nil, guides: [Point] = []
    ) -> LocalWaypointPlanner.SegmentOption {
        .init(
            gap: gap, id: "\(gap)-\(id)", guides: guides,
            distanceMetres: metres, durationSeconds: seconds ?? metres / 1.39
        )
    }

    // MARK: - Placing a shaping point

    func testTheDetourIsAboutAsMuchLongerAsWasAskedFor() {
        let a = origin, b = at(east: 1000, north: 0)
        for extra in [200.0, 600, 1500] {
            let guide = LocalWaypointPlanner.guideForDetour(from: a, to: b, extraMetres: extra, side: 1)
            let viaGuide = haversine(a, guide) + haversine(guide, b)
            XCTAssertEqual(viaGuide - haversine(a, b), extra, accuracy: 5)
        }
    }

    func testTheTwoSidesAreNotTheSamePlace() {
        let a = origin, b = at(east: 1000, north: 0)
        let left = LocalWaypointPlanner.guideForDetour(from: a, to: b, extraMetres: 600, side: 1)
        let right = LocalWaypointPlanner.guideForDetour(from: a, to: b, extraMetres: 600, side: -1)
        XCTAssertGreaterThan(haversine(left, right), 100)
    }

    func testNoDetourIsEverAskedForOnTopOfTheWalkItself() {
        let a = origin, b = at(east: 1000, north: 0)
        let guide = LocalWaypointPlanner.guideForDetour(from: a, to: b, extraMetres: 0, side: 1)
        XCTAssertLessThan(haversine(a, guide) + haversine(guide, b) - haversine(a, b), 10)
    }

    /// Where the network doubles every crow-flight metre, the shaping point has
    /// to sit closer in for the walk to come out the same length.
    func testTheNetworkMakingADetourLongerIsAllowedFor() {
        let a = origin, b = at(east: 1000, north: 0)
        let flat = LocalWaypointPlanner.planSegmentOptions(gap: 0, from: a, to: b, slackForGap: 1000, networkStretch: 1)
        let stretched = LocalWaypointPlanner.planSegmentOptions(gap: 0, from: a, to: b, slackForGap: 1000, networkStretch: 2)
        func reach(_ plan: (id: String, guides: [Point])) -> Double {
            plan.guides.first.map { haversine(a, $0) } ?? 0
        }
        XCTAssertLessThan(reach(stretched[1]), reach(flat[1]))
    }

    // MARK: - What each gap is offered

    func testTheShortestWayIsAlwaysOfferedWhateverTheSlack() {
        let a = origin, b = at(east: 1000, north: 0)
        for slack in [0.0, 100, 5000] {
            XCTAssertTrue(
                LocalWaypointPlanner.planSegmentOptions(gap: 0, from: a, to: b, slackForGap: slack)[0].guides.isEmpty
            )
        }
    }

    func testNothingButTheShortestWayWhenThereIsNothingToSpend() {
        let a = origin, b = at(east: 1000, north: 0)
        XCTAssertEqual(LocalWaypointPlanner.planSegmentOptions(gap: 0, from: a, to: b, slackForGap: 0).count, 1)
        XCTAssertEqual(LocalWaypointPlanner.planSegmentOptions(gap: 0, from: a, to: b, slackForGap: -500).count, 1)
    }

    func testEachDetourSizeIsOfferedBothWaysRound() {
        let planned = LocalWaypointPlanner.planSegmentOptions(
            gap: 0, from: origin, to: at(east: 1000, north: 0), slackForGap: 1000
        )
        XCTAssertEqual(planned.count, 1 + (LocalWaypointPlanner.detourShares.count - 1) * 2)
        XCTAssertEqual(Set(planned.map(\.id)).count, planned.count)
    }

    /// Guides are shaping points between anchors, never anchors themselves.
    func testNoGuideIsEverAPlaceTheWalkerChose() {
        let a = origin, b = at(east: 1000, north: 0)
        for plan in LocalWaypointPlanner.planSegmentOptions(gap: 0, from: a, to: b, slackForGap: 1200) {
            XCTAssertLessThanOrEqual(plan.guides.count, 2)
            for guide in plan.guides {
                XCTAssertNotEqual(guide, a)
                XCTAssertNotEqual(guide, b)
            }
        }
    }

    // MARK: - Spending the slack

    func testTheCombinationThatAddsUpToTheWalkAskedForIsPicked() {
        let allocations = LocalWaypointPlanner.allocateSlack([
            [option(0, "short", 1000), option(0, "long", 2000)],
            [option(1, "short", 1000), option(1, "long", 3000)],
        ], options: .init(target: 4000))
        XCTAssertEqual(allocations.first?.total, 4000)
        XCTAssertEqual(allocations.first?.error, 0)
    }

    /// Three combinations come to exactly 3 km. Two spend their whole detour in
    /// a single gap; one splits it. Splitting it is the better walk.
    func testTheDetourIsSpreadRatherThanDumpedInOneGap() {
        let allocations = LocalWaypointPlanner.allocateSlack([
            [option(0, "short", 1000), option(0, "mid", 1500), option(0, "long", 2000)],
            [option(1, "short", 1000), option(1, "mid", 1500), option(1, "long", 2000)],
        ], options: .init(target: 3000, limit: 4))
        XCTAssertEqual(allocations[0].error, 0)
        XCTAssertEqual(allocations[0].chosen.map(\.id), ["0-mid", "1-mid"])
        XCTAssertEqual(allocations[0].concentration, 0.5, accuracy: 1e-9)
    }

    /// A steep option and a flat one, deliberately not proportional: the steep
    /// way round is the shorter walk and the longer one.
    func testWhicheverQuantityTheWalkerAskedForIsWhatIsAddedUp() {
        let gaps = [
            [option(0, "flat", 2000, seconds: 1440), option(0, "steep", 1500, seconds: 1800)],
            [option(1, "flat", 2000, seconds: 1440), option(1, "steep", 1500, seconds: 1800)],
        ]
        let byTime = LocalWaypointPlanner.allocateSlack(gaps, options: .init(
            target: 3600, bucketSize: 90, measure: { $0.durationSeconds }
        ))
        XCTAssertEqual(byTime.first?.chosen.map(\.id), ["0-steep", "1-steep"])
        XCTAssertEqual(byTime.first?.error, 0)

        // The same ground asked for in metres wants the other pair entirely.
        let byDistance = LocalWaypointPlanner.allocateSlack(gaps, options: .init(target: 4000))
        XCTAssertEqual(byDistance.first?.chosen.map(\.id), ["0-flat", "1-flat"])
        XCTAssertEqual(byDistance.first?.error, 0)
    }

    /// Every option is the same length; only the time differs. Measured in
    /// metres nothing is a detour at all, so nothing can be concentrated.
    func testLopsidednessIsMeasuredInThatSameQuantity() {
        let gaps = [
            [option(0, "quick", 1000, seconds: 600), option(0, "slow", 1000, seconds: 1200)],
            [option(1, "quick", 1000, seconds: 600), option(1, "slow", 1000, seconds: 1200)],
        ]
        let byTime = LocalWaypointPlanner.allocateSlack(gaps, options: .init(
            target: 1800, bucketSize: 60, measure: { $0.durationSeconds }
        ))
        XCTAssertEqual(byTime.first?.total, 1800)
        XCTAssertEqual(byTime.first?.concentration, 1)
    }

    func testSeveralDifferentWaysOfSpendingItAreOffered() {
        let gaps = (0..<3).map { gap in [200.0, 400, 600, 800].map { option(gap, "\(Int($0))", $0) } }
        let allocations = LocalWaypointPlanner.allocateSlack(gaps, options: .init(target: 1500, limit: 5))
        XCTAssertGreaterThan(allocations.count, 1)
        XCTAssertEqual(Set(allocations.map(\.key)).count, allocations.count)
    }

    func testEveryGapIsKeptInOrderExactlyOnce() {
        let gaps = (0..<4).map { gap in [500.0, 900].map { option(gap, "\(Int($0))", $0) } }
        for allocation in LocalWaypointPlanner.allocateSlack(gaps, options: .init(target: 2800, limit: 4)) {
            XCTAssertEqual(allocation.chosen.map(\.gap), [0, 1, 2, 3])
        }
    }

    func testTheSameAnswerComesBackEveryTime() {
        let gaps = (0..<3).map { gap in [300.0, 500, 900].map { option(gap, "\(Int($0))", $0) } }
        let once = LocalWaypointPlanner.allocateSlack(gaps, options: .init(target: 1800, limit: 4))
        let twice = LocalWaypointPlanner.allocateSlack(gaps, options: .init(target: 1800, limit: 4))
        XCTAssertEqual(twice, once)
    }

    func testTheAnswerDoesNotDependOnTheOrderTheOptionsCameIn() {
        let forwards = (0..<2).map { gap in [300.0, 700, 1100].map { option(gap, "\(Int($0))", $0) } }
        let backwards = forwards.map { $0.reversed().map { $0 } }
        XCTAssertEqual(
            LocalWaypointPlanner.allocateSlack(backwards, options: .init(target: 1400, limit: 3)).map(\.key),
            LocalWaypointPlanner.allocateSlack(forwards, options: .init(target: 1400, limit: 3)).map(\.key)
        )
    }

    /// Sixty-one thousand combinations; a bounded table and six answers.
    func testItStaysBoundedHoweverManyOptionsItIsHanded() {
        let gaps = (0..<5).map { gap in (0..<11).map { option(gap, "o\($0)", 200 + Double($0) * 130) } }
        let allocations = LocalWaypointPlanner.allocateSlack(gaps, options: .init(target: 5000, limit: 6))
        XCTAssertLessThanOrEqual(allocations.count, 6)
        XCTAssertTrue(allocations.allSatisfy { $0.chosen.count == 5 })
    }

    func testNothingIsAnsweredWhenAGapHasNoWayAcrossItAtAll() {
        XCTAssertTrue(LocalWaypointPlanner.allocateSlack(
            [[option(0, "a", 500)], []], options: .init(target: 1000)
        ).isEmpty)
        XCTAssertTrue(LocalWaypointPlanner.allocateSlack([], options: .init(target: 1000)).isEmpty)
    }

    // MARK: - Choosing between combinations

    private func allocation(_ ids: [String], error: Double) -> LocalWaypointPlanner.Allocation {
        .init(
            chosen: ids.enumerated().map { gap, id in
                .init(gap: gap, id: id, guides: [], distanceMetres: 100, durationSeconds: 72)
            },
            total: 100 * Double(ids.count), error: error, concentration: 0, shape: 0
        )
    }

    func testHowManyGapsTwoCombinationsDisagreeAboutIsCounted() {
        XCTAssertEqual(LocalWaypointPlanner.gapsDiffering(
            between: allocation(["a", "b", "c"], error: 0), and: allocation(["a", "b", "c"], error: 0)
        ), 0)
        XCTAssertEqual(LocalWaypointPlanner.gapsDiffering(
            between: allocation(["a", "b", "c"], error: 0), and: allocation(["a", "x", "y"], error: 0)
        ), 2)
    }

    func testTheClosestComesFirstThenWhateverIsMostUnlikeIt() {
        let spread = LocalWaypointPlanner.spreadAllocations([
            allocation(["a", "b", "c"], error: 0),
            allocation(["a", "b", "x"], error: 10),
            allocation(["p", "q", "r"], error: 20),
        ], limit: 2)
        XCTAssertEqual(spread[0].chosen.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(spread[1].chosen.map(\.id), ["p", "q", "r"])
    }

    func testItNeverReturnsMoreThanItWasAskedForOrInventsOne() {
        XCTAssertTrue(LocalWaypointPlanner.spreadAllocations([], limit: 3).isEmpty)
        XCTAssertEqual(LocalWaypointPlanner.spreadAllocations([allocation(["a"], error: 0)], limit: 3).count, 1)
    }

    // MARK: - Whether it fits the plan

    func testABackboneComfortablyInsideThePlanIsAccepted() {
        XCTAssertTrue(LocalWaypointPlanner.fitsInPlan(backbone: 4000, target: 5000, maxErrorFraction: 0.25))
    }

    func testOneOverByLessThanTheToleranceAllowsIsAccepted() {
        XCTAssertTrue(LocalWaypointPlanner.fitsInPlan(backbone: 5000 * 1.25, target: 5000, maxErrorFraction: 0.25))
        XCTAssertTrue(LocalWaypointPlanner.fitsInPlan(
            backbone: 5000 * 1.25 * (1 + LocalWaypointPlanner.feasibilityTolerance) - 1,
            target: 5000, maxErrorFraction: 0.25
        ))
    }

    func testOneThatIsGenuinelyTooLongIsRefused() {
        XCTAssertFalse(LocalWaypointPlanner.fitsInPlan(backbone: 9000, target: 5000, maxErrorFraction: 0.25))
    }

    /// Exactly on the limit is inside it: refusing costs a walker their walk.
    func testTheWalkerGetsTheBenefitOfTheDoubtAtTheBoundary() {
        let exactly = 5000 * 1.25
        XCTAssertTrue(LocalWaypointPlanner.fitsInPlan(backbone: exactly, target: 5000, maxErrorFraction: 0.25))
        XCTAssertFalse(LocalWaypointPlanner.fitsInPlan(
            backbone: exactly * (1 + LocalWaypointPlanner.feasibilityTolerance * 2),
            target: 5000, maxErrorFraction: 0.25
        ))
    }

    func testAPlanOfNothingIsRefusedRatherThanDividedBy() {
        XCTAssertFalse(LocalWaypointPlanner.fitsInPlan(backbone: 1000, target: 0, maxErrorFraction: 0.25))
    }

    // MARK: - The shape a combination plans

    /// Measured on real ground, `shapeless` killed 18 of 24 assembled waypoint
    /// walks and `u-turns` another 14 — while the best-fitting combination by
    /// length enclosed no area at all. Length was never the problem.
    func testTheShapingPointsAreThreadedBetweenTheAnchorsInOrder() {
        let start = origin, pin = at(east: 800, north: 0)
        let guide = at(east: 400, north: 600)
        let ring = LocalWaypointPlanner.ringOf(anchors: [start, pin, start], chosen: [
            option(0, "out", 1500, guides: [guide]), option(1, "back", 1500),
        ])
        XCTAssertEqual(ring, [start, guide, pin, start])
    }

    /// Both gaps bulge to the same side of the line out: the walk goes out and
    /// comes back over itself, which is exactly what fails the shape gate.
    func testAPlanThatDoublesBackOnItselfEnclosesNothing() {
        let start = origin, pin = at(east: 800, north: 0)
        let sameSide = LocalWaypointPlanner.ringShapeOf(anchors: [start, pin, start], chosen: [
            option(0, "out", 1500, guides: [at(east: 400, north: 500)]),
            option(1, "back", 1500, guides: [at(east: 400, north: 500)]),
        ])
        XCTAssertLessThan(sameSide, 0.05)
    }

    func testAPlanThatGoesOutOneWayAndBackAnotherEnclosesGround() {
        let start = origin, pin = at(east: 800, north: 0)
        let opposite = LocalWaypointPlanner.ringShapeOf(anchors: [start, pin, start], chosen: [
            option(0, "out", 1500, guides: [at(east: 400, north: 500)]),
            option(1, "back", 1500, guides: [at(east: 400, north: -500)]),
        ])
        XCTAssertGreaterThan(opposite, 0.4)
    }

    /// 1500 + 1500 = 3000 is the exact fit and encloses nothing; 1500 + 1600
    /// misses by 100 m and is a proper loop.
    func testASlightlyWorseFitThatIsALoopBeatsAPerfectFitThatIsNot() {
        let start = origin, pin = at(east: 800, north: 0)
        let byGap = [
            [option(0, "flat", 1500, guides: [at(east: 400, north: 500)]),
             option(0, "wide", 1900, guides: [at(east: 400, north: 900)])],
            [option(1, "same", 1500, guides: [at(east: 400, north: 500)]),
             option(1, "other", 1600, guides: [at(east: 400, north: -500)])],
        ]
        let best = LocalWaypointPlanner.allocateSlack(
            byGap, anchors: [start, pin, start], options: .init(target: 3000, limit: 4)
        ).first
        XCTAssertEqual(best?.chosen.map(\.id), ["0-flat", "1-other"])
        XCTAssertGreaterThan(best?.shape ?? 0, 0.4)
    }

    /// A pin down a single lane has no loop in it. Refusing everything would
    /// offer the walker nothing where a there-and-back is the honest answer.
    func testItStillAnswersWhenNothingAvailableEnclosesAnything() {
        let start = origin, pin = at(east: 800, north: 0)
        let byGap = [
            [option(0, "out", 1500, guides: [at(east: 400, north: 20)])],
            [option(1, "back", 1500, guides: [at(east: 400, north: 20)])],
        ]
        XCTAssertEqual(LocalWaypointPlanner.allocateSlack(
            byGap, anchors: [start, pin, start], options: .init(target: 3000, limit: 4)
        ).count, 1)
    }

    func testNothingIsScoredRatherThanGuessedWhenNoAnchorsWereSupplied() {
        let byGap = [[option(0, "a", 1500)], [option(1, "b", 1500)]]
        XCTAssertEqual(LocalWaypointPlanner.allocateSlack(byGap, options: .init(target: 3000)).first?.shape, 0)
    }
}
