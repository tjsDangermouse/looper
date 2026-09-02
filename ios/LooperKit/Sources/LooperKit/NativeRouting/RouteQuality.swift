import Foundation

/// Whether a walk is good enough to offer.
///
/// A port of the route service's `quality.ts`, with no threshold relaxed and
/// no rule dropped. That fidelity is the point: the app now has two engines,
/// and a comparison between them is only meaningful if both are judged by the
/// same gate. A local engine that offered walks its remote counterpart would
/// have refused would look better in testing for exactly the wrong reason.
///
/// Geometry is the source of truth throughout. A route can hit the requested
/// distance exactly, return to the door, and still be a long path walked
/// twice.
public enum RouteQuality {
    // --- Thresholds. A candidate failing any of these is not offered. ------
    public static let maxDistanceError = 0.12
    public static let maxDurationError = 0.15
    public static let maxRepeatedFraction = 0.12
    /// A short backtrack in the middle of a walk is a corner that turned out
    /// to be a dead end. A long one is the opposite — a pier, a headland, a
    /// towpath with no second path back — and worth keeping. So this is a
    /// *minimum*: backtracking shorter than it is always held against a walk;
    /// at or past it, never on length alone.
    public static let minBacktrackMetres: Double = 500
    /// How much of the walk's own length its longest backtrack has to be
    /// before the walk is treated as fundamentally a there-and-back.
    public static let outAndBackShareThreshold = 0.3
    public static let startStubShare = 0.04
    public static let maxUTurns = 1
    public static let maxBoundingBoxRatio = 4.5
    /// Below 0.20 is a tangle; 0.26 and up is a walk. The bar sits at the
    /// tangle line rather than a margin above it, because 0.21–0.25 was being
    /// spent rejecting real neighbourhood loops in tightly-streeted suburbs.
    public static let minCompactness = 0.2
    /// How far the walk's furthest point is from the door, over the radius a
    /// circle of the same length would have. Dimensionless, and it reads off
    /// the shape directly: a lobed rosette sits well under 1, a circle at 1,
    /// a 2:1 oval at about 1.3, a there-and-back at about π.
    ///
    /// This is the measurement compactness cannot make. Compactness says how
    /// round a walk is, and answers "elongated loop" and "tangle of little
    /// loops" identically — both are far from round. Reach separates them,
    /// because a tangle by construction never gets far from where it started.
    /// So a walk clearing this bar is judged on the generous thresholds
    /// below: it is long and thin because that is the walk, not because it
    /// is scribble.
    public static let elongationReachRatio = 1.3
    /// What compactness has to clear once reach has vouched for the walk.
    /// Still a floor — an elongated walk may wander, but not fold up.
    public static let elongatedMinCompactness = 0.1
    /// And what aspect ratio, which is the whole point: a walk earns the
    /// right to be long and thin by actually going somewhere.
    public static let elongatedBoundingBoxRatio = 12.0
    /// What share of a loop one corner-to-corner leg may be, and what share
    /// an interior one must be. `MAX_LEG_SHARE` and `MIN_LEG_SHARE`. A loop
    /// with one leg carrying half the distance is a walk out and a scramble
    /// back; a loop with a leg of nothing has a corner that does no work.
    public static let maxLegShare = 0.45
    public static let minLegShare = 0.08
    public static let maxStartStubMetres: Double = 150
    public static let endpointToleranceMetres: Double = 40

    // --- Repeat detection tuning ------------------------------------------
    /// Route geometry is compared at this resolution.
    public static let sampleMetres: Double = 15
    /// Two stretches this close together are on the same ground.
    public static let corridorMatchMetres: Double = 17.5
    /// Shorter than this and it is a crossing, not a shared corridor.
    public static let minSharedRunMetres: Double = 37.5
    /// Stretches nearer than this along the route are the route continuing.
    public static let nonAdjacentMetres: Double = 50
    /// The shared start and finish of any loop is not retracing.
    public static let startIgnoreMetres: Double = 75
    /// Beyond this angle two stretches are crossing, not running together.
    static let parallelCosine = cos(35 * Double.pi / 180)
    /// Walking the same street back the other way is the worse failure.
    public static let reverseOverlapWeight = 1.5
    /// The three offered walks may share at most this much ground.
    public static let maxSharedFraction = 0.55

    public static func spurLimitMetres(routeMetres: Double, floorMetres: Double = maxStartStubMetres, share: Double = startStubShare) -> Double {
        Swift.max(floorMetres, routeMetres * share)
    }

    // MARK: - Sampling

    /// A near-uniform slice of a path, so two stretches can be compared
    /// without either one's vertex spacing mattering. OSM puts a vertex per
    /// surveyed node, which is metres apart on a winding lane and hundreds
    /// apart on a straight one.
    public struct Sample {
        public var midX: Double
        public var midY: Double
        public var dirX: Double
        public var dirY: Double
        public var length: Double
        public var along: Double
    }

    public static func resample(_ coordinates: [Point], spacingMetres: Double, origin: Point? = nil) -> (samples: [Sample], totalMetres: Double) {
        guard coordinates.count >= 2 else { return ([], 0) }
        let frame = MetricFrame(originLon: (origin ?? coordinates[0]).lng, originLat: (origin ?? coordinates[0]).lat)
        let flat = coordinates.map { frame.project(lon: $0.lng, lat: $0.lat) }
        var samples: [Sample] = []
        samples.reserveCapacity(flat.count)
        var carried = 0.0
        var from = flat[0]
        var sampleStart = flat[0]
        var travelled = 0.0

        func make(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double), _ done: Double) -> Sample {
            let length = Swift.max(1e-9, ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot())
            return Sample(
                midX: (a.x + b.x) / 2, midY: (a.y + b.y) / 2,
                dirX: (b.x - a.x) / length, dirY: (b.y - a.y) / length,
                length: length, along: done + length / 2
            )
        }

        for i in 1..<flat.count {
            var remaining = ((flat[i].x - from.x) * (flat[i].x - from.x) + (flat[i].y - from.y) * (flat[i].y - from.y)).squareRoot()
            while remaining > 0 && carried + remaining >= spacingMetres {
                let need = spacingMetres - carried
                let t = need / remaining
                let point = (x: from.x + (flat[i].x - from.x) * t, y: from.y + (flat[i].y - from.y) * t)
                samples.append(make(sampleStart, point, travelled))
                travelled += spacingMetres
                sampleStart = point
                from = point
                remaining -= need
                carried = 0
            }
            carried += remaining
            from = flat[i]
        }
        // A trailing stub shorter than a third of the spacing is noise.
        if carried > spacingMetres / 3 { samples.append(make(sampleStart, from, travelled)) }
        return (samples, travelled + carried)
    }

    /// Isoperimetric quotient: 1 for a circle, 0 for a path enclosing nothing.
    /// The measure of "is this a loop or is this a there-and-back".
    public static func compactness(_ coordinates: [Point]) -> Double {
        guard coordinates.count >= 4 else { return 0 }
        let frame = MetricFrame(originLon: coordinates[0].lng, originLat: coordinates[0].lat)
        let flat = coordinates.map { frame.project(lon: $0.lng, lat: $0.lat) }
        var twiceArea = 0.0, perimeter = 0.0
        for i in 0..<flat.count {
            let a = flat[i], b = flat[(i + 1) % flat.count]
            twiceArea += a.x * b.y - b.x * a.y
            perimeter += ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }
        guard perimeter > 0 else { return 0 }
        return Swift.min(1, 4 * .pi * abs(twiceArea / 2) / (perimeter * perimeter))
    }

    /// How far the walk gets from the door, against the radius a circle of its
    /// length would have. See `elongationReachRatio`.
    public static func reachRatio(maxRadiusMetres: Double, distanceMetres: Double) -> Double {
        let idealRadius = distanceMetres / (2 * Double.pi)
        return idealRadius > 0 ? maxRadiusMetres / idealRadius : 0
    }

    /// The furthest any point of the walk gets from the start, in metres.
    public static func maxRadiusMetres(_ coordinates: [Point], start: Point) -> Double {
        let frame = MetricFrame(originLon: start.lng, originLat: start.lat)
        var radius = 0.0
        for point in coordinates {
            let projected = frame.project(lon: point.lng, lat: point.lat)
            radius = Swift.max(radius, (projected.x * projected.x + projected.y * projected.y).squareRoot())
        }
        return radius
    }

    public static func boundingBoxSides(_ coordinates: [Point]) -> (longMetres: Double, shortMetres: Double) {
        guard coordinates.count >= 2 else { return (0, 0) }
        let frame = MetricFrame(originLon: coordinates[0].lng, originLat: coordinates[0].lat)
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for point in coordinates {
            let projected = frame.project(lon: point.lng, lat: point.lat)
            minX = Swift.min(minX, projected.x); maxX = Swift.max(maxX, projected.x)
            minY = Swift.min(minY, projected.y); maxY = Swift.max(maxY, projected.y)
        }
        let width = maxX - minX, height = maxY - minY
        return (Swift.max(width, height), Swift.min(width, height))
    }

    // MARK: - Retracing

    public struct SharedRun {
        public var metres: Double
        public var reversed: Bool
        public var alongStart: Double
    }

    public struct RepeatReport {
        public var repeatedMetres: Double = 0
        public var repeatedPercent: Double = 0
        /// Reverse-direction overlap counted at a premium, for scoring only.
        public var weightedRepeatedMetres: Double = 0
        public var runs: [SharedRun] = []
        public var longestReverseRunMetres: Double = 0
    }

    /// A grid over sample midpoints, so "what else is near here" is a handful
    /// of cell lookups rather than a scan of the whole walk.
    fileprivate struct SampleIndex {
        let samples: [Sample]
        let cell: Double
        var grid: [Int64: [Int]] = [:]

        init(_ samples: [Sample], cell: Double) {
            self.samples = samples
            self.cell = cell
            for (i, sample) in samples.enumerated() {
                grid[SampleIndex.key(Int(floor(sample.midX / cell)), Int(floor(sample.midY / cell))), default: []].append(i)
            }
        }

        static func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) &* 1_000_003 &+ Int64(y) }

        /// Every sample within one cell, so a match is never missed at an edge.
        func near(x: Double, y: Double) -> [Int] {
            let cx = Int(floor(x / cell)), cy = Int(floor(y / cell))
            var found: [Int] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    if let bucket = grid[SampleIndex.key(cx + dx, cy + dy)] { found.append(contentsOf: bucket) }
                }
            }
            return found
        }
    }

    /// How much of the walk is spent on ground it has already covered.
    ///
    /// Only *earlier* ground counts, so a shared corridor is charged once
    /// rather than twice. Matches must run together for at least ~40 m before
    /// they count: a route crossing its own path at a junction touches itself
    /// for a couple of metres, and that is a crossroads, not retracing.
    public static func findRepeatedCorridors(_ coordinates: [Point], ignoreStartMetres: Double = startIgnoreMetres) -> RepeatReport {
        let (samples, totalMetres) = resample(coordinates, spacingMetres: sampleMetres)
        guard samples.count >= 3, totalMetres > 0 else { return RepeatReport() }
        let index = SampleIndex(samples, cell: corridorMatchMetres)
        var matched = [Bool?](repeating: nil, count: samples.count)

        for i in 0..<samples.count {
            let sample = samples[i]
            // The first and last stretch of any loop share a doorstep.
            if sample.along < ignoreStartMetres || sample.along > totalMetres - ignoreStartMetres { continue }
            var bestReversed = false
            var bestDistance = Double.infinity
            for j in index.near(x: sample.midX, y: sample.midY) {
                let other = samples[j]
                // Earlier ground only, and far enough back along the route
                // that this is not simply the walk continuing round a bend.
                guard other.along < sample.along - nonAdjacentMetres, other.along >= ignoreStartMetres else { continue }
                let dx = sample.midX - other.midX, dy = sample.midY - other.midY
                let gap = (dx * dx + dy * dy).squareRoot()
                guard gap <= corridorMatchMetres else { continue }
                let alignment = sample.dirX * other.dirX + sample.dirY * other.dirY
                guard abs(alignment) >= parallelCosine else { continue }
                if gap < bestDistance { bestDistance = gap; bestReversed = alignment < 0 }
            }
            if bestDistance.isFinite { matched[i] = bestReversed }
        }

        // Group consecutive matched samples; short ones are junctions.
        var report = RepeatReport()
        var runStart = -1
        var runMetres = 0.0
        var reversedMetres = 0.0
        func closeRun() {
            defer { runStart = -1; runMetres = 0; reversedMetres = 0 }
            guard runStart >= 0, runMetres >= minSharedRunMetres else { return }
            report.runs.append(SharedRun(metres: runMetres, reversed: reversedMetres * 2 >= runMetres, alongStart: samples[runStart].along))
        }
        for i in 0..<samples.count {
            if let reversed = matched[i] {
                if runStart < 0 { runStart = i }
                runMetres += samples[i].length
                if reversed { reversedMetres += samples[i].length }
            } else {
                closeRun()
            }
        }
        closeRun()

        report.repeatedMetres = report.runs.reduce(0) { $0 + $1.metres }
        report.weightedRepeatedMetres = report.runs.reduce(0) { $0 + $1.metres * ($1.reversed ? reverseOverlapWeight : 1) }
        report.repeatedPercent = report.repeatedMetres / totalMetres * 100
        report.longestReverseRunMetres = report.runs.filter(\.reversed).reduce(0) { Swift.max($0, $1.metres) }
        return report
    }

    // MARK: - Retracing, from the network

    /// One pass over one physical edge, in walking order.
    public struct EdgeTraversal: Sendable {
        /// The physical (base graph) edge, so the two halves of a split edge
        /// are the same street and are charged as such.
        public var id: Int32
        public var metres: Double
        /// Distance from the walk's start to where this pass began.
        public var along: Double
        /// Unit vector of the pass, in any consistent metric frame. Only its
        /// sign against another pass of the same edge is ever used.
        public var dirX: Double
        public var dirY: Double

        public init(id: Int32, metres: Double, along: Double, dirX: Double, dirY: Double) {
            self.id = id
            self.metres = metres
            self.along = along
            self.dirX = dirX
            self.dirY = dirY
        }
    }

    /// The same question as `findRepeatedCorridors`, asked of the network
    /// instead of the line. A port of the route service's `edgeRepeatReport`.
    ///
    /// This is the measure to prefer wherever the walk knows its edges, and a
    /// searched walk always does. The geometric measure calls two stretches the
    /// same ground when they run within 17.5 m of each other at under 35°,
    /// which is true of a road and its own pavement, of a footway beside a
    /// river, and of the two sides of a dual carriageway — none of which a
    /// walker experiences as covering the same ground twice. Asking the network
    /// removes those, and only those: a street genuinely walked twice has the
    /// same edge id twice and is still charged for it.
    ///
    /// The doorstep is skipped at both ends for the same reason as the
    /// geometric measure — every loop shares the way out and the way back.
    public static func edgeRepeatReport(
        _ traversals: [EdgeTraversal], totalMetres: Double, ignoreStartMetres: Double = startIgnoreMetres
    ) -> RepeatReport {
        guard !traversals.isEmpty, totalMetres > 0 else { return RepeatReport() }
        /// The most of an edge covered in one pass so far, and which way it ran.
        var covered: [Int32: (metres: Double, dirX: Double, dirY: Double)] = [:]
        var report = RepeatReport()
        var repeatedRun = 0.0
        var reverseRun = 0.0
        var longestRepeatedRun = 0.0

        for traversal in traversals {
            // Symmetric on purpose, where the reference tests only where a
            // pass *starts*. A pass is at the doorstep if any part of it lies
            // in the opening or closing window — otherwise the leg that walks
            // back up to the door is excused only when it happens to begin
            // past the boundary, which the returning half of a stem never
            // does: it begins exactly on it.
            let atDoorstep = traversal.along < ignoreStartMetres
                || traversal.along + traversal.metres > totalMetres - ignoreStartMetres
            let seen = covered[traversal.id]
            // A pass repeats only as much of the edge as an earlier pass
            // already covered, so the second full traversal of a street counts
            // once and the third counts twice.
            let overlap = atDoorstep ? 0 : Swift.min(traversal.metres, seen?.metres ?? 0)

            if overlap > 0 {
                let reversed = seen.map { traversal.dirX * $0.dirX + traversal.dirY * $0.dirY < 0 } ?? false
                report.repeatedMetres += overlap
                report.weightedRepeatedMetres += overlap * (reversed ? reverseOverlapWeight : 1)
                repeatedRun += overlap
                reverseRun = reversed ? reverseRun + overlap : 0
                longestRepeatedRun = Swift.max(longestRepeatedRun, repeatedRun)
                report.longestReverseRunMetres = Swift.max(report.longestReverseRunMetres, reverseRun)
            } else {
                repeatedRun = 0
                reverseRun = 0
            }

            if seen == nil || traversal.metres > seen!.metres {
                covered[traversal.id] = (traversal.metres, traversal.dirX, traversal.dirY)
            }
        }

        // `runs` stays empty: nothing downstream reads it, and an edge report
        // has no notion of a contiguous stretch of line to populate it with.
        report.repeatedPercent = report.repeatedMetres / totalMetres * 100
        return report
    }

    /// The out-and-back stub at the start: walk outwards from the beginning
    /// and inwards from the end at the same pace, and while the two are on the
    /// same ground the walk has not started its loop yet.
    public static func startStubMetres(_ coordinates: [Point], toleranceMetres: Double = 25) -> Double {
        let (samples, totalMetres) = resample(coordinates, spacingMetres: sampleMetres)
        guard samples.count >= 4, totalMetres > 0 else { return 0 }
        func at(_ target: Double) -> Sample {
            var low = 0, high = samples.count - 1
            while low < high {
                let mid = (low + high) / 2
                if samples[mid].along < target { low = mid + 1 } else { high = mid }
            }
            if low > 0, abs(samples[low - 1].along - target) < abs(samples[low].along - target) { return samples[low - 1] }
            return samples[low]
        }
        var stub = 0.0
        for sample in samples {
            if sample.along * 2 >= totalMetres { break }
            let mirror = at(totalMetres - sample.along)
            let dx = sample.midX - mirror.midX, dy = sample.midY - mirror.midY
            if (dx * dx + dy * dy).squareRoot() > toleranceMetres { break }
            stub = sample.along
        }
        return stub
    }

    /// Turn-arounds, from the line itself. An angle alone is not enough: a
    /// switchback lane can swing more than 165° in thirty metres without the
    /// walker having reversed anything. What makes a turn a U-turn is that the
    /// walk comes back past where it was.
    public static func countUTurns(_ coordinates: [Point]) -> Int {
        let (samples, _) = resample(coordinates, spacingMetres: sampleMetres)
        var metric: [Double] = []
        metric.reserveCapacity(coordinates.count * 2)
        guard !coordinates.isEmpty else { return 0 }
        let frame = MetricFrame(originLon: coordinates[0].lng, originLat: coordinates[0].lat)
        for point in coordinates {
            let projected = frame.project(lon: point.lng, lat: point.lat)
            metric.append(projected.x)
            metric.append(projected.y)
        }
        _ = samples
        return WalkUTurns.count(metric)
    }

    /// How much of route `a` runs along route `b`. Deliberately
    /// one-directional: a two-kilometre walk entirely contained in a
    /// six-kilometre one shares all of itself and only a third of the other.
    /// Every caller needing a symmetric answer asks twice and takes the worse.
    /// One side of a corridor comparison, resampled ready to be measured
    /// against many others.
    ///
    /// Comparing one walk against a handful of others — which is what excluding
    /// the already-offered walks from a refresh is — resampled both sides of
    /// every pair, so the same three excluded walks were rebuilt once for each
    /// of a couple of hundred candidates. Hoisting that out turns the work from
    /// candidates times excluded into candidates plus excluded. The frame is
    /// the reason it was not already hoisted: both sides of a comparison have
    /// to be measured in one, or two loops three kilometres apart come out
    /// overlapping. Passing the doorstep as that frame satisfies it for every
    /// pair at once, which the left-hand walk's own first point could not.
    public struct Corridor {
        let samples: [Sample]
        let totalMetres: Double
        fileprivate let index: SampleIndex?
    }

    /// - Parameter indexed: whether this side will be searched against, rather
    ///   than walked along. Only the right-hand side of a comparison needs it.
    public static func corridor(_ coordinates: [Point], origin: Point, indexed: Bool = false) -> Corridor {
        let sampled = resample(coordinates, spacingMetres: sampleMetres, origin: origin)
        return Corridor(
            samples: sampled.samples, totalMetres: sampled.totalMetres,
            index: indexed && !sampled.samples.isEmpty
                ? SampleIndex(sampled.samples, cell: corridorMatchMetres) : nil
        )
    }

    public static func sharedCorridorMetres(_ a: [Point], _ b: [Point], ignoreStartMetres: Double = startIgnoreMetres) -> (metres: Double, fraction: Double) {
        guard let origin = a.first else { return (0, 0) }
        // Both routes must be measured in the *same* frame, or two loops three
        // kilometres apart come out overlapping.
        return sharedCorridorMetres(
            corridor(a, origin: origin), corridor(b, origin: origin, indexed: true),
            ignoreStartMetres: ignoreStartMetres
        )
    }

    public static func sharedCorridorMetres(_ left: Corridor, _ right: Corridor, ignoreStartMetres: Double = startIgnoreMetres) -> (metres: Double, fraction: Double) {
        guard !left.samples.isEmpty, let index = right.index else { return (0, 0) }

        var runMetres = 0.0, shared = 0.0
        func closeRun() {
            if runMetres >= minSharedRunMetres { shared += runMetres }
            runMetres = 0
        }
        for sample in left.samples {
            if sample.along < ignoreStartMetres || sample.along > left.totalMetres - ignoreStartMetres {
                closeRun()
                continue
            }
            let hit = index.near(x: sample.midX, y: sample.midY).contains { j in
                let other = index.samples[j]
                let dx = sample.midX - other.midX, dy = sample.midY - other.midY
                guard (dx * dx + dy * dy).squareRoot() <= corridorMatchMetres else { return false }
                return abs(sample.dirX * other.dirX + sample.dirY * other.dirY) >= parallelCosine
            }
            if hit { runMetres += sample.length } else { closeRun() }
        }
        closeRun()
        return (shared, left.totalMetres > 0 ? shared / left.totalMetres : 0)
    }

    // MARK: - The report

    public struct Score: Sendable, Equatable {
        public var score: Double
        public var repeatedMetres: Double
        public var repeatedPercent: Double
        public var uTurnCount: Int
        public var compactness: Double
    }

    public struct Report: Sendable {
        public var pass: Bool
        /// Machine-readable reasons, for logs and tests. Never shown.
        public var rejections: [String]
        public var quality: Score
        public var distanceErrorFraction: Double
        public var distanceMetres: Double
        public var targetMetres: Double
        public var boundingBoxRatio: Double
        public var startStubMetres: Double
        public var longestReverseRunMetres: Double
        /// Right length, right place, but the shape is compromised. Offered
        /// only where nothing clean exists, and never silently.
        public var passesEssentials: Bool
    }

    /// The rejections that mean "this is not the walk you asked for". Every
    /// other rejection is about the *shape* of the walk.
    public static let essentialRejections: Set<String> = ["distance", "duration", "open-ended"]

    /// - Parameters:
    ///   - traversals: the physical edges the walk spent, in walking order,
    ///     where the engine knows them. Retracing is then measured on the
    ///     network rather than from the line — see `edgeRepeatReport`. The
    ///     remote engine does exactly this whenever GraphHopper gives it
    ///     traversals, so supplying them is parity, not leniency.
    ///   - excusedRetraceMetres: retracing the walker asked for, rather than
    ///     retracing the engine chose.
    ///
    ///     A pin dropped at the end of a lane, on a pier, at a viewpoint, can
    ///     only be visited by walking in and walking out again. That is not a
    ///     routing defect and it is not noise: it is the walk that was
    ///     requested, and the ground offers no other way to honour it. Judged
    ///     without this the gate refuses the walk for doing exactly what it
    ///     was told, and the only escape is to delete the visit — which is the
    ///     escape the remote engine takes, and why more than half its waypoint
    ///     walks no longer pass their own pins.
    ///
    ///     Measured, never assumed: the caller supplies only ground it can
    ///     show is the mirrored approach to and retreat from a pin. Every
    ///     other metre of retracing is still charged in full.
    ///   - stemMetres: an out-and-back at the door that the *engine* imposed
    ///     rather than the walk choosing it. The on-device search must root a
    ///     circuit at a node inside the 2-core, so a walk from a cul-de-sac
    ///     address carries the same stem out and back whatever it does in
    ///     between. It is not a spur the walker would recognise as one, and no
    ///     remote route has one, so it is not charged as one.
    ///   - maxDistanceError: how far off the requested length a walk may be.
    ///     Only ever passed by the waypoint path, and it is the service's own
    ///     waypoint tolerance rather than a relaxation invented here: a walk
    ///     through fixed pins cannot choose its own length as freely as a ring
    ///     can, so both engines judge it in a wider band. Note that it moves
    ///     the *verdict* and not the score — closeness is still scored against
    ///     the standard threshold, so a waypoint walk's quality number stays
    ///     on one scale with every other walk's.
    public static func analyse(
        coordinates: [Point],
        start: Point,
        distanceMetres: Double,
        targetMetres: Double,
        traversals: [EdgeTraversal]? = nil,
        stemMetres: Double = 0,
        maxDistanceError: Double = RouteQuality.maxDistanceError,
        excusedRetraceMetres: Double = 0,
        excusedUTurns: Int = 0,
        /// What share of the walk each of its legs is, where a leg is one
        /// corner-to-corner stretch. Absent from an engine that never cut the
        /// walk into legs, which is why the two rules and the score term below
        /// only apply when it is given. See `scoreRoute`.
        legShares: [Double]? = nil
    ) -> Report {
        var rejections: [String] = []
        // The stem is the same edges out and back, so on the network it reads
        // as retracing — which is exactly what it is, and exactly what the
        // walker did not choose. It is excused the same way the doorstep is,
        // by widening the window rather than by discounting afterwards: the
        // doorstep simply reaches as far as the circuit does.
        let doorstep = Swift.max(startIgnoreMetres, stemMetres)
        let repeats = traversals.map { edgeRepeatReport($0, totalMetres: distanceMetres, ignoreStartMetres: doorstep) }
            ?? findRepeatedCorridors(coordinates)
        let uTurnCount = countUTurns(coordinates)
        let shape = compactness(coordinates)
        let sides = boundingBoxSides(coordinates)
        let boundingBoxRatio = sides.shortMetres > 0 ? sides.longMetres / sides.shortMetres : .infinity
        // The stem is walked at both ends and is measured as part of the stub,
        // so it comes off the measurement rather than being added to the limit.
        let stub = Swift.max(0, startStubMetres(coordinates) - stemMetres)
        let startStubLimit = spurLimitMetres(routeMetres: distanceMetres)

        /// Long enough that it can only be a real feature, not an accident.
        let longEnoughBacktrack = repeats.longestReverseRunMetres >= minBacktrackMetres
        /// What is left of the longest backtrack once the ground a pin forced
        /// the walk to cover twice is taken off it. A walk whose only
        /// backtracking is the lane to the viewpoint the walker chose has
        /// nothing here to answer for.
        let unaskedReverseRun = Swift.max(0, repeats.longestReverseRunMetres - excusedRetraceMetres)
        /// Some ground retraced, but not enough of it to be the walk's own
        /// feature rather than a corner that turned out to be a dead end.
        let shortBacktrack = unaskedReverseRun > 0 && !longEnoughBacktrack
        /// A walk that is essentially there-and-back — a promenade, a pier, a
        /// headland with one road in — legitimately encloses almost no area
        /// and runs long and thin. That is what the walk is, not a failure.
        let wholeWalkOutAndBack = longEnoughBacktrack
            && repeats.longestReverseRunMetres > distanceMetres * outAndBackShareThreshold
        /// Ground repeated beyond the one long crossing already excused above.
        let scribbleMetres = Swift.max(
            0,
            repeats.repeatedMetres
                - (longEnoughBacktrack ? repeats.longestReverseRunMetres : 0)
                - excusedRetraceMetres
        )
        /// A walk that genuinely goes somewhere. It may be long and thin and
        /// enclose little area, and that is a shape a walker asked for as much
        /// as a circle is — a river out and a street back, a ridge, a
        /// seafront. What it may not be is a knot of little loops near the
        /// door, and reach is exactly the measurement that tells the two
        /// apart. See `elongationReachRatio`.
        /// Measured only when it can change the verdict. It is a pass over
        /// every vertex of the walk, and the walks it would change the verdict
        /// for are the minority that one of the two shape rules is about to
        /// refuse.
        let shapeInDoubt = boundingBoxRatio > maxBoundingBoxRatio || shape < minCompactness
        let reaches = !wholeWalkOutAndBack && shapeInDoubt && reachRatio(
            maxRadiusMetres: maxRadiusMetres(coordinates, start: start), distanceMetres: distanceMetres
        ) >= elongationReachRatio

        let distanceErrorFraction = targetMetres > 0 ? abs(distanceMetres - targetMetres) / targetMetres : 0

        if distanceErrorFraction > maxDistanceError { rejections.append("distance") }
        if scribbleMetres > distanceMetres * maxRepeatedFraction { rejections.append("repeated-corridor") }
        if shortBacktrack { rejections.append("out-and-back-spur") }
        // Turning round at the tip of a lane a pin sits on is the same fact as
        // the retracing excused above, counted a second way: the walk went in
        // and came out, so it turned. Charging it once is right and charging it
        // twice refuses the walk outright, because two pins on lanes exhaust
        // the allowance on their own. Only pins whose mirrored ground was
        // actually measured buy an excuse here.
        if uTurnCount > maxUTurns + excusedUTurns { rejections.append("u-turns") }
        if !wholeWalkOutAndBack
            && boundingBoxRatio > (reaches ? elongatedBoundingBoxRatio : maxBoundingBoxRatio) {
            rejections.append("elongated")
        }
        if !wholeWalkOutAndBack
            && shape < (reaches ? elongatedMinCompactness : minCompactness) {
            rejections.append("shapeless")
        }
        // The doorstep stub is judged in the same band as the mid-route
        // backtrack: fine as the ordinary shared pavement every loop has, fine
        // again once it is long enough to be a real feature in its own right,
        // and rejected only in between.
        if stub > startStubLimit && stub < minBacktrackMetres { rejections.append("start-spur") }
        if !returnsToStart(coordinates, start: start) { rejections.append("open-ended") }
        // A loop whose legs are wildly uneven is a walk out and a scramble
        // back, not a ring — one corner-to-corner stretch carrying half the
        // distance means the other corners are decoration. Both rules are the
        // service's, and both are skipped for a walk that is honestly an
        // out-and-back, which is a shape a walker may legitimately want.
        if let shares = legShares, !wholeWalkOutAndBack {
            if shares.count > 2, shares.contains(where: { $0 > maxLegShare }) {
                rejections.append("leg-too-long")
            }
            if shares.count > 2, shares.dropFirst().dropLast().contains(where: { $0 < minLegShare }) {
                rejections.append("leg-too-short")
            }
        }

        let score = scoreRoute(
            legShares: legShares,
            repeats: repeats, distanceErrorFraction: distanceErrorFraction,
            compactness: shape, uTurnCount: uTurnCount, distanceMetres: distanceMetres
        )
        return Report(
            pass: rejections.isEmpty,
            rejections: rejections,
            quality: Score(
                score: score, repeatedMetres: repeats.repeatedMetres.rounded(),
                repeatedPercent: (repeats.repeatedPercent * 10).rounded() / 10,
                uTurnCount: uTurnCount, compactness: (shape * 1000).rounded() / 1000
            ),
            distanceErrorFraction: distanceErrorFraction,
            distanceMetres: distanceMetres,
            targetMetres: targetMetres,
            boundingBoxRatio: boundingBoxRatio,
            startStubMetres: stub,
            longestReverseRunMetres: repeats.longestReverseRunMetres,
            passesEssentials: !rejections.contains { essentialRejections.contains($0) }
        )
    }

    /// A loop that does not end where it began is not a loop. The comparison
    /// is against the route's own first point, which is where the router
    /// actually started after snapping to the network.
    static func returnsToStart(_ coordinates: [Point], start: Point) -> Bool {
        guard coordinates.count >= 2, let first = coordinates.first, let last = coordinates.last else { return false }
        return LocalGeo.distance(lat1: first.lat, lon1: first.lng, lat2: last.lat, lon2: last.lng) <= endpointToleranceMetres
            && LocalGeo.distance(lat1: start.lat, lon1: start.lng, lat2: first.lat, lon2: first.lng) <= 1000
    }

    /// Weighted the way a walker would weigh it: not covering the same ground
    /// twice matters most, then getting the length they asked for, then
    /// whether it feels like a loop, then how fiddly it is to follow.
    ///
    /// Leg balance is one of the service's five terms and is absent here for
    /// the same reason it is absent from the remote engine's own direct path:
    /// a searched walk was never cut into legs, so there is nothing to be
    /// lopsided against. It contributes nothing rather than being re-weighted,
    /// which keeps the two engines' scores on one scale.
    static func scoreRoute(
        legShares: [Double]? = nil,
        repeats: RepeatReport, distanceErrorFraction: Double,
        compactness: Double, uTurnCount: Int, distanceMetres: Double
    ) -> Double {
        func clamp(_ value: Double) -> Double { Swift.min(1, Swift.max(0, value)) }
        let totalMetres = Swift.max(1, distanceMetres)
        let overlap = clamp(1 - (repeats.weightedRepeatedMetres / totalMetres) / maxRepeatedFraction)
        let closeness = clamp(1 - distanceErrorFraction / maxDistanceError)
        let shape = clamp(compactness)
        let simplicity = clamp(1 - Double(uTurnCount) / Double(maxUTurns + 1))
        // The service's fifth term. A walk that was never cut into legs has
        // nothing to be lopsided against, so rather than re-weight the other
        // four for it — which would put the two engines' scores on different
        // scales without saying so — such a walk is given the balance of a
        // perfectly even one. It is then judged on the four things that can
        // actually be measured about it, and scored out of the same hundred.
        let balance: Double
        if let shares = legShares, let widest = shares.max(), let narrowest = shares.min(), shares.count > 1 {
            balance = clamp(1 - (widest - narrowest) / (maxLegShare - minLegShare))
        } else {
            balance = 1
        }
        let raw = 100 * (0.35 * overlap + 0.25 * closeness + 0.20 * shape
            + 0.10 * balance + 0.10 * simplicity)
        return (raw * 10).rounded() / 10
    }

    // MARK: - Pavement

    /// The road classes that are somewhere a walker is meant to be, rather than
    /// a carriageway they are tolerated on. `edges.ts`'s
    /// `PEDESTRIAN_ROAD_CLASSES`.
    public static let pedestrianRoadClasses: Set<PedestrianAccessPolicy.RoadClass> =
        [.footway, .path, .pedestrian, .steps]

    /// How often a walk changes its mind about which side of the road it is on.
    ///
    /// Where OSM maps a pavement as its own way, a pavement and its carriageway
    /// are near enough the same length that a router with no preference between
    /// them takes whichever is a few metres shorter, block by block. The line
    /// then crosses and recrosses the road, which is confusing to look at and
    /// produces a turn prompt every time.
    ///
    /// Counted as *transitions*, not as classes: a walk entirely on pavements
    /// and a walk entirely on roads both score zero, because neither leaves the
    /// walker wondering where they are meant to be. Only alternation costs. Per
    /// kilometre, so a 10 km walk is comparable with a 3 km one.
    ///
    /// A faithful port of `edges.ts`'s `pavementReport`, which the service uses
    /// as telemetry only. It is what `looper_foot.json`'s 0.8 multiplier was
    /// tuned against — Douglas went from 13% of the leg on pavement to 97% —
    /// and the on-device graph has no equivalent of that multiplier, so this is
    /// the number that says whether it needs one.
    public struct PavementReport: Sendable, Equatable {
        public var pavementMetres: Double
        public var measuredMetres: Double
        /// Times the walk changed between pavement and carriageway.
        public var hops: Int

        public var share: Double { measuredMetres > 0 ? pavementMetres / measuredMetres : 0 }
        public var hopsPerKm: Double { measuredMetres > 0 ? Double(hops) * 1000 / measuredMetres : 0 }

        public init(pavementMetres: Double = 0, measuredMetres: Double = 0, hops: Int = 0) {
            self.pavementMetres = pavementMetres
            self.measuredMetres = measuredMetres
            self.hops = hops
        }
    }

    /// Consecutive legs of the same kind are one stretch — the graph splits an
    /// edge at every junction, so a single pavement is many legs and none of
    /// those boundaries is a hop.
    public static func pavement(of legs: [WalkLeg]) -> PavementReport {
        var report = PavementReport()
        var previous: Bool?
        for leg in legs where leg.metres > 0 {
            let isPavement = pedestrianRoadClasses.contains(leg.roadClass)
            report.measuredMetres += leg.metres
            if isPavement { report.pavementMetres += leg.metres }
            if let was = previous, was != isPavement { report.hops += 1 }
            previous = isPavement
        }
        return report
    }
}
