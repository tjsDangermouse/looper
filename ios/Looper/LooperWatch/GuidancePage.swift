import LooperKit
import MapKit
import SwiftUI
import WatchKit

struct WatchNavigationScene {
    let snapshot: MKMapSnapshotter.Snapshot
    let route: [Point]
    let turn: Point
}

/// Downloads the small map around every turn as soon as a loop reaches the
/// Watch. Unlike an interactive Map, these snapshots remain usable when the
/// Watch loses its data connection later in the route.
@MainActor
final class WatchNavigationMapCache: ObservableObject {
    @Published private(set) var scenes: [Int: WatchNavigationScene] = [:]
    @Published private(set) var liveScene: WatchNavigationScene?
    @Published private(set) var liveStepIndex: Int?
    @Published private(set) var isPreparing = false
    var onDiagnostic: ((String, [String: String]) -> Void)?

    private var sessionID: String?
    private var task: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveAnchor: Point?
    private var requestedLiveStepIndex: Int?

    func prepare(_ plan: LoopPlanPayload) {
        if sessionID != plan.sessionID {
            task?.cancel()
            sessionID = plan.sessionID
            scenes = [:]
            liveScene = nil
            liveStepIndex = nil
            liveAnchor = nil
            requestedLiveStepIndex = nil
            isPreparing = false
        }
        let geometry = plan.plannedGeometry ?? []
        let maneuvers = plan.plannedManeuvers ?? []
        guard !geometry.isEmpty, !maneuvers.isEmpty else {
            isPreparing = false
            return
        }

        if sessionID == plan.sessionID, isPreparing { return }
        let missing = maneuvers.filter { scenes[$0.stepIndex] == nil }
        guard !missing.isEmpty else { return }

        isPreparing = true
        onDiagnostic?("mapPreloadStarted", ["maps": String(missing.count)])
        task = Task { [weak self] in
            // Route order is intentional: the first map needed is downloaded
            // first, while later turns continue filling in behind it.
            for maneuver in missing {
                guard !Task.isCancelled, let turn = maneuver.coordinate else { break }
                let route = Self.routeWindow(around: turn, in: geometry)
                do {
                    let snapshot = try await Self.download(turn: turn, route: route)
                    guard !Task.isCancelled else { break }
                    self?.scenes[maneuver.stepIndex] = WatchNavigationScene(
                        snapshot: snapshot, route: route, turn: turn
                    )
                } catch {
                    // The vector route remains available without map data. A
                    // failed later snapshot does not discard completed ones.
                    self?.onDiagnostic?("mapSnapshotFailed", [
                        "kind": "preload", "step": String(maneuver.stepIndex),
                        "error": error.localizedDescription
                    ])
                }
            }
            guard self?.sessionID == plan.sessionID else { return }
            self?.onDiagnostic?("mapPreloadFinished", ["maps": String(self?.scenes.count ?? 0)])
            self?.isPreparing = false
            self?.task = nil
        }
    }

    func release() {
        task?.cancel()
        liveTask?.cancel()
        task = nil
        liveTask = nil
        sessionID = nil
        scenes = [:]
        liveScene = nil
        liveStepIndex = nil
        liveAnchor = nil
        requestedLiveStepIndex = nil
        isPreparing = false
    }

    /// watchOS maps are static snapshots. Refresh one after meaningful
    /// movement so the basemap follows the full walk without continuously
    /// downloading and rendering a new image for every one-second fix.
    func prepareLive(position: Point, next: ManeuverPayload, geometry: [Point]) {
        guard let turn = next.coordinate, geometry.count > 1 else { return }
        if requestedLiveStepIndex == next.stepIndex,
           let liveAnchor,
           haversine(liveAnchor, position) < 60 { return }

        liveTask?.cancel()
        liveAnchor = position
        requestedLiveStepIndex = next.stepIndex
        let route = Self.routeWindow(from: position, through: turn, in: geometry)
        onDiagnostic?("mapSnapshotRequested", [
            "kind": "live", "step": String(next.stepIndex)
        ])
        liveTask = Task { [weak self] in
            do {
                let snapshot = try await Self.download(
                    position: position,
                    turn: turn,
                    route: route,
                    distanceToTurn: next.distanceMeters
                )
                guard !Task.isCancelled else { return }
                self?.liveScene = WatchNavigationScene(snapshot: snapshot, route: route, turn: turn)
                self?.liveStepIndex = next.stepIndex
                self?.scenes[next.stepIndex] = self?.liveScene
                self?.liveTask = nil
                self?.onDiagnostic?("mapSnapshotReady", [
                    "kind": "live", "step": String(next.stepIndex)
                ])
            } catch {
                guard !Task.isCancelled else { return }
                self?.liveTask = nil
                self?.onDiagnostic?("mapSnapshotFailed", [
                    "kind": "live", "step": String(next.stepIndex),
                    "error": error.localizedDescription
                ])
                #if DEBUG
                print("[Looper Watch map] Snapshot failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private static func download(turn: Point, route: [Point]) async throws -> MKMapSnapshotter.Snapshot {
        // The turn marker has to sit comfortably below the Watch's curved
        // top edge. Centring as far back as 130 m put the junction at the
        // very top of the snapshot (and often clipped it), especially on the
        // smaller cases.
        let approach = pointBeforeTurn(70, turn: turn, route: route)
        return try await snapshot(
            center: approach,
            distance: 600,
            heading: bearing(from: approach, to: turn)
        )
    }

    private static func download(
        position: Point,
        turn: Point,
        route: [Point],
        distanceToTurn: Double
    ) async throws -> MKMapSnapshotter.Snapshot {
        let directDistance = haversine(position, turn)
        // Keep the next junction in the upper-middle of the rectangular map
        // image, not against the rounded top edge of the physical display.
        // A fraction also behaves consistently as the walker approaches.
        let lead = directDistance > 0 ? 0.6 : 0
        let center = Point(
            position.lng + (turn.lng - position.lng) * lead,
            position.lat + (turn.lat - position.lat) * lead
        )
        return try await snapshot(
            center: center,
            distance: min(1_000, max(180, distanceToTurn * 2.4)),
            heading: bearing(from: position, to: turn)
        )
    }

    private static func snapshot(
        center: Point,
        distance: CLLocationDistance,
        heading: CLLocationDirection
    ) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        let camera = MKMapCamera(
            lookingAtCenter: center.coordinate,
            fromDistance: distance,
            pitch: 0,
            heading: heading
        )
        options.camera = camera
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

/// A glanceable navigation map: no scrolling, no zooming, and no whole-loop
/// overview. Its camera follows the phone's live GPS fix while the cached
/// turn image remains available before the first fix or without map data.
struct GuidancePage: View {
    @ObservedObject var model: WatchModel
    @ObservedObject private var navigationMaps: WatchNavigationMapCache

    init(model: WatchModel) {
        self.model = model
        _navigationMaps = ObservedObject(wrappedValue: model.navigationMaps)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                TurnMapArtwork(
                    scene: currentScene,
                    fallbackRoute: fallbackRoute,
                    turn: next?.coordinate,
                    turnKind: next?.turnKind,
                    position: model.state?.position
                )
            }
            .ignoresSafeArea()

            guidanceBanner
                .padding(.horizontal, 7)
                .padding(.bottom, 22)
        }
        .ignoresSafeArea()
        .onAppear(perform: prepareLiveMap)
        .onChange(of: model.state?.updatedAt) { _, _ in prepareLiveMap() }
    }

    private var next: ManeuverPayload? {
        guard let next = model.state?.next, next.turnKind != .arrive else { return nil }
        return next
    }

    private var fallbackRoute: [Point] {
        guard let turn = next?.coordinate, let geometry = model.plan?.plannedGeometry else { return [] }
        if let position = model.state?.position {
            return WatchNavigationMapCache.routeWindow(from: position, through: turn, in: geometry)
        }
        return WatchNavigationMapCache.routeWindow(around: turn, in: geometry)
    }

    private var currentScene: WatchNavigationScene? {
        guard let next else { return nil }
        if navigationMaps.liveStepIndex == next.stepIndex,
           let scene = navigationMaps.liveScene { return scene }
        return navigationMaps.scenes[next.stepIndex]
    }

    private func prepareLiveMap() {
        guard let position = model.state?.position,
              let next,
              let geometry = model.plan?.plannedGeometry else { return }
        navigationMaps.prepareLive(position: position, next: next, geometry: geometry)
    }

    @ViewBuilder
    private var guidanceBanner: some View {
        if !model.isPhoneLive {
            StatusBanner(
                icon: "iphone.slash", title: "iPhone disconnected",
                detail: "Map saved · Guidance paused", tint: .orange
            )
        } else if model.state?.offRoute == true {
            StatusBanner(
                icon: "exclamationmark.triangle.fill", title: "Off route",
                detail: "Check your iPhone", tint: .orange
            )
        } else if let next {
            Turning(next: next, unit: model.plan?.displayUnit ?? .km)
        } else {
            StatusBanner(
                icon: "checkmark.circle.fill", title: "On route",
                detail: "No turns coming up", tint: Color.looperAccent
            )
        }
    }
}

private struct TurnMapArtwork: View {
    let scene: WatchNavigationScene?
    let fallbackRoute: [Point]
    let turn: Point?
    let turnKind: Turn?
    let position: Point?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let scene {
                    Image(uiImage: scene.snapshot.image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(red: 0.12, green: 0.14, blue: 0.15)
                }

                Canvas { context, size in
                    let route = scene?.route ?? fallbackRoute
                    guard route.count > 1 else { return }
                    let points = projected(route, scene: scene, size: size)
                    var line = Path()
                    line.move(to: points[0])
                    for point in points.dropFirst() { line.addLine(to: point) }
                    context.stroke(
                        line, with: .color(.black.opacity(0.72)),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
                    )
                    context.stroke(
                        line, with: .color(Color.appleMapsRoute),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )

                    let markerPoint = turn.flatMap {
                        projected($0, against: route, scene: scene, size: size)
                    }
                    if let point = markerPoint {
                        let marker = Path(
                            ellipseIn: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)
                        )
                        context.fill(marker, with: .color(Color.appleMapsRoute))
                        context.stroke(marker, with: .color(.white), lineWidth: 2)
                        if let turnKind {
                            let symbol = context.resolve(
                                Text(Image(systemName: turnSymbolName(turnKind)))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            context.draw(symbol, at: point)
                        }
                    }

                    if let position {
                        let locationPoint = projected(
                            position, against: route, scene: scene, size: size
                        )
                        if let locationPoint {
                            let outer = Path(
                                ellipseIn: CGRect(
                                    x: locationPoint.x - 9, y: locationPoint.y - 9,
                                    width: 18, height: 18
                                )
                            )
                            let inner = Path(
                                ellipseIn: CGRect(
                                    x: locationPoint.x - 6, y: locationPoint.y - 6,
                                    width: 12, height: 12
                                )
                            )
                            context.fill(outer, with: .color(.white))
                            context.fill(inner, with: .color(Color.appleMapsRoute))
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func projected(_ coordinates: [Point], scene: WatchNavigationScene?, size: CGSize) -> [CGPoint] {
        if let scene {
            let imageSize = scene.snapshot.image.size
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            let xInset = (size.width - imageSize.width * scale) / 2
            let yInset = (size.height - imageSize.height * scale) / 2
            return coordinates.map {
                let point = scene.snapshot.point(
                    for: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                )
                return CGPoint(x: point.x * scale + xInset, y: point.y * scale + yInset)
            }
        }

        let latitudes = coordinates.map(\.lat)
        let longitudes = coordinates.map(\.lng)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLng = longitudes.min(), let maxLng = longitudes.max() else { return [] }
        let padding = 28.0
        let width = max(0.000_001, maxLng - minLng)
        let height = max(0.000_001, maxLat - minLat)
        return coordinates.map {
            CGPoint(
                x: padding + (($0.lng - minLng) / width) * (size.width - padding * 2),
                y: padding + ((maxLat - $0.lat) / height) * (size.height - padding * 2)
            )
        }
    }

    /// Projects an overlay point in the same coordinate space as the route.
    /// In the no-tiles fallback this is important: projecting the point on
    /// its own has no extent, while snapping it to a route vertex makes a
    /// smoothly simulated walk appear frozen until the next vertex.
    private func projected(
        _ coordinate: Point,
        against route: [Point],
        scene: WatchNavigationScene?,
        size: CGSize
    ) -> CGPoint? {
        if let scene {
            return projected([coordinate], scene: scene, size: size).first
        }
        return projected(route + [coordinate], scene: nil, size: size).last
    }
}

private struct Turning: View {
    let next: ManeuverPayload
    let unit: LooperKit.Unit

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: turnSymbolName(next.turnKind))
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Color.appleMapsRoute)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text(distanceText)
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .lineLimit(1)
                Text(next.instruction)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In \(distanceText), \(next.instruction)")
    }

    private var distanceText: String {
        next.distanceMeters < 300
            ? "\(Int((next.distanceMeters / 10).rounded() * 10)) m"
            : formatDistance(next.distanceMeters, unit: unit)
    }

}

private struct StatusBanner: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline)
                Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private extension Color {
    static let appleMapsRoute = Color(red: 0.04, green: 0.52, blue: 1.0)
}

private extension Point {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

func turnSymbolName(_ turn: Turn) -> String {
    switch turn {
    case .left: return "arrow.turn.up.left"
    case .slightLeft: return "arrow.up.left"
    case .sharpLeft: return "arrow.uturn.left"
    case .right: return "arrow.turn.up.right"
    case .slightRight: return "arrow.up.right"
    case .sharpRight: return "arrow.uturn.right"
    case .straight: return "arrow.up"
    case .uTurn: return "arrow.uturn.down"
    case .arrive: return "checkmark.circle"
    }
}
