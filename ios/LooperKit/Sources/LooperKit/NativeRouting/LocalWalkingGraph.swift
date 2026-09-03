import Foundation

/// The walking network the device routes on.
///
/// Structure-of-arrays rather than a graph of objects, for the ordinary
/// reason: a 5 km search area around Douglas is tens of thousands of edges,
/// and a Swift class per edge would spend more time in retain/release traffic
/// than in the search. Everything here is a flat array indexed by node or edge
/// number, with a CSR adjacency, which is the same shape the ported search
/// already expects.
///
/// Node identity is OSM's. That is not incidental: it is the mechanism by
/// which data stored as separate chunks becomes one graph. A junction present
/// in two chunks is the same integer in both, so merging chunks and building a
/// graph joins their ways automatically, with no geometric stitching and no
/// seam at the boundary.
public struct LocalWalkingGraph: Sendable {
    // MARK: Nodes
    public let nodeOSMID: [Int64]
    public let nodeLat: [Double]
    public let nodeLon: [Double]

    // MARK: Edges
    public let edgeFrom: [Int32]
    public let edgeTo: [Int32]
    public let edgeMetres: [Double]
    /// What a metre of this edge costs a search that is choosing between ways,
    /// against a metre of the ground a walker would rather be on. 1 for a
    /// dedicated pedestrian way. Never applied to a reported distance — see
    /// `PedestrianAccessPolicy.weight(tags:roadClass:)`.
    public let edgeWeight: [Double]
    public let edgeForward: [Bool]
    public let edgeBackward: [Bool]
    /// Offsets into `geometry`; edge `i` occupies `geometryStart[i]..<geometryStart[i+1]`.
    public let geometryStart: [Int32]
    /// Flat lon/lat pairs, `from` end first.
    public let geometry: [Double]
    /// Index into `names`, or -1 where the way has no name.
    public let edgeName: [Int32]
    public let edgeRoadClass: [UInt8]
    /// The OSM way this edge came from. The physical identity a walk's
    /// "already spent this ground" accounting is decided on.
    public let edgeWayID: [Int64]
    /// Whether this edge is a walker crossing a carriageway rather than a way
    /// running along one. Read from tags by
    /// `PedestrianAccessPolicy.isCrossing(tags:)`, and deliberately kept
    /// separate from `edgeRoadClass` — see that method for why.
    ///
    /// Nothing in the cost model reads this. It exists so that guidance can say
    /// "cross the road" instead of calling a turn onto ten metres of unnamed
    /// tarmac, and so that a route's crossings can be counted.
    public let edgeIsCrossing: [Bool]
    /// For a crossing edge, the `names` slot of the carriageway it crosses, or
    /// `-1` where none could be identified. Meaningless on any other edge.
    public let edgeCrosses: [Int32]
    /// The street this edge belongs to, as a `names` slot — the same slot for a
    /// carriageway, both its pavements, and the crossings between them. `-1`
    /// where nothing could be established. See `LocalStreetGroups`.
    public let edgeStreet: [Int32]
    /// Whether a pedestrian way runs alongside this carriageway edge.
    public let edgeHasParallelPavement: [Bool]
    /// Additive cost in metres-equivalent, on top of `edgeMetres × edgeWeight`.
    /// Never applied to a reported distance.
    public let edgeSurcharge: [Double]
    public let names: [String]

    // MARK: Adjacency (CSR)
    public let arcStart: [Int32]
    public let arcEdge: [Int32]
    public let arcTo: [Int32]
    public let arcForward: [Bool]

    public var nodeCount: Int { nodeOSMID.count }
    public var edgeCount: Int { edgeFrom.count }
    public var arcCount: Int { arcEdge.count }

    public func name(ofEdge edge: Int) -> String? {
        let index = edgeName[edge]
        return index >= 0 ? names[Int(index)] : nil
    }

    public func roadClass(ofEdge edge: Int) -> PedestrianAccessPolicy.RoadClass {
        PedestrianAccessPolicy.RoadClass(rawValue: edgeRoadClass[edge]) ?? .other
    }

    public func isCrossing(ofEdge edge: Int) -> Bool {
        edge < edgeIsCrossing.count ? edgeIsCrossing[edge] : false
    }

    /// The carriageway a crossing edge crosses, where the builder could name
    /// one. Nil on a non-crossing edge and on a crossing of an unnamed road.
    public func crossedRoad(ofEdge edge: Int) -> String? {
        guard edge < edgeCrosses.count else { return nil }
        let slot = edgeCrosses[edge]
        return slot >= 0 ? names[Int(slot)] : nil
    }

    /// The street this edge belongs to, where one is known.
    public func street(ofEdge edge: Int) -> String? {
        guard edge < edgeStreet.count else { return nil }
        let slot = edgeStreet[edge]
        return slot >= 0 ? names[Int(slot)] : nil
    }

    /// Flat lon/lat pairs for one edge, `from` end first.
    public func line(ofEdge edge: Int) -> ArraySlice<Double> {
        geometry[Int(geometryStart[edge])..<Int(geometryStart[edge + 1])]
    }

    public func coordinates(ofEdge edge: Int, forward: Bool) -> [Point] {
        let slice = line(ofEdge: edge)
        var out: [Point] = []
        out.reserveCapacity(slice.count / 2)
        var index = slice.startIndex
        while index + 1 < slice.endIndex {
            out.append(Point(slice[index], slice[index + 1]))
            index += 2
        }
        return forward ? out : out.reversed()
    }

    public init(
        nodeOSMID: [Int64], nodeLat: [Double], nodeLon: [Double],
        edgeFrom: [Int32], edgeTo: [Int32], edgeMetres: [Double],
        edgeWeight: [Double] = [],
        edgeForward: [Bool], edgeBackward: [Bool],
        geometryStart: [Int32], geometry: [Double],
        edgeName: [Int32], edgeRoadClass: [UInt8], edgeWayID: [Int64],
        edgeIsCrossing: [Bool] = [], edgeCrosses: [Int32] = [],
        groups: LocalStreetGroups? = nil,
        names: [String],
        arcStart: [Int32], arcEdge: [Int32], arcTo: [Int32], arcForward: [Bool]
    ) {
        self.nodeOSMID = nodeOSMID
        self.nodeLat = nodeLat
        self.nodeLon = nodeLon
        self.edgeFrom = edgeFrom
        self.edgeTo = edgeTo
        self.edgeMetres = edgeMetres
        // An unweighted caller — a fixture, or `empty` — gets a graph where
        // every way is as good as every other, which is what it was asking for.
        self.edgeWeight = edgeWeight.count == edgeFrom.count
            ? edgeWeight : [Double](repeating: 1, count: edgeFrom.count)
        self.edgeForward = edgeForward
        self.edgeBackward = edgeBackward
        self.geometryStart = geometryStart
        self.geometry = geometry
        self.edgeName = edgeName
        self.edgeRoadClass = edgeRoadClass
        self.edgeWayID = edgeWayID
        // A caller that says nothing about crossings — a fixture, or `empty` —
        // gets a graph with none, which is what it was asking for.
        self.edgeIsCrossing = edgeIsCrossing.count == edgeFrom.count
            ? edgeIsCrossing : [Bool](repeating: false, count: edgeFrom.count)
        self.edgeCrosses = edgeCrosses.count == edgeFrom.count
            ? edgeCrosses : [Int32](repeating: -1, count: edgeFrom.count)
        // A caller that says nothing about streets — a fixture, or `empty` —
        // gets a graph where no street rule fires, which is what it asked for.
        let grouping = (groups?.street.count == edgeFrom.count ? groups : nil)
            ?? LocalStreetGroups.empty(edgeCount: edgeFrom.count)
        self.edgeStreet = grouping.street
        self.edgeHasParallelPavement = grouping.hasParallelPavement
        self.edgeSurcharge = grouping.surcharge
        self.names = names
        self.arcStart = arcStart
        self.arcEdge = arcEdge
        self.arcTo = arcTo
        self.arcForward = arcForward
    }

    public static let empty = LocalWalkingGraph(
        nodeOSMID: [], nodeLat: [], nodeLon: [],
        edgeFrom: [], edgeTo: [], edgeMetres: [], edgeForward: [], edgeBackward: [],
        geometryStart: [0], geometry: [], edgeName: [], edgeRoadClass: [], edgeWayID: [], names: [],
        arcStart: [0], arcEdge: [], arcTo: [], arcForward: []
    )
}

/// Turning stored OSM data into the graph above.
///
/// Three things here are worth stating because getting any of them wrong
/// produces a graph that looks fine and routes badly:
///
/// 1. **Only junctions become nodes.** A way's intermediate vertices are
///    geometry, not decision points. Keeping them as nodes would multiply the
///    search space by the vertex density of the survey, which varies by an
///    order of magnitude between a straight road and a winding lane.
/// 2. **A way is cut where its data runs out.** When only some of a way's
///    nodes are in the loaded chunks, the way becomes runs of consecutive
///    known nodes rather than being dropped or, worse, drawn as a straight
///    line across the gap.
/// 3. **A blocked node genuinely severs the way.** A locked gate mapped as a
///    point is a wall; the runs either side of it get separate node identities
///    so no route can pass through.
public enum LocalWalkingGraphBuilder {
    public struct Report: Sendable, Equatable {
        public var waysConsidered = 0
        public var waysWalkable = 0
        public var nodesLoaded = 0
        public var graphNodes = 0
        public var graphEdges = 0
        /// Edges the street grouping could place. See `LocalStreetGroups`.
        public var groupedEdges = 0
        /// Carriageway edges with a pavement running alongside them.
        public var pavedCarriageways = 0
        public var buildMs: Double = 0
    }

    public static func build(
        from data: OSMData,
        policy: PedestrianAccessPolicy = .standard
    ) -> (graph: LocalWalkingGraph, report: Report) {
        let began = Date()
        var report = Report()
        report.nodesLoaded = data.nodes.count
        report.waysConsidered = data.ways.count

        var nodeByID: [Int64: OSMNode] = [:]
        nodeByID.reserveCapacity(data.nodes.count)
        for node in data.nodes { nodeByID[node.id] = node }

        /// One walkable stretch of one way, as ids we have coordinates for.
        struct Run {
            var wayID: Int64
            var ids: [Int64]
            var decision: PedestrianAccessPolicy.Decision
            var name: String?
            var isCrossing: Bool
        }

        var runs: [Run] = []
        runs.reserveCapacity(data.ways.count)
        for way in data.ways {
            let decision = policy.decide(way: way)
            guard decision.isWalkable else { continue }
            report.waysWalkable += 1
            let name = way.tags["name"] ?? way.tags["ref"]
            let crossing = policy.isCrossing(tags: way.tags)
            var current: [Int64] = []
            for id in way.nodes {
                guard let node = nodeByID[id] else {
                    // Coordinates for this node are in a chunk we have not
                    // loaded. Close the run here rather than bridging the gap.
                    if current.count >= 2 { runs.append(Run(wayID: way.id, ids: current, decision: decision, name: name, isCrossing: crossing)) }
                    current = []
                    continue
                }
                if policy.canPass(node: node) {
                    current.append(id)
                } else {
                    // The barrier terminates the approach and is not an
                    // endpoint of what lies beyond it: restarting the next run
                    // *at* the barrier node would reconnect the two sides
                    // through the very thing that blocks them.
                    current.append(id)
                    if current.count >= 2 { runs.append(Run(wayID: way.id, ids: current, decision: decision, name: name, isCrossing: crossing)) }
                    current = []
                }
            }
            if current.count >= 2 { runs.append(Run(wayID: way.id, ids: current, decision: decision, name: name, isCrossing: crossing)) }
        }

        // A node is a junction if more than one run uses it, if it begins or
        // ends a run, or if one run passes through it twice.
        var usage: [Int64: Int] = [:]
        usage.reserveCapacity(nodeByID.count)
        for run in runs {
            var seenInRun: Set<Int64> = []
            for (position, id) in run.ids.enumerated() {
                let isEnd = position == 0 || position == run.ids.count - 1
                if isEnd || !seenInRun.insert(id).inserted {
                    usage[id, default: 0] += 2
                } else {
                    usage[id, default: 0] += 1
                }
            }
        }

        var nodeIndex: [Int64: Int32] = [:]
        var nodeOSMID: [Int64] = []
        var nodeLat: [Double] = []
        var nodeLon: [Double] = []
        func graphNode(_ id: Int64) -> Int32 {
            if let existing = nodeIndex[id] { return existing }
            let node = nodeByID[id]!
            let index = Int32(nodeOSMID.count)
            nodeIndex[id] = index
            nodeOSMID.append(id)
            nodeLat.append(node.lat)
            nodeLon.append(node.lon)
            return index
        }

        var edgeFrom: [Int32] = [], edgeTo: [Int32] = []
        var edgeMetres: [Double] = [], edgeWeight: [Double] = []
        var edgeForward: [Bool] = [], edgeBackward: [Bool] = []
        var geometryStart: [Int32] = [0]
        var geometry: [Double] = []
        var edgeName: [Int32] = [], edgeRoadClass: [UInt8] = [], edgeWayID: [Int64] = []
        var edgeIsCrossing: [Bool] = []
        var names: [String] = []
        var nameIndex: [String: Int32] = [:]
        geometry.reserveCapacity(runs.count * 8)

        for run in runs {
            let nameSlot: Int32
            if let name = run.name {
                if let existing = nameIndex[name] {
                    nameSlot = existing
                } else {
                    nameSlot = Int32(names.count)
                    nameIndex[name] = nameSlot
                    names.append(name)
                }
            } else {
                nameSlot = -1
            }

            var segmentStart = 0
            var metres = 0.0
            var pending: [Double] = []
            let first = nodeByID[run.ids[0]]!
            pending.append(first.lon)
            pending.append(first.lat)

            for position in 1..<run.ids.count {
                let previous = nodeByID[run.ids[position - 1]]!
                let node = nodeByID[run.ids[position]]!
                metres += LocalGeo.distance(lat1: previous.lat, lon1: previous.lon, lat2: node.lat, lon2: node.lon)
                pending.append(node.lon)
                pending.append(node.lat)

                let isJunction = (usage[run.ids[position]] ?? 0) >= 2
                guard isJunction || position == run.ids.count - 1 else { continue }
                // A zero-length hop between two coincident nodes is survey
                // noise, not an edge; it would give the search a free move.
                if metres > 0.05 {
                    edgeFrom.append(graphNode(run.ids[segmentStart]))
                    edgeTo.append(graphNode(run.ids[position]))
                    edgeMetres.append(metres)
                    edgeWeight.append(run.decision.weight)
                    edgeForward.append(run.decision.forward)
                    edgeBackward.append(run.decision.backward)
                    edgeName.append(nameSlot)
                    edgeRoadClass.append(run.decision.roadClass.rawValue)
                    edgeWayID.append(run.wayID)
                    edgeIsCrossing.append(run.isCrossing)
                    geometry.append(contentsOf: pending)
                    geometryStart.append(Int32(geometry.count))
                }
                segmentStart = position
                metres = 0
                pending = [node.lon, node.lat]
            }
        }

        // CSR adjacency over the oriented moves.
        let nodeCount = nodeOSMID.count
        var outDegree = [Int32](repeating: 0, count: nodeCount)
        for edge in 0..<edgeFrom.count {
            if edgeForward[edge] { outDegree[Int(edgeFrom[edge])] += 1 }
            if edgeBackward[edge] { outDegree[Int(edgeTo[edge])] += 1 }
        }
        var arcStart = [Int32](repeating: 0, count: nodeCount + 1)
        for node in 0..<nodeCount { arcStart[node + 1] = arcStart[node] + outDegree[node] }
        let arcTotal = Int(arcStart[nodeCount])
        var arcEdge = [Int32](repeating: 0, count: arcTotal)
        var arcTo = [Int32](repeating: 0, count: arcTotal)
        var arcForward = [Bool](repeating: false, count: arcTotal)
        var cursor = Array(arcStart[0..<nodeCount])
        for edge in 0..<edgeFrom.count {
            if edgeForward[edge] {
                let slot = Int(cursor[Int(edgeFrom[edge])])
                cursor[Int(edgeFrom[edge])] += 1
                arcEdge[slot] = Int32(edge)
                arcTo[slot] = edgeTo[edge]
                arcForward[slot] = true
            }
            if edgeBackward[edge] {
                let slot = Int(cursor[Int(edgeTo[edge])])
                cursor[Int(edgeTo[edge])] += 1
                arcEdge[slot] = Int32(edge)
                arcTo[slot] = edgeFrom[edge]
                arcForward[slot] = false
            }
        }

        // The road each crossing crosses, for guidance to name.
        //
        // A `footway=crossing` way is split *at* the carriageway it crosses,
        // because the node the two share is a junction and so becomes a graph
        // node. The carriageway is therefore incident to one of the crossing
        // edge's own endpoints, and its name can be read from the graph's own
        // topology — no geometry, no spatial query, no guessing at what runs
        // alongside what.
        var crossingEndpoints: Set<Int32> = []
        for edge in 0..<edgeFrom.count where edgeIsCrossing[edge] {
            crossingEndpoints.insert(edgeFrom[edge])
            crossingEndpoints.insert(edgeTo[edge])
        }
        var edgeCrosses = [Int32](repeating: -1, count: edgeFrom.count)
        if !crossingEndpoints.isEmpty {
            var roadsAtNode: [Int32: [Int32]] = [:]
            for edge in 0..<edgeFrom.count {
                guard !edgeIsCrossing[edge], edgeName[edge] >= 0 else { continue }
                let roadClass = PedestrianAccessPolicy.RoadClass(rawValue: edgeRoadClass[edge]) ?? .other
                guard !roadClass.isPedestrianWay else { continue }
                for node in [edgeFrom[edge], edgeTo[edge]] where crossingEndpoints.contains(node) {
                    roadsAtNode[node, default: []].append(edgeName[edge])
                }
            }
            for edge in 0..<edgeFrom.count where edgeIsCrossing[edge] {
                var tally: [Int32: Int] = [:]
                for node in [edgeFrom[edge], edgeTo[edge]] {
                    for slot in roadsAtNode[node] ?? [] { tally[slot, default: 0] += 1 }
                }
                // The most-shared name wins, and the lowest slot breaks a tie so
                // the answer never depends on dictionary ordering.
                edgeCrosses[edge] = tally
                    .sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }
                    .first?.key ?? -1
            }
        }

        report.graphNodes = nodeCount
        report.graphEdges = edgeFrom.count

        // Grouping needs the finished graph to read — geometry, classes,
        // crossings and names all at once — so it runs against a graph built
        // without it, and its answers are folded into the graph that is
        // returned. Swift arrays are copy-on-write, so this costs one array of
        // weights rather than a second graph.
        let ungrouped = LocalWalkingGraph(
            nodeOSMID: nodeOSMID, nodeLat: nodeLat, nodeLon: nodeLon,
            edgeFrom: edgeFrom, edgeTo: edgeTo, edgeMetres: edgeMetres, edgeWeight: edgeWeight,
            edgeForward: edgeForward, edgeBackward: edgeBackward,
            geometryStart: geometryStart, geometry: geometry,
            edgeName: edgeName, edgeRoadClass: edgeRoadClass, edgeWayID: edgeWayID,
            edgeIsCrossing: edgeIsCrossing, edgeCrosses: edgeCrosses,
            names: names,
            arcStart: arcStart, arcEdge: arcEdge, arcTo: arcTo, arcForward: arcForward
        )
        let groups = LocalStreetGroups.build(for: ungrouped)

        // A carriageway with a pavement beside it is dearer *there*, and
        // nowhere else. A road with no pavement alongside keeps exactly the
        // 1.25 it has always had: it is very often the only way through, so a
        // charge with no escape would distort leg lengths and buy nothing.
        var grouped = edgeWeight
        for edge in 0..<grouped.count where groups.hasParallelPavement[edge] {
            grouped[edge] *= LocalStreetGroups.parallelPavementPenalty
        }
        report.groupedEdges = groups.street.reduce(0) { $1 >= 0 ? $0 + 1 : $0 }
        report.pavedCarriageways = groups.hasParallelPavement.reduce(0) { $1 ? $0 + 1 : $0 }
        report.buildMs = Date().timeIntervalSince(began) * 1000

        let graph = LocalWalkingGraph(
            nodeOSMID: nodeOSMID, nodeLat: nodeLat, nodeLon: nodeLon,
            edgeFrom: edgeFrom, edgeTo: edgeTo, edgeMetres: edgeMetres, edgeWeight: grouped,
            edgeForward: edgeForward, edgeBackward: edgeBackward,
            geometryStart: geometryStart, geometry: geometry,
            edgeName: edgeName, edgeRoadClass: edgeRoadClass, edgeWayID: edgeWayID,
            edgeIsCrossing: edgeIsCrossing, edgeCrosses: edgeCrosses,
            groups: groups,
            names: names,
            arcStart: arcStart, arcEdge: arcEdge, arcTo: arcTo, arcForward: arcForward
        )
        return (graph, report)
    }
}
