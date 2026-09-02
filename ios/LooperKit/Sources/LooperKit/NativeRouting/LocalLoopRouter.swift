import Foundation

/// The on-device closed-walk engine, end to end.
///
/// One request in, a set of finished routes out, and no routing call anywhere
/// in between. The stages are the reference implementation's, in the same
/// order and with the same responsibilities:
///
/// ```text
/// bounded exploration   Dijkstra over the local foot graph, out to
///                       (1 + MAX_DISTANCE_ERROR) / 2 of the target
/// graph reduction       2-core peel and degree-2 contraction
/// search                the beam over distance bands
/// selection             the exact shape and turn measures the search already
///                       holds, with a compass-octant quota so what is handed
///                       on is separable
/// materialisation       the searched edge sequence turned into a line, a
///                       duration and instructions — without searching again
/// ```
///
/// ## The searched walk is the answer
///
/// Phase 9 measured what happens when a searched walk is handed back to a
/// router as via points: given three corners of a walk known to be good, the
/// router returns something 1,486 m away from it at median, agreeing on 15% of
/// its edges, and not one of twelve passes the gate. So nothing here
/// re-routes, and nothing here is sent anywhere. The edge sequence the search
/// chose is the edge sequence that comes back.
///
/// ## What this does not decide
///
/// Whether a walk is offered. `RouteQuality` is the authority, with no
/// threshold relaxed — the same gate, ported from the same source, that judges
/// the remote engine's answers.
public struct LocalLoopRouter: Sendable {
    /// `MAX_BOUNDING_BOX_RATIO` in the quality gate.
    public static let maxBoundingBoxRatio = RouteQuality.maxBoundingBoxRatio
    /// How many walks the search hands the gate to judge. The search closes
    /// far more than this; what the number buys is the selector's room to
    /// separate three genuinely different ones.
    ///
    /// The service caps this at 24 because every candidate it hands back
    /// crosses a wire carrying its full geometry, instructions and path
    /// details. On the device there is no wire, and the cap is simply the
    /// pool a refresh draws from: what is not shortlisted can never be
    /// offered, however many walks the search closed.
    ///
    /// It has been the binding constraint twice. At 24 the selector starved.
    /// At 64, widening the beam raised Douglas 4 km from 80 closed walks to
    /// 274 and the walker saw *fewer* of them, because a refresh exhausted the
    /// same 64 either way. So it now sits above what the search closes, and
    /// costs about two milliseconds a candidate against a search of seconds.
    public static let defaultCandidateWalks = 256

    public struct Request: Sendable {
        public var lat: Double
        public var lon: Double
        public var targetMetres: Double
        public var wanted: Int
        public var candidateWalks: Int
        public var searchBudget: Int
        /// Which of the equally-good walks to prefer, advanced by the app on
        /// every refresh. The search is deterministic, so without this a
        /// refresh re-runs the identical search; exclusion can then only hand
        /// back what is left of one fixed pool, and a walker leaning on the
        /// button exhausts it. See `WalkSearch.variationAmplitude`.
        public var variation: Int
        /// Walks already offered from this doorstep, as lines.
        ///
        /// The search is deterministic: the same start and the same target
        /// close the same walks in the same order every time. So "show me
        /// different ones" cannot be answered by searching again — it is
        /// answered by choosing again, from the same pool, without the walks
        /// already seen. That is why this has to reach the selector rather
        /// than filtering what the selector returned.
        public var exclude: [[Point]]

        public init(
            lat: Double, lon: Double, targetMetres: Double, wanted: Int = 3,
            candidateWalks: Int = LocalLoopRouter.defaultCandidateWalks, searchBudget: Int = 4_000_000,
            variation: Int = 0, exclude: [[Point]] = []
        ) {
            self.lat = lat
            self.lon = lon
            self.targetMetres = targetMetres
            self.wanted = wanted
            self.candidateWalks = candidateWalks
            self.searchBudget = searchBudget
            self.variation = variation
            self.exclude = exclude
        }
    }

    /// Everything a development build wants to know about how the answer was
    /// produced. None of it reaches a walker.
    public struct Diagnostics: Sendable, Equatable {
        public var graphNodes = 0
        public var graphEdges = 0
        public var exploration = LocalExploration.Diagnostics()
        public var searchGraph = WalkSearchGraph.Stats()
        public var search = WalkSearch.Stats()
        public var closedWalks = 0
        public var rejectedShape = 0
        public var rejectedTurns = 0
        public var gateRejected = 0
        /// Which of the gate's rules did the refusing, by `RouteQuality`'s own
        /// rejection names. A walk failing three rules is counted under all
        /// three: the question this answers is "which rule is costing us
        /// walks", not "how were the walks distributed".
        public var gateRejectionsByReason: [String: Int] = [:]
        public var passedGate = 0
        /// Walks that passed the gate but were too like one already chosen.
        public var diversityRejected = 0
        /// Passed the gate, were different enough, and simply did not fit.
        public var diversityNoRoom = 0
        /// Gate-passing walks set aside because they had already been offered.
        public var excludedAsAlreadySeen = 0
        /// Every gate-passing walk had already been offered, so the answer was
        /// filled entirely from walks the walker has seen.
        public var excludeExhausted = false
        /// Places in the answer filled from already-seen walks because there
        /// were not enough new ones to fill them.
        public var toppedUpFromSeen = 0
        /// The out-and-back to the nearest node the circuit search could root
        /// at. Zero when the start is already in the 2-core. Every walk in the
        /// answer carries it, at both ends, and is charged for it by the
        /// gate's start-spur rule.
        public var stemMetres: Double = 0
        /// How many compass octants the shortlist handed to the gate spans.
        /// The selector's first pass insists on a new octant per walk, so a
        /// shortlist sitting in two octants cannot yield three separable
        /// walks however long it is.
        public var shortlistOctants = 0
        /// One per offered walk, in the order they are offered. See
        /// `RouteQuality.pavement`: the share of the walk on ways meant for
        /// walkers, and how often it crossed between those and the carriageway.
        public var offeredPavement: [RouteQuality.PavementReport] = []
        public var offered = 0
        // --- The ported ring generator. Zero on the searched path. ----------
        /// Candidates the sweep tried to build.
        public var candidatesBuilt = 0
        /// Builds that gave up — a leg that could not be routed at all, or a
        /// running total already past `ringAbandonShare` of the target.
        public var candidatesAbandoned = 0
        /// Sweeps run before the pool was big enough to choose from.
        public var batchesRun = 0
        /// Gate-passing candidates that go somewhere rather than round —
        /// `reachRatio >= RouteQuality.elongationReachRatio`. The selector's
        /// first pass asks for one kind of each, so a pool with none of these
        /// can only ever offer three round walks, however many it holds.
        public var poolElongated = 0
        /// How long the sweep spent building and judging candidates.
        public var sweepMs: Double = 0
        /// What the one re-aim rescaled the planned legs by, if it ran.
        public var reAimScale: Double = 0
        public var buildMs: Double = 0
        public var judgeMs: Double = 0
        public var assembleMs: Double = 0
        public var totalMs: Double = 0
        public var snappedLat: Double = 0
        public var snappedLon: Double = 0
        public var failure: String?

        // --- Ordered waypoints. Zero on every plain loop. ------------------
        /// Pins the walker dropped.
        public var waypointCount = 0
        /// Which way the waypoint path answered: the backbone generator, or
        /// the ring search filtered by pins that constrained almost nothing.
        public var waypointStage: String?
        /// The floor: the shortest walk visiting the pins in order. Whether a
        /// request is possible at all is decided against this and nothing else.
        public var waypointBackboneMetres: Double = 0
        /// Ways of crossing a gap that were routed and measured, over all gaps.
        public var waypointOptions = 0
        /// Combinations the slack allocation handed back to be assembled.
        public var waypointAllocations = 0
        /// How many of those enclosed enough ground to be worth preferring. If
        /// this is zero the shape preference had nothing to prefer, and the
        /// problem is where the shaping points are put rather than which
        /// combination is chosen.
        public var waypointEnclosing = 0
        /// Joins at which the departing gap had to be routed again to stop it
        /// turning round on the edge the arriving gap came in on. Each gap is
        /// routed independently, so without this every anchor costs the walk a
        /// U-turn — which on real ground refused every candidate.
        public var waypointJoinsRepaired = 0
        /// Assembled walks that had a short backtrack cut out of them before
        /// they were judged. Without this the gate refuses a whole walk for a
        /// forty-metre duck into a driveway — see `LocalSpikeTrim`.
        public var waypointSpikesTrimmed = 0
        /// Gate-passing walks that still pass every pin in order. Walks that
        /// do not are still offered when there is nothing better, but never
        /// ahead of one that does.
        public var waypointOfferedHittingPins = 0

        public init() {}
    }

    public struct Result {
        public var routes: [Route]
        public var diagnostics: Diagnostics
    }

    public enum Failure: Error, LocalizedError {
        case noNetwork(String)
        case noLoopFound

        public var errorDescription: String? {
            switch self {
            case .noNetwork(let detail): return detail
            case .noLoopFound:
                return "We couldn’t find a clean loop of that length from here. Try a different distance or move the start point."
            }
        }
    }

    public init() {}

    public func findLoops(_ request: Request, in data: OSMData) throws -> Result {
        let began = Date()
        var diagnostics = Diagnostics()

        let (graph, buildReport) = LocalWalkingGraphBuilder.build(from: data)
        diagnostics.graphNodes = buildReport.graphNodes
        diagnostics.graphEdges = buildReport.graphEdges
        diagnostics.buildMs = buildReport.buildMs
        return try findLoops(request, in: graph, index: LocalEdgeIndex(graph: graph), began: began, diagnostics: diagnostics)
    }

    /// The same search over a graph that has already been built. The app keeps
    /// one per area so that asking for a second set of loops from the same
    /// doorstep does not rebuild the town.
    public func findLoops(
        _ request: Request,
        in graph: LocalWalkingGraph,
        index: LocalEdgeIndex,
        began: Date = Date(),
        diagnostics initial: Diagnostics = Diagnostics()
    ) throws -> Result {
        var diagnostics = initial
        diagnostics.graphNodes = graph.nodeCount
        diagnostics.graphEdges = graph.edgeCount

        let limit = RoutingCoverage.explorationRadiusMetres(targetMetres: request.targetMetres)
        let explored: (subgraph: RoutingSubgraph, diagnostics: LocalExploration.Diagnostics)
        do {
            explored = try LocalExploration.explore(
                graph: graph, index: index, lat: request.lat, lon: request.lon, limitMetres: limit
            )
        } catch {
            diagnostics.failure = "no-network"
            diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
            throw Failure.noNetwork((error as? LocalizedError)?.errorDescription ?? "There are no walking paths near that starting point.")
        }
        diagnostics.exploration = explored.diagnostics
        diagnostics.snappedLat = explored.subgraph.snappedLat
        diagnostics.snappedLon = explored.subgraph.snappedLon

        let searchGraph = WalkSearchGraph(explored.subgraph)
        diagnostics.searchGraph = searchGraph.stats
        guard searchGraph.edgeCount > 0 else {
            diagnostics.failure = "no-circuit"
            diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
            throw Failure.noLoopFound
        }

        let result = WalkSearch.run(searchGraph, options: .init(
            targetMetres: request.targetMetres, budget: request.searchBudget, variation: request.variation
        ))
        diagnostics.search = result.stats
        diagnostics.closedWalks = result.walks.count

        // ------------------------------------------------------------- judge
        let judgeBegan = Date()
        let root = result.stats.root
        let stem = root == searchGraph.start ? nil : searchGraph.stem(to: root)
        let stemMetric = stem?.metric ?? []
        diagnostics.stemMetres = stem?.metres ?? 0

        struct Scored {
            var walk: WalkSearch.Walk
            var uTurns: Int
            var rank: Double
        }
        var scored: [Scored] = []
        for walk in result.walks {
            // The gate's own aspect rule, applied here on the gate's own terms
            // — a walk that reaches is allowed to be long and thin — so that
            // this stage never drops a walk the gate would have passed.
            let aspectLimit = walk.reachRatio >= RouteQuality.elongationReachRatio
                ? RouteQuality.elongatedBoundingBoxRatio : LocalLoopRouter.maxBoundingBoxRatio
            if walk.bboxRatio > aspectLimit { diagnostics.rejectedShape += 1; continue }
            let uTurns = WalkUTurns.count(metricLine(searchGraph, arcs: walk.arcs, stem: stemMetric))
            // The gate's own rule, applied here rather than only afterwards,
            // so a walk it is certain to reject does not take one of the
            // places handed on.
            if uTurns > WalkSearch.maxUTurns { diagnostics.rejectedTurns += 1; continue }
            scored.append(Scored(walk: walk, uTurns: uTurns, rank: rank(walk, uTurns: uTurns, targetMetres: request.targetMetres)))
        }
        let shortlist = withOctantQuota(scored.map { ($0.walk.family, $0.rank) }, wanted: request.candidateWalks)
            .map { scored[$0] }
        diagnostics.shortlistOctants = Set(shortlist.map(\.walk.family)).count
        diagnostics.judgeMs = Date().timeIntervalSince(judgeBegan) * 1000

        // ------------------------------------------------------- materialise
        let assembleBegan = Date()
        var candidates: [RouteDiversity.Candidate] = []
        var assembled: [(legs: [WalkLeg], coordinates: [Point], metres: Double, report: RouteQuality.Report)] = []
        let start = Point(explored.subgraph.snappedLon, explored.subgraph.snappedLat)

        for entry in shortlist {
            let legs = assemble(searchGraph, subgraph: explored.subgraph, base: graph, arcs: entry.walk.arcs, stem: stem)
            guard legs.count >= 2 else { continue }
            var coordinates: [Point] = []
            var metres = 0.0
            var physical: [Int32: Double] = [:]
            for leg in legs {
                metres += leg.metres
                for point in leg.coordinates where coordinates.last != point { coordinates.append(point) }
            }
            for id in walkSubEdgeIDs(searchGraph, arcs: entry.walk.arcs, stem: stem) {
                let edge = explored.subgraph.edges[Int(id)]
                physical[edge.physical, default: 0] += edge.metres
            }
            guard coordinates.count >= 4 else { continue }
            let report = RouteQuality.analyse(
                coordinates: coordinates, start: start, distanceMetres: metres, targetMetres: request.targetMetres,
                traversals: traversals(of: legs, origin: start),
                stemMetres: stem?.metres ?? 0
            )
            guard report.pass else {
                diagnostics.gateRejected += 1
                for reason in report.rejections { diagnostics.gateRejectionsByReason[reason, default: 0] += 1 }
                continue
            }
            assembled.append((legs, coordinates, metres, report))
            candidates.append(RouteDiversity.Candidate(
                coordinates: coordinates,
                score: report.quality.score,
                bearing: RouteDiversity.initialBearing(coordinates, from: start),
                edges: physical,
                totalMetres: metres,
                reachRatio: entry.walk.reachRatio
            ))
        }

        diagnostics.passedGate = candidates.count

        // Exclusion belongs here, on the pool, and not to the walks that come
        // back — which is where the service applies it too. Filtering the
        // answer instead of the pool means a refresh re-offers the same walks
        // or nothing at all, because the selector had already narrowed sixty
        // candidates down to the same three it chose last time.
        var unseen = Array(candidates.indices)
        var seen: [Int] = []
        if !request.exclude.isEmpty {
            // Every candidate against every excluded walk, which is the one
            // place in the request where the work is a product rather than a
            // sum. Both sides are resampled once, in the doorstep's frame, so
            // that the product is only the comparing.
            let excluded = request.exclude.map { RouteQuality.corridor($0, origin: start, indexed: true) }
            let sampled = candidates.map { RouteQuality.corridor($0.coordinates, origin: start) }
            let split = partition(unseen) { index in
                excluded.allSatisfy { previous in
                    RouteQuality.sharedCorridorMetres(sampled[index], previous).fraction
                        <= RouteQuality.maxSharedFraction
                }
            }
            unseen = split.matching
            seen = split.rest
            diagnostics.excludedAsAlreadySeen = seen.count
            diagnostics.excludeExhausted = unseen.isEmpty
        }

        // Walks not yet seen fill the answer first. If there are not enough of
        // them the rest of the places are filled from the ones that have been
        // — because a walker in a small town pressing refresh wants three
        // walks with whatever is new among them, and handing back one walk, or
        // the same three every time, are both worse answers than that.
        let selection = RouteDiversity.selecting(unseen.map { candidates[$0] }, limit: request.wanted)
        var chosen = selection.chosen.map { unseen[$0] }
        if chosen.count < request.wanted && !seen.isEmpty {
            let topUp = RouteDiversity.selecting(
                seen.map { candidates[$0] }, limit: request.wanted - chosen.count,
                alreadyTaken: chosen.map { candidates[$0] }
            )
            chosen += topUp.chosen.map { seen[$0] }
            diagnostics.toppedUpFromSeen = topUp.chosen.count
        }
        diagnostics.diversityRejected = selection.rejectedShared
        diagnostics.diversityNoRoom = selection.noRoom
        let labels = RouteDiversity.labels(for: chosen.map {
            (bearing: candidates[$0].bearing, distanceMetres: assembled[$0].metres)
        })
        var routes: [Route] = []
        for (position, index) in chosen.enumerated() {
            let entry = assembled[index]
            diagnostics.offeredPavement.append(RouteQuality.pavement(of: entry.legs))
            let seconds = entry.metres / LocalInstructions.walkingMetresPerSecond
            routes.append(Route(
                id: UUID().uuidString,
                name: labels[position],
                distanceMeters: entry.metres.rounded(),
                durationSeconds: seconds.rounded(),
                targetDifferencePercent: ((entry.metres / request.targetMetres - 1) * 100).rounded(),
                geometry: LineGeometry(coordinates: entry.coordinates),
                steps: tidySteps(LocalInstructions.steps(for: entry.legs)),
                routingEngine: .onDevice
            ))
        }
        diagnostics.assembleMs = Date().timeIntervalSince(assembleBegan) * 1000
        diagnostics.offered = routes.count
        diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
        if routes.isEmpty { diagnostics.failure = diagnostics.closedWalks == 0 ? "no-closed-walk" : "gate-rejected-all" }
        return Result(routes: routes, diagnostics: diagnostics)
    }

    // MARK: - Ranking and selection

    /// Split in one pass, keeping both halves in their original order.
    private func partition(_ indices: [Int], by keep: (Int) -> Bool) -> (matching: [Int], rest: [Int]) {
        var matching: [Int] = [], rest: [Int] = []
        for index in indices { if keep(index) { matching.append(index) } else { rest.append(index) } }
        return (matching, rest)
    }

    /// How well a closed walk answers the request, on the terms the quality
    /// score already uses and this stage already knows exactly: how close it
    /// is to the asked-for length, how good a shape it is, and whether it
    /// turns back on itself. Retracing is not among them because an
    /// edge-simple circuit has none, and leg balance is not because a searched
    /// walk has no legs.
    func rank(_ walk: WalkSearch.Walk, uTurns: Int, targetMetres: Double) -> Double {
        let closeness = 1 - Swift.min(1, abs(walk.metres - targetMetres) / (targetMetres * RoutingCoverage.maxDistanceError))
        // A good shape, not a round one. Scoring roundness alone puts every
        // long thin walk below every circle whatever else is true of it, which
        // is a claim about geometry and not about walking: a river out and a
        // street back is not a worse walk than a lap of the same estate. So a
        // walk may earn this either way, by being round or by going somewhere,
        // and only a walk that does neither — the knot of little loops — is
        // marked down.
        let round = Swift.min(1, walk.compactness / 0.5)
        let reaching = Swift.min(1, walk.reachRatio / RouteQuality.elongationReachRatio)
        let shape = Swift.max(round, reaching)
        let simplicity = 1 - Double(uTurns) / Double(WalkSearch.maxUTurns + 1)
        return 0.5 * closeness + 0.35 * shape + 0.15 * simplicity
    }

    /// Hand on the best of each compass octant before the best overall.
    ///
    /// The selector offers walks that share no more than 55% of their ground,
    /// so a set that is all one direction is a set it can take one walk from.
    /// The search already carries the octant a walk committed to, and it is
    /// the axis the selector judges on.
    func withOctantQuota(_ entries: [(family: Int, rank: Double)], wanted: Int) -> [Int] {
        let order = entries.indices.sorted { entries[$0].rank > entries[$1].rank }
        guard entries.count > wanted else { return order }
        var present = [Bool](repeating: false, count: 9)
        for entry in entries { present[entry.family + 1] = true }
        let families = present.filter { $0 }.count
        let quota = Swift.max(1, wanted / Swift.max(1, families))
        var taken = [Int](repeating: 0, count: 9)
        var chosen: [Int] = []
        var used = Set<Int>()
        for index in order {
            if chosen.count >= wanted { break }
            let slot = entries[index].family + 1
            if taken[slot] >= quota { continue }
            taken[slot] += 1
            used.insert(index)
            chosen.append(index)
        }
        for index in order where !used.contains(index) {
            if chosen.count >= wanted { break }
            chosen.append(index)
        }
        return chosen
    }

    // MARK: - Assembly

    /// The walk as a sequence of passes over physical edges, which is what the
    /// gate needs to measure retracing on the network rather than from the
    /// line. One leg is one pass, already oriented the way it was walked.
    func traversals(of legs: [WalkLeg], origin: Point) -> [RouteQuality.EdgeTraversal] {
        let frame = MetricFrame(originLon: origin.lng, originLat: origin.lat)
        var out: [RouteQuality.EdgeTraversal] = []
        out.reserveCapacity(legs.count)
        var along = 0.0
        for leg in legs {
            defer { along += leg.metres }
            guard leg.physical >= 0, let first = leg.coordinates.first, let last = leg.coordinates.last else { continue }
            let a = frame.project(lon: first.lng, lat: first.lat)
            let b = frame.project(lon: last.lng, lat: last.lat)
            let dx = b.x - a.x, dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            // A leg whose ends coincide has no direction to compare; without
            // one, a second pass over it cannot be called a reversal, so it is
            // counted as forward rather than guessed at.
            let (ux, uy) = length > 1e-9 ? (dx / length, dy / length) : (0.0, 0.0)
            out.append(RouteQuality.EdgeTraversal(
                id: leg.physical, metres: leg.metres, along: along, dirX: ux, dirY: uy
            ))
        }
        return out
    }

    /// The whole walk as flat x/y pairs in the start's metric frame: stem,
    /// circuit, stem back.
    func metricLine(_ graph: WalkSearchGraph, arcs: [Int32], stem: [Double]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(stem.count * 2 + arcs.count * 8)
        append(&out, stem, forward: true)
        for arc in arcs {
            append(&out, graph.edgeMetric[Int(graph.arcEdge[Int(arc)])], forward: graph.arcForward[Int(arc)])
        }
        append(&out, stem, forward: false)
        return out
    }

    private func append(_ out: inout [Double], _ line: [Double], forward: Bool) {
        guard line.count >= 2 else { return }
        if forward {
            var i = 0
            while i + 1 < line.count {
                if !(out.count >= 2 && out[out.count - 2] == line[i] && out[out.count - 1] == line[i + 1]) {
                    out.append(line[i]); out.append(line[i + 1])
                }
                i += 2
            }
        } else {
            var i = line.count - 2
            while i >= 0 {
                if !(out.count >= 2 && out[out.count - 2] == line[i] && out[out.count - 1] == line[i + 1]) {
                    out.append(line[i]); out.append(line[i + 1])
                }
                i -= 2
            }
        }
    }

    /// The subgraph edges the whole walk is made of, in walking order.
    func walkSubEdgeIDs(_ graph: WalkSearchGraph, arcs: [Int32], stem: WalkSearchGraph.Stem?) -> [Int32] {
        var ids: [Int32] = []
        if let stem { ids.append(contentsOf: stem.subEdgeIDs) }
        for arc in arcs {
            let edge = Int(graph.arcEdge[Int(arc)])
            let sub = graph.edgeSubIDs[edge]
            ids.append(contentsOf: graph.arcForward[Int(arc)] ? sub : sub.reversed())
        }
        if let stem { ids.append(contentsOf: stem.subEdgeIDs.reversed()) }
        return ids
    }

    /// The walk as ground: stem out, the circuit, stem back, one leg per
    /// underlying edge and each leg oriented the way it was walked.
    ///
    /// The legs are taken from the *subgraph* rather than from the base graph,
    /// which matters at exactly one place and matters a lot there: a walk
    /// starting mid-street begins on half an edge, and only the subgraph holds
    /// the half.
    func assemble(
        _ graph: WalkSearchGraph, subgraph: RoutingSubgraph, base: LocalWalkingGraph,
        arcs: [Int32], stem: WalkSearchGraph.Stem?
    ) -> [WalkLeg] {
        var legs: [WalkLeg] = []
        func add(_ id: Int32, forward: Bool) {
            let edge = subgraph.edges[Int(id)]
            var coordinates: [Point] = []
            coordinates.reserveCapacity(edge.geometry.count / 2)
            var i = 0
            while i + 1 < edge.geometry.count {
                coordinates.append(Point(edge.geometry[i], edge.geometry[i + 1]))
                i += 2
            }
            if !forward { coordinates.reverse() }
            let physical = Int(edge.physical)
            legs.append(WalkLeg(
                coordinates: coordinates,
                metres: edge.metres,
                name: base.name(ofEdge: physical),
                roadClass: base.roadClass(ofEdge: physical),
                physical: edge.physical
            ))
        }

        if let stem {
            for (position, id) in stem.subEdgeIDs.enumerated() { add(id, forward: stem.forward[position]) }
        }
        for arc in arcs {
            let edge = Int(graph.arcEdge[Int(arc)])
            let ids = graph.edgeSubIDs[edge]
            let runs = graph.edgeSubForward[edge]
            if graph.arcForward[Int(arc)] {
                for position in 0..<ids.count { add(ids[position], forward: runs[position]) }
            } else {
                for position in stride(from: ids.count - 1, through: 0, by: -1) { add(ids[position], forward: !runs[position]) }
            }
        }
        if let stem {
            for position in stride(from: stem.subEdgeIDs.count - 1, through: 0, by: -1) {
                add(stem.subEdgeIDs[position], forward: !stem.forward[position])
            }
        }
        return legs
    }
}
