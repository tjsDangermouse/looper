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
        self.init(origin: origin) { snapshot.point(for: $0.coordinate) }
    }

    /// Fits the map from any function that places a coordinate on the picture.
    init(origin: Point, pointFor: (Point) -> CGPoint) {
        let east = Self.offset(origin, east: Self.sampleMeters, north: 0)
        let north = Self.offset(origin, east: 0, north: Self.sampleMeters)
        let po = pointFor(origin)
        let pe = pointFor(east)
        let pn = pointFor(north)
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

/// Maps on disk, per route. A snapshot is a few hundred kilobytes and is cheap
/// to keep; fetching it needs the Watch's connection, which a walk shouldn't
/// depend on. A route's maps outlive the walk, so walking a saved route again
/// costs nothing. Each map is filed under a key: `t<step>` for the picture of a
/// turn, `a<metres>` for one saved partway along the route.
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

    func save(_ scene: WatchNavigationScene, routeID: String, key: String) {
        let folder = directory(routeID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let image = scene.image.jpegData(compressionQuality: 0.72),
              let meta = try? JSONEncoder().encode(StoredScene(
                  projection: scene.projection, route: scene.route, turn: scene.turn, scale: Double(scene.image.scale)
              )) else { return }
        // The picture last: a scene is only complete when its image exists.
        try? meta.write(to: folder.appendingPathComponent("\(key).json"), options: .atomic)
        try? image.write(to: folder.appendingPathComponent("\(key).jpg"), options: .atomic)
    }

    func load(routeID: String, key: String) -> WatchNavigationScene? {
        let folder = directory(routeID)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(key).jpg")),
              let metaData = try? Data(contentsOf: folder.appendingPathComponent("\(key).json")),
              let meta = try? JSONDecoder().decode(StoredScene.self, from: metaData),
              let image = UIImage(data: data, scale: CGFloat(meta.scale)) else { return nil }
        return WatchNavigationScene(image: image, projection: meta.projection, route: meta.route, turn: meta.turn)
    }

    func has(routeID: String, key: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(routeID).appendingPathComponent("\(key).jpg").path)
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

/// The maps behind the guidance screen.
///
/// While the Watch has a connection it asks for a fresh map as the walker
/// moves, so the map follows them. Without one it falls back to maps saved
/// beforehand: one for each turn and one every 100 m along the route, each the
/// picture the live map would have asked for from that spot. They sit on disk,
/// so a relaunch or a lost signal costs nothing, and the screen looks the same
/// either way.
@MainActor
final class WatchNavigationMapCache: ObservableObject {
    /// The picture of each turn, by step.
    @Published private(set) var scenes: [Int: WatchNavigationScene] = [:]
    @Published private(set) var liveScene: WatchNavigationScene?
    @Published private(set) var liveStepIndex: Int?
    @Published private(set) var isPreparing = false
    /// Routes with every turn's map on the Watch, for the saved-routes list.
    @Published private(set) var turnMapsReadyRouteIDs: Set<String> = []
    /// Routes with every turn's map and the full run along the route saved.
    @Published private(set) var fullyReadyRouteIDs: Set<String> = []
    var onDiagnostic: ((String, [String: String]) -> Void)?

    private let store = WatchMapStore()
    private var plan: LoopPlanPayload?
    private var anchors: [MapAnchor] = []
    private var anchorScenes: [String: WatchNavigationScene] = [:]
    private var task: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveAnchor: Point?
    private var requestedLiveStepIndex: Int?
    private var lastLiveAttempt = Date.distantPast
    private static let retryDelays: [UInt64] = [2, 6, 15]
    /// A failed live request is tried again no sooner than this.
    private static let liveRetrySeconds: TimeInterval = 10

    private var routeID: String? { plan?.routeID }

    func prepare(_ plan: LoopPlanPayload) {
        if routeID != plan.routeID {
            task?.cancel()
            liveTask?.cancel()
            self.plan = plan
            scenes = [:]
            anchorScenes = [:]
            liveScene = nil
            liveStepIndex = nil
            liveAnchor = nil
            requestedLiveStepIndex = nil
            isPreparing = false
        }
        self.plan = plan
        let geometry = plan.plannedGeometry ?? []
        let maneuvers = plan.plannedManeuvers ?? []
        guard !geometry.isEmpty, !maneuvers.isEmpty else { return }
        anchors = mapAnchors(geometry: geometry, maneuvers: maneuvers)

        for maneuver in maneuvers where scenes[maneuver.stepIndex] == nil {
            if let scene = store.load(routeID: plan.routeID, key: "t\(maneuver.stepIndex)") {
                scenes[maneuver.stepIndex] = scene
            }
        }
        refreshReadiness(plan)
        let missingTurns = maneuvers.filter { scenes[$0.stepIndex] == nil && $0.coordinate != nil }
        let missingAnchors = anchors.filter { !store.has(routeID: plan.routeID, key: $0.key) }
        guard !missingTurns.isEmpty || !missingAnchors.isEmpty, !isPreparing else { return }

        isPreparing = true
        onDiagnostic?("mapPreloadStarted", [
            "turnMaps": String(missingTurns.count), "routeMaps": String(missingAnchors.count)
        ])
        let planID = plan.routeID
        task = Task { [weak self] in
            // Route order is intentional: the first map needed is downloaded
            // first, while later ones continue filling in behind it.
            for maneuver in missingTurns {
                guard !Task.isCancelled, let turn = maneuver.coordinate else { break }
                let route = Self.routeWindow(around: turn, in: geometry)
                let approach = Self.pointBeforeTurn(70, turn: turn, route: route)
                guard let scene = await Self.fetch(
                    center: approach, distance: 600, heading: Self.bearing(from: approach, to: turn),
                    route: route, turn: turn,
                    onFailure: { attempt, error in self?.logFailure("turn", maneuver.stepIndex, attempt, error) }
                ) else { continue }
                guard !Task.isCancelled, self?.routeID == planID else { break }
                self?.store.save(scene, routeID: planID, key: "t\(maneuver.stepIndex)")
                self?.scenes[maneuver.stepIndex] = scene
            }
            self?.refreshReadiness(plan)
            for anchor in missingAnchors {
                guard !Task.isCancelled, let turn = anchor.maneuver.coordinate else { break }
                guard let scene = await Self.fetchLiveStyle(
                    position: anchor.position, turn: turn, distanceToTurn: anchor.distanceToTurn,
                    geometry: geometry,
                    onFailure: { attempt, error in self?.logFailure("route", anchor.maneuver.stepIndex, attempt, error) }
                ) else { continue }
                guard !Task.isCancelled, self?.routeID == planID else { break }
                self?.store.save(scene, routeID: planID, key: anchor.key)
            }
            guard self?.routeID == planID else { return }
            self?.onDiagnostic?("mapPreloadFinished", ["turnMaps": String(self?.scenes.count ?? 0)])
            self?.isPreparing = false
            self?.task = nil
            self?.refreshReadiness(plan)
        }
    }

    /// Fetches the turn maps for routes that aren't being walked, a route at a
    /// time while the Watch is idle, so a saved route is partly ready before
    /// the phone is left behind. The full run along a route is saved when it
    /// is chosen.
    func prefetch(_ plans: [LoopPlanPayload]) {
        prefetchTask?.cancel()
        store.prune(keeping: Set(plans.map(\.routeID)).union(routeID.map { [$0] } ?? []))
        for plan in plans { refreshReadiness(plan) }
        let pending = plans.filter { !turnMapsReadyRouteIDs.contains($0.routeID) && $0.routeID != routeID }
        guard !pending.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            for plan in pending {
                guard let geometry = plan.plannedGeometry else { continue }
                for maneuver in plan.plannedManeuvers ?? [] {
                    guard !Task.isCancelled, let turn = maneuver.coordinate else { break }
                    while self?.isPreparing == true { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                    guard let self, !self.store.has(routeID: plan.routeID, key: "t\(maneuver.stepIndex)") else { continue }
                    let route = Self.routeWindow(around: turn, in: geometry)
                    let approach = Self.pointBeforeTurn(70, turn: turn, route: route)
                    guard let scene = await Self.fetch(
                        center: approach, distance: 600, heading: Self.bearing(from: approach, to: turn),
                        route: route, turn: turn,
                        onFailure: { attempt, error in self.logFailure("prefetch", maneuver.stepIndex, attempt, error) }
                    ) else { continue }
                    self.store.save(scene, routeID: plan.routeID, key: "t\(maneuver.stepIndex)")
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
        liveTask?.cancel()
        task = nil
        liveTask = nil
        plan = nil
        anchors = []
        scenes = [:]
        anchorScenes = [:]
        liveScene = nil
        liveStepIndex = nil
        liveAnchor = nil
        requestedLiveStepIndex = nil
        isPreparing = false
    }

    // MARK: Following the walker

    /// watchOS maps are static snapshots. Refresh one after meaningful
    /// movement so the basemap follows the full walk without continuously
    /// downloading and rendering a new image for every one-second fix.
    func prepareLive(position: Point, next: ManeuverPayload, geometry: [Point]) {
        guard let turn = next.coordinate, geometry.count > 1 else { return }
        if requestedLiveStepIndex == next.stepIndex,
           let liveAnchor,
           haversine(liveAnchor, position) < 60 { return }
        guard Date().timeIntervalSince(lastLiveAttempt) >= Self.liveRetrySeconds || requestedLiveStepIndex != next.stepIndex
                || liveAnchor.map({ haversine($0, position) >= 60 }) == true else { return }

        liveTask?.cancel()
        liveAnchor = position
        requestedLiveStepIndex = next.stepIndex
        lastLiveAttempt = Date()
        onDiagnostic?("mapSnapshotRequested", ["kind": "live", "step": String(next.stepIndex)])
        liveTask = Task { [weak self] in
            do {
                let scene = try await Self.liveScene(
                    position: position, turn: turn, distanceToTurn: next.distanceMeters, geometry: geometry
                )
                guard !Task.isCancelled else { return }
                self?.liveScene = scene
                self?.liveStepIndex = next.stepIndex
                self?.liveTask = nil
                self?.onDiagnostic?("mapSnapshotReady", ["kind": "live", "step": String(next.stepIndex)])
            } catch {
                guard !Task.isCancelled else { return }
                self?.liveTask = nil
                // Forgotten, so the next fix tries again rather than waiting
                // for the walker to move another 60 m with no map.
                self?.liveAnchor = nil
                self?.onDiagnostic?("mapSnapshotFailed", [
                    "kind": "live", "step": String(next.stepIndex), "error": error.localizedDescription
                ])
            }
        }
    }

    /// The map to draw for where the walker is: the live one if it is current,
    /// else the saved one nearest them along the route, else the picture of the
    /// turn. Nil — the plain route line — when none of them covers the walker.
    func scene(position: Point?, next: ManeuverPayload) -> WatchNavigationScene? {
        func covers(_ scene: WatchNavigationScene) -> Bool {
            position.map { scene.contains($0) } ?? true
        }
        if liveStepIndex == next.stepIndex, let live = liveScene, covers(live) { return live }
        if let position, let saved = savedScene(near: position, step: next.stepIndex), covers(saved) { return saved }
        if let turnScene = scenes[next.stepIndex], covers(turnScene) { return turnScene }
        return nil
    }

    private func savedScene(near position: Point, step: Int) -> WatchNavigationScene? {
        guard let routeID else { return nil }
        let candidates = anchors.filter { $0.maneuver.stepIndex == step }
        guard let nearest = candidates.min(by: {
            haversine($0.position, position) < haversine($1.position, position)
        }), haversine(nearest.position, position) < 150 else { return nil }
        if let cached = anchorScenes[nearest.key] { return cached }
        guard let scene = store.load(routeID: routeID, key: nearest.key) else { return nil }
        if anchorScenes.count >= 8 { anchorScenes.removeAll(keepingCapacity: true) }
        anchorScenes[nearest.key] = scene
        return scene
    }

    // MARK: Readiness

    private func refreshReadiness(_ plan: LoopPlanPayload) {
        let steps = (plan.plannedManeuvers ?? []).filter { $0.coordinate != nil }.map(\.stepIndex)
        let turnsReady = !steps.isEmpty && steps.allSatisfy { store.has(routeID: plan.routeID, key: "t\($0)") }
        let routeAnchors = mapAnchors(geometry: plan.plannedGeometry ?? [], maneuvers: plan.plannedManeuvers ?? [])
        let routeReady = turnsReady && routeAnchors.allSatisfy { store.has(routeID: plan.routeID, key: $0.key) }
        if turnsReady { turnMapsReadyRouteIDs.insert(plan.routeID) } else { turnMapsReadyRouteIDs.remove(plan.routeID) }
        if routeReady { fullyReadyRouteIDs.insert(plan.routeID) } else { fullyReadyRouteIDs.remove(plan.routeID) }
    }

    /// Every map for this route is on the Watch, so it can be walked with no
    /// connection and still look the same.
    func isReady(_ plan: LoopPlanPayload) -> Bool { fullyReadyRouteIDs.contains(plan.routeID) }
    func hasTurnMaps(_ plan: LoopPlanPayload) -> Bool { turnMapsReadyRouteIDs.contains(plan.routeID) }

    private func logFailure(_ kind: String, _ step: Int, _ attempt: Int, _ error: Error) {
        onDiagnostic?("mapSnapshotFailed", [
            "kind": kind, "step": String(step), "attempt": String(attempt), "error": error.localizedDescription
        ])
    }

    // MARK: Fetching

    /// One map, retried a few times: a Watch moving between its phone's
    /// connection and Wi-Fi fails a request now and then.
    private static func fetch(
        center: Point,
        distance: CLLocationDistance,
        heading: CLLocationDirection,
        route: [Point],
        turn: Point,
        onFailure: @escaping (Int, Error) -> Void
    ) async -> WatchNavigationScene? {
        for (attempt, delay) in ([0] + retryDelays).enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            if Task.isCancelled { return nil }
            do {
                return try await makeScene(center: center, distance: distance, heading: heading, route: route, turn: turn)
            } catch {
                onFailure(attempt + 1, error)
            }
        }
        return nil
    }

    private static func fetchLiveStyle(
        position: Point,
        turn: Point,
        distanceToTurn: Double,
        geometry: [Point],
        onFailure: @escaping (Int, Error) -> Void
    ) async -> WatchNavigationScene? {
        for (attempt, delay) in ([0] + retryDelays).enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            if Task.isCancelled { return nil }
            do {
                return try await liveScene(position: position, turn: turn, distanceToTurn: distanceToTurn, geometry: geometry, preloading: true)
            } catch {
                onFailure(attempt + 1, error)
            }
        }
        return nil
    }

    /// The picture for a walker at `position` heading for `turn`. The junction
    /// sits in the upper-middle of the image, not against the rounded top edge
    /// of the physical display, and a fraction behaves consistently as the
    /// walker approaches.
    private static func liveScene(
        position: Point,
        turn: Point,
        distanceToTurn: Double,
        geometry: [Point],
        preloading: Bool = false
    ) async throws -> WatchNavigationScene {
        #if DEBUG
        // Simulates a Watch with no connection once its maps are saved.
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_OFFLINE"] == "1", !preloading {
            throw URLError(.notConnectedToInternet)
        }
        #endif
        let route = routeWindow(from: position, through: turn, in: geometry)
        let direct = haversine(position, turn)
        let lead = direct > 0 ? 0.6 : 0
        let center = Point(
            position.lng + (turn.lng - position.lng) * lead,
            position.lat + (turn.lat - position.lat) * lead
        )
        return try await makeScene(
            center: center,
            distance: min(1_000, max(180, distanceToTurn * 2.4)),
            heading: bearing(from: position, to: turn),
            route: route,
            turn: turn
        )
    }

    private static func makeScene(
        center: Point,
        distance: CLLocationDistance,
        heading: CLLocationDirection,
        route: [Point],
        turn: Point
    ) async throws -> WatchNavigationScene {
        #if DEBUG
        // Simulator-only stand-in for Apple's tiles, to exercise saving and
        // choosing maps when the tile service isn't answering.
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_FAKE_MAPS"] == "1" {
            return fakeScene(center: center, distance: distance, heading: heading, route: route, turn: turn)
        }
        #endif
        let snapshot = try await snapshot(center: center, distance: distance, heading: heading)
        return WatchNavigationScene(
            image: snapshot.image,
            projection: SnapshotProjection(snapshot: snapshot, origin: center),
            route: route,
            turn: turn
        )
    }

    #if DEBUG
    private static func fakeScene(
        center: Point, distance: CLLocationDistance, heading: CLLocationDirection, route: [Point], turn: Point
    ) -> WatchNavigationScene {
        let size = WKInterfaceDevice.current().screenBounds.size
        let scale = WKInterfaceDevice.current().screenScale
        let pixelsPerMeter = Double(size.height) / (distance * 0.8)
        let theta = heading * Double.pi / 180
        func point(for p: Point) -> CGPoint {
            let east = (p.lng - center.lng) * 111_320 * cos(center.lat * Double.pi / 180)
            let north = (p.lat - center.lat) * 111_320
            let right = east * cos(theta) - north * sin(theta)
            let up = east * sin(theta) + north * cos(theta)
            return CGPoint(x: Double(size.width) / 2 + right * pixelsPerMeter, y: Double(size.height) / 2 - up * pixelsPerMeter)
        }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Draw in the same top-left coordinates as the points above.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(red: 0.16, green: 0.22, blue: 0.3, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        let metersPerLng = 111_320 * cos(center.lat * Double.pi / 180)
        // A grid every 100 m so movement between maps is visible.
        for i in -20...20 {
            let a = point(for: Point(center.lng + Double(i) * 100 / metersPerLng, center.lat - 0.01))
            let b = point(for: Point(center.lng + Double(i) * 100 / metersPerLng, center.lat + 0.01))
            let c = point(for: Point(center.lng - 0.02, center.lat + Double(i) * 100 / 111_320))
            let d = point(for: Point(center.lng + 0.02, center.lat + Double(i) * 100 / 111_320))
            context.move(to: a); context.addLine(to: b)
            context.move(to: c); context.addLine(to: d)
        }
        context.strokePath()
        let image = UIImage(cgImage: context.makeImage()!, scale: scale, orientation: .up)
        let projection = SnapshotProjection(origin: center, pointFor: point(for:))
        return WatchNavigationScene(image: image, projection: projection, route: route, turn: turn)
    }
    #endif

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
