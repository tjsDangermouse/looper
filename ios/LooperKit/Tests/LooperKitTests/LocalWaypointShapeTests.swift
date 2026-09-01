import XCTest
@testable import LooperKit

/// The three pieces that decide whether a waypoint walk is offered at all.
///
/// Each of them was, at some point in this work, the single reason seven of
/// every eight requests came back with nothing. They are subtle in the way
/// that geometry is subtle — every one of them looked right and measured
/// wrong — so each is pinned here by the behaviour that actually matters
/// rather than by its internals.
final class LocalWaypointShapeTests: XCTestCase {

    private let origin = SyntheticOSM.douglas

    private func at(east: Double, north: Double) -> Point {
        let moved = LocalGeo.destination(lat: origin.lat, lon: origin.lng, metres: north, bearing: 0)
        let placed = LocalGeo.destination(lat: moved.lat, lon: moved.lon, metres: east, bearing: 90)
        return Point(placed.lon, placed.lat)
    }

    private func leg(_ from: Point, _ to: Point, physical: Int32, name: String? = nil) -> WalkLeg {
        WalkLeg(
            coordinates: [from, to], metres: haversine(from, to),
            name: name, roadClass: .residential, physical: physical
        )
    }

    // MARK: - Trimming short spikes

    /// The failure this whole file exists for: a walk that ducks forty metres
    /// into a driveway and back is refused entire by the gate, for a detour
    /// no walker would even notice.
    func testAShortDuckIntoADeadEndIsCutOut() {
        let a = at(east: 0, north: 0), b = at(east: 100, north: 0)
        let tip = at(east: 120, north: 30), c = at(east: 300, north: 0)
        let walk = [
            leg(a, b, physical: 1),
            leg(b, tip, physical: 2),
            leg(tip, b, physical: 2),
            leg(b, c, physical: 3),
        ]
        XCTAssertEqual(LocalSpikeTrim.trimming(walk, protecting: []).map(\.physical), [1, 3])
    }

    /// And the opposite, which matters just as much: a pier, a headland, a
    /// towpath with no way back is the walk, not noise in it.
    func testALongOutAndBackIsLeftAlone() {
        let a = at(east: 0, north: 0), b = at(east: 100, north: 0)
        let tip = at(east: 100, north: 600), c = at(east: 300, north: 0)
        let walk = [
            leg(a, b, physical: 1),
            leg(b, tip, physical: 2),
            leg(tip, b, physical: 2),
            leg(b, c, physical: 3),
        ]
        XCTAssertEqual(LocalSpikeTrim.trimming(walk, protecting: []).count, 4)
    }

    /// A walk merely passing close to itself — a tight corner, a turning
    /// circle, a narrow zigzag — has not backtracked and must survive.
    func testATightCornerIsNotASpike() {
        let walk = [
            leg(at(east: 0, north: 0), at(east: 100, north: 0), physical: 1),
            leg(at(east: 100, north: 0), at(east: 105, north: 10), physical: 2),
            leg(at(east: 105, north: 10), at(east: 105, north: 200), physical: 3),
        ]
        XCTAssertEqual(LocalSpikeTrim.trimming(walk, protecting: []).count, 3)
    }

    /// Asked to, the trim keeps its hands off a place the walker chose — even
    /// though that place is exactly the shape it hunts for.
    func testAProtectedPinSurvivesATrimThatWouldOtherwiseCutIt() {
        let a = at(east: 0, north: 0), b = at(east: 100, north: 0)
        let pin = at(east: 120, north: 30), c = at(east: 300, north: 0)
        let walk = [
            leg(a, b, physical: 1),
            leg(b, pin, physical: 2),
            leg(pin, b, physical: 2),
            leg(b, c, physical: 3),
        ]
        XCTAssertEqual(LocalSpikeTrim.trimming(walk, protecting: [pin]).count, 4)
        XCTAssertEqual(LocalSpikeTrim.trimming(walk, protecting: []).count, 2, "the premise")
    }

    // MARK: - What a pin forced

    /// A pin down a lane makes the walk cover that lane twice. That is the
    /// walk that was asked for, and the gate is told so.
    func testGroundAPinForcedTheWalkToCoverTwiceIsMeasured() {
        let a = at(east: 0, north: 0), b = at(east: 100, north: 0)
        let pin = at(east: 100, north: 200), c = at(east: 300, north: 0)
        let walk = [
            leg(a, b, physical: 1),
            leg(b, pin, physical: 2),
            leg(pin, b, physical: 2),
            leg(b, c, physical: 3),
        ]
        let forced = LocalLoopRouter.spurForced(by: [pin], in: walk)
        XCTAssertEqual(forced.metres, 400, accuracy: 5, "the lane, both ways")
        XCTAssertEqual(forced.turns, 1)
    }

    /// A pin in the middle of a proper loop forced nothing, so it is forgiven
    /// nothing. Without this the excuse would be a general amnesty on
    /// retracing, which is not what it is for.
    func testAPinThatForcedNothingIsExcusedNothing() {
        let pin = at(east: 200, north: 0)
        let walk = [
            leg(at(east: 0, north: 0), at(east: 100, north: 0), physical: 1),
            leg(at(east: 100, north: 0), pin, physical: 2),
            leg(pin, at(east: 300, north: 0), physical: 3),
            leg(at(east: 300, north: 0), at(east: 400, north: 0), physical: 4),
        ]
        let forced = LocalLoopRouter.spurForced(by: [pin], in: walk)
        XCTAssertEqual(forced.metres, 0)
        XCTAssertEqual(forced.turns, 0)
    }

    /// The excuse is exactly as large as it was shown to be, and no larger.
    func testTheGateForgivesOnlyWhatItWasToldWasForced() {
        // A long thin there-and-back down one street: retraced, and short
        // enough that the gate calls it a spur rather than a feature.
        var line: [Point] = []
        for step in stride(from: 0.0, through: 300, by: 15) { line.append(at(east: step, north: 0)) }
        for step in stride(from: 300.0, through: 0, by: -15) { line.append(at(east: step, north: 2)) }
        var traversals: [RouteQuality.EdgeTraversal] = []
        for index in 0..<10 {
            traversals.append(RouteQuality.EdgeTraversal(
                id: Int32(index), metres: 30, along: Double(index) * 30, dirX: 1, dirY: 0
            ))
        }
        for index in stride(from: 9, through: 0, by: -1) {
            let along: Double = 300 + Double(9 - index) * 30
            traversals.append(RouteQuality.EdgeTraversal(
                id: Int32(index), metres: 30, along: along, dirX: -1, dirY: 0
            ))
        }
        let charged = RouteQuality.analyse(
            coordinates: line, start: line[0], distanceMetres: 600, targetMetres: 600, traversals: traversals
        )
        XCTAssertTrue(charged.rejections.contains("out-and-back-spur"), "the premise: this is refused when charged")

        let forgiven = RouteQuality.analyse(
            coordinates: line, start: line[0], distanceMetres: 600, targetMetres: 600, traversals: traversals,
            excusedRetraceMetres: 600, excusedUTurns: 1
        )
        XCTAssertFalse(forgiven.rejections.contains("out-and-back-spur"))

        // Forgiving a fraction of it forgives only that fraction.
        let partly = RouteQuality.analyse(
            coordinates: line, start: line[0], distanceMetres: 600, targetMetres: 600, traversals: traversals,
            excusedRetraceMetres: 50
        )
        XCTAssertTrue(partly.rejections.contains("out-and-back-spur"))
    }

    /// The ring search must be untouched by any of this: a plain loop is
    /// judged exactly as it was before waypoints existed.
    func testAPlainLoopIsJudgedExactlyAsBefore() {
        var line: [Point] = []
        for degrees in stride(from: 0.0, to: 360, by: 10) {
            let point = LocalGeo.destination(lat: origin.lat, lon: origin.lng, metres: 300, bearing: degrees)
            line.append(Point(point.lon, point.lat))
        }
        line.append(line[0])
        let metres = 2 * Double.pi * 300
        XCTAssertEqual(
            RouteQuality.analyse(coordinates: line, start: line[0], distanceMetres: metres, targetMetres: metres).rejections,
            RouteQuality.analyse(
                coordinates: line, start: line[0], distanceMetres: metres, targetMetres: metres,
                excusedRetraceMetres: 0, excusedUTurns: 0
            ).rejections
        )
    }
}
