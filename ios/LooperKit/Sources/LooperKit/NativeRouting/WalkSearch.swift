import Foundation

/// A beam over distance bands, searching for the walk itself.
///
/// Ported from the route service's `WalkSearch.java`, which is itself Phase
/// 9's `search.mts`. The formulation, the two exact prunes, the ranking proxy,
/// the per-node cap, the compass-octant quota and the turn-angle term are all
/// Phase 9's.
///
/// It is no longer a faithful port, and the divergence is deliberate. Phase
/// 9's ranking has one positive term, compactness, which is dimensionless: a
/// 200 m circle and a 3 km circle both score exactly 1. So the reference asks
/// a walk to be round and never asks it to be anywhere or to be any size, and
/// on a real street network the answer is a knot of little loops by the door —
/// every one of them a legal edge-simple circuit that the gate has no grounds
/// to refuse. `reachShortfall` in `promise` supplies the missing size term and
/// the shape quota in the beam supplies the missing variety, and neither is in
/// the Java or the TypeScript. See `Options.reachWeight`.
///
/// ## What bounds the search
///
/// Two prunes are exact and lose nothing admissible:
///
/// - a super-edge already spent is not offered as a move, which on a physical
///   network is what the gate's `out-and-back-spur` rule amounts to;
/// - `distanceUsed + home[node] > maxMetres` discards a state whose best
///   possible finish is already past the top of the band. `home` is the
///   exploration's own Dijkstra distance, so it is the exact shortest walk
///   home rather than an estimate of one.
///
/// Everything else that limits the search is beam selection, which is
/// approximate by construction.
///
/// ## Why bands are drained rather than visited
///
/// Most super-edges are shorter than a band, so expanding a band produces
/// states belonging to the same band. Processing each band once would silently
/// discard most of the search, so each pass applies the beam to whatever is
/// currently in the band and the band is finished only when it empties.
/// Termination is not in doubt: no walk may spend an edge twice, so depth is
/// bounded by the edge count.
public enum WalkSearch {
    /// Phase 9's retained operating point. Not re-tuned here.
    public static let beam = 300
    public static let bandMetres: Double = 100
    public static let perNode = 3

    /// How wide to search for a given target, and how many partial walks one
    /// junction may hold.
    ///
    /// The reference's 300 and 3 were chosen for a server answering once, and
    /// on the device they leave the search starving in the middle of a budget
    /// it never touches: at Douglas 3 km the beam discarded seventy thousand
    /// partial walks and the per-node cap twenty-three thousand more, to close
    /// two hundred and sixteen walks, with `stoppedEarly` false throughout.
    ///
    /// The two have to move together. Raising `perNode` alone is actively
    /// worse — states pile up on a few junctions and crowd the fixed beam, so
    /// fewer distinct nodes are ever expanded. Measured at 8 km, perNode 6
    /// against a beam of 300 closed 39 walks where perNode 3 closed 174.
    ///
    /// Work goes roughly as the beam times the number of bands, and bands go
    /// as the target — so holding their product near constant keeps the wall
    /// clock flat while spending far more of it where walkers actually ask.
    /// A long target spends its whole width on bands and lands back on the
    /// reference pair, which is the right answer there: at 8 km a wider
    /// per-node cap against a floor-width beam closed 31 walks where the
    /// reference closed 174. So the cap only lifts once the beam has room to
    /// carry it.
    public static func widthFor(targetMetres: Double) -> (beam: Int, perNode: Int) {
        let scaled = targetMetres > 0 ? 2_250_000 / targetMetres : Double(beam)
        let width = Int(Swift.min(750, Swift.max(300, scaled)))
        return (width, width <= beam ? perNode : Swift.max(perNode, width / 56))
    }
    /// The gate's own compactness floor; a closure below it is not a walk.
    public static let minCompactness = 0.20
    /// The gate's own allowance for a walk that goes somewhere. A closure that
    /// reaches this far is judged on `RouteQuality.elongatedMinCompactness`
    /// instead, because at closure the search knows both numbers exactly and
    /// there is no sense in it discarding a walk the gate would have passed.
    public static let elongationReachRatio = RouteQuality.elongationReachRatio
    public static let elongatedMinCompactness = RouteQuality.elongatedMinCompactness
    /// Where a partial walk stops counting as compact for the beam's shape
    /// quota. Not a threshold anything is judged on — only the line the two
    /// halves of the beam are drawn along, so it sits well below the gate's
    /// own 4.5 and simply asks whether this state is the rounder kind or the
    /// longer kind of the walks currently in hand.
    public static let elongatedAspect = 2.0
    /// How hard to push a partial walk away from the door.
    ///
    /// The other negative term, `shortfall`, stops the moment the walk can
    /// reach the band — which happens early, and after it nothing in the score
    /// asks for distance at all. This one never stops: a walk coiling by the
    /// door carries it to the last band.
    ///
    /// Swept against live data at Douglas 3/4/5/8 km, Peel 5 km and Onchan
    /// 5 km, on how many of those six handed back a full three walks: 0.2 gave
    /// four, 0.3 and 0.6 gave five, and 0.4 gave all six. The failures are at
    /// both ends and for opposite reasons — too little and the beam still
    /// fills with walks by the door that the offer selector then finds
    /// indistinguishable, too much and it chases reach past the point of
    /// closing anything, which showed up first at 8 km where there are most
    /// bands to survive. The middle is not a compromise between them so much
    /// as the only setting that is neither.
    public static let reachWeight = 0.4
    /// The gate's own turn allowance.
    public static let maxUTurns = 1
    /// `INITIAL_BEARING_METRES` and `INITIAL_BEARING_FRACTION` from diversity.ts.
    public static let initialBearingMetres: Double = 500
    public static let initialBearingFraction = 0.2
    /// A turn this sharp is the junction half of the gate's u-turn test — the
    /// gate also asks whether the two arms come back within 20 m of each
    /// other, which needs the whole walk and is therefore checked once,
    /// exactly, at closure. This is only a ranking discouragement.
    public static let tightTurnDegrees: Double = 150
    /// How far a variation may nudge a partial walk's promise.
    ///
    /// Swept: 0.02 gave 20/17/15 distinct walks over ten refreshes at Douglas
    /// 3/4/5 km, 0.06 gave 28/24/22, and 0.15 fell back to 25/14/17. Wide
    /// enough to reshuffle a beam that has stopped being selective, narrow
    /// enough not to drown the shape term it perturbs.
    ///
    /// The beam is deterministic, so the same doorstep and the same target
    /// close the same walks forever — which makes "show me some others" a
    /// question it cannot answer, however many walks it found. A variation
    /// perturbs the ranking just enough to reshuffle walks the beam considered
    /// near enough to equal, and not nearly enough to promote a bad one: the
    /// shape term it perturbs runs 0 to 1. Nothing downstream is relaxed — the
    /// gate judges whatever comes out exactly as before, so a variation
    /// changes which good walks are found and never how good they must be.
    public static let variationAmplitude = 0.06
    /// What a beam at the reference width needs instead. Such a beam is still
    /// doing hard selection, so it reshuffles under a much smaller nudge and
    /// is actively harmed by a large one: at 8 km, which searches at the floor
    /// width, the wide amplitude cost more variety than it bought.
    public static let narrowVariationAmplitude = 0.02

    /// How far to nudge, given how selective the beam being nudged is.
    public static func variationAmplitude(beam: Int) -> Double {
        beam <= WalkSearch.beam ? narrowVariationAmplitude : variationAmplitude
    }

    /// A stable, uniform nudge in ±`amplitude` for one state under one
    /// variation. Variation 0 nudges nothing, so the default search is
    /// bit-for-bit what it was.
    @inline(__always)
    static func jitter(variation: Int, node: Int32, arc: Int32, amplitude: Double) -> Double {
        guard variation != 0 else { return 0 }
        var hash = UInt64(bitPattern: Int64(variation)) &* 0x9E37_79B9_7F4A_7C15
        hash ^= UInt64(bitPattern: Int64(node)) &* 0xBF58_476D_1CE4_E5B9
        hash ^= UInt64(bitPattern: Int64(arc) &+ 1) &* 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        return (Double(hash % 10_000) / 10_000 - 0.5) * 2 * amplitude
    }

    public struct Options: Sendable {
        public var targetMetres: Double
        public var tolerance: Double
        public var beam: Int
        public var band: Double
        public var perNode: Int
        public var diversityQuota: Bool
        public var turnAware: Bool
        public var turnPenalty: Double
        public var minCompactness: Double
        /// How much a partial walk is penalised for not having gone anywhere.
        /// See `WalkSearch.reachWeight`.
        public var reachWeight: Double
        /// Which of the equally-good walks to prefer. See `variationAmplitude`.
        public var variation: Int
        /// A ceiling on expansions. On a phone this is also the thing that
        /// keeps a pathological network from spending a walker's battery.
        public var budget: Int
        public var wanted: Int

        public init(
            targetMetres: Double, tolerance: Double = RoutingCoverage.maxDistanceError,
            beam: Int? = nil, band: Double = WalkSearch.bandMetres, perNode: Int? = nil,
            diversityQuota: Bool = true, turnAware: Bool = true, turnPenalty: Double = 0.05,
            minCompactness: Double = WalkSearch.minCompactness, budget: Int = 4_000_000, wanted: Int = .max,
            variation: Int = 0, reachWeight: Double = WalkSearch.reachWeight
        ) {
            self.targetMetres = targetMetres
            self.tolerance = tolerance
            let width = WalkSearch.widthFor(targetMetres: targetMetres)
            self.beam = beam ?? width.beam
            self.band = band
            self.perNode = perNode ?? width.perNode
            self.diversityQuota = diversityQuota
            self.turnAware = turnAware
            self.turnPenalty = turnPenalty
            self.minCompactness = minCompactness
            self.reachWeight = reachWeight
            self.variation = variation
            self.budget = budget
            self.wanted = wanted
        }
    }

    /// One closed walk, as the arcs it is made of.
    public struct Walk: Sendable {
        public var arcs: [Int32]
        public var metres: Double
        public var compactness: Double
        public var bboxRatio: Double
        public var maxRadius: Double
        /// See `RouteQuality.elongationReachRatio`.
        public var reachRatio: Double
        public var family: Int
        public var promise: Double
    }

    public struct Stats: Sendable, Equatable {
        public var generated = 0
        public var expanded = 0
        public var prunedDistance = 0
        public var prunedReuse = 0
        public var prunedBeam = 0
        public var prunedDominated = 0
        public var peakBand = 0
        public var completed = 0
        /// Every time the search arrived back at the root, however the walk
        /// that got there was then judged. The three counters below account
        /// for the difference between this and `completed`, which is where to
        /// look when the engine is short of walks to offer.
        public var closures = 0
        /// Reached the root, but too short or too long to be the walk asked for.
        public var closuresOutsideBand = 0
        /// The right length, but not round enough to be offered as a loop.
        public var closuresTooShapeless = 0
        public var searchMs: Double = 0
        public var storeSize = 0
        public var chunksReleased = 0
        public var retainedBytes = 0
        public var peakStoreBytes = 0
        public var stemMetres: Double = 0
        public var root = -1
        /// True when the budget or the wanted count stopped the search early.
        public var stoppedEarly = false
    }

    public struct Result: Sendable {
        public var walks: [Walk]
        public var stats: Stats
    }

    public static func run(_ graph: WalkSearchGraph, options: Options) -> Result {
        let began = Date()
        var stats = Stats()
        let amplitude = variationAmplitude(beam: options.beam)
        let minMetres = options.targetMetres * (1 - options.tolerance)
        let maxMetres = options.targetMetres * (1 + options.tolerance)
        let root = graph.root()
        guard root >= 0 else {
            stats.searchMs = Date().timeIntervalSince(began) * 1000
            return Result(walks: [], stats: stats)
        }
        let stemMetres = root == graph.start ? 0 : graph.home[root]
        let commitAt = Swift.min(initialBearingMetres, options.targetMetres * initialBearingFraction)
        let turnLimit = cos(LocalGeo.toRadians(tightTurnDegrees))
        stats.root = root
        stats.stemMetres = stemMetres

        let store = WalkStateStore()
        var spent = [UInt64](repeating: 0, count: (graph.edgeCount + 63) >> 6)
        let nodeSlots = graph.arcStart.count - 1
        var nodeCount = [Int32](repeating: 0, count: nodeSlots)
        var nodeStamp = [Int32](repeating: 0, count: nodeSlots)
        var stamp: Int32 = 0
        var familyCount = [Int](repeating: 0, count: quotaSlots)

        // Bands are drained in increasing order and a state's band is never
        // below the one it was generated in, so a flat array with a forward
        // cursor is exactly a sorted map here, without the tree.
        let maxBand = Int(maxMetres / options.band) + 2
        var bands = [[Int32]](repeating: [], count: maxBand + 1)
        var walks: [Walk] = []

        @inline(__always) func bandKey(_ distance: Double) -> Int {
            Swift.max(0, Swift.min(maxBand, Int(distance / options.band)))
        }

        // One seed per arc out of the root. Which family a walk belongs to is
        // not decided here: it is whichever octant the walk has committed to
        // once it is clear of the door, the axis the offer selector judges on.
        let seed = store.add(
            parent: -1, arc: -1, node: Int32(root), distance: stemMetres, area: 0, drawn: 0,
            lowX: 0, highX: 0, lowY: 0, highY: 0, radius: 0, depth: 0, family: -1, tightTurns: 0,
            band: bandKey(stemMetres)
        )
        for a in Int(graph.arcStart[root])..<Int(graph.arcStart[root + 1]) {
            let distance = stemMetres + graph.arcMetres[a]
            let to = Int(graph.arcTo[a])
            guard distance + graph.home[to] <= maxMetres else { continue }
            let child = extend(graph, store, parent: seed, arc: Int32(a), distance: distance,
                               commitAt: commitAt, options: options, parentDepth: -1, tightTurns: 0)
            bands[bandKey(distance)].append(child)
            stats.generated += 1
        }

        var cursor = 0
        drain: while cursor <= maxBand {
            if bands[cursor].isEmpty { cursor += 1; continue }
            let members = bands[cursor]
            bands[cursor] = []
            stats.peakBand = Swift.max(stats.peakBand, members.count)
            // Everything behind the live band is only ever read again to
            // reconstruct a walk, and reconstruction needs the parent and the
            // arc alone. Everything else in those chunks goes now.
            store.releaseBelow(cursor)
            stats.peakStoreBytes = Swift.max(stats.peakStoreBytes, store.retainedBytes)

            var score = [Double](repeating: 0, count: members.count)
            for i in 0..<members.count {
                score[i] = promise(graph, store, members[i], root: root, minMetres: minMetres, options: options)
                    + jitter(
                        variation: options.variation, node: store.nodeOf(members[i]),
                        arc: store.arcOf(members[i]), amplitude: amplitude
                    )
            }
            var ordered = Array(0..<members.count)
            ordered.sort { score[$0] > score[$1] }

            // Beam selection with a family quota. Ranking on shape alone
            // converges: without the quota Phase 9 measured every closed walk
            // at Douglas 5 km sitting in one compass octant and overlapping
            // the best of them by 89%, so the offer selector could only ever
            // take one. Diversity has to be a property of the search.
            //
            // Direction is not the only axis a walker sees, though, and the
            // reference only quotas on direction. `shape` is the beam's one
            // positive term, so an elongated partial walk is behind a round
            // one in every band it is scored in and is culled long before the
            // band where it would have closed into a perfectly good long thin
            // loop. Splitting each octant into a round half and a long half
            // costs nothing — the bounding box is already on the state — and
            // it does not demote roundness, which still wins inside its own
            // half. It only stops round being the only thing that survives.
            stamp += 1
            for i in 0..<quotaSlots { familyCount[i] = 0 }
            var seen = [Bool](repeating: false, count: quotaSlots)
            var present = 0
            for index in members {
                let slot = quotaSlot(store, index)
                if !seen[slot] { seen[slot] = true; present += 1 }
            }
            let quota = options.diversityQuota ? Swift.max(1, options.beam / Swift.max(1, present)) : Int.max
            var kept: [Int32] = []
            kept.reserveCapacity(Swift.min(options.beam, members.count))
            var taken = [Bool](repeating: false, count: members.count)
            for pass in 0..<2 {
                if kept.count >= Swift.min(options.beam, members.count) { break }
                let limit = pass == 0 ? quota : Int.max
                for position in ordered {
                    if kept.count >= Swift.min(options.beam, members.count) { break }
                    if pass == 1 && taken[position] { continue }
                    let index = members[position]
                    let slot = quotaSlot(store, index)
                    if familyCount[slot] >= limit { continue }
                    let node = Int(store.nodeOf(index))
                    let onNode = nodeStamp[node] == stamp ? Int(nodeCount[node]) : 0
                    if onNode >= options.perNode {
                        if pass == 0 { stats.prunedDominated += 1 }
                        continue
                    }
                    nodeStamp[node] = stamp
                    nodeCount[node] = Int32(onNode + 1)
                    familyCount[slot] += 1
                    kept.append(index)
                    if pass == 0 { taken[position] = true }
                }
            }
            stats.prunedBeam += members.count - kept.count

            for index in kept {
                stats.expanded += 1
                let depth = mark(graph, store, &spent, index)
                let node = Int(store.nodeOf(index))
                let distanceHere = store.distanceOf(index)
                let inArc = store.arcOf(index)
                let tight = store.tightTurnsOf(index)
                for a in Int(graph.arcStart[node])..<Int(graph.arcStart[node + 1]) {
                    let superEdge = Int(graph.arcEdge[a])
                    if spent[superEdge >> 6] & (UInt64(1) << UInt64(superEdge & 63)) != 0 {
                        stats.prunedReuse += 1
                        continue
                    }
                    let to = Int(graph.arcTo[a])
                    let distance = distanceHere + graph.arcMetres[a]
                    if distance + graph.home[to] > maxMetres { stats.prunedDistance += 1; continue }
                    stats.generated += 1
                    var turns = tight
                    if options.turnAware, inArc >= 0, isTightTurn(graph, inArc: Int(inArc), outArc: a, cosineLimit: turnLimit) {
                        turns += 1
                    }
                    let child = extend(graph, store, parent: index, arc: Int32(a), distance: distance,
                                       commitAt: commitAt, options: options, parentDepth: depth, tightTurns: turns)
                    if to == root {
                        stats.closures += 1
                        let total = distance + stemMetres
                        if total >= minMetres && total <= maxMetres {
                            if let walk = walkOf(graph, store, child, stemMetres: stemMetres, root: root,
                                                 minMetres: minMetres, options: options),
                               walk.compactness >= compactnessFloor(for: walk, options: options) {
                                walks.append(walk)
                                stats.completed += 1
                            } else {
                                stats.closuresTooShapeless += 1
                            }
                        } else {
                            stats.closuresOutsideBand += 1
                        }
                        continue
                    }
                    bands[bandKey(distance)].append(child)
                }
                unmark(graph, store, &spent, index)
                if stats.expanded >= options.budget || walks.count >= options.wanted {
                    stats.stoppedEarly = true
                    break drain
                }
            }
        }

        stats.searchMs = Date().timeIntervalSince(began) * 1000
        stats.storeSize = store.count
        stats.chunksReleased = store.releasedChunks
        stats.retainedBytes = store.retainedBytes
        stats.peakStoreBytes = Swift.max(stats.peakStoreBytes, store.retainedBytes)
        return Result(walks: walks, stats: stats)
    }

    // MARK: - Machinery

    private static func extend(
        _ graph: WalkSearchGraph, _ store: WalkStateStore, parent: Int32, arc: Int32, distance: Double,
        commitAt: Double, options: Options, parentDepth: Int, tightTurns: Int
    ) -> Int32 {
        let edge = Int(graph.arcEdge[Int(arc)])
        let to = Int(graph.arcTo[Int(arc)])
        let parentFamily = parent < 0 ? -1 : store.familyOf(parent)
        let family = parentFamily >= 0 ? parentFamily : (distance >= commitAt ? Int(graph.octant[to]) : -1)
        let area = (parent < 0 ? 0 : store.twiceAreaOf(parent))
            + (graph.arcForward[Int(arc)] ? graph.edgeTwiceArea[edge] : -graph.edgeTwiceArea[edge])
        let drawn = (parent < 0 ? 0 : store.drawnOf(parent)) + graph.edgeDrawn[edge]
        let lowX = Float(Swift.min(parent < 0 ? 0 : Double(store.minXOf(parent)), graph.edgeMinX[edge]))
        let highX = Float(Swift.max(parent < 0 ? 0 : Double(store.maxXOf(parent)), graph.edgeMaxX[edge]))
        let lowY = Float(Swift.min(parent < 0 ? 0 : Double(store.minYOf(parent)), graph.edgeMinY[edge]))
        let highY = Float(Swift.max(parent < 0 ? 0 : Double(store.maxYOf(parent)), graph.edgeMaxY[edge]))
        let radius = Float(Swift.max(parent < 0 ? 0 : Double(store.maxRadiusOf(parent)), graph.edgeMaxRadius[edge]))
        let depth = (parentDepth < 0 ? (parent < 0 ? 0 : store.depthOf(parent)) : parentDepth) + 1
        return store.add(
            parent: parent, arc: arc, node: Int32(to), distance: distance, area: area, drawn: drawn,
            lowX: lowX, highX: highX, lowY: lowY, highY: highY, radius: radius,
            depth: depth, family: family, tightTurns: tightTurns,
            band: Swift.max(0, Int(distance / options.band))
        )
    }

    /// How promising a partial walk is: close it with a straight line home and
    /// ask how round the result would be, then ask whether it has been
    /// anywhere. The cheapest honest proxy for the gate's own compactness,
    /// needing only the running shoelace and the drawn length — and the
    /// quantity the anchor-based generators could not see, because they never
    /// held a walk.
    private static func promise(
        _ graph: WalkSearchGraph, _ store: WalkStateStore, _ index: Int32,
        root: Int, minMetres: Double, options: Options
    ) -> Double {
        let node = Int(store.nodeOf(index))
        // Closed with the straight line the comment above promises, and not
        // with `home`. Bands are drained in order, so every state scored
        // together has walked the same distance and this term alone decides
        // between them — and `home` is a network distance, which charges a
        // state out at the edge of the search the street grid's detour factor
        // on a leg it has not walked and may never walk. The prune that has to
        // be exact still uses `home`; this one only has to be fair.
        let dx = graph.nodeX[node] - graph.nodeX[root]
        let dy = graph.nodeY[node] - graph.nodeY[root]
        let closing = (dx * dx + dy * dy).squareRoot()
        let perimeter = store.drawnOf(index) + closing
        let area = abs(store.twiceAreaOf(index) / 2)
        let shape = perimeter > 0 ? Swift.min(1, 4 * .pi * area / (perimeter * perimeter)) : 0
        // A walk that can no longer reach the band is worthless however round.
        let shortfall = Swift.max(0, minMetres - (store.distanceOf(index) + graph.home[node])) / options.targetMetres
        // And a walk that has not left the doorstep is worthless however round,
        // which is the thing `shape` cannot say: it is a ratio, so it scores a
        // 200 m circle and a 3 km circle identically. Measured against the
        // radius a circle of the asked-for length would have, so a state is
        // being asked to be the size of the walk requested rather than to be
        // large in the abstract.
        let idealRadius = options.targetMetres / (2 * .pi)
        let reach = idealRadius > 0
            ? Swift.max(0, idealRadius - Double(store.maxRadiusOf(index))) / idealRadius
            : 0
        let turns = options.turnAware ? options.turnPenalty * Double(store.tightTurnsOf(index)) : 0
        return shape - shortfall - options.reachWeight * reach - turns
    }

    /// What roundness this closure has to clear. A walk that has genuinely
    /// gone somewhere is held to the gate's generous floor rather than its
    /// ordinary one, because the ordinary floor cannot tell a long thin walk
    /// from a tangle and this one can. See `RouteQuality.elongationReachRatio`.
    private static func compactnessFloor(for walk: Walk, options: Options) -> Double {
        walk.reachRatio >= elongationReachRatio ? elongatedMinCompactness : options.minCompactness
    }

    /// Nine compass families — the eight octants plus the one for a walk still
    /// too close to the door to have committed — each split in two by shape.
    static let quotaSlots = 18

    /// The beam slot a partial walk competes in: where it is going, and what
    /// shape it is making on the way.
    @inline(__always)
    private static func quotaSlot(_ store: WalkStateStore, _ index: Int32) -> Int {
        (Int(store.familyOf(index)) + 1) * 2 + (elongated(store, index) ? 1 : 0)
    }

    /// Which half of the shape quota a partial walk belongs to: the rounder
    /// kind, or the longer kind. Read off the running bounding box, which the
    /// state already carries. See `elongatedAspect`.
    @inline(__always)
    private static func elongated(_ store: WalkStateStore, _ index: Int32) -> Bool {
        let width = Double(store.maxXOf(index) - store.minXOf(index))
        let height = Double(store.maxYOf(index) - store.minYOf(index))
        let short = Swift.min(width, height), long = Swift.max(width, height)
        return short > 0 ? long / short >= elongatedAspect : true
    }

    /// The junction half of the gate's u-turn rule: did the walk turn back on
    /// itself at this node. The gate's full test also asks whether the arms
    /// come back within 20 m, which needs the drawn line and is applied at
    /// closure.
    private static func isTightTurn(_ graph: WalkSearchGraph, inArc: Int, outArc: Int, cosineLimit: Double) -> Bool {
        let incoming = LocalGeo.toRadians(graph.arcInBearing[inArc])
        let outgoing = LocalGeo.toRadians(graph.arcOutBearing[outArc])
        let dot = sin(incoming) * sin(outgoing) + cos(incoming) * cos(outgoing)
        return dot <= cosineLimit
    }

    private static func mark(_ graph: WalkSearchGraph, _ store: WalkStateStore, _ spent: inout [UInt64], _ index: Int32) -> Int {
        var depth = 0
        var at = index
        while at >= 0 {
            let arc = store.arcOf(at)
            if arc >= 0 {
                let edge = Int(graph.arcEdge[Int(arc)])
                spent[edge >> 6] |= UInt64(1) << UInt64(edge & 63)
                depth += 1
            }
            at = store.parentOf(at)
        }
        return depth
    }

    private static func unmark(_ graph: WalkSearchGraph, _ store: WalkStateStore, _ spent: inout [UInt64], _ index: Int32) {
        var at = index
        while at >= 0 {
            let arc = store.arcOf(at)
            if arc >= 0 {
                let edge = Int(graph.arcEdge[Int(arc)])
                spent[edge >> 6] &= ~(UInt64(1) << UInt64(edge & 63))
            }
            at = store.parentOf(at)
        }
    }

    /// The arcs of the walk ending at `index`, root first.
    static func arcs(_ store: WalkStateStore, _ index: Int32) -> [Int32] {
        var reversed: [Int32] = []
        var at = index
        while at >= 0 {
            let arc = store.arcOf(at)
            if arc >= 0 { reversed.append(arc) }
            at = store.parentOf(at)
        }
        return reversed.reversed()
    }

    private static func walkOf(
        _ graph: WalkSearchGraph, _ store: WalkStateStore, _ index: Int32,
        stemMetres: Double, root: Int, minMetres: Double, options: Options
    ) -> Walk? {
        let path = arcs(store, index)
        guard !path.isEmpty else { return nil }
        let drawn = store.drawnOf(index)
        let width = Double(store.maxXOf(index) - store.minXOf(index))
        let height = Double(store.maxYOf(index) - store.minYOf(index))
        let compactness = drawn > 0 ? Swift.min(1, 4 * .pi * abs(store.twiceAreaOf(index) / 2) / (drawn * drawn)) : 0
        let bbox = Swift.min(width, height) > 0 ? Swift.max(width, height) / Swift.min(width, height) : Double.infinity
        let metres = store.distanceOf(index) + stemMetres
        let maxRadius = Double(store.maxRadiusOf(index))
        return Walk(
            arcs: path, metres: metres, compactness: compactness,
            bboxRatio: bbox, maxRadius: maxRadius,
            reachRatio: RouteQuality.reachRatio(maxRadiusMetres: maxRadius, distanceMetres: metres),
            family: store.familyOf(index),
            promise: promise(graph, store, index, root: root, minMetres: minMetres, options: options)
        )
    }
}
