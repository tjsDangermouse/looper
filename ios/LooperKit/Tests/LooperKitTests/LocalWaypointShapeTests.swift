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

    // The gate's cul-de-sac / pin-spur excusals (`spurForced`,
    // `excusedRetraceMetres`, `excusedUTurns`) were reverted for parity with
    // the remote engine, which has no such thing — it relies on the trim above
    // plus its wider waypoint distance tolerance. See LOOPER_PARITY_AUDIT.md
    // items B2/B3. Their tests were removed with the behaviour.
}
