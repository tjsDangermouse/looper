import Foundation

/// Waypoint loops, as a length problem rather than a shape problem.
///
/// A port of the route service's `waypoints.ts`, function for function and
/// constant for constant. That fidelity is deliberate: the two engines are
/// meant to answer the same question the same way, and a local engine that
/// spread its slack differently would be a different product rather than the
/// same one working offline.
///
/// When a walker drops pins, the walk is no longer "a ring of about five
/// kilometres from here" — it is "through these places, in this order, in
/// about five kilometres". The structure the problem has:
///
/// ```text
/// anchors   a0 = start, a1 … am = the walker's pins, a(m+1) = start
/// backbone  B = Σ shortest(ai, a(i+1))          — the walk you cannot avoid
/// slack     Δ = K - B                            — what there is to spend
/// ```
///
/// `B` is a floor: no walk through those pins in that order is shorter. If Δ
/// is negative the request is impossible and is refused, honestly and
/// immediately. If it is positive, the question is *where to spend it* — and
/// spending it evenly across the gaps produces a rounder walk than spending it
/// all in one place.
///
/// Nothing in here moves a pin or reorders one: the anchors are the problem
/// statement, not part of the search. Nothing in here routes, either — every
/// function is geometry and arithmetic, which is what makes it testable
/// without a graph and what let it be ported at all.
public enum LocalWaypointPlanner {
    /// One way of getting from one anchor to the next.
    public struct SegmentOption: Sendable, Equatable {
        /// Which anchor gap this crosses.
        public var gap: Int
        /// Stable within a gap, so a chosen combination can be named and compared.
        public var id: String
        /// Invisible shaping points between the two anchors. Never a walker's pin.
        public var guides: [Point]
        public var distanceMetres: Double
        public var durationSeconds: Double

        public init(gap: Int, id: String, guides: [Point], distanceMetres: Double, durationSeconds: Double) {
            self.gap = gap
            self.id = id
            self.guides = guides
            self.distanceMetres = distanceMetres
            self.durationSeconds = durationSeconds
        }
    }

    /// The detour sizes each gap is offered, as shares of the slack available
    /// to it. Zero is always among them: the shortest way between two anchors
    /// has to stay on the table, or a walk with no room to spare has nothing
    /// to choose.
    public static let detourShares: [Double] = [0, 0.35, 0.7, 1.2, 2]

    /// Where to put a shaping point so a gap comes out a given length longer.
    ///
    /// Treating the detour as an isoceles triangle over the gap: to walk
    /// `extra` further than the straight line `L`, step out perpendicular from
    /// the middle by `sqrt(((L + extra) / 2)² - (L / 2)²)`. That is a
    /// crow-flight answer to a crow-flight question, and the network will not
    /// honour it exactly — which is why the routed length of every option is
    /// measured rather than assumed.
    public static func guideForDetour(from: Point, to: Point, extraMetres: Double, side: Double) -> Point {
        let straight = haversine(from, to)
        let wanted = straight + Swift.max(0, extraMetres)
        let offset = Swift.max(0, pow(wanted / 2, 2) - pow(straight / 2, 2)).squareRoot()
        let bearing = LocalGeo.bearing(lat1: from.lat, lon1: from.lng, lat2: to.lat, lon2: to.lng)
        let mid = LocalGeo.destination(lat: from.lat, lon: from.lng, metres: straight / 2, bearing: bearing)
        let out = LocalGeo.destination(
            lat: mid.lat, lon: mid.lon,
            metres: Swift.max(25, offset),
            bearing: LocalGeo.normaliseBearing(bearing + 90 * side)
        )
        return Point(out.lon, out.lat)
    }

    /// Plan the shaping points for one gap. Pure — it decides what to ask the
    /// router for, and asks it for nothing.
    ///
    /// `networkStretch` is how much further the network made the direct route
    /// than the crow flies across this gap. A detour asked for in crow-flight
    /// metres comes back that much longer, so the shaping point is placed for
    /// the detour we want *after* the network has had its way with it.
    public static func planSegmentOptions(
        gap: Int, from: Point, to: Point, slackForGap: Double, networkStretch: Double = 1
    ) -> [(id: String, guides: [Point])] {
        var planned: [(id: String, guides: [Point])] = [(id: "\(gap)-direct", guides: [])]
        guard slackForGap > 0 else { return planned }
        let stretch = networkStretch.isFinite ? Swift.min(3, Swift.max(0.8, networkStretch)) : 1
        for share in detourShares where share > 0 {
            for side in [1.0, -1.0] {
                planned.append((
                    id: "\(gap)-\(formatShare(share))-\(side > 0 ? "l" : "r")",
                    guides: [guideForDetour(from: from, to: to, extraMetres: slackForGap * share / stretch, side: side)]
                ))
            }
        }
        return planned
    }

    /// The share as the service names it, so an id means the same thing in
    /// both engines and a log line from one can be read against the other.
    private static func formatShare(_ share: Double) -> String {
        share == share.rounded() ? String(Int(share)) : String(share)
    }

    // MARK: - Allocation

    public struct AllocationOptions: Sendable {
        /// Distance or duration the whole walk is aiming at.
        public var target: Double
        /// Resolution of the dynamic programme, in the same unit as `target`.
        public var bucketSize: Double
        /// Most buckets the table may have. Bounds the work, whatever is asked for.
        public var maxBuckets: Int
        /// Distinct combinations kept per state, which is what makes several
        /// answers possible.
        public var keepPerState: Int
        /// How many finished combinations to return.
        public var limit: Int
        /// How far off the target a combination may be and still be picked for
        /// variety's sake, as a share of the target. Variety is worth
        /// something and it is not worth the walker's distance.
        public var spreadWithinError: Double
        /// How much ground a combination's plan must enclose before it is
        /// worth routing. Measured on the anchors and shaping points, so it is
        /// free. Below the finished walk's own compactness gate, because
        /// routing adds wiggle and therefore only ever lowers it: this catches
        /// the plans that enclose nothing at all.
        public var minShape: Double
        /// What of an option the table is adding up. A walk asked for in
        /// minutes and assembled in metres is the right length and the wrong
        /// walk.
        public var measure: @Sendable (SegmentOption) -> Double

        public init(
            target: Double, bucketSize: Double = 100, maxBuckets: Int = 96, keepPerState: Int = 3,
            limit: Int = 6, spreadWithinError: Double = 0.1, minShape: Double = 0.25,
            measure: @escaping @Sendable (SegmentOption) -> Double = { $0.distanceMetres }
        ) {
            self.target = target
            self.bucketSize = bucketSize
            self.maxBuckets = maxBuckets
            self.keepPerState = keepPerState
            self.limit = limit
            self.spreadWithinError = spreadWithinError
            self.minShape = minShape
            self.measure = measure
        }
    }

    public struct Allocation: Sendable, Equatable {
        /// One option per gap, in gap order.
        public var chosen: [SegmentOption]
        /// In whatever `measure` counts — metres by default, seconds in time mode.
        public var total: Double
        /// How far off the target, in the target's own unit.
        public var error: Double
        /// How lopsided the spending was: the largest share of the total
        /// detour that landed in any one gap. All the slack in one gap is a
        /// walk with a balloon on the side of it.
        public var concentration: Double
        /// How much ground the combination encloses, against a circle of the
        /// same perimeter — measured on the anchors and shaping points alone,
        /// before anything is routed. This is what stops the allocation
        /// assembling a walk that is exactly the right length and shaped like
        /// a closed pair of scissors.
        public var shape: Double

        public var key: String { chosen.map(\.id).joined(separator: "|") }
    }

    /// The crow-flight ring a combination describes: the anchors in order,
    /// with each gap's shaping points threaded between them.
    ///
    /// Deliberately geometric and unrouted. It is not what the walk will look
    /// like — the network decides that — but a combination whose *plan*
    /// encloses nothing will not produce a walk that encloses something, and
    /// finding that out here costs nothing rather than costing a routed leg.
    public static func ringOf(anchors: [Point], chosen: [SegmentOption]) -> [Point] {
        guard let first = anchors.first else { return [] }
        var ring: [Point] = [first]
        for gap in 0..<chosen.count {
            ring.append(contentsOf: chosen[gap].guides)
            ring.append(gap + 1 < anchors.count ? anchors[gap + 1] : first)
        }
        return ring
    }

    public static func ringShapeOf(anchors: [Point], chosen: [SegmentOption]) -> Double {
        RouteQuality.compactness(ringOf(anchors: anchors, chosen: chosen))
    }

    /// Choose one option per gap so the whole walk comes out near the target.
    ///
    /// A bucketed dynamic programme rather than an exhaustive search, so the
    /// cost is bounded by the table rather than by the number of gaps: five
    /// gaps with nine options each is fifty-nine thousand combinations, and
    /// the table is a few hundred entries whatever the gap count.
    ///
    /// Several answers, not one: three walks that all spend their slack the
    /// same way are one walk.
    ///
    /// Deterministic throughout — states are visited in order, ties are broken
    /// by a stated rule, and the returned list is sorted.
    public static func allocateSlack(
        _ byGap: [[SegmentOption]], anchors: [Point] = [], options: AllocationOptions
    ) -> [Allocation] {
        guard !byGap.isEmpty, !byGap.contains(where: \.isEmpty) else { return [] }

        func bucketOf(_ value: Double) -> Int {
            Swift.min(options.maxBuckets - 1, Swift.max(0, Int((value / options.bucketSize).rounded())))
        }
        struct PartialCombination { var chosen: [SegmentOption]; var total: Double }
        var states: [Int: [PartialCombination]] = [0: [PartialCombination(chosen: [], total: 0)]]

        for gap in byGap {
            var next: [Int: [PartialCombination]] = [:]
            // Options in a stable order, so the table is filled the same way
            // every run.
            let ordered = gap.sorted {
                let a = options.measure($0), b = options.measure($1)
                return a != b ? a < b : $0.id < $1.id
            }
            for bucket in states.keys.sorted() {
                for partial in states[bucket]! {
                    for option in ordered {
                        let total = partial.total + options.measure(option)
                        // Anything already this far over cannot come back
                        // under it, and a walk twice as long as the plan is not
                        // a walk the plan describes.
                        if total > options.target * 2 { continue }
                        let key = bucketOf(total)
                        var bag = next[key] ?? []
                        if bag.count >= options.keepPerState {
                            // Keep the ones closest to the target within this
                            // bucket; the bucket is a coarse grouping, not a
                            // claim they are equal.
                            var worst = 0
                            for (index, entry) in bag.enumerated()
                            where abs(entry.total - options.target) > abs(bag[worst].total - options.target) {
                                worst = index
                            }
                            if abs(total - options.target) >= abs(bag[worst].total - options.target) { continue }
                            bag[worst] = PartialCombination(chosen: partial.chosen + [option], total: total)
                        } else {
                            bag.append(PartialCombination(chosen: partial.chosen + [option], total: total))
                        }
                        next[key] = bag
                    }
                }
            }
            states = next
            if states.isEmpty { return [] }
        }

        var finished: [Allocation] = []
        for bucket in states.keys.sorted() {
            for partial in states[bucket]! {
                finished.append(Allocation(
                    chosen: partial.chosen,
                    total: partial.total,
                    error: abs(partial.total - options.target),
                    concentration: concentrationOf(partial.chosen, byGap: byGap, measure: options.measure),
                    shape: anchors.isEmpty ? 0 : ringShapeOf(anchors: anchors, chosen: partial.chosen)
                ))
            }
        }

        var seen: Set<String> = []
        let ranked = finished
            .sorted(by: closenessThenSpread)
            .filter { seen.insert($0.key).inserted }

        let band = options.target * options.spreadWithinError
        func encloses(_ allocation: Allocation) -> Bool { allocation.shape >= options.minShape }
        /// Four tiers, best first: the right length *and* encloses ground;
        /// encloses ground; the right length; neither.
        ///
        /// Ordering the whole list rather than filtering the front of it is
        /// the point. Filtering only the combinations that get spread for
        /// variety leaves the rest of the set to be filled in plain
        /// distance-error order, which is how a shape preference ends up
        /// governing three of twenty-four assembled walks.
        func tierOf(_ allocation: Allocation) -> Int {
            (encloses(allocation) ? 0 : 2) + (allocation.error <= band ? 0 : 1)
        }
        let ordered = ranked.sorted { a, b in
            let ta = tierOf(a), tb = tierOf(b)
            return ta != tb ? ta < tb : closenessThenSpread(a, b)
        }

        // Variety is chosen among the best tier where there is one, so two
        // walks that both enclose ground but spend their slack in different
        // gaps beat one of each. Where nothing encloses ground — a pin down a
        // single lane — the honest there-and-back is still offered rather than
        // nothing.
        let best = ordered.filter { tierOf($0) == 0 }
        let spread = spreadAllocations(best.isEmpty ? ordered : best, limit: options.limit)
        if spread.count >= options.limit { return spread }
        let already = Set(spread.map(\.key))
        return Array((spread + ordered.filter { !already.contains($0.key) }).prefix(options.limit))
    }

    /// Closest to the target first, then the least lopsided, then by name so
    /// the order never depends on how the table was walked.
    private static func closenessThenSpread(_ a: Allocation, _ b: Allocation) -> Bool {
        if a.error != b.error { return a.error < b.error }
        if a.concentration != b.concentration { return a.concentration < b.concentration }
        return a.key < b.key
    }

    /// Pick allocations that spend their slack in genuinely different places.
    ///
    /// The table's best twelve answers are usually the same walk twelve times:
    /// the same choice in every gap but one, differing by a hundred metres
    /// nobody would notice. Sorting by target error alone therefore hands the
    /// diversity selector a set it has to throw most of away, and the walker
    /// ends up with one choice.
    ///
    /// So after the closest answer, each further one is whichever remaining
    /// answer differs in the most gaps from everything picked so far. Error
    /// breaks ties, so a spread-out answer never beats a close one that is
    /// equally different.
    public static func spreadAllocations(_ ranked: [Allocation], limit: Int) -> [Allocation] {
        guard ranked.count > 1 else { return Array(ranked.prefix(limit)) }
        var chosen = [ranked[0]]
        var remaining = Array(ranked.dropFirst())

        while chosen.count < limit && !remaining.isEmpty {
            var bestIndex = 0
            var bestDistance = -1
            for index in remaining.indices {
                let distance = chosen.map { gapsDiffering(between: $0, and: remaining[index]) }.min() ?? 0
                if distance > bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            chosen.append(remaining.remove(at: bestIndex))
        }
        return chosen
    }

    /// How many gaps two allocations made a different choice in.
    public static func gapsDiffering(between a: Allocation, and b: Allocation) -> Int {
        var differing = 0
        for gap in 0..<Swift.max(a.chosen.count, b.chosen.count) {
            let left = gap < a.chosen.count ? a.chosen[gap].id : nil
            let right = gap < b.chosen.count ? b.chosen[gap].id : nil
            if left != right { differing += 1 }
        }
        return differing
    }

    /// The largest share of the walk's total detour spent in any one gap. Zero
    /// gaps of detour, or none at all, is perfectly even rather than undefined.
    static func concentrationOf(
        _ chosen: [SegmentOption], byGap: [[SegmentOption]], measure: (SegmentOption) -> Double
    ) -> Double {
        var detours: [Double] = []
        for (gap, option) in chosen.enumerated() {
            guard gap < byGap.count, let shortest = byGap[gap].map(measure).min() else { continue }
            detours.append(Swift.max(0, measure(option) - shortest))
        }
        let total = detours.reduce(0, +)
        guard total > 0, let largest = detours.max() else { return 0 }
        return largest / total
    }

    // MARK: - Feasibility

    /// The tolerance is for snapping and measurement, not for optimism:
    /// refusing a walk that is actually possible is the failure that costs a
    /// walker their walk, so the doubt goes their way.
    public static let feasibilityTolerance = 0.05

    /// Whether a walk through these anchors can fit in the plan at all.
    ///
    /// `backbone` must be a genuine lower bound on the ordinary walking
    /// distance. On the device it always is, and that is worth stating: the
    /// service has to route each gap a second time under a shortest-path model
    /// before it dares refuse, because GraphHopper's *preferred* route is not
    /// a shortest one and a preference is not a bound. Here the backbone comes
    /// from a Dijkstra on metres, so it is the bound already.
    public static func fitsInPlan(
        backbone: Double, target: Double, maxErrorFraction: Double,
        tolerance: Double = feasibilityTolerance
    ) -> Bool {
        guard target > 0 else { return false }
        return backbone <= target * (1 + maxErrorFraction) * (1 + tolerance)
    }
}
