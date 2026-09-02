import Foundation

/// The remote engine's own loop generator, on the device.
///
/// `LocalLoopRouter.findLoops` searches for the walk itself: a beam over
/// distance bands looking for a closed edge-simple circuit. That engine is
/// Phase 9/10, and it has never been what the service answers a walker with —
/// `LOOPER_DIRECT_CLOSED_WALK_SEARCH` ships false and the deployed GraphHopper
/// does not advertise the endpoint it needs, so production has always been the
/// generator ported here.
///
/// The difference is not a tuning: it is what a candidate *is*. The search asks
/// "which circuits of the right length exist", and answers with the ones its
/// ranking liked. This asks "if a walk set off that way and turned that often,
/// where would it go", and lets the street network answer one leg at a time.
/// Two consequences the walker sees:
///
/// - **Legs are shortest paths, so the weighting applies.** The search accrues
///   raw metres, so a pavement and the carriageway beside it are the same to
///   it, and the walk crosses and recrosses the road picking whichever is a few
///   metres shorter. A leg is routed by `LocalLegRouter`, which reads
///   `edgeWeight`, so the pavement wins the near-tie the way it does remotely.
/// - **Ground already used is dear, not forbidden.** The search forbids
///   spending an edge twice, which sounds stricter and is weaker: the two sides
///   of one street are two edges, so it can pad distance by zig-zagging and
///   never has to go anywhere. Here previous legs' edges cost twenty times
///   their length — the service's `AVOID_PRIORITY = 0.05` — which discourages
///   the whole corridor rather than one arbitrary side of it.
///
/// Ported from `src/loops/candidates.ts` and `src/loops/routing.ts`, with the
/// flag defaults production actually runs: `progressiveCornerSweep` on,
/// `keepBestLegAttempt` off, `backtrackNeedsBudgetToo` off,
/// `perimeterRetention` off. Everything after a candidate is built — the gate,
/// the selector, the labels, the instructions — is the code the other two
/// engines already share.
extension LocalLoopRouter {

    // MARK: - Constants, all from the service

    /// `config.candidateCount`. Twenty-four bearings, in mirrored pairs.
    public static let ringCandidateCount = 24
    /// `BEARING_JITTER_DEGREES`. Enough that two runs never look stencilled.
    public static let ringBearingJitterDegrees = 12.0
    /// `PROGRESSIVE_CORNER_WAVES`. Corner counts are tried in waves across the
    /// whole batch rather than exhaustively per bearing, and a bearing that has
    /// already produced a walk drops out of the later waves.
    public static let ringCornerWaves: [[Int]] = [[3], [2], [1, 4]]
    /// `DEFAULT_MAX_LEG_ATTEMPTS`, so up to three tries at a leg.
    public static let ringMaxLegAttempts = 2
    /// `DEFAULT_LEG_OVERSHOOT_TOLERANCE`.
    public static let ringLegOvershootTolerance = 1.4
    /// `LEG_BUDGET_SHARE`. No single leg may be half the walk.
    public static let ringLegBudgetShare = 0.5
    /// `abandonAboveMetres`, as a share of the target.
    public static let ringAbandonShare = 2.2
    /// `LEG_RETRY_LENGTH_STEP` and `LEG_RETRY_BEARING_STEP_DEGREES`: a retry
    /// reaches a fifth less far and swings twenty degrees further round.
    public static let ringRetryLengthStep = 0.2
    public static let ringRetryBearingStepDegrees = 20.0
    /// `JOIN_TURN_THRESHOLD_DEGREES` and `WAYPOINT_PULLBACK_SCALE`.
    public static let ringJoinTurnDegrees = 150.0
    public static let ringPullbackScale = 0.65
    /// `MAX_DISCOVERY_BATCHES`.
    public static let ringMaxBatches = 3
    /// `EARLY_STOP_PASSING_COUNT`. Enough of a pool for the selector to have a
    /// real choice, and not so much that a walker waits for candidates that
    /// will not be offered.
    public static let ringEarlyStopPassing = 5
    /// `clampScale`. A re-aim may not ask for a wildly different walk.
    public static let ringReAimClamp = (low: 0.55, high: 1.5)
    /// Below this the first pass was aimed well enough that re-aiming would
    /// only reshuffle it.
    public static let ringReAimThreshold = 0.05

    public enum RingDirection: Sendable, Equatable {
        case clockwise, counterClockwise
        var turn: Double { self == .clockwise ? 1 : -1 }
    }

    /// One deterministic attempt: where it sets off, and which way round.
    struct RingAttempt {
        var pair: Int
        var direction: RingDirection
        var initialBearing: Double
    }

    /// A candidate walk, before the gate has looked at it.
    struct RingWalk {
        var legs: [WalkLeg]
        var coordinates: [Point]
        var metres: Double
        /// What share of the walk each corner-to-corner leg is. The searched
        /// engine has no such thing, which is why the gate treats it as
        /// optional. See `RouteQuality.analyse`.
        var legShares: [Double]
    }

    // MARK: - Deterministic candidate bearings

    /// FNV-1a, 32 bit — `random.ts`'s `hashString`.
    static func ringHash(_ value: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for scalar in value.unicodeScalars {
            hash ^= UInt32(scalar.value & 0xFFFF)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// JavaScript's `toFixed(4)`, which the seed string is built from and which
    /// therefore has to round the same way to give the same walks.
    static func ringFixed4(_ value: Double) -> String { String(format: "%.4f", value) }

    /// The start is rounded to about 11 m before it reaches the seed, so
    /// standing still and re-asking does not reshuffle the answer because GPS
    /// drifted a few metres. `seedFor`.
    static func ringSeed(lon: Double, lat: Double, targetMetres: Double, variation: Int) -> UInt32 {
        ringHash("\(ringFixed4(lon))|\(ringFixed4(lat))|\(Int(targetMetres.rounded()))|\(variation)")
    }

    /// Mulberry32 — `random.ts`. One 32-bit word of state.
    struct Mulberry32 {
        var state: UInt32
        mutating func next() -> Double {
            state = state &+ 0x6d2b_79f5
            var t = state
            t = (t ^ (t >> 15)) &* (t | 1)
            t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }

    /// Attempts come in mirrored pairs that share a bearing and run opposite
    /// ways round: the same three streets can make a good loop one way and an
    /// awkward one the other, and which is which depends on one-way paths,
    /// stairs and crossings that cannot be seen from here.
    static func ringAttempts(seed: UInt32, count: Int = ringCandidateCount) -> [RingAttempt] {
        var random = Mulberry32(state: seed)
        let pairs = count / 2
        var attempts: [RingAttempt] = []
        attempts.reserveCapacity(count)
        for pair in 0..<pairs {
            let jitter = (random.next() - 0.5) * 2 * ringBearingJitterDegrees
            let bearing = LocalGeo.normaliseBearing(Double(pair) * 360 / Double(pairs) + jitter)
            for direction in [RingDirection.clockwise, .counterClockwise] {
                attempts.append(RingAttempt(pair: pair, direction: direction, initialBearing: bearing))
            }
        }
        return attempts
    }

    /// Reorder so that any *prefix* already covers the compass.
    ///
    /// Bearings come out in order round the dial, which is right when every
    /// attempt runs and wrong the moment the generator can stop partway: the
    /// first six of twenty-four would be one quarter of the compass and nothing
    /// else, so a rule asking "have we three walks setting off different ways"
    /// could never answer yes. Bit-reversal gives every prefix the most even
    /// spread a prefix of that length can have. Mirrored pairs stay adjacent.
    static func ringSpreadAcrossCompass(_ attempts: [RingAttempt]) -> [RingAttempt] {
        let pairs = attempts.count / 2
        guard pairs >= 2 else { return attempts }
        let bits = Int(ceil(log2(Double(pairs))))
        var out: [RingAttempt] = []
        out.reserveCapacity(attempts.count)
        for reversed in 0..<(1 << bits) {
            var pair = 0
            for bit in 0..<bits { pair |= ((reversed >> bit) & 1) << (bits - 1 - bit) }
            guard pair < pairs else { continue }
            out.append(attempts[pair * 2])
            out.append(attempts[pair * 2 + 1])
        }
        return out
    }

    // MARK: - Building one candidate

    /// One attempt at a loop, one leg at a time.
    ///
    /// Nothing about the shape is decided up front beyond the bearing it sets
    /// off on and how often it turns. Each leg is planned as an equal share of
    /// what is left — `remaining / legsLeft`, so a leg that came back long is
    /// paid for by the ones after it — aimed at a guide point that far away on
    /// the current heading, and routed. The heading then advances by a full turn
    /// divided between the corners. The last leg is aimed at the door.
    func buildRingCandidate(
        start: Point, targetMetres: Double, initialBearing: Double,
        direction: LocalLoopRouter.RingDirection, corners: Int,
        graph: LocalWalkingGraph, index: LocalEdgeIndex
    ) -> RingWalk? {
        let turn = direction.turn
        let legBudget = targetMetres * LocalLoopRouter.ringLegBudgetShare
        let abandonAbove = targetMetres * LocalLoopRouter.ringAbandonShare

        var points: [Point] = [start]
        var routed: [LocalLegRouter.Leg] = []
        var running = 0.0
        var heading = initialBearing

        /// Ground every leg before `keeping` used, and the ground beside it.
        /// Rebuilt rather than carried, because the join repair below un-routes
        /// the leg before this one. See `ringCorridor`.
        var corridors: [Set<Int32>] = []
        func spent(keeping count: Int) -> Set<Int32> {
            var out: Set<Int32> = []
            for corridor in corridors.prefix(count) { out.formUnion(corridor) }
            return out
        }

        for step in 0...corners {
            let closing = step == corners
            let legsLeft = corners - step + 1
            let from = points[points.count - 1]
            let planned = Swift.max(0, targetMetres - running) / Double(legsLeft)
            let avoiding = spent(keeping: routed.count)

            // The closing leg has no budget to fit and so gets one aim: home.
            let attempts = closing ? 0 : LocalLoopRouter.ringMaxLegAttempts
            var best: (target: Point, leg: LocalLegRouter.Leg)?
            for attempt in 0...attempts {
                let aim: Point
                if closing {
                    aim = start
                } else {
                    let reach = planned * Swift.max(0.4, 1 - Double(attempt) * LocalLoopRouter.ringRetryLengthStep)
                    let swung = LocalGeo.normaliseBearing(
                        heading + Double(attempt) * turn * LocalLoopRouter.ringRetryBearingStepDegrees
                    )
                    let placed = LocalGeo.destination(lat: from.lat, lon: from.lng, metres: reach, bearing: swung)
                    aim = Point(placed.lon, placed.lat)
                }
                guard let leg = try? LocalLegRouter.route(
                    graph: graph, index: index, from: from, to: aim,
                    penalising: avoiding, penalty: LocalLegRouter.avoidPenalty, weighted: true
                ), leg.metres > 0 else { continue }

                // Overwriting on every attempt keeps the *last* one, which is
                // the shortest and most swung guess the leg made rather than its
                // closest fit. `keepBestLegAttempt` is off in production and this
                // reproduces that, deliberately.
                best = (aim, leg)
                if closing { break }

                let fitsBudget = leg.metres <= planned * LocalLoopRouter.ringLegOvershootTolerance
                    && leg.metres <= legBudget
                // A leg that shares ground with the one before it, but not
                // enough of it to be a real feature, is a corner that turned out
                // to be a dead end — worth a different aim rather than accepted.
                // Measured on edges here rather than on geometry, which is both
                // exact and cheaper than the thing it replaces.
                let previous = corridors.last ?? []
                let backtrack = leg.legs.reduce(0.0) {
                    previous.contains($1.physical) ? $0 + $1.metres : $0
                }
                let shortBacktrack = backtrack > 0 && backtrack < RouteQuality.minBacktrackMetres
                if fitsBudget && !shortBacktrack { break }
            }
            guard var chosen = best else { return nil }

            // Every corner but the first and last is somebody's arrival and
            // somebody's departure. A hairpin there is a turn the walker has to
            // make standing in the street, and the gate refuses more than one.
            if routed.count >= 1,
               let repair = repairRingJoin(
                   previousCorner: points[points.count - 2], corner: from, next: chosen.target,
                   start: start, avoiding: spent(keeping: routed.count - 1),
                   graph: graph, index: index
               ) {
                running -= routed.removeLast().metres
                corridors.removeLast()
                points.removeLast()
                points.append(repair.corner)
                routed.append(repair.previous)
                corridors.append(ringCorridor(around: repair.previous.coordinates, graph: graph, index: index))
                running += repair.previous.metres
                chosen = (chosen.target, repair.next)
            }

            running += chosen.leg.metres
            if running > abandonAbove { return nil }
            points.append(chosen.target)
            routed.append(chosen.leg)
            corridors.append(ringCorridor(around: chosen.leg.coordinates, graph: graph, index: index))
            if !closing {
                heading = LocalGeo.normaliseBearing(heading + turn * 360 / Double(corners + 1))
            }
        }

        // The same trim the waypoint path uses, for the same reason: a leg that
        // runs a few metres past a corner and back is an artefact of aiming at a
        // point rather than at a street, and no walker would call it part of the
        // walk.
        let trimmed = LocalSpikeTrim.trimming(routed.flatMap(\.legs), protecting: [])
        guard trimmed.count >= 2 else { return nil }
        var coordinates: [Point] = []
        for leg in trimmed {
            for point in leg.coordinates where coordinates.last != point { coordinates.append(point) }
        }
        guard coordinates.count >= 4 else { return nil }
        // Measured before the trim, which removes a few metres here and there
        // and would otherwise make a leg's share depend on how many spikes it
        // happened to have.
        let total = Swift.max(1, routed.reduce(0) { $0 + $1.metres })
        return RingWalk(
            legs: trimmed, coordinates: coordinates,
            metres: trimmed.reduce(0) { $0 + $1.metres },
            legShares: routed.map { $0.metres / total }
        )
    }

    /// Pull a hairpin corner in towards the door and route through it again.
    ///
    /// `applyJoinPullback`. A corner the walk arrives at and leaves on nearly
    /// the same bearing is one it has to turn round in. Moving that corner two
    /// thirds of the way back towards the start usually finds a different street
    /// to come back on. Both legs either side of it are re-routed, and the pair
    /// is kept only if the turn actually straightened — a repair that makes
    /// things no better is not a repair.
    func repairRingJoin(
        previousCorner: Point, corner: Point, next: Point, start: Point,
        avoiding: Set<Int32>, graph: LocalWalkingGraph, index: LocalEdgeIndex
    ) -> (corner: Point, previous: LocalLegRouter.Leg, next: LocalLegRouter.Leg)? {
        guard turnAt(previousCorner, corner, next) >= LocalLoopRouter.ringJoinTurnDegrees else { return nil }

        let home = LocalGeo.distance(lat1: start.lat, lon1: start.lng, lat2: corner.lat, lon2: corner.lng)
        let outward = LocalGeo.bearing(lat1: start.lat, lon1: start.lng, lat2: corner.lat, lon2: corner.lng)
        let placed = LocalGeo.destination(
            lat: start.lat, lon: start.lng,
            metres: home * LocalLoopRouter.ringPullbackScale, bearing: outward
        )
        let pulled = Point(placed.lon, placed.lat)
        guard turnAt(previousCorner, pulled, next) < turnAt(previousCorner, corner, next) else { return nil }
        guard let before = try? LocalLegRouter.route(
            graph: graph, index: index, from: previousCorner, to: pulled,
            penalising: avoiding, penalty: LocalLegRouter.avoidPenalty, weighted: true
        ), before.metres > 0 else { return nil }
        var after = avoiding
        for walked in before.legs where walked.physical >= 0 { after.insert(walked.physical) }
        guard let onward = try? LocalLegRouter.route(
            graph: graph, index: index, from: pulled, to: next,
            penalising: after, penalty: LocalLegRouter.avoidPenalty, weighted: true
        ), onward.metres > 0 else { return nil }
        return (pulled, before, onward)
    }

    // MARK: - Corridors

    /// `CORRIDOR_HALF_WIDTH_METRES`. The service buffers a walked leg by this
    /// much and makes everything inside expensive.
    public static let ringCorridorHalfWidth = 25.0
    /// How finely both sides of the comparison are sampled. `SAMPLE_METRES`.
    public static let ringCorridorSampleMetres = 12.0

    /// Every edge running within `ringCorridorHalfWidth` of ground already
    /// walked, including the ground itself.
    ///
    /// This is the difference between an edge penalty and an avoidance
    /// corridor, and it is the whole of the walker's complaint about going a
    /// few metres up one side of the road and back down the other. The two
    /// sides of a street are two different ways: penalising the edge just
    /// walked says nothing at all about the pavement eight metres away across
    /// the carriageway, so a leg that must come back this way simply comes back
    /// on the other side and the walk retraces a street it has already seen.
    /// The gate does not catch it either — its corridor matcher pairs ground
    /// within 17.5 m, and a road wider than that hides the repeat.
    ///
    /// A corridor says what was meant: this *street* has been walked. Measured
    /// on the grid the snapper already maintains, so the cost is a box query
    /// and a hashed point lookup rather than the polygon buffering, union and
    /// simplification the service has to do to express the same idea to a
    /// routing engine over HTTP.
    func ringCorridor(
        around coordinates: [Point], graph: LocalWalkingGraph, index: LocalEdgeIndex
    ) -> Set<Int32> {
        guard coordinates.count >= 2 else { return [] }
        let halfWidth = LocalLoopRouter.ringCorridorHalfWidth
        let spacing = LocalLoopRouter.ringCorridorSampleMetres
        // One frame for both sides of the comparison, so the whole thing is
        // done in metres on a plane rather than in degrees on a sphere.
        let origin = coordinates[0]
        let walked = RouteQuality.resample(coordinates, spacingMetres: spacing, origin: origin).samples
        guard !walked.isEmpty else { return [] }

        // A hash at the corridor's own width, so a lookup only ever has to
        // examine the nine cells around a point to be sure of finding anything
        // within it.
        @inline(__always) func key(_ x: Double, _ y: Double) -> Int64 {
            Int64((x / halfWidth).rounded(.down)) &* 1_000_003
                &+ Int64((y / halfWidth).rounded(.down))
        }
        var buckets: [Int64: [(x: Double, y: Double)]] = [:]
        for sample in walked {
            buckets[key(sample.midX, sample.midY), default: []].append((sample.midX, sample.midY))
        }
        @inline(__always) func isInside(_ x: Double, _ y: Double) -> Bool {
            let cellX = Int64((x / halfWidth).rounded(.down))
            let cellY = Int64((y / halfWidth).rounded(.down))
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let nearby = buckets[(cellX + Int64(dx)) &* 1_000_003 &+ (cellY + Int64(dy))]
                    else { continue }
                    for other in nearby {
                        let ox = x - other.x, oy = y - other.y
                        if ox * ox + oy * oy <= halfWidth * halfWidth { return true }
                    }
                }
            }
            return false
        }

        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for point in coordinates {
            minLat = Swift.min(minLat, point.lat); maxLat = Swift.max(maxLat, point.lat)
            minLon = Swift.min(minLon, point.lng); maxLon = Swift.max(maxLon, point.lng)
        }
        let padLat = halfWidth / LocalGeo.metresPerDegreeLatitude
        let padLon = padLat / Swift.max(0.1, cos(origin.lat * .pi / 180))
        let nearby = index.edges(
            minLat: minLat - padLat, maxLat: maxLat + padLat,
            minLon: minLon - padLon, maxLon: maxLon + padLon
        )
        var corridor: Set<Int32> = []
        for edge in nearby {
            let slot = Int(edge)
            var line: [Point] = []
            var position = Int(graph.geometryStart[slot])
            let end = Int(graph.geometryStart[slot + 1])
            while position + 1 < end {
                line.append(Point(graph.geometry[position], graph.geometry[position + 1]))
                position += 2
            }
            guard line.count >= 2 else { continue }
            // An edge counts as inside if any of it is: a street that touches
            // the corridor for a hundred metres and leaves is still a street
            // the walk has been down.
            let sampled = RouteQuality.resample(line, spacingMetres: spacing, origin: origin).samples
            if sampled.contains(where: { isInside($0.midX, $0.midY) }) { corridor.insert(edge) }
        }
        return corridor
    }

    /// How sharply the walk turns at `corner`, in degrees, where 180 is a walk
    /// straight back the way it came.
    func turnAt(_ from: Point, _ corner: Point, _ to: Point) -> Double {
        let incoming = LocalGeo.bearing(lat1: from.lat, lon1: from.lng, lat2: corner.lat, lon2: corner.lng)
        let outgoing = LocalGeo.bearing(lat1: corner.lat, lon1: corner.lng, lat2: to.lat, lon2: to.lng)
        let deviation = LocalGeo.normaliseBearing(outgoing - incoming)
        return Swift.min(deviation, 360 - deviation)
    }

    // MARK: - The answer

    /// Three loops from this doorstep, the way the service finds them.
    ///
    /// Candidates are built until there are enough of them for the selector to
    /// have a real choice, not until they run out: the sweep is ordered so that
    /// any prefix of it already covers the compass, which is what makes stopping
    /// early safe. Everything from the gate onwards is the shared code.
    public func findRingLoops(
        _ request: Request, in graph: LocalWalkingGraph, index: LocalEdgeIndex
    ) throws -> Result {
        let began = Date()
        var diagnostics = Diagnostics()
        diagnostics.graphNodes = graph.nodeOSMID.count
        diagnostics.graphEdges = graph.edgeMetres.count
        guard graph.edgeMetres.count > 0 else {
            diagnostics.failure = "no-network"
            throw Failure.noNetwork("There's no walking data for this area yet.")
        }
        let start = Point(request.lon, request.lat)

        var candidates: [RouteDiversity.Candidate] = []
        var assembled: [(legs: [WalkLeg], coordinates: [Point], metres: Double, report: RouteQuality.Report)] = []
        /// What the walks that were *built* came out at, passing or not. A pass
        /// that misses the target the same way every time is a pass that was
        /// aimed wrong, and this is what says so.
        var observed: [Double] = []

        // Resampled once. A refresh compares every candidate against every
        // walk already offered, which is the one place the work is a product
        // rather than a sum, so neither side is resampled twice.
        let excluded = request.exclude.map { RouteQuality.corridor($0, origin: start, indexed: true) }
        /// Whether each candidate is ground the walker has not been offered.
        var fresh: [Bool] = []

        /// One built walk, judged. `true` when it passed and was kept.
        func consider(_ walk: RingWalk, targetMetres: Double) -> Bool {
            observed.append(walk.metres)
            diagnostics.closedWalks += 1
            var coordinates = walk.coordinates
            if let first = coordinates.first, coordinates.last != first { coordinates.append(first) }
            let report = RouteQuality.analyse(
                coordinates: coordinates, start: start, distanceMetres: walk.metres,
                targetMetres: targetMetres,
                traversals: traversals(of: walk.legs, origin: start),
                legShares: walk.legShares
            )
            guard report.pass else {
                diagnostics.gateRejected += 1
                for reason in report.rejections { diagnostics.gateRejectionsByReason[reason, default: 0] += 1 }
                return false
            }
            var physical: [Int32: Double] = [:]
            for leg in walk.legs where leg.physical >= 0 { physical[leg.physical, default: 0] += leg.metres }
            assembled.append((walk.legs, coordinates, walk.metres, report))
            let sampled = excluded.isEmpty ? nil : RouteQuality.corridor(coordinates, origin: start)
            fresh.append(sampled.map { mine in
                excluded.allSatisfy {
                    RouteQuality.sharedCorridorMetres(mine, $0).fraction <= RouteQuality.maxSharedFraction
                }
            } ?? true)
            candidates.append(RouteDiversity.Candidate(
                coordinates: coordinates,
                score: report.quality.score,
                bearing: RouteDiversity.initialBearing(coordinates, from: start),
                edges: physical,
                totalMetres: walk.metres,
                reachRatio: RouteQuality.reachRatio(
                    maxRadiusMetres: RouteQuality.maxRadiusMetres(coordinates, start: start),
                    distanceMetres: walk.metres
                )
            ))
            return true
        }

        /// Enough of a pool that the selector has a real choice — counting
        /// only walks the walker has not already been offered.
        ///
        /// Counting all of them is what makes a refresh worse than the first
        /// ask: the sweep stops as soon as five walks exist, and on the second
        /// press four of those are ones the walker just rejected, so the pool
        /// the selector draws from is one walk deep and empties within a few
        /// presses. A walker leaning on the button is asking for ground they
        /// have not seen, and that is the thing to have five of.
        func enough() -> Bool {
            let unseen = candidates.indices.filter { fresh[$0] }
            return unseen.count >= LocalLoopRouter.ringEarlyStopPassing
                && RouteDiversity.select(unseen.map { candidates[$0] }, limit: request.wanted).count >= request.wanted
        }

        /// One sweep of the compass. `aimMetres` is what the legs are planned
        /// against; `targetMetres` is what the gate judges the result by, and
        /// they differ only on a re-aim.
        func sweep(variation: Int, aimMetres: Double, targetMetres: Double) {
            let attempts = LocalLoopRouter.ringSpreadAcrossCompass(
                LocalLoopRouter.ringAttempts(
                    seed: LocalLoopRouter.ringSeed(
                        lon: request.lon, lat: request.lat,
                        targetMetres: targetMetres, variation: variation
                    ),
                    // Not `request.candidateWalks`, which is the searched
                    // engine's pool size and means something else entirely.
                    count: LocalLoopRouter.ringCandidateCount
                )
            )
            // A bearing that has already produced a walk drops out of the later
            // waves: the question "does anything work this way" has been
            // answered, and asking it again with a different corner count spends
            // the budget where it is least likely to buy a new walk.
            var answered: Set<Int> = []
            // Built in parallel, judged in order.
            //
            // A candidate knows nothing about the others while it is being
            // built, so a slice of them is exactly the shape a phone's spare
            // cores want. What must stay serial is everything after: which
            // bearings are answered, when the pool is big enough to stop, and
            // in what order candidates reach the selector. So a slice is built
            // concurrently and then read back in the order it was written, and
            // the answer does not depend on which core finished first.
            let width = Swift.max(1, ProcessInfo.processInfo.activeProcessorCount)
            for wave in LocalLoopRouter.ringCornerWaves {
                for corners in wave {
                    var pending = attempts.filter { !answered.contains($0.pair) }
                    while !pending.isEmpty {
                        let slice = Array(pending.prefix(width))
                        pending.removeFirst(slice.count)
                        var built = [RingWalk?](repeating: nil, count: slice.count)
                        built.withUnsafeMutableBufferPointer { out in
                            DispatchQueue.concurrentPerform(iterations: slice.count) { position in
                                out[position] = self.buildRingCandidate(
                                    start: start, targetMetres: aimMetres,
                                    initialBearing: slice[position].initialBearing,
                                    direction: slice[position].direction,
                                    corners: corners, graph: graph, index: index
                                )
                            }
                        }
                        for (position, attempt) in slice.enumerated() {
                            diagnostics.candidatesBuilt += 1
                            guard let walk = built[position] else {
                                diagnostics.candidatesAbandoned += 1
                                continue
                            }
                            if consider(walk, targetMetres: targetMetres) { answered.insert(attempt.pair) }
                        }
                        if enough() { return }
                        pending.removeAll { answered.contains($0.pair) }
                    }
                }
            }
        }

        let searchBegan = Date()
        for batch in 0..<LocalLoopRouter.ringMaxBatches {
            sweep(
                variation: request.variation + batch,
                aimMetres: request.targetMetres, targetMetres: request.targetMetres
            )
            diagnostics.batchesRun += 1
            if enough() { break }
        }

        // One re-aim. A pass whose walks all came back short was not unlucky,
        // it was aimed short: the legs are planned in crow-flight metres and
        // walked in street metres, and the ratio between those is a property of
        // the ground rather than of the attempt. Re-planning against the miss
        // costs one more sweep and is judged against the original target, so a
        // re-aimed walk is never held to an easier standard.
        if candidates.count < request.wanted, observed.count >= 3 {
            let median = observed.sorted()[observed.count / 2]
            if median > 0 {
                let scale = Swift.min(
                    LocalLoopRouter.ringReAimClamp.high,
                    Swift.max(LocalLoopRouter.ringReAimClamp.low, request.targetMetres / median)
                )
                if abs(scale - 1) > LocalLoopRouter.ringReAimThreshold {
                    diagnostics.reAimScale = scale
                    sweep(
                        variation: request.variation, aimMetres: request.targetMetres * scale,
                        targetMetres: request.targetMetres
                    )
                }
            }
        }
        diagnostics.sweepMs = Date().timeIntervalSince(searchBegan) * 1000
        diagnostics.passedGate = candidates.count
        diagnostics.poolElongated = candidates.filter(RouteDiversity.isElongated).count

        // Exclusion belongs on the pool and not on the answer — filtering what
        // the selector returned means a refresh re-offers the same walks or
        // nothing at all. The same argument, and the same code, as `findLoops`.
        let unseen = candidates.indices.filter { fresh[$0] }
        let seen = candidates.indices.filter { !fresh[$0] }
        if !request.exclude.isEmpty {
            diagnostics.excludedAsAlreadySeen = seen.count
            diagnostics.excludeExhausted = unseen.isEmpty
        }

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
        if let first = routes.first?.geometry.coordinates.first {
            diagnostics.snappedLat = first.lat
            diagnostics.snappedLon = first.lng
        }
        diagnostics.offered = routes.count
        diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
        if routes.isEmpty {
            diagnostics.failure = diagnostics.closedWalks == 0 ? "no-candidate-built" : "gate-rejected-all"
            throw Failure.noLoopFound
        }
        return Result(routes: routes, diagnostics: diagnostics)
    }
}
