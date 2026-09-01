import Foundation

/// Cutting the noise out of a walk assembled from legs.
///
/// A port of the route service's `trimTinySpikes`, and it exists here for the
/// reason it exists there, recorded in its own comment: *"Joining without
/// trimming leaves the short dead-end branches that the ground genuinely
/// offers no way round, and the quality engine then refuses the whole walk for
/// a forty-metre duck into a driveway. That is what happened to waypoint
/// walks, in both generators, for as long as they have existed: they joined
/// and did not trim, and `out-and-back-spur` threw out twenty of every
/// twenty-four."*
///
/// Leaving it out here reproduced that number exactly: `out-and-back-spur` and
/// `u-turns` between them refused seven of every eight waypoint requests.
///
/// ## Why this is not the reversal cancelling in `LocalLegRouter`
///
/// That one removes a leg walked immediately back the other way — the same
/// edge, exactly reversed. It is exact and it is cheap, and it catches only
/// the tidiest case. What the gate actually objects to is broader: a duck into
/// a turning circle, a loop round a tiny block, a pair of parallel alleys
/// walked out and back. None of those retrace an edge, and all of them read as
/// backtracking. So this works on geometry, as the service does, and by the
/// service's rules.
///
/// ## Pins are never trimmed
///
/// A splice may not reach past a place the walker chose. A walk that no longer
/// passes a pin is not the walk that was asked for, however tidy the geometry
/// reads afterwards — and a pin at the tip of a short cul-de-sac is exactly
/// the shape this is looking for, so that is the common case rather than the
/// corner one.
public enum LocalSpikeTrim {
    /// Beyond this round trip a backtrack is a feature of the walk rather than
    /// noise in it, and is left alone for the gate to judge.
    public static let roundTripMetres: Double = 80
    /// How close the walk has to come back to a point to have come back to it.
    public static let matchMetres: Double = 15
    /// Beyond this angle the walk genuinely reversed, rather than merely
    /// curving near itself — a tight corner, a turning circle and a narrow
    /// zigzag all bring two points close together without either being a
    /// backtrack.
    public static let angleDegrees: Double = 150
    /// A ceiling on what one walk may lose in total, nesting included. A walk
    /// that is fundamentally an out-and-back would otherwise have almost all of
    /// itself trimmed away pass after pass. Comfortably below
    /// `RouteQuality.minBacktrackMetres`: this is for noise, not for deciding
    /// whether a real feature belongs in the walk.
    public static let maximumTotalMetres: Double = 300

    /// Trim `legs`, keeping every point in `protecting` on the walk.
    ///
    /// Repeated until it settles rather than a fixed number of passes: a
    /// detour off a detour — into a cul-de-sac, then into a driveway off it,
    /// and all the way back out — is a longer round trip than the window
    /// allows in one look, even though each of its two turn-arounds is short
    /// on its own. One pass resolves the inner one; a repeat resolves what is
    /// left of the outer one now that the ground between its ends is shorter.
    /// Bounded by the walk only ever getting shorter, never by a count.
    public static func trimming(_ legs: [WalkLeg], protecting pins: [Point]) -> [WalkLeg] {
        let originalMetres = legs.reduce(0) { $0 + $1.metres }
        var current = legs
        while true {
            let next = onePass(current, protecting: pins)
            if next.count == current.count { return next }
            if originalMetres - next.reduce(0, { $0 + $1.metres }) > maximumTotalMetres { return current }
            current = next
        }
    }

    /// One pass, at the resolution the survey actually has.
    ///
    /// Worth stating because getting it wrong makes this whole file do
    /// nothing: the scan runs over the walk's *vertices*, not over its legs. A
    /// leg is one graph edge and is fifty to a hundred and fifty metres of
    /// street, so at leg resolution an eighty-metre round trip never fits
    /// inside the window and not one spike is ever found. The service scans
    /// GraphHopper's polyline, whose vertices are metres apart, and this has
    /// to scan the same ground the same way. The legs are then rebuilt from
    /// the vertices that survived, so geometry, instructions and the edges the
    /// gate measures retracing on all continue to describe one walk.
    private static func onePass(_ legs: [WalkLeg], protecting pins: [Point]) -> [WalkLeg] {
        guard legs.count >= 2 else { return legs }

        // Flatten to vertices. `owner[v]` is the leg the walk was on when it
        // arrived at vertex `v`; vertex 0 was never arrived at.
        var vertices: [Point] = []
        var owner: [Int] = []
        for (index, leg) in legs.enumerated() {
            for point in leg.coordinates {
                if vertices.last == point { continue }
                if vertices.isEmpty { owner.append(-1) } else { owner.append(index) }
                vertices.append(point)
            }
        }
        guard vertices.count > 3 else { return legs }

        let protectedIndices = protectedBoundaries(vertices, pins: pins)
        let reversalLimit = cos(angleDegrees * .pi / 180)
        var keep = [Bool](repeating: true, count: vertices.count)

        var i = 0
        while i < vertices.count - 2 {
            guard keep[i] else { i += 1; continue }
            // The segment leaving `i`, against the segment arriving at each
            // candidate `j`: for a genuine out-and-back these point opposite
            // ways, because leaving `j`'s match reverses however `i` was left.
            // A path merely curving close to itself — a tight corner, a
            // turning circle, a narrow zigzag — keeps heading roughly the same
            // way through both, and is left alone.
            guard let leaving = direction(from: vertices[i], to: vertices[i + 1]) else { i += 1; continue }
            // Splicing at `j` removes everything from `i + 1` to `j`, so the
            // first pin lying ahead of `i` is a ceiling on how far this splice
            // may reach.
            let firstProtectedAhead = protectedIndices.first { $0 > i } ?? Int.max
            var pathMetres = 0.0
            var spliceAt = -1
            var j = i + 2
            // The last point is where the walk closes back on the start; it is
            // never a spike to be spliced away, whatever it sits near.
            while j < vertices.count - 1 && j < firstProtectedAhead {
                pathMetres += LocalGeo.distance(
                    lat1: vertices[j - 1].lat, lon1: vertices[j - 1].lng,
                    lat2: vertices[j].lat, lon2: vertices[j].lng
                )
                if pathMetres > roundTripMetres { break }
                defer { j += 1 }
                let apart = LocalGeo.distance(
                    lat1: vertices[i].lat, lon1: vertices[i].lng,
                    lat2: vertices[j].lat, lon2: vertices[j].lng
                )
                guard apart < matchMetres, let arriving = direction(from: vertices[j - 1], to: vertices[j]) else { continue }
                if leaving.x * arriving.x + leaving.y * arriving.y < reversalLimit { spliceAt = j }
            }
            if spliceAt > i {
                for k in (i + 1)...spliceAt { keep[k] = false }
                i = spliceAt + 1
            } else {
                i += 1
            }
        }
        guard keep.contains(false) else { return legs }

        // Rebuild the legs from what survived. A run of consecutive kept
        // vertices that arrived on the same leg is that leg, as much of it as
        // the walk still covers; a leg with nothing left of it is ground the
        // walk no longer treads and is dropped rather than collapsed onto a
        // point, so it stops counting as walked.
        var rebuilt: [WalkLeg] = []
        var runStart: Point?
        var runPoints: [Point] = []
        var runOwner = -1
        var runMetres = 0.0

        func flush() {
            guard runOwner >= 0, runPoints.count >= 2 else { runPoints = []; return }
            let source = legs[runOwner]
            // An untouched leg keeps the graph's own recorded length; a cut one
            // is measured from what is left, as the service measures its own.
            let untouched = runPoints.count == source.coordinates.count
            rebuilt.append(WalkLeg(
                coordinates: runPoints, metres: untouched ? source.metres : runMetres,
                name: source.name, roadClass: source.roadClass, physical: source.physical
            ))
            runPoints = []
            runMetres = 0
        }

        for index in vertices.indices where keep[index] {
            let point = vertices[index]
            if let previous = runStart {
                let step = LocalGeo.distance(lat1: previous.lat, lon1: previous.lng, lat2: point.lat, lon2: point.lng)
                if owner[index] != runOwner {
                    flush()
                    runOwner = owner[index]
                    runPoints = [previous]
                }
                runPoints.append(point)
                runMetres += step
            } else {
                runOwner = owner.indices.contains(index + 1) ? owner[index + 1] : -1
                runPoints = [point]
            }
            runStart = point
        }
        flush()
        return rebuilt
    }

    /// Where on the walk each place the walker insisted on actually falls.
    ///
    /// A pin is an end of the leg that arrives at it, so it is one of these
    /// boundaries rather than merely near one; the nearest search is for the
    /// metre or two of snapping between what was asked for and what the
    /// network offered, not for a genuine search. Sorted, so the scan above
    /// can ask for the first one ahead of a point and stop looking.
    static func protectedBoundaries(_ boundary: [Point], pins: [Point]) -> [Int] {
        guard !pins.isEmpty else { return [] }
        var found: Set<Int> = []
        for pin in pins {
            var bestIndex = -1
            var bestMetres = Double.infinity
            for (index, point) in boundary.enumerated() {
                let away = LocalGeo.distance(lat1: point.lat, lon1: point.lng, lat2: pin.lat, lon2: pin.lng)
                if away < bestMetres {
                    bestMetres = away
                    bestIndex = index
                }
            }
            if bestIndex >= 0 { found.insert(bestIndex) }
        }
        return found.sorted()
    }

    private static func direction(from: Point, to: Point) -> (x: Double, y: Double)? {
        let scale = cos(from.lat * .pi / 180)
        let dx = (to.lng - from.lng) * scale, dy = to.lat - from.lat
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return nil }
        return (dx / length, dy / length)
    }
}
