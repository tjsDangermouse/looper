import Foundation

/// Choosing what to offer.
///
/// A port of the route service's `diversity.ts`. Three loops that all leave by
/// the same street and differ by a block are one choice wearing three hats. A
/// candidate is dropped if it walks more than `maxSharedFraction` of the same
/// ground as one already chosen, and the picker looks for a different way out
/// of the door before it settles for a second loop heading the same way.
public enum RouteDiversity {
    /// In a town with a natural bottleneck — a harbour, a single bridge, a
    /// headland — every clean loop leaves and returns the same way, whatever
    /// direction it heads in between. Cutting at a third of shared ground threw
    /// those away and regularly left a walker with one loop where three
    /// genuinely different ones existed but for a shared street at each end.
    public static let maxSharedFraction = RouteQuality.maxSharedFraction
    /// How far into the walk "which way does this go" is decided.
    public static let initialBearingMetres: Double = 500
    public static let initialBearingFraction = 0.2

    public static let compassLabels = [
        "North loop", "North-east loop", "East loop", "South-east loop",
        "South loop", "South-west loop", "West loop", "North-west loop",
    ]

    /// The bearing the walk sets off on, taken a few hundred metres in rather
    /// than at the first vertex: the first thirty metres of any walk is
    /// whichever way the pavement happens to run.
    public static func initialBearing(_ coordinates: [Point], from start: Point) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<coordinates.count {
            total += LocalGeo.distance(
                lat1: coordinates[i - 1].lat, lon1: coordinates[i - 1].lng,
                lat2: coordinates[i].lat, lon2: coordinates[i].lng
            )
        }
        let target = Swift.min(initialBearingMetres, total * initialBearingFraction)
        var travelled = 0.0
        for i in 1..<coordinates.count {
            travelled += LocalGeo.distance(
                lat1: coordinates[i - 1].lat, lon1: coordinates[i - 1].lng,
                lat2: coordinates[i].lat, lon2: coordinates[i].lng
            )
            if travelled >= target {
                return LocalGeo.bearing(lat1: start.lat, lon1: start.lng, lat2: coordinates[i].lat, lon2: coordinates[i].lng)
            }
        }
        let last = coordinates[coordinates.count - 1]
        return LocalGeo.bearing(lat1: start.lat, lon1: start.lng, lat2: last.lat, lon2: last.lng)
    }

    public static func bearingLabel(_ bearing: Double) -> String {
        compassLabels[LocalGeo.bearingOctant(bearing)]
    }

    /// Something the picker can judge without knowing what it is.
    public struct Candidate {
        public var coordinates: [Point]
        public var score: Double
        public var bearing: Double
        /// The physical edges this walk spent, and how many metres of each.
        /// Where both walks in a comparison have them, "the same ground" stops
        /// being a question about proximity and becomes one about the network.
        public var edges: [Int32: Double]
        public var totalMetres: Double

        public init(coordinates: [Point], score: Double, bearing: Double, edges: [Int32: Double], totalMetres: Double) {
            self.coordinates = coordinates
            self.score = score
            self.bearing = bearing
            self.edges = edges
            self.totalMetres = totalMetres
        }
    }

    /// How much of `a` runs along `b`, on the network where both know their
    /// edges and by geometric proximity where either does not.
    ///
    /// The searched walks always know their edges, which makes this exact
    /// rather than a proximity estimate — one of the quiet advantages of an
    /// engine that returns the edges it walked instead of a line.
    public static func sharedFraction(_ a: Candidate, _ b: Candidate) -> Double {
        if !a.edges.isEmpty && !b.edges.isEmpty && a.totalMetres > 0 {
            // Metres, not edges: counting edges would let a hundred metres of
            // shared main road weigh the same as five metres of shared alley.
            var shared = 0.0
            for (edge, metres) in a.edges where b.edges[edge] != nil { shared += metres }
            return shared / a.totalMetres
        }
        return RouteQuality.sharedCorridorMetres(a.coordinates, b.coordinates).fraction
    }

    /// The worse of the two directions: "are these the same walk" has no
    /// favourite.
    public static func mutualSharedFraction(_ a: Candidate, _ b: Candidate) -> Double {
        Swift.max(sharedFraction(a, b), sharedFraction(b, a))
    }

    /// What the picker took, and what the ground it had to work with cost it.
    ///
    /// The counts exist because "fewer routes than the remote engine" has two
    /// very different causes that look identical from outside: a gate that
    /// refused everything, and a gate that passed plenty of walks which were
    /// all the same walk. Only the second shows up here.
    public struct Selection: Sendable, Equatable {
        public var chosen: [Int]
        /// Gate-passing candidates left out because they shared more than
        /// `maxShared` of their ground with one that was taken. This is the
        /// number that says diversity, not quality, is the constraint.
        public var rejectedShared: Int
        /// Left out only because the limit was already full. Not a loss.
        public var noRoom: Int

        public init(chosen: [Int], rejectedShared: Int, noRoom: Int) {
            self.chosen = chosen
            self.rejectedShared = rejectedShared
            self.noRoom = noRoom
        }
    }

    /// Best first, then the best that is a different walk from the ones
    /// already taken. Two passes: the first insists on a different way out of
    /// the door, the second accepts a same-bearing loop that is nonetheless
    /// different ground, because two good loops beat one good loop and a rule.
    public static func select(_ candidates: [Candidate], limit: Int = 3, maxShared: Double = maxSharedFraction) -> [Int] {
        selecting(candidates, limit: limit, maxShared: maxShared).chosen
    }

    /// `select`, with the reasons. The choosing is identical — this is the
    /// implementation and `select` is the view of it that only wants the walks.
    /// - Parameter alreadyTaken: walks that count against these for diversity
    ///   without being among them. Used to fill the remaining places of an
    ///   answer from a second, less-preferred pool — a walker who has seen
    ///   most of what a small town has should still be handed three walks,
    ///   and the ones they have not seen should come first.
    public static func selecting(
        _ candidates: [Candidate], limit: Int = 3, maxShared: Double = maxSharedFraction,
        alreadyTaken: [Candidate] = []
    ) -> Selection {
        let ranked = candidates.indices.sorted { candidates[$0].score > candidates[$1].score }
        var chosen: [Int] = []
        var taken = alreadyTaken
        var octants = Set(alreadyTaken.map { LocalGeo.bearingOctant($0.bearing) })
        for requireNewOctant in [true, false] {
            for index in ranked {
                if chosen.count >= limit { break }
                if chosen.contains(index) { continue }
                let octant = LocalGeo.bearingOctant(candidates[index].bearing)
                if requireNewOctant && octants.contains(octant) { continue }
                let tooSimilar = taken.contains { mutualSharedFraction(candidates[index], $0) > maxShared }
                if tooSimilar { continue }
                chosen.append(index)
                taken.append(candidates[index])
                octants.insert(octant)
            }
            if chosen.count >= limit { break }
        }

        // Counted against the final set rather than tallied during the passes:
        // a walk the first pass skipped on octant is usually taken by the
        // second, so a running tally would report losses that never happened.
        var rejectedShared = 0
        for index in candidates.indices where !chosen.contains(index) {
            if taken.contains(where: { mutualSharedFraction(candidates[index], $0) > maxShared }) {
                rejectedShared += 1
            }
        }
        return Selection(
            chosen: chosen,
            rejectedShared: rejectedShared,
            noRoom: candidates.count - chosen.count - rejectedShared
        )
    }

    /// Two loops that both head north-east would otherwise arrive with the
    /// same name. Length is the thing the walker is choosing between, so that
    /// is what separates them.
    public static func labels(for routes: [(bearing: Double, distanceMetres: Double)]) -> [String] {
        let base = routes.map { bearingLabel($0.bearing) }
        return base.enumerated().map { index, label in
            var sameWay = base.indices.filter { base[$0] == label }
            guard sameWay.count >= 2 else { return label }
            sameWay.sort { routes[$0].distanceMetres < routes[$1].distanceMetres }
            guard let rank = sameWay.firstIndex(of: index) else { return label }
            if rank == 0 { return "Shorter \(label.lowercased())" }
            if rank == sameWay.count - 1 { return "Longer \(label.lowercased())" }
            return label
        }
    }
}
