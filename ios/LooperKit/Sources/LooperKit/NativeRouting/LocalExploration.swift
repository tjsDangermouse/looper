import Foundation

/// The request-local slice of the network a walk is searched over.
///
/// The same shape the Java reference builds before its closed-walk search, and
/// for the same reasons: `networkMetres` is an exact shortest walking distance
/// from the start rather than an estimate, which is what lets the search prune
/// on "this state can no longer get home inside the band" without ever
/// discarding a walk it should have kept.
public struct RoutingSubgraph: Sendable {
    public struct ReachedNode: Sendable {
        /// Index in the base graph, or -1 for the virtual start node.
        public var baseNode: Int32
        public var lat: Double
        public var lon: Double
        /// Exact shortest walkable distance from the start, in metres.
        public var networkMetres: Double
    }

    public struct SubEdge: Sendable {
        public var from: Int32
        public var to: Int32
        public var metres: Double
        /// Identity within this subgraph; what a rebuilt walk is made of.
        public var id: Int32
        /// The base-graph edge underneath. Two halves of a split edge share
        /// it, which is what makes "this ground is already spent" mean the
        /// same thing here as it does on the network.
        public var physical: Int32
        public var forward: Bool
        public var backward: Bool
        /// Flat lon/lat pairs, `from` end first.
        public var geometry: [Double]
    }

    public var nodes: [ReachedNode]
    public var edges: [SubEdge]
    /// Index into `nodes` of where the walk begins.
    public var startNode: Int
    public var snappedLat: Double
    public var snappedLon: Double
}

/// Bounded Dijkstra over the local graph.
///
/// This is the milestone that proves the phone genuinely owns a routing graph
/// rather than a pile of downloaded coordinates: given a point and a distance,
/// it walks the network outward exactly as far as a closed walk of that length
/// could possibly reach, with no service involved at any point.
public enum LocalExploration {
    public struct Diagnostics: Sendable, Equatable {
        public var nodesLoaded = 0
        public var edgesLoaded = 0
        public var nodesReached = 0
        public var edgesReached = 0
        public var snapDistanceMetres: Double = 0
        public var limitMetres: Double = 0
        public var exploreMs: Double = 0
        /// Approximate bytes held by the loaded graph's own arrays.
        public var graphBytes = 0
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case emptyGraph
        case nothingToSnapTo(nearestMetres: Double?)

        public var errorDescription: String? {
            switch self {
            case .emptyGraph:
                return "There are no walking paths in the downloaded data for this area."
            case .nothingToSnapTo:
                return "There's no walking path near enough to that starting point."
            }
        }
    }

    /// Explore outward to `limitMetres` of network distance.
    public static func explore(
        graph: LocalWalkingGraph,
        index: LocalEdgeIndex,
        lat: Double,
        lon: Double,
        limitMetres: Double,
        maximumSnapMetres: Double = 500
    ) throws -> (subgraph: RoutingSubgraph, diagnostics: Diagnostics) {
        let began = Date()
        var diagnostics = Diagnostics()
        diagnostics.nodesLoaded = graph.nodeCount
        diagnostics.edgesLoaded = graph.edgeCount
        diagnostics.limitMetres = limitMetres
        diagnostics.graphBytes = approximateBytes(of: graph)
        guard graph.edgeCount > 0 else { throw Failure.emptyGraph }
        guard let snap = index.snap(lat: lat, lon: lon, graph: graph, maximumMetres: maximumSnapMetres) else {
            throw Failure.nothingToSnapTo(nearestMetres: nil)
        }
        diagnostics.snapDistanceMetres = snap.distanceMetres

        // ------------------------------------------------------------ seeds
        // A start mid-edge is a node the network does not have, so one is
        // made: the edge is split in two, both halves keeping the base edge's
        // identity. A start already at a junction needs none of this.
        let fromNode = Int(graph.edgeFrom[snap.edge])
        let toNode = Int(graph.edgeTo[snap.edge])
        let atFrom = snap.metresFromStart < 0.5
        let atTo = snap.metresToEnd < 0.5
        let splitsAnEdge = !(atFrom || atTo)

        var distance = [Double](repeating: .infinity, count: graph.nodeCount)
        var settled = [Bool](repeating: false, count: graph.nodeCount)
        var heap = BinaryHeap()

        if atFrom {
            distance[fromNode] = 0
            heap.push(node: Int32(fromNode), key: 0)
        } else if atTo {
            distance[toNode] = 0
            heap.push(node: Int32(toNode), key: 0)
        } else {
            // Reaching `from` means walking the edge backwards, which only a
            // two-way edge allows; reaching `to` means walking it forwards.
            if graph.edgeBackward[snap.edge], snap.metresFromStart <= limitMetres {
                distance[fromNode] = snap.metresFromStart
                heap.push(node: Int32(fromNode), key: snap.metresFromStart)
            }
            if graph.edgeForward[snap.edge], snap.metresToEnd <= limitMetres {
                distance[toNode] = snap.metresToEnd
                heap.push(node: Int32(toNode), key: snap.metresToEnd)
            }
        }

        // ---------------------------------------------------------- Dijkstra
        while let entry = heap.pop() {
            let node = Int(entry.node)
            if settled[node] { continue }
            if entry.key > distance[node] { continue }
            settled[node] = true
            let here = distance[node]
            for arc in Int(graph.arcStart[node])..<Int(graph.arcStart[node + 1]) {
                let next = Int(graph.arcTo[arc])
                let step = here + graph.edgeMetres[Int(graph.arcEdge[arc])]
                guard step <= limitMetres, step < distance[next] else { continue }
                distance[next] = step
                heap.push(node: Int32(next), key: step)
            }
        }

        // ------------------------------------------------------- the subgraph
        var subIndex = [Int32](repeating: -1, count: graph.nodeCount)
        var nodes: [RoutingSubgraph.ReachedNode] = []
        let startSub: Int
        if splitsAnEdge {
            startSub = 0
            nodes.append(.init(baseNode: -1, lat: snap.lat, lon: snap.lon, networkMetres: 0))
        } else {
            startSub = 0
            let base = atFrom ? fromNode : toNode
            subIndex[base] = 0
            nodes.append(.init(baseNode: Int32(base), lat: graph.nodeLat[base], lon: graph.nodeLon[base], networkMetres: 0))
        }
        for node in 0..<graph.nodeCount where distance[node] <= limitMetres && subIndex[node] < 0 {
            subIndex[node] = Int32(nodes.count)
            nodes.append(.init(
                baseNode: Int32(node),
                lat: graph.nodeLat[node],
                lon: graph.nodeLon[node],
                networkMetres: distance[node]
            ))
        }

        var edges: [RoutingSubgraph.SubEdge] = []
        edges.reserveCapacity(graph.edgeCount / 2)
        for edge in 0..<graph.edgeCount {
            // The split edge is represented by its two halves instead.
            if splitsAnEdge && edge == snap.edge { continue }
            let a = subIndex[Int(graph.edgeFrom[edge])], b = subIndex[Int(graph.edgeTo[edge])]
            guard a >= 0, b >= 0 else { continue }
            edges.append(.init(
                from: a, to: b, metres: graph.edgeMetres[edge], id: Int32(edges.count), physical: Int32(edge),
                forward: graph.edgeForward[edge], backward: graph.edgeBackward[edge],
                geometry: Array(graph.line(ofEdge: edge))
            ))
        }
        if splitsAnEdge {
            let halves = index.split(snap, graph: graph)
            if subIndex[fromNode] >= 0 {
                edges.append(.init(
                    from: 0, to: subIndex[fromNode], metres: snap.metresFromStart, id: Int32(edges.count),
                    physical: Int32(snap.edge),
                    // Start-to-`from` runs against the edge; `from`-to-start runs with it.
                    forward: graph.edgeBackward[snap.edge], backward: graph.edgeForward[snap.edge],
                    geometry: halves.towardsFrom
                ))
            }
            if subIndex[toNode] >= 0 {
                edges.append(.init(
                    from: 0, to: subIndex[toNode], metres: snap.metresToEnd, id: Int32(edges.count),
                    physical: Int32(snap.edge),
                    forward: graph.edgeForward[snap.edge], backward: graph.edgeBackward[snap.edge],
                    geometry: halves.towardsTo
                ))
            }
        }

        diagnostics.nodesReached = nodes.count
        diagnostics.edgesReached = edges.count
        diagnostics.exploreMs = Date().timeIntervalSince(began) * 1000

        return (
            RoutingSubgraph(nodes: nodes, edges: edges, startNode: startSub, snappedLat: snap.lat, snappedLon: snap.lon),
            diagnostics
        )
    }

    static func approximateBytes(of graph: LocalWalkingGraph) -> Int {
        graph.nodeCount * (8 + 8 + 8)
            + graph.edgeCount * (4 + 4 + 8 + 1 + 1 + 4 + 4 + 1 + 8)
            + graph.geometry.count * 8
            + graph.arcCount * (4 + 4 + 1)
            + graph.names.reduce(0) { $0 + $1.utf8.count + 16 }
    }
}

/// A pairing heap would be asymptotically nicer; a binary heap on two flat
/// arrays is faster at the sizes this actually runs at, and has no allocation
/// per push.
struct BinaryHeap {
    private var nodes: [Int32] = []
    private var keys: [Double] = []

    var isEmpty: Bool { nodes.isEmpty }

    mutating func push(node: Int32, key: Double) {
        nodes.append(node)
        keys.append(key)
        var child = nodes.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard keys[child] < keys[parent] else { break }
            nodes.swapAt(child, parent)
            keys.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (node: Int32, key: Double)? {
        guard !nodes.isEmpty else { return nil }
        let top = (node: nodes[0], key: keys[0])
        let last = nodes.count - 1
        nodes.swapAt(0, last)
        keys.swapAt(0, last)
        nodes.removeLast()
        keys.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1, right = left + 1
            var smallest = parent
            if left < nodes.count && keys[left] < keys[smallest] { smallest = left }
            if right < nodes.count && keys[right] < keys[smallest] { smallest = right }
            guard smallest != parent else { break }
            nodes.swapAt(parent, smallest)
            keys.swapAt(parent, smallest)
            parent = smallest
        }
        return top
    }
}
