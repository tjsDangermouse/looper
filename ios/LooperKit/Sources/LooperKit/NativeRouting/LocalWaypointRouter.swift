import Foundation

/// Ordered-waypoint walks, on the device.
///
/// The closed-walk search answers "a ring of about five kilometres from here".
/// This answers "through these places, in this order, in about five
/// kilometres", which is a different question and is built a different way:
/// the backbone is routed gap by gap on the raw graph, and whatever the plan
/// has left over is spread across the gaps by `LocalWaypointPlanner`.
///
/// Everything downstream of assembly is the *same* code the ring search uses —
/// the quality gate, the diversity selector, the labels, the instructions. A
/// waypoint walk is judged by exactly the rules a plain loop is judged by, one
/// tolerance apart, and that tolerance is the service's own.
extension LocalLoopRouter {
    /// How far off the requested length a waypoint walk may be. The service's
    /// `WAYPOINT_DISTANCE_TOLERANCE`. Wider than a plain loop's because a walk
    /// through fixed pins cannot choose its own length as freely.
    public static let waypointDistanceTolerance = 0.25
    /// How much of the walk the pins have to account for before they are
    /// describing a route through places rather than a loop with a pin on it.
    public static let pinConstraintShare = 0.1
    /// How many assembled walks are measured before the diversity selector
    /// picks three.
    public static let backboneAssemblyLimit = 24
    /// Resolution of the slack allocation, as a share of the requested length.
    public static let backboneBucketShare = 0.02
    /// The loosest two waypoint walks may be and still be offered as two
    /// walks. Well above the ordinary limit, because pins force shared ground;
    /// well below "identical", because at some point a second option is not
    /// one.
    public static let waypointRelaxedShared = 0.8
    /// How near a route must pass a pin to count as having gone there.
    public static let waypointHitToleranceMetres: Double = 40

    public struct WaypointRequest: Sendable {
        public var start: Point
        /// The walker's pins, in the order they were dropped. Never moved,
        /// never reordered, never treated as suggestions.
        public var waypoints: [Point]
        public var targetMetres: Double
        public var wanted: Int
        public var variation: Int
        public var exclude: [[Point]]

        public init(
            start: Point, waypoints: [Point], targetMetres: Double,
            wanted: Int = 3, variation: Int = 0, exclude: [[Point]] = []
        ) {
            self.start = start
            self.waypoints = waypoints
            self.targetMetres = targetMetres
            self.wanted = wanted
            self.variation = variation
            self.exclude = exclude
        }
    }

    public struct WaypointResult {
        public var routes: [Route]
        public var diagnostics: Diagnostics
        /// The shortest walk that visits these pins in this order, set only
        /// when that is more than the plan allows. The walker is told this
        /// number rather than simply being refused, because "you need at
        /// least 8.2 km" is something they can act on and "no" is not.
        public var minimumMetres: Double?
        public var warning: String?
    }

    /// Build waypoint walks, or say why not.
    ///
    /// Follows the service's backbone generator step for step. Two of its
    /// steps are absent, and both because the device is in a better position
    /// rather than a worse one:
    ///
    /// - **No `trueLowerBound` pass.** The service re-routes every gap under a
    ///   shortest-path model before it dares refuse, because GraphHopper's
    ///   preferred route is not a shortest one. `LocalLegRouter` is a Dijkstra
    ///   on metres, so the backbone is the true floor the first time.
    /// - **No time-mode re-aim.** The service assembles in metres and may be
    ///   judged in seconds, so it can miss on duration while hitting on
    ///   distance. Here duration is derived from distance at a fixed pace, so
    ///   there is exactly one measure and nothing to re-aim.
    public func findWaypointLoops(
        _ request: WaypointRequest,
        in graph: LocalWalkingGraph,
        index: LocalEdgeIndex,
        began: Date = Date(),
        diagnostics initial: Diagnostics = Diagnostics()
    ) throws -> WaypointResult {
        var diagnostics = initial
        diagnostics.graphNodes = graph.nodeCount
        diagnostics.graphEdges = graph.edgeCount
        diagnostics.waypointCount = request.waypoints.count

        let anchors = [request.start] + request.waypoints + [request.start]
        let gapCount = anchors.count - 1
        guard gapCount >= 2, request.targetMetres > 0 else { throw Failure.noLoopFound }

        // ---------------------------------------------------------- backbone
        // One direct route per gap. These are the floor that says whether the
        // walk is possible at all, and they are also the "spend nothing here"
        // option, so nothing is paid for twice.
        var directs: [LocalLegRouter.Leg] = []
        for gap in 0..<gapCount {
            do {
                directs.append(try LocalLegRouter.route(
                    graph: graph, index: index, from: anchors[gap], to: anchors[gap + 1]
                ))
            } catch {
                diagnostics.failure = "waypoint-unreachable"
                diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
                return WaypointResult(
                    routes: [], diagnostics: diagnostics,
                    warning: (error as? LocalizedError)?.errorDescription
                        ?? "One or more waypoints cannot be reached on foot."
                )
            }
        }
        let backbone = directs.reduce(0) { $0 + $1.metres }
        diagnostics.waypointBackboneMetres = backbone

        // A pin on the doorstep, or three pins within a street of each other,
        // does not describe a route: the backbone is nearly nothing and the
        // slack is nearly the whole walk, so "spread the slack across the
        // gaps" degenerates into "invent a loop" — which is the ring search's
        // job and it is far better at it. So ask it, and keep the loops that
        // already pass the pins in order.
        if backbone < request.targetMetres * LocalLoopRouter.pinConstraintShare {
            diagnostics.failure = nil
            return try loopsPassingPins(request, in: graph, index: index, began: began, diagnostics: diagnostics)
        }

        // ------------------------------------------------------- feasibility
        // Refusing costs the walker their walk, so the floor is a genuine
        // lower bound and not a preference — see `fitsInPlan`.
        guard LocalWaypointPlanner.fitsInPlan(
            backbone: backbone, target: request.targetMetres,
            maxErrorFraction: LocalLoopRouter.waypointDistanceTolerance
        ) else {
            diagnostics.failure = "waypoint-over-plan"
            diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
            return WaypointResult(routes: [], diagnostics: diagnostics, minimumMetres: backbone)
        }

        // ---------------------------------------------- options for each gap
        let slack = Swift.max(0, request.targetMetres - backbone)
        let perGap = slack / Double(gapCount)
        var byGap: [[LocalWaypointPlanner.SegmentOption]] = []
        var routed: [String: LocalLegRouter.Leg] = [:]

        for gap in 0..<gapCount {
            let directID = "\(gap)-direct"
            routed[directID] = directs[gap]
            var forThisGap: [LocalWaypointPlanner.SegmentOption] = [.init(
                gap: gap, id: directID, guides: [],
                distanceMetres: directs[gap].metres,
                durationSeconds: directs[gap].metres / LocalInstructions.walkingMetresPerSecond
            )]

            let crow = haversine(anchors[gap], anchors[gap + 1])
            let stretch = crow > 0 ? directs[gap].metres / crow : 1
            for plan in LocalWaypointPlanner.planSegmentOptions(
                gap: gap, from: anchors[gap], to: anchors[gap + 1], slackForGap: perGap, networkStretch: stretch
            ) where !plan.guides.isEmpty {
                // A guide that cannot be routed through is a guide the ground
                // does not offer; there are eight others.
                guard let leg = try? LocalLegRouter.route(
                    graph: graph, index: index,
                    through: [anchors[gap]] + plan.guides + [anchors[gap + 1]]
                ) else { continue }
                routed[plan.id] = leg
                forThisGap.append(.init(
                    gap: gap, id: plan.id, guides: plan.guides,
                    distanceMetres: leg.metres,
                    durationSeconds: leg.metres / LocalInstructions.walkingMetresPerSecond
                ))
            }
            byGap.append(forThisGap)
        }
        diagnostics.waypointOptions = byGap.reduce(0) { $0 + $1.count }

        let allocations = LocalWaypointPlanner.allocateSlack(
            byGap, anchors: anchors,
            options: .init(
                target: request.targetMetres,
                bucketSize: Swift.max(25, request.targetMetres * LocalLoopRouter.backboneBucketShare),
                limit: LocalLoopRouter.backboneAssemblyLimit
            )
        )
        guard !allocations.isEmpty else {
            diagnostics.failure = "waypoint-no-allocation"
            diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
            return WaypointResult(routes: [], diagnostics: diagnostics)
        }
        diagnostics.waypointAllocations = allocations.count
        // If this is zero the shape preference had nothing to prefer, and the
        // problem is where the shaping points are put rather than which
        // combination is chosen.
        diagnostics.waypointEnclosing = allocations.filter { $0.shape >= 0.25 }.count

        // ------------------------------------------------------- materialise
        let assembleBegan = Date()
        let start = request.start
        var candidates: [RouteDiversity.Candidate] = []
        /// Per candidate, whether it still passes every pin in order.
        var hitsPins: [Bool] = []
        /// Repairs are shared across allocations: the same gap option meeting
        /// the same arriving edge has the same answer however many
        /// combinations it appears in.
        var repaired: [String: LocalLegRouter.Leg] = [:]
        var assembled: [(legs: [WalkLeg], coordinates: [Point], metres: Double, report: RouteQuality.Report)] = []

        /// One assembled walk, trimmed, measured and judged — the same way
        /// however it was built. Both the backbone and the fallback below feed
        /// this, so a walk is never offered on easier terms because of which
        /// generator happened to produce it.
        func judge(_ assembledLegs: [WalkLeg]) {
            // Judged under both trims, because the choice between them is not
            // one answer for every walk.
            //
            // The trim is what makes waypoint walks offerable at all — without
            // it the gate refuses seven in eight. But it is also allowed to cut
            // through a pin, and a pin at the tip of a lane is exactly the
            // shape it hunts for: measured on Douglas, the unprotected trim
            // left two of eight walks still passing their own pins, and the
            // protected trim left all eight. Production picks one of these
            // once and for all (`keepPinnedSpurs`, off) and pays for its offer
            // rate with walks that do not go where they were asked.
            //
            // There is no need to choose. Both are cheap, both are judged on
            // the same terms, and the selection below prefers a walk that
            // still passes its pins. Where the protected trim leaves an
            // offerable walk the walker gets the one they asked for; where it
            // does not, they still get a walk rather than nothing.
            for protecting in [request.waypoints, []] {
                judgeOne(LocalSpikeTrim.trimming(assembledLegs, protecting: protecting))
                if protecting.isEmpty { break }
            }
        }

        func judgeOne(_ legs: [WalkLeg]) {
            guard legs.count >= 2 else { return }

            var coordinates = LocalLegRouter.line(of: legs)
            let metres = legs.reduce(0) { $0 + $1.metres }
            guard coordinates.count >= 4 else { return }
            // The walk must read as closed to the gate, and it is: the last
            // gap ends at the start. Snapping can leave the two ends a metre
            // apart, which the gate already tolerates.
            if let first = coordinates.first, coordinates.last != first { coordinates.append(first) }

            var physical: [Int32: Double] = [:]
            for leg in legs where leg.physical >= 0 { physical[leg.physical, default: 0] += leg.metres }

            let spur = LocalLoopRouter.spurForced(by: request.waypoints, in: legs)
            let report = RouteQuality.analyse(
                coordinates: coordinates, start: start, distanceMetres: metres,
                targetMetres: request.targetMetres,
                traversals: traversals(of: legs, origin: start),
                maxDistanceError: LocalLoopRouter.waypointDistanceTolerance,
                excusedRetraceMetres: spur.metres,
                excusedUTurns: spur.turns
            )
            diagnostics.closedWalks += 1
            guard report.pass else {
                diagnostics.gateRejected += 1
                for reason in report.rejections { diagnostics.gateRejectionsByReason[reason, default: 0] += 1 }
                return
            }
            assembled.append((legs, coordinates, metres, report))
            // Whether the finished walk still goes where it was asked to.
            //
            // It is a question worth asking because the trim above is allowed
            // to cut through a pin — production ships that way because the
            // alternative is no walks at all — and a walk that lost its pin
            // is still a perfectly good loop, just not the one requested. So
            // rather than refuse it or pretend it hit, it is ranked below the
            // ones that did. Measured on Douglas the remote engine offers a
            // walk that misses a pin more often than not; this does not have
            // to inherit that just because it inherited the trim.
            hitsPins.append(LocalLoopRouter.route(coordinates, hits: request.waypoints))
            candidates.append(RouteDiversity.Candidate(
                coordinates: coordinates,
                score: report.quality.score,
                bearing: RouteDiversity.initialBearing(coordinates, from: start),
                edges: physical,
                totalMetres: metres,
                reachRatio: RouteQuality.reachRatio(
                    maxRadiusMetres: RouteQuality.maxRadiusMetres(coordinates, start: start),
                    distanceMetres: metres
                )
            ))
        }

        for allocation in allocations {
            // Each gap's legs are trimmed on their own and then concatenated,
            // never trimmed across a join. That is what makes it structurally
            // impossible for the trim to cut out a pin: a pin is only ever a
            // boundary between two lists, never inside one.
            var legs: [WalkLeg] = []
            for (gap, option) in allocation.chosen.enumerated() {
                guard var leg = routed[option.id] else { continue }
                // Each gap was routed on its own, so two legs meeting at a pin
                // are each individually shortest and together a U-turn: the
                // departure simply reverses the edge the arrival came in on.
                // That is not a walk anyone would choose, and it was refusing
                // every candidate on real ground — one U-turn per anchor,
                // exactly. So where a join reverses, the departing gap is
                // routed again with that edge penalised.
                //
                // A penalty rather than a prohibition, and so a pin at the end
                // of a cul-de-sac still gets its honest turn-around. And the
                // pin does not move: the leg still runs anchor to anchor. The
                // allocation's arithmetic drifts a little when this fires,
                // which is why the walk is measured after assembly and not
                // before — the plan was always a plan.
                if let arrival = legs.last, arrival.physical >= 0,
                   let departure = leg.legs.first, departure.physical == arrival.physical {
                    let key = "\(option.id)@\(arrival.physical)"
                    if let cached = repaired[key] {
                        leg = cached
                    } else if let fresh = try? LocalLegRouter.route(
                        graph: graph, index: index,
                        through: [anchors[gap]] + option.guides + [anchors[gap + 1]],
                        avoiding: [arrival.physical]
                    ) {
                        repaired[key] = fresh
                        leg = fresh
                    }
                    if leg.legs.first?.physical != arrival.physical { diagnostics.waypointJoinsRepaired += 1 }
                }
                legs.append(contentsOf: leg.legs)
            }
            // The closing join is the same problem at the door: the last gap
            // arrives on the edge the first gap left on, which reads as a
            // U-turn at the start rather than a loop closing.
            if let arrival = legs.last, let departure = legs.first,
               arrival.physical >= 0, arrival.physical == departure.physical,
               let last = allocation.chosen.last,
               let fresh = try? LocalLegRouter.route(
                   graph: graph, index: index,
                   through: [anchors[gapCount - 1]] + last.guides + [anchors[gapCount]],
                   avoiding: [departure.physical]
               ), fresh.legs.last?.physical != departure.physical {
                let keep = legs.count - (routed[last.id]?.legs.count ?? 0)
                if keep > 0 {
                    legs = Array(legs.prefix(keep)) + fresh.legs
                    diagnostics.waypointJoinsRepaired += 1
                }
            }
            // The trim the service applies to every walk it assembles from
            // legs, and for the same reason: without it the gate refuses the
            // whole walk for a forty-metre duck into a driveway.
            //
            // Nothing is protected from it, which looks wrong and is what
            // production measured and chose. Holding the trim off the walker's
            // pins is `keepPinnedSpurs`, and it ships **off**: with it on,
            // "waypoint requests went from 2-3 walks to none, with
            // `out-and-back-spur` refusing 20 of every 24 assembled". A pin at
            // the tip of a cul-de-sac is exactly the shape the trim looks for,
            // so protecting pins protects precisely the spikes that cost the
            // walker every walk. A spike is at most 80 m round trip, so a walk
            // still passes close to the pin; the alternative is no walk.
            judge(legs)
        }

        // Every backbone combination failed a gate. The service does not stop
        // there and neither does this: it hands over to the generator that
        // came before, which aims one shape at the whole walk instead of
        // spending slack gap by gap. On a sweep of forty-eight pin pairs that
        // hand-over is worth ten percentage points of offer rate — the
        // difference between a feature that mostly works and one that mostly
        // does not.
        if candidates.isEmpty {
            diagnostics.waypointStage = "guided"
            for leg in guidedWaypointCandidates(request, anchors: anchors, graph: graph, index: index) {
                judge(leg.legs)
            }
        }
        diagnostics.passedGate = candidates.count

        // Every assembled walk failed a gate. `gateRejectionsByReason` says
        // which, which is the only thing that makes this case debuggable from
        // a log line — so it is reported rather than thrown away.
        guard !candidates.isEmpty else {
            diagnostics.failure = "waypoint-gate-rejected-all"
            diagnostics.assembleMs = Date().timeIntervalSince(assembleBegan) * 1000
            diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
            return WaypointResult(routes: [], diagnostics: diagnostics)
        }

        // Pins constrain a walk in a way a plain loop is not: every
        // alternative has to visit the same places, and between two pins there
        // is often only one sensible way. So where the ordinary separation
        // cannot be met, the bar is lowered once — and then stops. Three walks
        // that are ninety per cent the same walk are one walk with two extra
        // taps to dismiss.
        // Walks that still pass every pin fill the answer first, and the rest
        // of the places are filled from the ones that do not — because a
        // walker who asked to go somewhere would rather be offered one walk
        // that goes there and two that nearly do than three that nearly do.
        // The same shape as the exclusion in the ring search: choose from the
        // preferred pool, then top up, rather than filtering the answer.
        func pick(_ pool: [Int], limit: Int, taken: [Int]) -> (chosen: [Int], selection: RouteDiversity.Selection) {
            var selection = RouteDiversity.selecting(
                pool.map { candidates[$0] }, limit: limit, alreadyTaken: taken.map { candidates[$0] }
            )
            if selection.chosen.count < limit {
                let relaxed = RouteDiversity.selecting(
                    pool.map { candidates[$0] }, limit: limit,
                    maxShared: LocalLoopRouter.waypointRelaxedShared,
                    alreadyTaken: taken.map { candidates[$0] }
                )
                if relaxed.chosen.count > selection.chosen.count { selection = relaxed }
            }
            return (selection.chosen.map { pool[$0] }, selection)
        }
        let hitting = candidates.indices.filter { hitsPins[$0] }
        let missing = candidates.indices.filter { !hitsPins[$0] }
        diagnostics.waypointOfferedHittingPins = hitting.count
        var (chosen, selection) = pick(hitting, limit: request.wanted, taken: [])
        if chosen.count < request.wanted && !missing.isEmpty {
            let topUp = pick(missing, limit: request.wanted - chosen.count, taken: chosen)
            chosen += topUp.chosen
        }
        diagnostics.diversityRejected = selection.rejectedShared
        diagnostics.diversityNoRoom = selection.noRoom
        let labels = RouteDiversity.labels(for: chosen.map {
            (bearing: candidates[$0].bearing, distanceMetres: assembled[$0].metres)
        })
        var routes: [Route] = []
        for (position, index) in chosen.enumerated() {
            let entry = assembled[index]
            routes.append(Route(
                id: UUID().uuidString,
                name: labels[position],
                distanceMeters: entry.metres.rounded(),
                durationSeconds: (entry.metres / LocalInstructions.walkingMetresPerSecond).rounded(),
                targetDifferencePercent: ((entry.metres / request.targetMetres - 1) * 100).rounded(),
                geometry: LineGeometry(coordinates: entry.coordinates),
                steps: tidySteps(LocalInstructions.steps(for: entry.legs)),
                routingEngine: .onDevice
            ))
        }
        diagnostics.assembleMs = Date().timeIntervalSince(assembleBegan) * 1000
        diagnostics.offered = routes.count
        diagnostics.totalMs = Date().timeIntervalSince(began) * 1000
        return WaypointResult(
            routes: routes, diagnostics: diagnostics,
            warning: routes.count < request.wanted
                ? "We found only \(routes.count) clean \(routes.count == 1 ? "loop" : "loops") through those waypoints. Try moving a waypoint for more choices."
                : nil
        )
    }

    // MARK: - The fallback the backbone hands over to

    /// How many shaping points the fallback tries round the compass.
    public static let waypointGuideCount = 16
    /// How finely the radius that hits the plan is solved for.
    public static let waypointGuideRadiusSamples = 48

    /// Candidates built by threading one shaping point through the whole pin
    /// sequence, rather than by spending slack gap by gap.
    ///
    /// This is the service's legacy generator, and it earns its place: on a
    /// sweep of forty-eight pin pairs round Douglas the backbone answered
    /// twenty-five per cent of them and this answered ten per cent more. They
    /// fail differently, which is the whole point of having both — the
    /// backbone spends slack evenly across the gaps and produces walks that
    /// are the right length and sometimes a poor shape, while this aims one
    /// shape at the whole walk and lets the length fall where it does.
    ///
    /// The other difference matters more than it looks: every leg here is
    /// routed as one chain, so ground used before a pin is avoided after it.
    /// The backbone cannot do that — it routes each gap independently, because
    /// it has to measure every gap's options before knowing which combination
    /// it will keep — and that is most of why its walks retrace.
    private func guidedWaypointCandidates(
        _ request: WaypointRequest, anchors: [Point],
        graph: LocalWalkingGraph, index: LocalEdgeIndex
    ) -> [LocalLegRouter.Leg] {
        var built: [LocalLegRouter.Leg] = []
        // The pins on their own, with each leg kept off the ground the ones
        // before it used. A pin on an existing loop often already divides it
        // into two perfectly good paths, and forcing an extra corner into that
        // only makes it less likely to fit.
        if let pinOnly = try? LocalLegRouter.route(
            graph: graph, index: index, through: anchors, protecting: request.waypoints
        ) {
            built.append(pinOnly)
        }

        let crow = crowLength(anchors)
        guard crow > 0 else { return built }
        // A shaping point's reach is solved from the stretch the network
        // actually applied, not by treating every metre left in the budget as
        // a metre of crow flight — which put the guide well outside the ring
        // and had otherwise available loops refused as too long.
        let direct = zip(anchors, anchors.dropFirst()).compactMap {
            try? LocalLegRouter.route(graph: graph, index: index, from: $0, to: $1)
        }
        guard direct.count == anchors.count - 1 else { return built }
        let stretch = Swift.min(3, Swift.max(0.8, direct.reduce(0) { $0 + $1.metres } / crow))
        let targetCrow = request.targetMetres / stretch
        let scales = [0.78, 0.9, 1.0, 1.0, 1.1, 1.22]

        for attempt in 0..<LocalLoopRouter.waypointGuideCount {
            let bearing = LocalGeo.normaliseBearing(
                Double(attempt) * 360 / Double(LocalLoopRouter.waypointGuideCount)
                    + Double(request.variation) * 11
            )
            let insertion = 1 + (attempt % (anchors.count - 1))
            let radius = guideRadius(
                anchors: anchors, insertion: insertion, start: request.start,
                bearing: bearing, targetCrowMetres: targetCrow
            )
            let placed = LocalGeo.destination(
                lat: request.start.lat, lon: request.start.lng,
                metres: radius * scales[attempt % scales.count], bearing: bearing
            )
            var shaped = anchors
            shaped.insert(Point(placed.lon, placed.lat), at: insertion)
            if let leg = try? LocalLegRouter.route(
                graph: graph, index: index, through: shaped, protecting: request.waypoints
            ) {
                built.append(leg)
            }
        }
        return built
    }

    /// How far out to put a shaping point so the whole sequence comes to about
    /// the plan, as the crow flies. Sampled rather than solved: the sequence
    /// changes length in two places at once as the guide moves, and a sweep of
    /// forty-eight radii is both exact enough and cheaper than being clever.
    private func guideRadius(
        anchors: [Point], insertion: Int, start: Point, bearing: Double, targetCrowMetres: Double
    ) -> Double {
        let before = anchors[insertion - 1], after = anchors[insertion]
        let unchanged = crowLength(anchors) - haversine(before, after)
        let maximum = Swift.max(300, targetCrowMetres)
        var bestRadius = 0.0
        var bestError = Double.infinity
        for sample in 0...LocalLoopRouter.waypointGuideRadiusSamples {
            let radius = maximum * Double(sample) / Double(LocalLoopRouter.waypointGuideRadiusSamples)
            let placed = LocalGeo.destination(lat: start.lat, lon: start.lng, metres: radius, bearing: bearing)
            let guide = Point(placed.lon, placed.lat)
            let error = abs(unchanged + haversine(before, guide) + haversine(guide, after) - targetCrowMetres)
            if error < bestError {
                bestError = error
                bestRadius = radius
            }
        }
        return Swift.max(75, bestRadius)
    }

    private func crowLength(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + haversine($1.0, $1.1) }
    }

    // MARK: - Doorstep pins

    /// Ordinary loops that happen to pass the pins already.
    ///
    /// For pins that constrain almost nothing — one dropped on the next
    /// street, or three within a hundred metres of each other — this is both
    /// the cheaper answer and the better one. The ring search is asked for a
    /// wide pool and the pins do the filtering, so the walk is a walk the
    /// search chose rather than a backbone with a balloon on it.
    private func loopsPassingPins(
        _ request: WaypointRequest,
        in graph: LocalWalkingGraph,
        index: LocalEdgeIndex,
        began: Date,
        diagnostics initial: Diagnostics
    ) throws -> WaypointResult {
        var diagnostics = initial
        diagnostics.waypointStage = "doorstep-pin"
        let loops = try findLoops(
            .init(
                lat: request.start.lat, lon: request.start.lng, targetMetres: request.targetMetres,
                wanted: request.wanted, variation: request.variation, exclude: request.exclude
            ),
            in: graph, index: index, began: began, diagnostics: diagnostics
        )
        let passing = loops.routes.filter {
            LocalLoopRouter.route($0.geometry.coordinates, hits: request.waypoints)
        }
        diagnostics = loops.diagnostics
        diagnostics.waypointStage = "doorstep-pin"
        diagnostics.offered = passing.count
        guard !passing.isEmpty else {
            diagnostics.failure = "waypoint-doorstep-missed"
            return WaypointResult(routes: [], diagnostics: diagnostics)
        }
        return WaypointResult(routes: passing, diagnostics: diagnostics)
    }

    /// The ground a pin left the walk no choice but to cover twice.
    ///
    /// A pin at the end of a lane, on a pier, at a viewpoint is reached by
    /// walking in and walking out, and the way out is the way in reversed.
    /// That is the walk the walker asked for, and charging it as retracing
    /// refuses them the thing they requested for the crime of requesting it.
    ///
    /// Measured, not assumed. The walk is scanned outward from each pin, and
    /// only ground that genuinely mirrors — the same base edge, immediately
    /// either side of the pin, walked opposite ways — is counted. A pin in the
    /// middle of a proper loop mirrors nothing and is excused nothing, which
    /// is right: it forced no retracing, so there is none to forgive.
    static func spurForced(by pins: [Point], in legs: [WalkLeg]) -> (metres: Double, turns: Int) {
        guard !pins.isEmpty, legs.count >= 2 else { return (0, 0) }
        // Where each leg begins, so a pin can be located on the walk.
        var boundary: [Point] = legs.compactMap(\.coordinates.first)
        guard boundary.count == legs.count, let end = legs.last?.coordinates.last else { return (0, 0) }
        boundary.append(end)

        var excused = 0.0
        var turns = 0
        for pin in pins {
            var at = 0
            var nearest = Double.infinity
            for (index, point) in boundary.enumerated() {
                let away = LocalGeo.distance(lat1: point.lat, lon1: point.lng, lat2: pin.lat, lon2: pin.lng)
                if away < nearest { nearest = away; at = index }
            }
            guard nearest <= LocalLoopRouter.waypointHitToleranceMetres else { continue }
            // Legs `at - 1` and `at` are the approach and the retreat. Walk
            // outward while they keep mirroring.
            var out = at - 1, back = at
            var mirrored = false
            while out >= 0, back < legs.count,
                  legs[out].physical >= 0, legs[out].physical == legs[back].physical {
                excused += legs[out].metres + legs[back].metres
                mirrored = true
                out -= 1
                back += 1
            }
            // One turn per pin that genuinely turned the walk round, and never
            // more than one: the excuse is for the shape the pin forced, not a
            // general allowance.
            if mirrored { turns += 1 }
        }
        return (excused, turns)
    }

    /// True when a route passes every pin, in the order they were dropped.
    ///
    /// The order matters and is what makes this more than a proximity check: a
    /// walk that visits the second pin before the first went somewhere else,
    /// however near both it came. Each pin must match on or after the segment
    /// the previous one matched.
    static func route(_ coordinates: [Point], hits waypoints: [Point]) -> Bool {
        guard coordinates.count >= 2 else { return false }
        let frame = MetricFrame(originLon: coordinates[0].lng, originLat: coordinates[0].lat)
        let line = coordinates.map { frame.project(lon: $0.lng, lat: $0.lat) }
        var afterSegment = 0
        for waypoint in waypoints {
            let point = frame.project(lon: waypoint.lng, lat: waypoint.lat)
            var bestSegment = -1
            var bestDistance = Double.infinity
            for segment in afterSegment..<(line.count - 1) {
                let distance = pointToSegmentMetres(point, line[segment], line[segment + 1])
                if distance < bestDistance {
                    bestDistance = distance
                    bestSegment = segment
                }
            }
            guard bestDistance <= LocalLoopRouter.waypointHitToleranceMetres else { return false }
            afterSegment = bestSegment
        }
        return true
    }

    private static func pointToSegmentMetres(
        _ point: (x: Double, y: Double), _ from: (x: Double, y: Double), _ to: (x: Double, y: Double)
    ) -> Double {
        let dx = to.x - from.x, dy = to.y - from.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return ((point.x - from.x) * (point.x - from.x) + (point.y - from.y) * (point.y - from.y)).squareRoot()
        }
        let position = Swift.max(0, Swift.min(1, ((point.x - from.x) * dx + (point.y - from.y) * dy) / lengthSquared))
        let cx = from.x + position * dx - point.x, cy = from.y + position * dy - point.y
        return (cx * cx + cy * cy).squareRoot()
    }
}
