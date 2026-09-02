import Foundation

/// Where a coordinate meets the walking network.
///
/// Snapping happens entirely on the device. There is no service to ask, and
/// deliberately so: a routing engine that needs the network to work out where
/// the walker is standing is not an offline routing engine, whatever else it
/// can do without a connection.
///
/// The result addresses a point *along* an edge rather than the nearest
/// junction. That matters more than it sounds: junctions on a residential
/// street sit 80–150 m apart, so snapping to the nearest one can move the
/// start of a walk further than the width of the street the walker is on, and
/// every distance in the answer inherits the error.
public struct EdgeSnap: Sendable, Equatable {
    public var edge: Int
    /// Index of the geometry segment the projection fell on, within the edge.
    public var segment: Int
    /// Position along that segment, 0...1.
    public var t: Double
    public var lat: Double
    public var lon: Double
    /// How far the queried point was from the network, in metres.
    public var distanceMetres: Double
    /// Metres from the edge's `from` end to the snapped point.
    public var metresFromStart: Double
    /// Metres from the snapped point to the edge's `to` end.
    public var metresToEnd: Double

    /// True when the projection landed on a junction rather than mid-edge, in
    /// which case no virtual node is needed.
    public var isAtNode: Bool { metresFromStart < 0.5 || metresToEnd < 0.5 }
}

/// A uniform grid over the edges' bounding boxes.
///
/// A grid rather than an R-tree because the network is near-uniformly dense
/// over a search area of a few square kilometres, which is the case a grid
/// handles best and the case Looper always has. It is built once per graph and
/// queried a handful of times, so build cost matters as much as query cost.
public struct LocalEdgeIndex: Sendable {
    /// Roughly 150 m cells: a couple of edges each in a town, and small enough
    /// that the first ring of a query usually settles it.
    public static let defaultCellMetres: Double = 150

    private let cellSizeLat: Double
    private let cellSizeLon: Double
    private let minLat: Double
    private let minLon: Double
    private let columns: Int
    private let rows: Int
    /// CSR over the grid: `cellStart[c]..<cellStart[c+1]` indexes `cellEdge`.
    private let cellStart: [Int32]
    private let cellEdge: [Int32]

    public init(graph: LocalWalkingGraph, cellMetres: Double = LocalEdgeIndex.defaultCellMetres) {
        guard graph.edgeCount > 0, !graph.nodeLat.isEmpty else {
            cellSizeLat = 1; cellSizeLon = 1; minLat = 0; minLon = 0
            columns = 1; rows = 1; cellStart = [0, 0]; cellEdge = []
            return
        }
        let latMin = graph.nodeLat.min()!, latMax = graph.nodeLat.max()!
        let lonMin = graph.nodeLon.min()!, lonMax = graph.nodeLon.max()!
        let scale = Swift.max(0.01, cos(LocalGeo.toRadians((latMin + latMax) / 2)))
        cellSizeLat = cellMetres / LocalGeo.metresPerDegreeLatitude
        cellSizeLon = cellMetres / (LocalGeo.metresPerDegreeLatitude * scale)
        minLat = latMin
        minLon = lonMin
        columns = Swift.max(1, Int((lonMax - lonMin) / cellSizeLon) + 1)
        rows = Swift.max(1, Int((latMax - latMin) / cellSizeLat) + 1)

        // Two passes so the CSR can be exact rather than an array of arrays:
        // the second is the same walk as the first, and both are cheap next to
        // allocating a bucket per cell.
        let cells = columns * rows
        var counts = [Int32](repeating: 0, count: cells + 1)
        let localColumns = columns, localRows = rows
        let localMinLat = minLat, localMinLon = minLon
        let localCellLat = cellSizeLat, localCellLon = cellSizeLon

        func visitCells(ofEdge edge: Int, _ body: (Int) -> Void) {
            let line = graph.line(ofEdge: edge)
            var lowLat = Double.infinity, highLat = -Double.infinity
            var lowLon = Double.infinity, highLon = -Double.infinity
            var i = line.startIndex
            while i + 1 < line.endIndex {
                lowLon = Swift.min(lowLon, line[i]); highLon = Swift.max(highLon, line[i])
                lowLat = Swift.min(lowLat, line[i + 1]); highLat = Swift.max(highLat, line[i + 1])
                i += 2
            }
            guard lowLat <= highLat else { return }
            let x0 = Swift.max(0, Swift.min(localColumns - 1, Int((lowLon - localMinLon) / localCellLon)))
            let x1 = Swift.max(0, Swift.min(localColumns - 1, Int((highLon - localMinLon) / localCellLon)))
            let y0 = Swift.max(0, Swift.min(localRows - 1, Int((lowLat - localMinLat) / localCellLat)))
            let y1 = Swift.max(0, Swift.min(localRows - 1, Int((highLat - localMinLat) / localCellLat)))
            for y in y0...y1 {
                for x in x0...x1 { body(y * localColumns + x) }
            }
        }

        for edge in 0..<graph.edgeCount { visitCells(ofEdge: edge) { counts[$0 + 1] += 1 } }
        for cell in 0..<cells { counts[cell + 1] += counts[cell] }
        var entries = [Int32](repeating: 0, count: Int(counts[cells]))
        var cursor = counts
        for edge in 0..<graph.edgeCount {
            visitCells(ofEdge: edge) { cell in
                entries[Int(cursor[cell])] = Int32(edge)
                cursor[cell] += 1
            }
        }
        cellStart = counts
        cellEdge = entries
    }

    /// The nearest walkable edge, searching outward a ring of cells at a time
    /// and stopping once no unexamined cell can hold anything closer.
    /// Every edge with any geometry in the given box.
    ///
    /// The grid already answers this — it is what it is for — and the ring
    /// generator needs it to price the ground beside a leg as well as the
    /// ground under it. Approximate in the outward direction only: an edge is
    /// returned if its *cell* overlaps the box, so the caller still has to
    /// measure. That is the cheap half of the work done cheaply.
    public func edges(
        minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    ) -> Set<Int32> {
        guard !cellEdge.isEmpty else { return [] }
        var out: Set<Int32> = []
        let lowX = Swift.max(0, Int((minLon - self.minLon) / cellSizeLon))
        let highX = Swift.min(columns - 1, Int((maxLon - self.minLon) / cellSizeLon))
        let lowY = Swift.max(0, Int((minLat - self.minLat) / cellSizeLat))
        let highY = Swift.min(rows - 1, Int((maxLat - self.minLat) / cellSizeLat))
        guard lowX <= highX, lowY <= highY else { return [] }
        for cellY in lowY...highY {
            for cellX in lowX...highX {
                let cell = cellY * columns + cellX
                for slot in Int(cellStart[cell])..<Int(cellStart[cell + 1]) {
                    out.insert(cellEdge[slot])
                }
            }
        }
        return out
    }

    public func snap(
        lat: Double,
        lon: Double,
        graph: LocalWalkingGraph,
        maximumMetres: Double = 500
    ) -> EdgeSnap? {
        guard !cellEdge.isEmpty else { return nil }
        let x = Int((lon - minLon) / cellSizeLon)
        let y = Int((lat - minLat) / cellSizeLat)
        let cellMetres = cellSizeLat * LocalGeo.metresPerDegreeLatitude
        let maximumRing = Swift.max(columns, rows)
        var best: EdgeSnap?
        var seen = Set<Int32>()

        var ring = 0
        while ring <= maximumRing {
            // Everything in this ring is at least `(ring - 1)` cells away, so
            // once the best find is nearer than that, no later ring can beat it.
            if let best, best.distanceMetres <= Double(ring - 1) * cellMetres { break }
            if Double(ring - 1) * cellMetres > maximumMetres { break }
            var examined = false
            for cellY in (y - ring)...(y + ring) {
                guard cellY >= 0, cellY < rows else { continue }
                for cellX in (x - ring)...(x + ring) {
                    guard cellX >= 0, cellX < columns else { continue }
                    // Only the ring's boundary is new.
                    guard ring == 0 || abs(cellX - x) == ring || abs(cellY - y) == ring else { continue }
                    examined = true
                    let cell = cellY * columns + cellX
                    for slot in Int(cellStart[cell])..<Int(cellStart[cell + 1]) {
                        let edge = cellEdge[slot]
                        guard seen.insert(edge).inserted else { continue }
                        guard let candidate = project(lat: lat, lon: lon, onto: Int(edge), graph: graph) else { continue }
                        if best == nil || candidate.distanceMetres < best!.distanceMetres { best = candidate }
                    }
                }
            }
            if !examined && ring > Swift.max(columns, rows) { break }
            ring += 1
        }
        guard let best, best.distanceMetres <= maximumMetres else { return nil }
        return best
    }

    /// Perpendicular projection onto every segment of one edge.
    func project(lat: Double, lon: Double, onto edge: Int, graph: LocalWalkingGraph) -> EdgeSnap? {
        let line = graph.line(ofEdge: edge)
        guard line.count >= 4 else { return nil }
        let frame = MetricFrame(originLon: lon, originLat: lat)
        var bestDistance = Double.infinity
        var bestSegment = 0
        var bestT = 0.0
        var bestPoint = (x: 0.0, y: 0.0)
        var lengths: [Double] = []
        lengths.reserveCapacity(line.count / 2 - 1)

        var index = line.startIndex
        var previous = frame.project(lon: line[index], lat: line[index + 1])
        var segment = 0
        index += 2
        while index + 1 < line.endIndex {
            let current = frame.project(lon: line[index], lat: line[index + 1])
            let dx = current.x - previous.x, dy = current.y - previous.y
            let lengthSquared = dx * dx + dy * dy
            let length = lengthSquared.squareRoot()
            lengths.append(length)
            let t = lengthSquared > 0 ? Swift.max(0, Swift.min(1, (-previous.x * dx + -previous.y * dy) / lengthSquared)) : 0
            let px = previous.x + dx * t, py = previous.y + dy * t
            let distance = (px * px + py * py).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                bestSegment = segment
                bestT = t
                bestPoint = (px, py)
            }
            previous = current
            segment += 1
            index += 2
        }
        guard bestDistance.isFinite else { return nil }

        var along = 0.0
        for i in 0..<bestSegment { along += lengths[i] }
        along += lengths[bestSegment] * bestT
        // The edge's own recorded length is the authority — it is what every
        // distance in the search is measured in — so the split is expressed as
        // a share of it rather than as a second, slightly different, total.
        let geometryTotal = lengths.reduce(0, +)
        let share = geometryTotal > 0 ? along / geometryTotal : 0
        let metresFromStart = graph.edgeMetres[edge] * share

        // Back to degrees, from the metric frame centred on the query point.
        let latitude = lat + bestPoint.y / LocalGeo.metresPerDegreeLatitude
        let longitude = lon + bestPoint.x / (LocalGeo.metresPerDegreeLatitude * Swift.max(0.01, frame.scale))

        return EdgeSnap(
            edge: edge,
            segment: bestSegment,
            t: bestT,
            lat: latitude,
            lon: longitude,
            distanceMetres: bestDistance,
            metresFromStart: metresFromStart,
            metresToEnd: Swift.max(0, graph.edgeMetres[edge] - metresFromStart)
        )
    }

    /// The edge geometry split at the snap: the part back towards `from`
    /// (reversed, so it reads outward from the snapped point) and the part
    /// onward to `to`. Both are needed to draw the doorstep stem of a walk
    /// that starts mid-street.
    public func split(_ snap: EdgeSnap, graph: LocalWalkingGraph) -> (towardsFrom: [Double], towardsTo: [Double]) {
        let line = Array(graph.line(ofEdge: snap.edge))
        var back: [Double] = [snap.lon, snap.lat]
        var forward: [Double] = [snap.lon, snap.lat]
        var vertex = 0
        var index = 0
        while index + 1 < line.count {
            if vertex <= snap.segment { back.append(contentsOf: [line[index], line[index + 1]]) }
            if vertex > snap.segment { forward.append(contentsOf: [line[index], line[index + 1]]) }
            vertex += 1
            index += 2
        }
        // `back` was collected from the snapped point outward already; reverse
        // the vertices after the first so it reads snapped-point-first.
        var ordered: [Double] = [snap.lon, snap.lat]
        var i = back.count - 2
        while i >= 2 {
            ordered.append(back[i])
            ordered.append(back[i + 1])
            i -= 2
        }
        return (ordered, forward)
    }
}
