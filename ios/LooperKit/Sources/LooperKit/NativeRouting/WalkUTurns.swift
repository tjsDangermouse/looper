import Foundation

/// The quality gate's own u-turn measure, on a walk the search has closed.
///
/// A port of `countUTurns` in the route service's `quality.ts` by way of the
/// Java `UTurns.java` — the same 15 m resample, the same three-sample window
/// either side, the same 150° turn and the same 20 m return, and the same rule
/// that one turn-around counts once rather than once per sample that can see
/// it. Nothing here is a new or a harsher definition: the point of computing
/// it inside the search is that a walk the gate is going to reject can be
/// dropped before it takes one of the places offered to the gate, not that a
/// different rule applies.
enum WalkUTurns {
    /// `SAMPLE_METRES` in quality.ts.
    static let sampleMetres: Double = 15
    /// Roughly 45 m of route either side of the turn.
    static let window = 3
    static let uTurnDegrees: Double = 150
    static let uTurnReturnMetres: Double = 20
    /// One turn-around, not one per sample that can see it.
    static let minimumSeparationMetres: Double = 60

    /// - Parameter metric: the walk as flat x/y pairs in a local metric frame.
    static func count(_ metric: [Double]) -> Int {
        let points = metric.count / 2
        guard points >= 2 else { return 0 }

        // resample(), streamed: midpoints of near-uniform 15 m samples.
        var midX: [Double] = [], midY: [Double] = [], along: [Double] = []
        midX.reserveCapacity(64); midY.reserveCapacity(64); along.reserveCapacity(64)
        var carried = 0.0, travelled = 0.0
        var fromX = metric[0], fromY = metric[1]
        var startX = fromX, startY = fromY

        for i in 1..<points {
            let toX = metric[i * 2], toY = metric[i * 2 + 1]
            var remaining = ((toX - fromX) * (toX - fromX) + (toY - fromY) * (toY - fromY)).squareRoot()
            while remaining > 0 && carried + remaining >= sampleMetres {
                let need = sampleMetres - carried
                let t = need / remaining
                let px = fromX + (toX - fromX) * t
                let py = fromY + (toY - fromY) * t
                let length = ((px - startX) * (px - startX) + (py - startY) * (py - startY)).squareRoot()
                midX.append((startX + px) / 2)
                midY.append((startY + py) / 2)
                along.append(travelled + length / 2)
                travelled += sampleMetres
                startX = px; startY = py
                fromX = px; fromY = py
                remaining -= need
                carried = 0
            }
            carried += remaining
            fromX = toX; fromY = toY
        }
        // A trailing stub shorter than a third of the spacing is noise.
        if carried > sampleMetres / 3 {
            let length = ((fromX - startX) * (fromX - startX) + (fromY - startY) * (fromY - startY)).squareRoot()
            midX.append((startX + fromX) / 2)
            midY.append((startY + fromY) / 2)
            along.append(travelled + length / 2)
        }

        let limit = cos(LocalGeo.toRadians(uTurnDegrees))
        var count = 0
        var lastAt = -Double.infinity
        let samples = midX.count
        guard samples > window * 2 else { return 0 }
        for i in window..<(samples - window) {
            let beforeX = midX[i - window], beforeY = midY[i - window]
            let hereX = midX[i], hereY = midY[i]
            let afterX = midX[i + window], afterY = midY[i + window]
            let inX = hereX - beforeX, inY = hereY - beforeY
            let outX = afterX - hereX, outY = afterY - hereY
            let inLength = (inX * inX + inY * inY).squareRoot()
            let outLength = (outX * outX + outY * outY).squareRoot()
            guard inLength >= 1e-6, outLength >= 1e-6 else { continue }
            let dot = (inX * outX + inY * outY) / (inLength * outLength)
            guard dot <= limit else { continue }
            let armGap = ((afterX - beforeX) * (afterX - beforeX) + (afterY - beforeY) * (afterY - beforeY)).squareRoot()
            guard armGap <= uTurnReturnMetres else { continue }
            guard along[i] - lastAt >= minimumSeparationMetres else { continue }
            lastAt = along[i]
            count += 1
        }
        return count
    }
}
