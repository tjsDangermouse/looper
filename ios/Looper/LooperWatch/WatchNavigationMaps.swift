import CryptoKit
import Foundation
import LooperKit
import MapKit
import SwiftUI
import WatchKit

/// Maps a coordinate onto the pixels of a saved snapshot.
///
/// An `MKMapSnapshotter.Snapshot` can answer "where is this coordinate" but
/// can't be saved. A flat, north-up-then-rotated camera makes the answer an
/// affine map over a snapshot a few hundred metres wide, so three sampled
/// points are enough to rebuild it from disk with no map data at all.
struct SnapshotProjection: Codable, Equatable {
    var origin: Point
    var a: Double, b: Double, c: Double, d: Double
    var tx: Double, ty: Double

    private static let metersPerDegree = 111_320.0
    private static let sampleMeters = 100.0

    init(origin: Point, a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.origin = origin
        self.a = a; self.b = b; self.c = c; self.d = d
        self.tx = tx; self.ty = ty
    }

    /// Fits the map from a live snapshot by sampling its own projection.
    init(snapshot: MKMapSnapshotter.Snapshot, origin: Point) {
        let east = Self.offset(origin, east: Self.sampleMeters, north: 0)
        let north = Self.offset(origin, east: 0, north: Self.sampleMeters)
        let po = snapshot.point(for: origin.coordinate)
        let pe = snapshot.point(for: east.coordinate)
        let pn = snapshot.point(for: north.coordinate)
        self.init(
            origin: origin,
            a: (pe.x - po.x) / Self.sampleMeters, b: (pe.y - po.y) / Self.sampleMeters,
            c: (pn.x - po.x) / Self.sampleMeters, d: (pn.y - po.y) / Self.sampleMeters,
            tx: po.x, ty: po.y
        )
    }

    private static func offset(_ point: Point, east: Double, north: Double) -> Point {
        let lngScale = metersPerDegree * cos(point.lat * Double.pi / 180)
        return Point(point.lng + east / lngScale, point.lat + north / metersPerDegree)
    }

    func point(for coordinate: Point) -> CGPoint {
        let x = (coordinate.lng - origin.lng) * Self.metersPerDegree * cos(origin.lat * Double.pi / 180)
        let y = (coordinate.lat - origin.lat) * Self.metersPerDegree
        return CGPoint(x: a * x + c * y + tx, y: b * x + d * y + ty)
    }
}

struct WatchNavigationScene {
    let image: UIImage
    let projection: SnapshotProjection
    let route: [Point]
    let turn: Point

    /// Whether a position falls on the picture with room to be seen. A walker
    /// far from the turn is off the edge of it; the vector view takes over.
    func contains(_ position: Point, margin: CGFloat = 18) -> Bool {
        let point = projection.point(for: position)
        return CGRect(origin: .zero, size: image.size).insetBy(dx: margin, dy: margin).contains(point)
    }
}

/// The saved half of a scene.
private struct StoredScene: Codable {
    var projection: SnapshotProjection
    var route: [Point]
    var turn: Point
    var scale: Double
}

/// Turn maps on disk, per route. A snapshot is a few hundred kilobytes and is
/// cheap to keep; fetching it needs the Watch's connection, which a walk
/// shouldn't depend on. A route's maps outlive the walk, so walking a saved
/// route again costs nothing.
struct WatchMapStore {
    private let root: URL

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent("Looper/maps", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func directory(_ routeID: String) -> URL {
        let digest = SHA256.hash(data: Data(routeID.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    func save(_ scene: WatchNavigationScene, routeID: String, step: Int, scale: CGFloat) {
        let folder = directory(routeID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let image = scene.image.jpegData(compressionQuality: 0.82),
              let meta = try? JSONEncoder().encode(StoredScene(
                  projection: scene.projection, route: scene.route, turn: scene.turn, scale: Double(scale)
              )) else { return }
        // The picture last: a scene is only complete when its image exists.
        try? meta.write(to: folder.appendingPathComponent("\(step).json"), options: .atomic)
        try? image.write(to: folder.appendingPathComponent("\(step).jpg"), options: .atomic)
    }

    func load(routeID: String, step: Int) -> WatchNavigationScene? {
        let folder = directory(routeID)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(step).jpg")),
              let metaData = try? Data(contentsOf: folder.appendingPathComponent("\(step).json")),
              let meta = try? JSONDecoder().decode(StoredScene.self, from: metaData),
              let image = UIImage(data: data, scale: CGFloat(meta.scale)) else { return nil }
        return WatchNavigationScene(image: image, projection: meta.projection, route: meta.route, turn: meta.turn)
    }

    func has(routeID: String, step: Int) -> Bool {
        FileManager.default.fileExists(atPath: directory(routeID).appendingPathComponent("\(step).jpg").path)
    }

    /// Drops every route's maps except those still wanted.
    func prune(keeping routeIDs: Set<String>) {
        let keep = Set(routeIDs.map { directory($0).lastPathComponent })
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// The small map around every turn of the route being walked, kept on disk.
///
/// Unlike an interactive map these stay usable with no connection at all, and
/// because the picture shown depends only on the route and the next turn, the
/// screen looks the same whether or not the Watch has a signal.
@MainActor
final class WatchNavigationMapCache: ObservableObject {
    @Published private(set) var scenes: [Int: WatchNavigationScene] = [:]
    @Published private(set) var isPreparing = false
    /// Routes whose every turn map is on the Watch, for the saved-routes list.
    @Published private(set) var readyRouteIDs: Set<String> = []
    var onDiagnostic: ((String, [String: String]) -> Void)?

    private let store = WatchMapStore()
    private var routeID: String?
    private var task: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private static let retryDelays: [UInt64] = [2, 6, 15]

    func prepare(_ plan: LoopPlanPayload) {
        if routeID != plan.routeID {
            task?.cancel()
            routeID = plan.routeID
            scenes = [:]
            isPreparing = false
        }
        let geometry = plan.plannedGeometry ?? []
        let maneuvers = plan.plannedManeuvers ?? []
        guard !geometry.isEmpty, !maneuvers.isEmpty else { return }

        for maneuver in maneuvers where scenes[maneuver.stepIndex] == nil {
            if let scene = store.load(routeID: plan.routeID, step: maneuver.stepIndex) {
                scenes[maneuver.stepIndex] = scene
            }
        }
        let missing = maneuvers.filter { scenes[$0.stepIndex] == nil && $0.coordinate != nil }
        refreshReadiness(plan)
        guard !missing.isEmpty, !isPreparing else { return }

        isPreparing = true
        onDiagnostic?("mapPreloadStarted", ["maps": String(missing.count), "stored": String(scenes.count)])
        let planID = plan.routeID
        task = Task { [weak self] in
            // Route order is intentional: the first map needed is downloaded
            // first, while later turns continue filling in behind it.
            for maneuver in missing {
                guard !Task.isCancelled, let turn = maneuver.coordinate else { break }
                guard let scene = await Self.fetch(turn: turn, geometry: geometry, onFailure: { attempt, error in
                    self?.onDiagnostic?("mapSnapshotFailed", [
                        "kind": "preload", "step": String(maneuver.stepIndex),
                        "attempt": String(attempt), "error": error.localizedDescription
                    ])
                }) else { continue }
                guard !Task.isCancelled, self?.routeID == planID else { break }
                self?.store.save(scene, routeID: planID, step: maneuver.stepIndex, scale: scene.image.scale)
                self?.scenes[maneuver.stepIndex] = scene
            }
            guard self?.routeID == planID else { return }
            self?.onDiagnostic?("mapPreloadFinished", ["maps": String(self?.scenes.count ?? 0)])
            self?.isPreparing = false
            self?.task = nil
            self?.refreshReadiness(plan)
        }
    }

    /// Fetches the maps for routes that aren't being walked, a route at a time
    /// while the Watch is idle. Done while there is a connection, so a saved
    /// route is ready before the phone is left behind.
    func prefetch(_ plans: [LoopPlanPayload]) {
        prefetchTask?.cancel()
        store.prune(keeping: Set(plans.map(\.routeID)).union(routeID.map { [$0] } ?? []))
        for plan in plans { refreshReadiness(plan) }
        let pending = plans.filter { !readyRouteIDs.contains($0.routeID) && $0.routeID != routeID }
        guard !pending.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            for plan in pending {
                guard let geometry = plan.plannedGeometry else { continue }
                for maneuver in plan.plannedManeuvers ?? [] {
                    guard !Task.isCancelled, let turn = maneuver.coordinate else { break }
                    while self?.isPreparing == true { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                    guard let self, !self.store.has(routeID: plan.routeID, step: maneuver.stepIndex) else { continue }
                    guard let scene = await Self.fetch(turn: turn, geometry: geometry, onFailure: { attempt, error in
                        self.onDiagnostic?("mapSnapshotFailed", [
                            "kind": "prefetch", "step": String(maneuver.stepIndex),
                            "attempt": String(attempt), "error": error.localizedDescription
                        ])
                    }) else { continue }
                    self.store.save(scene, routeID: plan.routeID, step: maneuver.stepIndex, scale: scene.image.scale)
                }
                self?.refreshReadiness(plan)
            }
            self?.prefetchTask = nil
        }
    }

    /// A walk has the Watch's full attention; background downloads wait.
    func pausePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func release() {
        task?.cancel()
        task = nil
        routeID = nil
        scenes = [:]
        isPreparing = false
    }

    private func refreshReadiness(_ plan: LoopPlanPayload) {
        let steps = (plan.plannedManeuvers ?? []).filter { $0.coordinate != nil }.map(\.stepIndex)
        let ready = !steps.isEmpty && steps.allSatisfy { store.has(routeID: plan.routeID, step: $0) }
        if ready { readyRouteIDs.insert(plan.routeID) } else { readyRouteIDs.remove(plan.routeID) }
    }

    func isReady(_ plan: LoopPlanPayload) -> Bool { readyRouteIDs.contains(plan.routeID) }

    /// One map, retried a few times: a Watch moving between its phone's
    /// connection and Wi-Fi fails a request now and then.
    private static func fetch(
        turn: Point,
        geometry: [Point],
        onFailure: @escaping (Int, Error) -> Void
    ) async -> WatchNavigationScene? {
        let route = routeWindow(around: turn, in: geometry)
        for (attempt, delay) in ([0] + retryDelays).enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            if Task.isCancelled { return nil }
            do {
                // The turn marker has to sit comfortably below the Watch's
                // curved top edge, so the camera is centred short of it.
                let approach = pointBeforeTurn(70, turn: turn, route: route)
                let snapshot = try await snapshot(
                    center: approach, distance: 600, heading: bearing(from: approach, to: turn)
                )
                return WatchNavigationScene(
                    image: snapshot.image,
                    projection: SnapshotProjection(snapshot: snapshot, origin: approach),
                    route: route,
                    turn: turn
                )
            } catch {
                onFailure(attempt + 1, error)
            }
        }
        return nil
    }

    private static func snapshot(
        center: Point,
        distance: CLLocationDistance,
        heading: CLLocationDirection
    ) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.camera = MKMapCamera(
            lookingAtCenter: center.coordinate,
            fromDistance: distance,
            pitch: 0,
            heading: heading
        )
        options.size = WKInterfaceDevice.current().screenBounds.size
        options.scale = WKInterfaceDevice.current().screenScale

        return try await withCheckedThrowingContinuation { continuation in
            MKMapSnapshotter(options: options).start { snapshot, error in
                if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    /// About 260 m of approach and 100 m beyond the corner gives junction
    /// context without turning this into a whole-route overview.
    static func routeWindow(around turn: Point, in geometry: [Point]) -> [Point] {
        guard geometry.count > 1 else { return geometry }
        let pivot = geometry.indices.min {
            haversine(geometry[$0], turn) < haversine(geometry[$1], turn)
        } ?? 0
        var first = pivot
        var distance = 0.0
        while first > 0, distance < 260 {
            distance += haversine(geometry[first], geometry[first - 1])
            first -= 1
        }
        var last = pivot
        distance = 0
        while last < geometry.count - 1, distance < 100 {
            distance += haversine(geometry[last], geometry[last + 1])
            last += 1
        }
        return Array(geometry[first...last])
    }

    /// The route still ahead of the live fix, through the next junction and
    /// briefly beyond it. A closed loop can legitimately wrap past the end
    /// of its geometry, so that case joins the tail and head without ever
    /// switching to a whole-route overview.
    static func routeWindow(from position: Point, through turn: Point, in geometry: [Point]) -> [Point] {
        guard geometry.count > 1 else { return [position, turn] }
        let start = geometry.indices.min {
            haversine(geometry[$0], position) < haversine(geometry[$1], position)
        } ?? 0
        let pivot = geometry.indices.min {
            haversine(geometry[$0], turn) < haversine(geometry[$1], turn)
        } ?? start

        var result: [Point]
        if start <= pivot {
            result = Array(geometry[start...pivot])
        } else {
            result = Array(geometry[start...]) + Array(geometry[...pivot])
        }

        var distance = 0.0
        var index = pivot
        while distance < 100, index < geometry.count - 1 {
            distance += haversine(geometry[index], geometry[index + 1])
            index += 1
            result.append(geometry[index])
        }
        // The live fix normally lies between two geometry vertices. Keep the
        // exact point at the head of the window so both the route line and
        // the vector fallback move continuously rather than waiting for the
        // nearest vertex to change.
        if result.first.map({ haversine($0, position) > 0.5 }) ?? true {
            result.insert(position, at: 0)
        } else {
            result[0] = position
        }
        return result.count > 1 ? result : [position, turn]
    }

    static func pointBeforeTurn(_ metres: Double, turn: Point, route: [Point]) -> Point {
        guard route.count > 1 else { return turn }
        let pivot = route.indices.min {
            haversine(route[$0], turn) < haversine(route[$1], turn)
        } ?? route.count - 1
        var remaining = metres
        var index = pivot
        while index > 0 {
            let segment = haversine(route[index - 1], route[index])
            if segment >= remaining, segment > 0 {
                let fraction = remaining / segment
                return Point(
                    route[index].lng + (route[index - 1].lng - route[index].lng) * fraction,
                    route[index].lat + (route[index - 1].lat - route[index].lat) * fraction
                )
            }
            remaining -= segment
            index -= 1
        }
        return route[0]
    }

    static func bearing(from: Point, to: Point) -> CLLocationDirection {
        let radians = Double.pi / 180
        let lat1 = from.lat * radians, lat2 = to.lat * radians
        let delta = (to.lng - from.lng) * radians
        let y = sin(delta) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(delta)
        return (atan2(y, x) / radians + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension Point {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
