import Foundation

/// The two pavements and the carriageway between them, as one street.
///
/// OSM maps them as three unrelated ways, and that is the whole of the walker's
/// complaint about the routes this app offers. Told nothing else, the router
/// sees three interchangeable paths of near-identical length: it takes whichever
/// is a few metres shorter to the next junction, crosses, and crosses back two
/// junctions later for the same reason. Neither the cost model nor the old
/// pavement metric could even see it happen — a walk that hops to the far
/// pavement and back never leaves pedestrian ground.
///
/// This pass gives every edge a **street**, and that one fact makes two rules
/// expressible that could not be written before:
///
/// 1. **A carriageway with a pavement alongside it is dearer.** Not every
///    carriageway — only where an escape actually exists, and the escape is
///    eight metres away rather than three hundred. That is the difference from
///    the remote engine's `looper-foot-2` experiment, which multiplied *every*
///    road by ten and bought long detours to any footway anywhere.
/// 2. **A crossing that returns to the street it started on is dear; one that
///    crosses a different street is free.** A walker has no choice about
///    crossing a side road on the way past it, and charging for it would buy
///    detours around junctions — the same mistake in a new place.
///
/// Rule 2 is why the grouping has to exist at all. `RouteQuality.crossingRuns`
/// already tells a junction crossing from a side-swap, but it does so from the
/// walk's approach heading — which is only known once a route exists. A search
/// has to price an edge before any path reaches it, and a cost that depends on
/// how the edge was reached breaks A\*'s guarantee. Grouping converts the same
/// question into a structural one, answerable per edge with no walk in sight.
public struct LocalStreetGroups: Sendable {
    /// The street each edge belongs to, as a slot in the graph's `names`.
    /// `-1` where nothing could be established.
    public let street: [Int32]
    /// Whether a pedestrian way runs alongside this carriageway edge, over
    /// enough of its length to be a real alternative.
    public let hasParallelPavement: [Bool]
    /// Additive cost in metres-equivalent. Additive rather than a multiplier
    /// because a crossing's cost to a walker is not proportional to its width —
    /// it is "one crossing" — and because an additive term keeps every edge
    /// costing at least its own length, which is what `LocalLegRouter`'s A\*
    /// heuristic depends on.
    public let surcharge: [Double]

    public init(street: [Int32], hasParallelPavement: [Bool], surcharge: [Double]) {
        self.street = street
        self.hasParallelPavement = hasParallelPavement
        self.surcharge = surcharge
    }

    public static func empty(edgeCount: Int) -> LocalStreetGroups {
        LocalStreetGroups(
            street: [Int32](repeating: -1, count: edgeCount),
            hasParallelPavement: [Bool](repeating: false, count: edgeCount),
            surcharge: [Double](repeating: 0, count: edgeCount)
        )
    }

    // MARK: - Constants

    /// How far a pavement can sit from its carriageway and still be its
    /// pavement. `RouteQuality.corridorMatchMetres` (17.5) is the wrong number
    /// here: it is tuned for two stretches of route being the same ground, and
    /// a pavement beside a wide road sits further out than that.
    public static let pavementPairMetres: Double = 22
    /// How much of a carriageway needs a pavement beside it before the pavement
    /// counts as an alternative to it. Edges run 80–150 m between junctions, so
    /// partial coverage is rarely ambiguous.
    public static let pavementCoverage: Double = 0.6
    /// Finer than `RouteQuality.sampleMetres` (15), because the things being
    /// paired here include edges only a few metres long.
    public static let sampleMetres: Double = 10

    /// What a carriageway costs when a pavement runs beside it, on top of the
    /// 1.25 every carriageway already carries.
    ///
    /// Deliberately moderate. Its whole job is to lose a near-tie against a way
    /// running *parallel* to it, so it buys no detour at all — and a large
    /// multiplier's failure mode is an OSM gap. Where a pavement is mapped but
    /// not connected at the point it is needed, a heavy penalty pays for a long
    /// way round to avoid a few metres of carriageway.
    public static let parallelPavementPenalty: Double = 2.0

    /// What a crossing costs when it returns to the street it left.
    ///
    /// Fixed with `parallelPavementPenalty` by one question a walker can
    /// actually answer: **how much pavement on the far side makes crossing
    /// worth it?** Answered at 35 m. Standing where a pavement has ended with
    /// `D` metres of street left:
    ///
    /// ```text
    /// walk the carriageway         D × 2.5
    /// cross and take the far side  S + 10 + D      (10 m ≈ the crossing)
    /// cross when  S + 10 + D < 2.5 D  →  S < 1.5 D − 10  →  S < 42.5 at D = 35
    /// ```
    ///
    /// So 40 m, putting the crossover at about 33 m of far-side pavement. The
    /// same number kills the pointless case from the other side: swapping when
    /// the pavement underfoot continues costs `D + 50` against `D`, and
    /// parallel pavements are never 50 m shorter. Over and back is 100 m
    /// against the three metres that motivated it.
    ///
    /// This inequality is also why no far-side lookahead is needed. "Cross only
    /// if you get enough pavement out of it" is not a second rule to write — it
    /// is what comparing these two costs already says.
    public static let sideSwapSurchargeMetres: Double = 40

    // MARK: - Building

    public static func build(for graph: LocalWalkingGraph) -> LocalStreetGroups {
        let count = graph.edgeCount
        guard count > 0, graph.nodeCount > 0 else { return .empty(edgeCount: count) }

        var street = [Int32](repeating: -1, count: count)
        var hasParallelPavement = [Bool](repeating: false, count: count)
        var surcharge = [Double](repeating: 0, count: count)

        /// A pavement or path: somewhere a walker is meant to be, running
        /// *along* rather than across.
        func isPavement(_ edge: Int) -> Bool {
            graph.roadClass(ofEdge: edge).isPedestrianWay && !graph.isCrossing(ofEdge: edge)
        }
        func isCarriageway(_ edge: Int) -> Bool {
            !graph.roadClass(ofEdge: edge).isPedestrianWay && !graph.isCrossing(ofEdge: edge)
        }

        // One metric frame for the whole graph, so every sample is comparable
        // with every other. Pairing across edges is the entire point, and two
        // edges projected in their own frames cannot be compared at all.
        let origin = Point(graph.nodeLon[0], graph.nodeLat[0])

        var samples: [RouteQuality.Sample] = []
        var sampleStart = [Int](repeating: 0, count: count + 1)
        for edge in 0..<count {
            sampleStart[edge] = samples.count
            let line = graph.coordinates(ofEdge: edge, forward: true)
            guard line.count >= 2 else { continue }
            var produced = RouteQuality.resample(line, spacingMetres: sampleMetres, origin: origin).samples
            if produced.isEmpty {
                // Shorter than the sampler's trailing-stub floor. A four-metre
                // dropped kerb still has to be pairable, so ask again at a
                // spacing it cannot fall through.
                let spacing = Swift.max(0.5, graph.edgeMetres[edge] / 2)
                produced = RouteQuality.resample(line, spacingMetres: spacing, origin: origin).samples
            }
            samples.append(contentsOf: produced)
        }
        sampleStart[count] = samples.count

        func slice(_ edge: Int) -> Range<Int> { sampleStart[edge]..<sampleStart[edge + 1] }

        /// Samples of one kind, with the edge each came from, ready to hash.
        func gather(_ include: (Int) -> Bool) -> (samples: [RouteQuality.Sample], owner: [Int]) {
            var out: [RouteQuality.Sample] = []
            var owner: [Int] = []
            for edge in 0..<count where include(edge) {
                for position in slice(edge) {
                    out.append(samples[position])
                    owner.append(edge)
                }
            }
            return (out, owner)
        }

        let roads = gather(isCarriageway)
        let paths = gather(isPavement)
        let roadIndex = RouteQuality.SampleIndex(roads.samples, cell: pavementPairMetres)
        let pathIndex = RouteQuality.SampleIndex(paths.samples, cell: pavementPairMetres)

        /// Whether two samples are the same street's ground, running the same
        /// way. `parallelCosine` is reused unchanged: past 35° two stretches are
        /// crossing rather than running together, which is exactly what stops a
        /// crossing being mistaken for a pavement.
        @inline(__always) func pairs(_ a: RouteQuality.Sample, _ b: RouteQuality.Sample) -> Bool {
            let dx = a.midX - b.midX, dy = a.midY - b.midY
            guard dx * dx + dy * dy <= pavementPairMetres * pavementPairMetres else { return false }
            return abs(a.dirX * b.dirX + a.dirY * b.dirY) >= RouteQuality.parallelCosine
        }

        /// The most-seen slot, with the lowest breaking a tie so the answer
        /// never depends on dictionary ordering.
        func dominant(_ tally: [Int32: Int]) -> Int32? {
            tally.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.first?.key
        }

        // --- A pavement belongs to the street it runs along ------------------
        for edge in 0..<count where isPavement(edge) {
            var tally: [Int32: Int] = [:]
            for position in slice(edge) {
                let sample = samples[position]
                for candidate in roadIndex.near(x: sample.midX, y: sample.midY) {
                    guard pairs(sample, roads.samples[candidate]) else { continue }
                    let slot = graph.edgeName[roads.owner[candidate]]
                    guard slot >= 0 else { continue }
                    tally[slot, default: 0] += 1
                }
            }
            if let best = dominant(tally) { street[edge] = best }
        }

        // --- A carriageway is its own street, and may have a pavement -------
        for edge in 0..<count where isCarriageway(edge) {
            street[edge] = graph.edgeName[edge]
            let positions = slice(edge)
            guard !positions.isEmpty else { continue }
            var covered = 0
            for position in positions {
                let sample = samples[position]
                let found = pathIndex.near(x: sample.midX, y: sample.midY).contains {
                    pairs(sample, paths.samples[$0])
                }
                if found { covered += 1 }
            }
            hasParallelPavement[edge] =
                Double(covered) / Double(positions.count) >= pavementCoverage
        }

        // --- A crossing that comes back to the street it left ---------------
        //
        // Grouped by OSM way rather than by edge, and that matters twice over.
        // A crossing way is cut *at* the carriageway it crosses, so one
        // kerb-to-kerb crossing is routinely two edges: classified per edge,
        // each half would be judged on the one end that happens to touch a
        // pavement. And charged per edge, the walker would pay twice for the
        // commonest tagging and once for the rest.
        var crossingsByWay: [Int64: [Int]] = [:]
        for edge in 0..<count where graph.isCrossing(ofEdge: edge) {
            crossingsByWay[graph.edgeWayID[edge], default: []].append(edge)
        }
        if !crossingsByWay.isEmpty {
            var streetsAtNode: [Int32: [Int32]] = [:]
            for edge in 0..<count where isPavement(edge) && street[edge] >= 0 {
                streetsAtNode[graph.edgeFrom[edge], default: []].append(street[edge])
                streetsAtNode[graph.edgeTo[edge], default: []].append(street[edge])
            }
            for (_, edges) in crossingsByWay {
                var crossedTally: [Int32: Int] = [:]
                for edge in edges where graph.edgeCrosses[edge] >= 0 {
                    crossedTally[graph.edgeCrosses[edge], default: 0] += 1
                }
                var endsTally: [Int32: Int] = [:]
                for edge in edges {
                    for node in [graph.edgeFrom[edge], graph.edgeTo[edge]] {
                        for slot in streetsAtNode[node] ?? [] { endsTally[slot, default: 0] += 1 }
                    }
                }
                // Unknown either side is left free. A rule that cannot tell
                // what it is looking at must not charge for it.
                guard let crossed = dominant(crossedTally),
                      let ends = dominant(endsTally),
                      crossed == ends
                else { continue }
                for edge in edges { street[edge] = crossed }
                let share = sideSwapSurchargeMetres / Double(edges.count)
                for edge in edges { surcharge[edge] = share }
            }
        }

        return LocalStreetGroups(
            street: street, hasParallelPavement: hasParallelPavement, surcharge: surcharge
        )
    }
}
