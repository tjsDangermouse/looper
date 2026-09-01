import Foundation

/// The shortest way from one place to another on the local graph.
///
/// The closed-walk search cannot answer this and never could: its state is a
/// rooted circuit, it is edge-simple by construction, and the two reductions
/// that make it fast — the 2-core peel and the degree-2 contraction — are both
/// justified only for circuits. A leg between two pins may legitimately walk
/// into a dead end and back out, and a pin very often snaps onto exactly the
/// spur the peel removed or into the middle of a chain the contraction
/// collapsed. So an ordered-waypoint walk is routed here, on the raw graph,
/// and assembled from legs.
///
/// This is deliberately the same Dijkstra as `LocalExploration`, with three
/// differences that the exploration has no use for:
///
/// 1. **Parents are kept**, so the path can be read back rather than only its
///    length. The exploration reconstructs parents afterwards from distances;
///    that trick works but costs a second pass, and here the path is the whole
///    point.
/// 2. **Both ends may be mid-edge.** The exploration only ever splits its
///    start. A pin is as likely to be halfway down a street as a doorstep is.
/// 3. **Edges may be penalised.** The remote engine keeps a later leg off
///    ground an earlier one used by drawing avoidance polygons round the
///    walked coordinates and multiplying priority inside them. On the device
///    there is no need to go via geometry: every leg already carries the base
///    edge it ran along, so "do not walk this again" is a number on an edge.
///    That is both exact and cheaper than the thing it replaces.
public enum LocalLegRouter {
    /// One anchor-to-anchor leg, as ground.
    public struct Leg: Sendable {
        /// One entry per base edge walked, oriented the way it was walked.
        /// The same shape `LocalLoopRouter.assemble` produces for a circuit,
        /// so everything downstream — instructions, traversals, the gate —
        /// takes this without knowing which engine built it.
        public var legs: [WalkLeg]
        /// True walked length. Never the penalised search cost.
        public var metres: Double
        public var coordinates: [Point]

        public init(legs: [WalkLeg], metres: Double, coordinates: [Point]) {
            self.legs = legs
            self.metres = metres
            self.coordinates = coordinates
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case nothingToSnapTo(Point)
        case unreachable(from: Point, to: Point)

        public var errorDescription: String? {
            switch self {
            case .nothingToSnapTo:
                return "There's no walking path near enough to one of your waypoints."
            case .unreachable:
                return "One or more waypoints cannot be reached on foot."
            }
        }
    }

    /// Route through a sequence of places in order, each hop kept off the
    /// ground the hops before it used.
    ///
    /// The penalty is what the remote engine's avoidance model is for, and it
    /// is needed for the same reason: a shaping point dropped near a cul-de-sac
    /// makes the honest shortest path walk in and straight back out, and two
    /// hops that meet there produce a spike no walker would recognise as part
    /// of the walk.
    ///
    /// `avoiding` seeds that penalty from outside — the caller's way of saying
    /// "the walk arrived here along this edge, so do not simply turn round on
    /// it". Without it, two legs meeting at a pin are each individually
    /// shortest and together a U-turn, which is what the walker sees.
    ///
    /// `points` are visited exactly as given. Nothing here moves one.
    public static func route(
        graph: LocalWalkingGraph,
        index: LocalEdgeIndex,
        through points: [Point],
        protecting: [Point] = [],
        avoiding: Set<Int32> = [],
        retracePenalty: Double = 4,
        maximumSnapMetres: Double = 500
    ) throws -> Leg {
        guard points.count >= 2 else { throw Failure.unreachable(from: points.first ?? Point(0, 0), to: points.last ?? Point(0, 0)) }
        var penalised = avoiding
        var legs: [WalkLeg] = []
        // Where each hop ended, so the cancelling below can be stopped at the
        // places it must not cross.
        var boundaries: [Int] = []
        for hop in 1..<points.count {
            let leg = try route(
                graph: graph, index: index, from: points[hop - 1], to: points[hop],
                penalising: penalised, penalty: retracePenalty, maximumSnapMetres: maximumSnapMetres
            )
            for walked in leg.legs where walked.physical >= 0 { penalised.insert(walked.physical) }
            legs.append(contentsOf: leg.legs)
            if protecting.contains(where: { haversine($0, points[hop]) < 1 }) { boundaries.append(legs.count) }
        }
        // Cancelling runs within each protected stretch and never across one.
        //
        // This is not fussiness. A walker's pin is very often the tip of an
        // out-and-back — down a lane to a viewpoint and back — and that shape
        // is *exactly* what the cancelling looks for. Run across the pin, it
        // deletes the visit and hands back a tidy loop that never goes where
        // it was asked. Measured before this existed, half the walks routed
        // literally through their own pins no longer passed them.
        var trimmed: [WalkLeg] = []
        var from = 0
        for boundary in boundaries + [legs.count] where boundary > from {
            trimmed += cancellingReversals(Array(legs[from..<boundary]))
            from = boundary
        }
        return Leg(
            legs: trimmed,
            metres: trimmed.reduce(0) { $0 + $1.metres },
            coordinates: line(of: trimmed)
        )
    }

    /// One hop. `penalising` edges are still walkable — a penalty is not a
    /// wall, and treating it as one is how a leg with only one honest way
    /// through becomes no leg at all — but they cost `penalty` times their
    /// length to the search. What is reported is always the true length.
    public static func route(
        graph: LocalWalkingGraph,
        index: LocalEdgeIndex,
        from: Point,
        to: Point,
        penalising: Set<Int32> = [],
        penalty: Double = 4,
        maximumSnapMetres: Double = 500
    ) throws -> Leg {
        guard graph.edgeCount > 0 else { throw Failure.nothingToSnapTo(from) }
        guard let source = index.snap(lat: from.lat, lon: from.lng, graph: graph, maximumMetres: maximumSnapMetres) else {
            throw Failure.nothingToSnapTo(from)
        }
        guard let target = index.snap(lat: to.lat, lon: to.lng, graph: graph, maximumMetres: maximumSnapMetres) else {
            throw Failure.nothingToSnapTo(to)
        }

        @inline(__always) func cost(_ edge: Int) -> Double {
            graph.edgeMetres[edge] * (penalising.contains(Int32(edge)) ? penalty : 1)
        }

        // Two points on the same edge with nothing but that edge between them
        // is the one case the node graph cannot express, and it is common: two
        // pins dropped on the same long street.
        if source.edge == target.edge, let direct = alongOneEdge(source, target, graph: graph, index: index) {
            return direct
        }

        // ------------------------------------------------------------ source
        // Leaving a mid-edge point means walking one half of its edge, which
        // only the direction that half allows. Identical reasoning to
        // `LocalExploration`'s seeding, and identical consequences if got
        // wrong: a one-way alley walked the wrong way.
        var distance = [Double](repeating: .infinity, count: graph.nodeCount)
        var parentArc = [Int32](repeating: -1, count: graph.nodeCount)
        var settled = [Bool](repeating: false, count: graph.nodeCount)
        var heap = BinaryHeap()

        let sourceFrom = Int(graph.edgeFrom[source.edge]), sourceTo = Int(graph.edgeTo[source.edge])
        /// Which half of the source edge the walk began on, if any.
        enum Departure { case atNode(Int), towardsFrom, towardsTo }
        var departures: [(node: Int, metres: Double, departure: Departure)] = []
        if source.metresFromStart < 0.5 {
            departures = [(sourceFrom, 0, .atNode(sourceFrom))]
        } else if source.metresToEnd < 0.5 {
            departures = [(sourceTo, 0, .atNode(sourceTo))]
        } else {
            if graph.edgeBackward[source.edge] { departures.append((sourceFrom, source.metresFromStart, .towardsFrom)) }
            if graph.edgeForward[source.edge] { departures.append((sourceTo, source.metresToEnd, .towardsTo)) }
        }
        let sourcePenalty = penalising.contains(Int32(source.edge)) ? penalty : 1
        var departureOf: [Int: Departure] = [:]
        for entry in departures {
            let seed = entry.metres * sourcePenalty
            guard seed < distance[entry.node] else { continue }
            distance[entry.node] = seed
            departureOf[entry.node] = entry.departure
            heap.push(node: Int32(entry.node), key: seed)
        }
        guard !departures.isEmpty else { throw Failure.unreachable(from: from, to: to) }

        // ------------------------------------------------------------ target
        // The mirror: arriving at a mid-edge point means walking one half of
        // its edge inward, and only the direction that half allows.
        let targetFrom = Int(graph.edgeFrom[target.edge]), targetTo = Int(graph.edgeTo[target.edge])
        enum Arrival { case atNode, fromEdgeStart, fromEdgeEnd }
        var arrivals: [(node: Int, metres: Double, arrival: Arrival)] = []
        if target.metresFromStart < 0.5 {
            arrivals = [(targetFrom, 0, .atNode)]
        } else if target.metresToEnd < 0.5 {
            arrivals = [(targetTo, 0, .atNode)]
        } else {
            if graph.edgeForward[target.edge] { arrivals.append((targetFrom, target.metresFromStart, .fromEdgeStart)) }
            if graph.edgeBackward[target.edge] { arrivals.append((targetTo, target.metresToEnd, .fromEdgeEnd)) }
        }
        guard !arrivals.isEmpty else { throw Failure.unreachable(from: from, to: to) }
        let targetPenalty = penalising.contains(Int32(target.edge)) ? penalty : 1
        let wanted = Set(arrivals.map(\.node))

        // ---------------------------------------------------------- Dijkstra
        // Unbounded, and stopped by the goal rather than by a radius: a leg's
        // length is the answer, not an input, so there is nothing honest to
        // bound it with. It terminates when every way of arriving has settled,
        // which on a town graph is a fraction of the nodes.
        var remaining = wanted
        while let entry = heap.pop() {
            let node = Int(entry.node)
            if settled[node] { continue }
            if entry.key > distance[node] { continue }
            settled[node] = true
            remaining.remove(node)
            if remaining.isEmpty { break }
            let here = distance[node]
            for arc in Int(graph.arcStart[node])..<Int(graph.arcStart[node + 1]) {
                let next = Int(graph.arcTo[arc])
                let step = here + cost(Int(graph.arcEdge[arc]))
                guard step < distance[next] else { continue }
                distance[next] = step
                parentArc[next] = Int32(arc)
                heap.push(node: Int32(next), key: step)
            }
        }

        var best: (node: Int, arrival: Arrival, key: Double)?
        for entry in arrivals {
            guard distance[entry.node].isFinite else { continue }
            let key = distance[entry.node] + entry.metres * targetPenalty
            if best == nil || key < best!.key { best = (entry.node, entry.arrival, key) }
        }
        guard let arrival = best else { throw Failure.unreachable(from: from, to: to) }

        // ------------------------------------------------------ read it back
        var arcs: [Int32] = []
        var node = arrival.node
        while parentArc[node] >= 0 {
            let arc = parentArc[node]
            arcs.append(arc)
            // The arc's other end. `arcTo` is where it leads, so the node it
            // left is whichever end of its edge is not this one.
            let edge = Int(graph.arcEdge[Int(arc)])
            node = graph.arcForward[Int(arc)] ? Int(graph.edgeFrom[edge]) : Int(graph.edgeTo[edge])
        }
        arcs.reverse()

        var legs: [WalkLeg] = []
        if let departure = departureOf[node] {
            switch departure {
            case .atNode: break
            case .towardsFrom:
                legs.append(half(source, graph: graph, index: index, towardsFrom: true, reversed: false))
            case .towardsTo:
                legs.append(half(source, graph: graph, index: index, towardsFrom: false, reversed: false))
            }
        }
        for arc in arcs {
            let edge = Int(graph.arcEdge[Int(arc)])
            legs.append(WalkLeg(
                coordinates: graph.coordinates(ofEdge: edge, forward: graph.arcForward[Int(arc)]),
                metres: graph.edgeMetres[edge],
                name: graph.name(ofEdge: edge),
                roadClass: graph.roadClass(ofEdge: edge),
                physical: Int32(edge)
            ))
        }
        switch arrival.arrival {
        case .atNode: break
        case .fromEdgeStart:
            // From the edge's `from` end inward: the towards-from half, walked
            // the other way.
            legs.append(half(target, graph: graph, index: index, towardsFrom: true, reversed: true))
        case .fromEdgeEnd:
            legs.append(half(target, graph: graph, index: index, towardsFrom: false, reversed: true))
        }

        let trimmed = cancellingReversals(legs)
        return Leg(
            legs: trimmed,
            metres: trimmed.reduce(0) { $0 + $1.metres },
            coordinates: line(of: trimmed)
        )
    }

    // MARK: - Pieces

    /// One half of a snapped edge as a leg. `towardsFrom` picks which half;
    /// `reversed` walks it inward to the snap rather than outward from it.
    private static func half(
        _ snap: EdgeSnap, graph: LocalWalkingGraph, index: LocalEdgeIndex,
        towardsFrom: Bool, reversed: Bool
    ) -> WalkLeg {
        let halves = index.split(snap, graph: graph)
        let flat = towardsFrom ? halves.towardsFrom : halves.towardsTo
        var coordinates: [Point] = []
        coordinates.reserveCapacity(flat.count / 2)
        var i = 0
        while i + 1 < flat.count {
            coordinates.append(Point(flat[i], flat[i + 1]))
            i += 2
        }
        if reversed { coordinates.reverse() }
        return WalkLeg(
            coordinates: coordinates,
            metres: towardsFrom ? snap.metresFromStart : snap.metresToEnd,
            name: graph.name(ofEdge: snap.edge),
            roadClass: graph.roadClass(ofEdge: snap.edge),
            physical: Int32(snap.edge)
        )
    }

    /// Two points on one edge, walked along it. Returns nil where the edge
    /// does not allow that direction, in which case the node graph has to
    /// answer — the long way round a one-way pair, which is the right answer.
    private static func alongOneEdge(
        _ source: EdgeSnap, _ target: EdgeSnap, graph: LocalWalkingGraph, index: LocalEdgeIndex
    ) -> Leg? {
        let edge = source.edge
        let forward = target.metresFromStart >= source.metresFromStart
        guard forward ? graph.edgeForward[edge] : graph.edgeBackward[edge] else { return nil }
        let metres = abs(target.metresFromStart - source.metresFromStart)
        guard metres > 0.05 else {
            let leg = WalkLeg(
                coordinates: [Point(source.lon, source.lat), Point(target.lon, target.lat)],
                metres: 0, name: graph.name(ofEdge: edge), roadClass: graph.roadClass(ofEdge: edge),
                physical: Int32(edge)
            )
            return Leg(legs: [leg], metres: 0, coordinates: leg.coordinates)
        }
        // The stretch between the two snaps: the survey's own vertices between
        // them, with a snapped point capping each end. Built in the edge's own
        // direction and reversed afterwards, so there is one piece of index
        // arithmetic rather than two.
        let line = Array(graph.line(ofEdge: edge))
        let nearer = source.metresFromStart <= target.metresFromStart ? source : target
        let further = source.metresFromStart <= target.metresFromStart ? target : source
        let total = Swift.max(0.001, graph.edgeMetres[edge])
        let geometryTotal = Swift.max(0.001, geometryLength(line))
        var coordinates: [Point] = [Point(nearer.lon, nearer.lat)]
        var travelled = 0.0
        var i = 0
        while i + 3 < line.count {
            let a = Point(line[i], line[i + 1]), b = Point(line[i + 2], line[i + 3])
            travelled += LocalGeo.distance(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng)
            // `travelled` runs along the geometry; the snaps are recorded as a
            // share of the edge's own recorded length, so compare on that scale.
            let along = travelled / geometryTotal * total
            if along > nearer.metresFromStart && along < further.metresFromStart { coordinates.append(b) }
            i += 2
        }
        coordinates.append(Point(further.lon, further.lat))
        if !forward { coordinates.reverse() }
        let leg = WalkLeg(
            coordinates: coordinates, metres: metres,
            name: graph.name(ofEdge: edge), roadClass: graph.roadClass(ofEdge: edge),
            physical: Int32(edge)
        )
        return Leg(legs: [leg], metres: metres, coordinates: coordinates)
    }

    private static func geometryLength(_ flat: [Double]) -> Double {
        var total = 0.0
        var i = 0
        while i + 3 < flat.count {
            total += LocalGeo.distance(lat1: flat[i + 1], lon1: flat[i], lat2: flat[i + 3], lon2: flat[i + 2])
            i += 2
        }
        return total
    }

    /// Cut out any place the walk stepped onto a piece of ground and straight
    /// back off it.
    ///
    /// The remote engine does this geometrically, hunting for a later point
    /// close in space to an earlier one and confirming the walk actually
    /// reversed there — because GraphHopper's answer is a line, and a line is
    /// all it has to work with. Here every leg names the base edge it ran
    /// along, so the same spike is an exact fact: the same edge, immediately
    /// again, the other way. No thresholds, no false positives on a tight
    /// corner or a hairpin, and nothing that could cut out a piece of walk
    /// that merely passes near itself.
    ///
    /// Note this only ever cancels *adjacent* pairs, so it cannot remove a
    /// waypoint: a pin is a boundary between two legs lists that are trimmed
    /// separately, and it is never in the middle of a cancelled pair.
    static func cancellingReversals(_ legs: [WalkLeg]) -> [WalkLeg] {
        var stack: [WalkLeg] = []
        stack.reserveCapacity(legs.count)
        for leg in legs {
            if let last = stack.last, last.physical >= 0, last.physical == leg.physical,
               reverses(last, leg) {
                stack.removeLast()
                continue
            }
            stack.append(leg)
        }
        return stack
    }

    private static func reverses(_ a: WalkLeg, _ b: WalkLeg) -> Bool {
        guard let aStart = a.coordinates.first, let aEnd = a.coordinates.last,
              let bStart = b.coordinates.first, let bEnd = b.coordinates.last else { return false }
        return close(aEnd, bStart) && close(aStart, bEnd) && abs(a.metres - b.metres) < 0.5
    }

    private static func close(_ a: Point, _ b: Point) -> Bool {
        LocalGeo.distance(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng) < 0.5
    }

    /// The legs as one line, without repeating the vertex two legs share.
    static func line(of legs: [WalkLeg]) -> [Point] {
        var out: [Point] = []
        for leg in legs {
            for point in leg.coordinates where out.last != point { out.append(point) }
        }
        return out
    }
}
