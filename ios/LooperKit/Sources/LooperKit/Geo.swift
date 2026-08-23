import Foundation

public func haversine(_ a: Point, _ b: Point) -> Double {
    let r = 6371000.0, rad = Double.pi / 180
    let dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad
    let x = pow(sin(dLat / 2), 2) + cos(a.lat * rad) * cos(b.lat * rad) * pow(sin(dLng / 2), 2)
    return 2 * r * atan2(sqrt(x), sqrt(1 - x))
}

private func cumulative(_ coords: [Point]) -> [Double] {
    var out = [0.0]
    for i in 1..<coords.count {
        out.append(out[i - 1] + haversine(coords[i - 1], coords[i]))
    }
    return out
}

private struct SegmentProjection {
    var along: Double
    var portion: Double
    var distance: Double
}

/// Distance to a segment and how far along it the foot of the perpendicular
/// falls, in metres on a local flat frame — ample over one segment's span.
private func projectOnSegment(_ p: Point, _ a: Point, _ b: Point) -> SegmentProjection {
    let m = 6371000.0 * Double.pi / 180, scale = cos(a.lat * Double.pi / 180)
    let bx = (b.lng - a.lng) * scale * m, by = (b.lat - a.lat) * m
    let px = (p.lng - a.lng) * scale * m, py = (p.lat - a.lat) * m
    let length = (bx * bx + by * by).squareRoot()
    let t = length != 0 ? min(1, max(0, (px * bx + py * by) / (length * length))) : 0
    let dx = px - bx * t, dy = py - by * t
    return SegmentProjection(along: t * length, portion: t, distance: (dx * dx + dy * dy).squareRoot())
}

public struct Progress: Equatable {
    public var distanceToRoute: Double
    public var index: Int
    public var distanceAlong: Double

    public init(distanceToRoute: Double, index: Int, distanceAlong: Double) {
        self.distanceToRoute = distanceToRoute
        self.index = index
        self.distanceAlong = distanceAlong
    }
}

/// How far round the loop the walker has come. Vertices sit tens of metres
/// apart, so the nearest one is refined by projecting onto the segment it lies
/// on. A loop ends where it begins, so the search is anchored to the progress
/// already made: without that, a wobble at the start reads as the final vertex
/// and the walk jumps straight to "almost home".
public func nearestProgress(_ point: Point, _ coords: [Point], from: Double = 0) -> Progress {
    if coords.count < 2 {
        return Progress(distanceToRoute: haversine(point, coords[0]), index: 0, distanceAlong: 0)
    }
    let along = cumulative(coords)
    var best: Progress?
    var ahead: Progress?
    for i in 0..<(coords.count - 1) {
        let seg = projectOnSegment(point, coords[i], coords[i + 1])
        let here = Progress(
            distanceToRoute: seg.distance,
            index: seg.portion > 0.5 ? i + 1 : i,
            distanceAlong: along[i] + seg.along
        )
        if best == nil || here.distanceToRoute < best!.distanceToRoute { best = here }
        // A little slack behind, so standing still or drifting back a pace does not
        // strand the walker on the far side of the anchor.
        if here.distanceAlong >= from - 25 && (ahead == nil || here.distanceToRoute < ahead!.distanceToRoute) {
            ahead = here
        }
    }
    // Keep to the anchored match while it is plausibly the route underfoot; when
    // it is not, the walk has left the loop and the whole line is fair game again.
    if let ahead, ahead.distanceToRoute < 55 { return ahead }
    return best!
}
