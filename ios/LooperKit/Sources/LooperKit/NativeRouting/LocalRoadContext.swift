import Foundation

/// Relates a routed pedestrian edge to the street around it. An OSM footway's
/// own name is often absent even when the carriageway beside it is named.
/// Instruction generation needs the surrounding graph while it is available,
/// rather than treating each routed edge's tag as a change of street.
enum LocalRoadContext {
    struct Resolved {
        var names: [String?]
        var oppositePavementCrossings: Set<Int>
    }

    private struct RoadMatch {
        var name: String
        var wayID: Int64
        /// Which side of the named carriageway this pavement lies on.
        var side: Int?
    }

    private static let searchMetres = 28.0
    private static let parallelDegrees = 35.0
    private static let streetClasses: Set<PedestrianAccessPolicy.RoadClass> = [
        .living, .residential, .unclassified, .tertiary, .secondary, .primary, .trunk,
    ]

    static func resolve(legs: [WalkLeg], graph: LocalWalkingGraph, index: LocalEdgeIndex) -> Resolved {
        var names = legs.map(\.name)
        var matches = [RoadMatch?](repeating: nil, count: legs.count)
        for position in legs.indices where !legs[position].isCrossing && legs[position].roadClass.isPedestrianWay {
            let match = neighbouringRoad(for: legs[position], graph: graph, index: index)
            if names[position] == nil { names[position] = match?.name }
            if match?.name == names[position] { matches[position] = match }
        }

        // A crossing is a link between pavements, not a road-name boundary.
        // Fill it only when the stretches on either side identify the same
        // corridor. This also prevents a nearby intersecting street from
        // lending its name to the crossing itself.
        var oppositePavementCrossings: Set<Int> = []
        for position in legs.indices where legs[position].isCrossing {
            let before = legs.indices.prefix(position).reversed().first { !legs[$0].isCrossing }
            let after = legs.indices.dropFirst(position + 1).first { !legs[$0].isCrossing }
            if let before, let after, names[before] != nil, names[before] == names[after] {
                names[position] = names[before]
                if let approach = matches[before], let departure = matches[after],
                   let approachSide = approach.side, let departureSide = departure.side,
                   approach.wayID == departure.wayID,
                   approachSide != departureSide {
                    oppositePavementCrossings.insert(position)
                }
            }
        }
        return Resolved(names: names, oppositePavementCrossings: oppositePavementCrossings)
    }

    static func names(for legs: [WalkLeg], graph: LocalWalkingGraph, index: LocalEdgeIndex) -> [String?] {
        resolve(legs: legs, graph: graph, index: index).names
    }

    /// Whether the walker could actually leave the chosen route at this graph
    /// node. A bend at a degree-two node is a bend in the only path, even when
    /// the adjacent OSM ways happen to have different tags or bearings.
    static func hasAlternative(at boundary: (WalkLeg, WalkLeg), graph: LocalWalkingGraph) -> Bool? {
        let first = Int(boundary.0.physical), second = Int(boundary.1.physical)
        guard graph.edgeFrom.indices.contains(first), graph.edgeFrom.indices.contains(second),
              first != second else { return nil }
        let firstEnds = [graph.edgeFrom[first], graph.edgeTo[first]]
        let secondEnds = [graph.edgeFrom[second], graph.edgeTo[second]]
        guard let junction = firstEnds.first(where: { secondEnds.contains($0) }) else { return nil }
        for arc in Int(graph.arcStart[Int(junction)])..<Int(graph.arcStart[Int(junction) + 1]) {
            let edge = Int(graph.arcEdge[arc])
            if edge != first && edge != second { return true }
        }
        return false
    }

    private static func neighbouringRoad(
        for leg: WalkLeg, graph: LocalWalkingGraph, index: LocalEdgeIndex
    ) -> RoadMatch? {
        guard let first = leg.coordinates.first, let last = leg.coordinates.last,
              leg.coordinates.count >= 2 else { return nil }
        let direction = LocalGeo.bearing(lat1: first.lat, lon1: first.lng, lat2: last.lat, lon2: last.lng)
        let samplePositions = leg.metres > 25 ? [0.25, 0.75] : [0.5]
        var samples: [(name: String, wayID: Int64, side: Int?, score: Double)] = []
        for fraction in samplePositions {
            let point = point(on: leg.coordinates, fraction: fraction)
            let bounds = LocalGeo.boundsAround(lat: point.lat, lon: point.lng, metres: searchMetres)
            var best: (name: String, wayID: Int64, side: Int?, score: Double)?
            for rawEdge in index.edges(minLat: bounds.south, maxLat: bounds.north,
                                       minLon: bounds.west, maxLon: bounds.east) {
                let edge = Int(rawEdge)
                guard edge != Int(leg.physical),
                      streetClasses.contains(graph.roadClass(ofEdge: edge)),
                      let name = graph.name(ofEdge: edge),
                      let snap = index.project(lat: point.lat, lon: point.lng, onto: edge, graph: graph),
                      snap.distanceMetres <= searchMetres else { continue }
                let coordinates = graph.coordinates(ofEdge: edge, forward: true)
                guard snap.segment + 1 < coordinates.count else { continue }
                let a = coordinates[snap.segment], b = coordinates[snap.segment + 1]
                let roadDirection = LocalGeo.bearing(lat1: a.lat, lon1: a.lng, lat2: b.lat, lon2: b.lng)
                let difference = abs(roadDirection - direction)
                let parallel = Swift.min(Swift.min(difference, 360 - difference), abs(180 - difference))
                guard parallel <= parallelDegrees else { continue }
                let score = snap.distanceMetres + parallel * 0.4
                let frame = MetricFrame(originLon: snap.lon, originLat: snap.lat)
                let roadStart = frame.project(lon: a.lng, lat: a.lat)
                let roadEnd = frame.project(lon: b.lng, lat: b.lat)
                let pavement = frame.project(lon: point.lng, lat: point.lat)
                let cross = (roadEnd.x - roadStart.x) * pavement.y
                    - (roadEnd.y - roadStart.y) * pavement.x
                let side = snap.distanceMetres >= 4 ? (cross >= 0 ? 1 : -1) : nil
                if best == nil || score < best!.score {
                    best = (name, graph.edgeWayID[edge], side, score)
                }
            }
            if let best { samples.append(best) }
        }
        guard samples.count == samplePositions.count,
              let first = samples.first,
              samples.allSatisfy({ $0.name == first.name }) else { return nil }
        let side = first.side.flatMap { value in
            samples.allSatisfy { $0.side == value && $0.wayID == first.wayID } ? value : nil
        }
        return RoadMatch(name: first.name, wayID: first.wayID, side: side)
    }

    private static func point(on line: [Point], fraction: Double) -> Point {
        let lengths = zip(line, line.dropFirst()).map { haversine($0, $1) }
        var remaining = lengths.reduce(0, +) * fraction
        for index in lengths.indices {
            let length = lengths[index]
            if remaining <= length || index == lengths.count - 1 {
                let share = length > 0 ? min(1, remaining / length) : 0
                return Point(
                    line[index].lng + (line[index + 1].lng - line[index].lng) * share,
                    line[index].lat + (line[index + 1].lat - line[index].lat) * share
                )
            }
            remaining -= length
        }
        return line.last!
    }
}
