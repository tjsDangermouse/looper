import Foundation

/// The reduced, request-local graph a closed-walk search moves over.
///
/// A port of the route service's `SearchGraph.java`, which is itself Phase 9's
/// `graph.mts` moved into the process that owns the graph. Nothing about the
/// reductions is new here and both are exact rather than heuristic:
///
/// 1. **The 2-core.** A rooted circuit cannot enter a dead end and come back
///    out without retracing that edge in reverse, and the quality gate's
///    `out-and-back-spur` rule makes a reverse retrace outside the 75 m
///    doorstep window fatal. So every leaf can be peeled, repeatedly, without
///    removing one admissible walk. What is peeled is kept, because the stem
///    out of the door may run through it.
/// 2. **Degree-2 contraction.** A chain of degree-2 junctions offers no
///    choice: entering it determines everything until the next real junction.
///    Each chain becomes one super-edge carrying its metres, its geometry and
///    the underlying edge ids, so repeated-ground accounting is unchanged and
///    search depth falls by the length of the chains.
///
/// The one thing that differs from the Java is what sits underneath. There,
/// two edge identities had to be kept — GraphHopper's QueryGraph ids and the
/// base-graph ids beneath them. Here the local graph is built from OSM
/// directly, so a subgraph edge id addresses the geometry and the `physical`
/// id addresses the ground; the split-at-the-start edge is the only place the
/// two diverge, and it diverges the same way GraphHopper's did.
public final class WalkSearchGraph {
    public struct Stats: Sendable, Equatable {
        public var rawNodes = 0
        public var rawEdges = 0
        public var coreNodes = 0
        public var coreEdges = 0
        public var nodes = 0
        public var superEdges = 0
        public var arcs = 0
        public var buildMs: Double = 0
    }

    /// The walk from the routing start out to a node, on the unreduced edges.
    public struct Stem {
        public var subEdgeIDs: [Int32]
        public var metres: Double
        /// Flat lon/lat pairs.
        public var line: [Double]
        /// The same line in the start's metric frame, flat x/y pairs.
        public var metric: [Double]
        /// Which end of each sub-edge the stem entered by, so the walk can be
        /// drawn without asking the geometry which way round it runs.
        public var forward: [Bool]
    }

    /// Metres east/north of the routing start; the frame every shape term uses.
    public let frame: MetricFrame
    public let startLon: Double
    public let startLat: Double

    // Compacted node space.
    public let lon: [Double]
    public let lat: [Double]
    /// Exact shortest walkable distance from the routing start, in metres.
    public let home: [Double]
    /// Compass octant of each node as seen from the start; the diversity axis.
    public let octant: [Int8]
    /// Each node in the start's metric frame, so a straight-line distance is a
    /// subtraction rather than a geodesic. The frame's origin is the start, so
    /// `hypot(nodeX, nodeY)` is already the node's radius from the door.
    public let nodeX: [Double]
    public let nodeY: [Double]
    /// The routing start, in compacted node space.
    public let start: Int

    // Super-edges.
    public let edgeCount: Int
    public let edgeFrom: [Int32]
    public let edgeTo: [Int32]
    public let edgeMetres: [Double]
    public let edgeForward: [Bool]
    public let edgeBackward: [Bool]
    /// Geometry, `from` end first, as flat lon/lat pairs.
    public let edgeGeometry: [[Double]]
    /// The same line projected into the start's metric frame.
    public let edgeMetric: [[Double]]
    /// Subgraph edge ids under this super-edge, in `from -> to` order.
    public let edgeSubIDs: [[Int32]]
    /// Whether each of those runs with its own `from -> to` at this point.
    public let edgeSubForward: [[Bool]]
    /// Physical edge ids, on which "this ground is already spent" is decided.
    public let edgePhysicalIDs: [[Int32]]

    // Shape contributions, precomputed once per super-edge in the start's frame.
    public let edgeTwiceArea: [Double]
    public let edgeDrawn: [Double]
    public let edgeMinX: [Double]
    public let edgeMaxX: [Double]
    public let edgeMinY: [Double]
    public let edgeMaxY: [Double]
    public let edgeMaxRadius: [Double]

    // Arcs: oriented moves out of each node, as a CSR.
    public let arcStart: [Int32]
    public let arcEdge: [Int32]
    public let arcTo: [Int32]
    public let arcMetres: [Double]
    public let arcForward: [Bool]
    /// Bearing leaving the arc's first point, and arriving at its last.
    public let arcOutBearing: [Double]
    public let arcInBearing: [Double]

    public let stats: Stats

    private let parentNode: [Int32]
    private let parentRaw: [Int32]
    private let rawEdges: [RawEdge]

    struct RawEdge {
        var a: Int32
        var b: Int32
        var metres: Double
        var subID: Int32
        var physical: Int32
        var forward: Bool
        var backward: Bool
        var geometry: [Double]
    }

    public init(_ raw: RoutingSubgraph) {
        let began = Date()
        let n = raw.nodes.count
        let startNode = raw.startNode
        var lonValues = [Double](repeating: 0, count: n)
        var latValues = [Double](repeating: 0, count: n)
        var homeValues = [Double](repeating: 0, count: n)
        for i in 0..<n {
            lonValues[i] = raw.nodes[i].lon
            latValues[i] = raw.nodes[i].lat
            homeValues[i] = raw.nodes[i].networkMetres
        }
        lon = lonValues
        lat = latValues
        home = homeValues
        start = startNode
        startLon = raw.snappedLon
        startLat = raw.snappedLat
        frame = MetricFrame(originLon: raw.snappedLon, originLat: raw.snappedLat)
        var octants = [Int8](repeating: 0, count: n)
        for i in 0..<n {
            octants[i] = Int8(LocalGeo.bearingOctant(
                LocalGeo.bearing(lat1: startLat, lon1: startLon, lat2: latValues[i], lon2: lonValues[i])
            ))
        }
        octant = octants
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let point = frame.project(lon: lonValues[i], lat: latValues[i])
            xs[i] = point.x
            ys[i] = point.y
        }
        nodeX = xs
        nodeY = ys

        // Undirected adjacency over the raw edges. Parallel edges and self
        // loops are kept: a pair of parallel ways between the same junctions
        // is a genuine two-way-round, and a self loop is a genuine circuit.
        var raws: [RawEdge] = []
        raws.reserveCapacity(raw.edges.count)
        for edge in raw.edges {
            var line = edge.geometry
            if line.count < 4 {
                line = [lonValues[Int(edge.from)], latValues[Int(edge.from)], lonValues[Int(edge.to)], latValues[Int(edge.to)]]
            }
            raws.append(RawEdge(
                a: edge.from, b: edge.to, metres: edge.metres, subID: edge.id,
                physical: edge.physical, forward: edge.forward, backward: edge.backward, geometry: line
            ))
        }
        rawEdges = raws

        let incidentAll = WalkSearchGraph.incidence(n, raws, alive: nil)

        // The start-rooted shortest-path tree, read back out of the distance
        // field rather than searched for again: a node's parent is the
        // neighbour whose own distance plus the edge between them is the
        // node's distance.
        var parents = [Int32](repeating: -1, count: n)
        var parentEdges = [Int32](repeating: -1, count: n)
        for v in 0..<n where v != startNode {
            for e in incidentAll[v] {
                let edge = raws[Int(e)]
                let other = edge.a == Int32(v) ? edge.b : edge.a
                let usable = edge.a == other ? edge.forward : edge.backward
                guard usable else { continue }
                guard abs(homeValues[Int(other)] + edge.metres - homeValues[v]) <= 0.2 else { continue }
                parents[v] = other
                parentEdges[v] = e
                break
            }
        }
        parentNode = parents
        parentRaw = parentEdges

        // ------------------------------------------------------- 2-core peel
        var alive = [Bool](repeating: true, count: raws.count)
        var degree = incidentAll.map { $0.count }
        var queue: [Int] = []
        for v in 0..<n where degree[v] <= 1 { queue.append(v) }
        while let v = queue.popLast() {
            guard degree[v] <= 1 else { continue }
            for e in incidentAll[v] {
                guard alive[Int(e)] else { continue }
                alive[Int(e)] = false
                let other = raws[Int(e)].a == Int32(v) ? raws[Int(e)].b : raws[Int(e)].a
                degree[v] -= 1
                if other != Int32(v) {
                    degree[Int(other)] -= 1
                    if degree[Int(other)] <= 1 { queue.append(Int(other)) }
                }
            }
        }
        var coreEdgeCount = 0
        var inCore = [Bool](repeating: false, count: n)
        for e in 0..<raws.count where alive[e] {
            coreEdgeCount += 1
            inCore[Int(raws[e].a)] = true
            inCore[Int(raws[e].b)] = true
        }
        let coreNodeCount = inCore.filter { $0 }.count

        // -------------------------------------------------- degree-2 contract
        let coreIncident = WalkSearchGraph.incidence(n, raws, alive: alive)
        func isJunction(_ v: Int) -> Bool { coreIncident[v].count != 2 || v == startNode }
        var used = [Bool](repeating: false, count: raws.count)

        /// Follow a degree-2 chain from `first` leaving `from` until a junction.
        func chain(first: Int32, from: Int) -> [Int32] {
            var steps: [Int32] = []
            var current = first
            var at = Int32(from)
            while true {
                let edge = raws[Int(current)]
                used[Int(current)] = true
                steps.append(current)
                let next = edge.a == at ? edge.b : edge.a
                at = next
                if isJunction(Int(next)) { break }
                var onward: Int32 = -1
                for candidate in coreIncident[Int(next)] where candidate != current && !used[Int(candidate)] {
                    onward = candidate
                    break
                }
                if onward < 0 { break }
                current = onward
            }
            return steps
        }

        var chains: [[Int32]] = []
        var chainFrom: [Int] = []
        for v in 0..<n where inCore[v] && isJunction(v) {
            for e in coreIncident[v] where !used[Int(e)] {
                chains.append(chain(first: e, from: v))
                chainFrom.append(v)
            }
        }
        // A ring of degree-2 nodes touching no junction at all: rare, but a
        // perfectly good circuit and it must not be dropped.
        for e in 0..<raws.count where alive[e] && !used[e] {
            chains.append(chain(first: Int32(e), from: Int(raws[e].a)))
            chainFrom.append(Int(raws[e].a))
        }

        let count = chains.count
        edgeCount = count
        var from = [Int32](repeating: 0, count: count)
        var to = [Int32](repeating: 0, count: count)
        var metres = [Double](repeating: 0, count: count)
        var forward = [Bool](repeating: true, count: count)
        var backward = [Bool](repeating: true, count: count)
        var geometry = [[Double]](repeating: [], count: count)
        var metric = [[Double]](repeating: [], count: count)
        var subIDs = [[Int32]](repeating: [], count: count)
        var subForward = [[Bool]](repeating: [], count: count)
        var physicalIDs = [[Int32]](repeating: [], count: count)
        var twiceArea = [Double](repeating: 0, count: count)
        var drawn = [Double](repeating: 0, count: count)
        var minX = [Double](repeating: 0, count: count)
        var maxX = [Double](repeating: 0, count: count)
        var minY = [Double](repeating: 0, count: count)
        var maxY = [Double](repeating: 0, count: count)
        var maxRadius = [Double](repeating: 0, count: count)
        let localFrame = frame

        for i in 0..<count {
            let steps = chains[i]
            var at = Int32(chainFrom[i])
            var total = 0.0
            var canGo = true, canReturn = true
            var lines: [[Double]] = []
            lines.reserveCapacity(steps.count)
            var ids = [Int32](repeating: 0, count: steps.count)
            var runs = [Bool](repeating: true, count: steps.count)
            var physical = [Int32](repeating: 0, count: steps.count)
            for s in 0..<steps.count {
                let edge = raws[Int(steps[s])]
                let runsForward = edge.a == at
                lines.append(runsForward ? edge.geometry : WalkSearchGraph.reverseLine(edge.geometry))
                ids[s] = edge.subID
                runs[s] = runsForward
                physical[s] = edge.physical
                total += edge.metres
                canGo = canGo && (runsForward ? edge.forward : edge.backward)
                canReturn = canReturn && (runsForward ? edge.backward : edge.forward)
                at = runsForward ? edge.b : edge.a
            }
            from[i] = Int32(chainFrom[i])
            to[i] = at
            metres[i] = total
            forward[i] = canGo
            backward[i] = canReturn
            subIDs[i] = ids
            subForward[i] = runs
            physicalIDs[i] = physical
            let joined = WalkSearchGraph.joinLines(lines)
            geometry[i] = joined
            let projected = localFrame.project(line: joined)
            metric[i] = projected

            // Shoelace, drawn length, bounding box and radius, in the start's frame.
            var area = 0.0, length = 0.0, radius = 0.0
            var lowX = Double.infinity, highX = -Double.infinity
            var lowY = Double.infinity, highY = -Double.infinity
            var p = 0
            while p + 1 < projected.count {
                let x = projected[p], y = projected[p + 1]
                lowX = Swift.min(lowX, x); highX = Swift.max(highX, x)
                lowY = Swift.min(lowY, y); highY = Swift.max(highY, y)
                radius = Swift.max(radius, (x * x + y * y).squareRoot())
                if p + 3 < projected.count {
                    let nx = projected[p + 2], ny = projected[p + 3]
                    area += x * ny - nx * y
                    length += ((nx - x) * (nx - x) + (ny - y) * (ny - y)).squareRoot()
                }
                p += 2
            }
            twiceArea[i] = area
            drawn[i] = length
            minX[i] = lowX; maxX[i] = highX; minY[i] = lowY; maxY[i] = highY
            maxRadius[i] = radius
        }

        edgeFrom = from
        edgeTo = to
        edgeMetres = metres
        edgeForward = forward
        edgeBackward = backward
        edgeGeometry = geometry
        edgeMetric = metric
        edgeSubIDs = subIDs
        edgeSubForward = subForward
        edgePhysicalIDs = physicalIDs
        edgeTwiceArea = twiceArea
        edgeDrawn = drawn
        edgeMinX = minX
        edgeMaxX = maxX
        edgeMinY = minY
        edgeMaxY = maxY
        edgeMaxRadius = maxRadius

        // ------------------------------------------------------------- arcs
        var outDegree = [Int32](repeating: 0, count: n)
        for i in 0..<count {
            if forward[i] { outDegree[Int(from[i])] += 1 }
            if backward[i] { outDegree[Int(to[i])] += 1 }
        }
        var starts = [Int32](repeating: 0, count: n + 1)
        for v in 0..<n { starts[v + 1] = starts[v] + outDegree[v] }
        let total = Int(starts[n])
        var arcEdges = [Int32](repeating: 0, count: total)
        var arcTos = [Int32](repeating: 0, count: total)
        var arcMetresValues = [Double](repeating: 0, count: total)
        var arcForwards = [Bool](repeating: false, count: total)
        var outBearings = [Double](repeating: 0, count: total)
        var inBearings = [Double](repeating: 0, count: total)
        var cursor = Array(starts[0..<n])
        for i in 0..<count {
            let line = geometry[i]
            let last = line.count - 2
            let out = LocalGeo.bearing(
                lat1: line[1], lon1: line[0],
                lat2: line[Swift.min(3, last + 1)], lon2: line[Swift.min(2, last)]
            )
            let incoming = LocalGeo.bearing(
                lat1: line[Swift.max(1, last - 1)], lon1: line[Swift.max(0, last - 2)],
                lat2: line[last + 1], lon2: line[last]
            )
            if forward[i] {
                let at = Int(cursor[Int(from[i])]); cursor[Int(from[i])] += 1
                arcEdges[at] = Int32(i); arcTos[at] = to[i]; arcMetresValues[at] = metres[i]; arcForwards[at] = true
                outBearings[at] = out; inBearings[at] = incoming
            }
            if backward[i] {
                let at = Int(cursor[Int(to[i])]); cursor[Int(to[i])] += 1
                arcEdges[at] = Int32(i); arcTos[at] = from[i]; arcMetresValues[at] = metres[i]; arcForwards[at] = false
                outBearings[at] = (incoming + 180).truncatingRemainder(dividingBy: 360)
                inBearings[at] = (out + 180).truncatingRemainder(dividingBy: 360)
            }
        }
        arcStart = starts
        arcEdge = arcEdges
        arcTo = arcTos
        arcMetres = arcMetresValues
        arcForward = arcForwards
        arcOutBearing = outBearings
        arcInBearing = inBearings

        var liveNodes = 0
        for v in 0..<n where starts[v + 1] > starts[v] { liveNodes += 1 }
        stats = Stats(
            rawNodes: n, rawEdges: raws.count, coreNodes: coreNodeCount, coreEdges: coreEdgeCount,
            nodes: liveNodes, superEdges: count, arcs: total,
            buildMs: Date().timeIntervalSince(began) * 1000
        )
    }

    /// The doorstep stem: the walk from the routing start out to `node`, on
    /// the unreduced edges. Empty where the start is already in the 2-core.
    public func stem(to destination: Int) -> Stem {
        var steps: [Int32] = []
        var nodes: [Int32] = []
        var at = destination
        var guardCount = 0
        while at != start, parentRaw[at] >= 0, guardCount < rawEdges.count + 2 {
            guardCount += 1
            steps.append(parentRaw[at])
            nodes.append(parentNode[at])
            at = Int(parentNode[at])
        }
        steps.reverse()
        nodes.reverse()
        var ids = [Int32](repeating: 0, count: steps.count)
        var runs = [Bool](repeating: true, count: steps.count)
        var metres = 0.0
        var lines: [[Double]] = []
        lines.reserveCapacity(steps.count)
        for i in 0..<steps.count {
            let edge = rawEdges[Int(steps[i])]
            ids[i] = edge.subID
            metres += edge.metres
            let runsForward = edge.a == nodes[i]
            runs[i] = runsForward
            lines.append(runsForward ? edge.geometry : WalkSearchGraph.reverseLine(edge.geometry))
        }
        let line = WalkSearchGraph.joinLines(lines)
        return Stem(subEdgeIDs: ids, metres: metres, line: line, metric: frame.project(line: line), forward: runs)
    }

    /// Where the walk actually starts searching, and what the doorstep costs.
    /// The start may have been peeled out of the 2-core — it usually is, since
    /// a front door is a dead end — in which case the nearest node that
    /// survived is the root and the walk out to it is the stem.
    public func root() -> Int {
        if arcStart[start + 1] > arcStart[start] { return start }
        var best = Double.infinity
        var chosen = -1
        for v in 0..<home.count {
            guard arcStart[v + 1] > arcStart[v] else { continue }
            if home[v] < best { best = home[v]; chosen = v }
        }
        return chosen
    }

    // MARK: - Helpers

    static func incidence(_ n: Int, _ edges: [RawEdge], alive: [Bool]?) -> [[Int32]] {
        var counts = [Int](repeating: 0, count: n)
        for e in 0..<edges.count {
            if let alive, !alive[e] { continue }
            counts[Int(edges[e].a)] += 1
            if edges[e].b != edges[e].a { counts[Int(edges[e].b)] += 1 }
        }
        var out = [[Int32]](repeating: [], count: n)
        for v in 0..<n { out[v].reserveCapacity(counts[v]) }
        for e in 0..<edges.count {
            if let alive, !alive[e] { continue }
            out[Int(edges[e].a)].append(Int32(e))
            if edges[e].b != edges[e].a { out[Int(edges[e].b)].append(Int32(e)) }
        }
        return out
    }

    static func reverseLine(_ line: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: line.count)
        var i = 0, j = line.count - 2
        while i < line.count {
            out[i] = line[j]
            out[i + 1] = line[j + 1]
            i += 2
            j -= 2
        }
        return out
    }

    /// Concatenate consecutive lines, dropping the duplicated join points.
    static func joinLines(_ lines: [[Double]]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(lines.reduce(0) { $0 + $1.count })
        for line in lines {
            var start = 0
            if out.count >= 2, line.count >= 2, out[out.count - 2] == line[0], out[out.count - 1] == line[1] { start = 2 }
            out.append(contentsOf: line[start...])
        }
        return out
    }
}
