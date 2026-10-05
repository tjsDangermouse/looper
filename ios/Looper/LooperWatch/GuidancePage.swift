import LooperKit
import MapKit
import SwiftUI
import WatchKit

/// A glanceable navigation map: no scrolling, no zooming, and no whole-loop
/// overview. Its camera follows the Watch's own GPS fix — a live map while
/// there is a connection, the maps saved along the route when there isn't —
/// so it looks the same with or without a phone. The route line alone is the
/// last resort. Whichever it is, it turns about the walker so the way they
/// are going is up.
struct GuidancePage: View {
    @ObservedObject var model: WatchModel
    @ObservedObject private var navigationMaps: WatchNavigationMapCache

    init(model: WatchModel) {
        self.model = model
        _navigationMaps = ObservedObject(wrappedValue: model.navigationMaps)
    }

    @State private var bannerFrame: CGRect = .zero
    /// The direction drawn as up. It runs on past 360 rather than wrapping, so
    /// the map always turns the short way round.
    @State private var course: Double?
    @State private var courseReported = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TurnMapArtwork(
                scene: currentScene,
                route: currentScene?.route ?? fallbackRoute,
                turn: target?.coordinate,
                turnKind: target?.turnKind,
                walker: model.state?.position,
                course: mapCourse
            )
            .ignoresSafeArea()

            guidanceBanner
                .padding(.horizontal, 7)
                .padding(.bottom, 22)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: BannerFrameKey.self, value: proxy.frame(in: .named(Self.space)))
                    }
                }

            // Above the banner, so the walker never disappears behind it.
            LocationDot(
                scene: currentScene,
                route: currentScene?.route ?? fallbackRoute,
                position: model.state?.position,
                bannerFrame: bannerFrame,
                course: mapCourse
            )
            .ignoresSafeArea()
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(BannerFrameKey.self) { bannerFrame = $0 }
        .ignoresSafeArea()
        .onAppear {
            followCourse()
            prepareLiveMap()
        }
        .onChange(of: model.state?.updatedAt) { _, _ in
            followCourse()
            prepareLiveMap()
        }
    }

    private static let space = "guidance"

    private var next: ManeuverPayload? {
        guard let next = model.state?.next, next.turnKind != .arrive else { return nil }
        return next
    }

    /// The finish, once the turns have run out: the last stretch still gets
    /// a map and a distance rather than an empty screen.
    private var finish: ManeuverPayload? {
        guard next == nil, let state = model.state, state.remainingMeters > 0,
              let geometry = model.plan?.plannedGeometry,
              var finish = finishManeuver(geometry: geometry) else { return nil }
        finish.distanceMeters = state.remainingMeters
        return finish
    }

    /// What the map aims at: the next turn, else the finish.
    private var target: ManeuverPayload? { next ?? finish }

    private var fallbackRoute: [Point] {
        guard let turn = target?.coordinate, let geometry = model.plan?.plannedGeometry else { return [] }
        if let position = model.state?.position {
            return WatchNavigationMapCache.routeWindow(from: position, through: turn, in: geometry)
        }
        return WatchNavigationMapCache.routeWindow(around: turn, in: geometry)
    }

    private var currentScene: WatchNavigationScene? {
        guard let target else { return nil }
        return navigationMaps.scene(position: model.state?.position, next: target)
    }

    private func prepareLiveMap() {
        guard let position = model.state?.position,
              let target,
              let geometry = model.plan?.plannedGeometry else { return }
        navigationMaps.prepareLive(position: position, course: course, next: target, geometry: geometry)
    }

    /// Up on the map. Before any direction is known the picture is left the
    /// way it was taken.
    private var mapCourse: Double { course ?? currentScene?.projection.heading ?? 0 }

    /// The way the route runs from where the walker is.
    private var routeCourse: Double? {
        guard let position = model.state?.position else { return nil }
        let ahead = fallbackRoute.dropFirst()
        guard let aim = ahead.first(where: { haversine(position, $0) >= 15 }) ?? ahead.last else { return nil }
        return WatchNavigationMapCache.bearing(from: position, to: aim)
    }

    /// Turns the map towards the walker's direction of travel. GPS gives no
    /// direction to someone standing still, so the last one is kept; until the
    /// first arrives the route's own direction stands in. Each fix moves the
    /// map only part of the way, which keeps a jittery course from shaking it.
    private func followCourse() {
        let reported = model.state?.courseDegrees
        if reported != nil { courseReported = true }
        guard let aim = reported ?? (courseReported ? nil : routeCourse) else { return }
        guard let shown = course else {
            course = aim
            return
        }
        let turn = WatchNavigationMapCache.turn(from: shown, to: aim)
        guard abs(turn) >= 2 else { return }
        withAnimation(.easeInOut(duration: 0.8)) { course = shown + turn * 0.6 }
    }

    @ViewBuilder
    private var guidanceBanner: some View {
        if model.state?.position == nil {
            StatusBanner(
                icon: "location.fill", title: "Finding GPS",
                detail: "Guidance starts with your first fix", tint: .orange
            )
        } else if model.state?.offRoute == true {
            StatusBanner(
                icon: "exclamationmark.triangle.fill", title: "Off route",
                detail: "Head back to the route", tint: .orange
            )
            .onTapGesture { model.repeatGuidance() }
        } else if let target {
            Turning(next: target, unit: model.plan?.displayUnit ?? .km) { model.repeatGuidance() }
        } else {
            StatusBanner(
                icon: "checkmark.circle.fill", title: "On route",
                detail: "No turns coming up", tint: Color.looperAccent
            )
        }
    }
}

private struct BannerFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Places route coordinates on the screen: through the map's own projection
/// when there is one, turned about the walker so their course is up, else by
/// fitting the route line to the screen with their course up.
private struct MapProjector {
    let scene: WatchNavigationScene?
    let route: [Point]
    let size: CGSize
    let walker: Point?
    let course: Double

    /// How far the picture is turned, clockwise, to put the course at the top.
    var turn: Angle { .degrees((scene?.projection.heading ?? course) - course) }

    /// Where the walker falls on the picture before it is turned: the point
    /// it turns about.
    var pivot: CGPoint? {
        guard let scene, let walker else { return nil }
        return place(walker, on: scene)
    }

    private func place(_ coordinate: Point, on scene: WatchNavigationScene) -> CGPoint {
        let imageSize = scene.image.size
        let scale = max(size.width / imageSize.width, size.height / imageSize.height)
        let point = scene.projection.point(for: coordinate)
        return CGPoint(
            x: point.x * scale + (size.width - imageSize.width * scale) / 2,
            y: point.y * scale + (size.height - imageSize.height * scale) / 2
        )
    }

    func points(_ coordinates: [Point]) -> [CGPoint] {
        if let scene {
            let placed = coordinates.map { place($0, on: scene) }
            guard let pivot else { return placed }
            let sine = sin(turn.radians), cosine = cos(turn.radians)
            return placed.map {
                let dx = $0.x - pivot.x, dy = $0.y - pivot.y
                return CGPoint(x: pivot.x + dx * cosine - dy * sine, y: pivot.y + dx * sine + dy * cosine)
            }
        }

        // Metres right of and ahead of the first point, for someone facing
        // along the course.
        guard let origin = coordinates.first else { return [] }
        let theta = course * Double.pi / 180
        let metres = coordinates.map { coordinate -> (right: Double, up: Double) in
            let east = (coordinate.lng - origin.lng) * 111_320 * cos(origin.lat * Double.pi / 180)
            let north = (coordinate.lat - origin.lat) * 111_320
            return (east * cos(theta) - north * sin(theta), east * sin(theta) + north * cos(theta))
        }
        let rights = metres.map(\.right), ups = metres.map(\.up)
        guard let minRight = rights.min(), let maxRight = rights.max(),
              let minUp = ups.min(), let maxUp = ups.max() else { return [] }
        let padding = 28.0
        let scale = min(
            (size.width - padding * 2) / max(1, maxRight - minRight),
            (size.height - padding * 2) / max(1, maxUp - minUp)
        )
        return metres.map {
            CGPoint(
                x: size.width / 2 + ($0.right - (minRight + maxRight) / 2) * scale,
                y: size.height / 2 - ($0.up - (minUp + maxUp) / 2) * scale
            )
        }
    }

    /// Projects an overlay point in the same coordinate space as the route.
    /// In the no-tiles fallback this is important: projecting the point on
    /// its own has no extent, while snapping it to a route vertex makes a
    /// smoothly simulated walk appear frozen until the next vertex.
    func point(_ coordinate: Point) -> CGPoint? {
        if scene != nil { return points([coordinate]).first }
        guard route.count > 1 else { return nil }
        return points(route + [coordinate]).last
    }
}

/// The walker, drawn above the banner. Where the two overlap the dot turns
/// to a faint ring: still findable, without covering the words.
private struct LocationDot: View, Animatable {
    let scene: WatchNavigationScene?
    let route: [Point]
    let position: Point?
    let bannerFrame: CGRect
    var course: Double

    var animatableData: Double {
        get { course }
        set { course = newValue }
    }

    var body: some View {
        Canvas { context, size in
            guard let position,
                  let point = MapProjector(
                      scene: scene, route: route, size: size, walker: position, course: course
                  ).point(position) else { return }
            let outer = Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18))
            let inner = Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
            if bannerFrame.insetBy(dx: -4, dy: -4).contains(point) {
                context.fill(inner, with: .color(Color.appleMapsRoute.opacity(0.45)))
                context.stroke(outer, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
            } else {
                context.fill(outer, with: .color(.white))
                context.fill(inner, with: .color(Color.appleMapsRoute))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The map and the route over it. The picture is turned as a whole; the route
/// and the turn marker are drawn already turned, which keeps the marker's
/// arrow upright.
private struct TurnMapArtwork: View, Animatable {
    let scene: WatchNavigationScene?
    let route: [Point]
    let turn: Point?
    let turnKind: Turn?
    let walker: Point?
    var course: Double

    var animatableData: Double {
        get { course }
        set { course = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Shows wherever a turned picture doesn't reach.
                Color(red: 0.12, green: 0.14, blue: 0.15)
                if let scene {
                    let projector = MapProjector(
                        scene: scene, route: route, size: proxy.size, walker: walker, course: course
                    )
                    let pivot = projector.pivot ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    Image(uiImage: scene.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .rotationEffect(
                            projector.pivot == nil ? .zero : projector.turn,
                            anchor: UnitPoint(
                                x: pivot.x / max(1, proxy.size.width), y: pivot.y / max(1, proxy.size.height)
                            )
                        )
                }

                Canvas { context, size in
                    guard route.count > 1 else { return }
                    let projector = MapProjector(
                        scene: scene, route: route, size: size, walker: walker, course: course
                    )
                    let points = projector.points(route)
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

                    if let point = turn.flatMap(projector.point) {
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
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The next instruction. A tap opens it up to the full wording and says it
/// again; it closes on a second tap or when the next turn comes up.
private struct Turning: View {
    let next: ManeuverPayload
    let unit: LooperKit.Unit
    let onTap: () -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: expanded ? .top : .center, spacing: 8) {
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
                    .lineLimit(expanded ? nil : 1)
                    .minimumScaleFactor(expanded ? 1 : 0.72)
                    .fixedSize(horizontal: false, vertical: expanded)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .foregroundStyle(.white)
        .background(
            expanded ? AnyShapeStyle(.black.opacity(0.88)) : AnyShapeStyle(.ultraThinMaterial),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            if expanded { onTap() }
        }
        .onChange(of: next.stepIndex) { _, _ in expanded = false }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In \(distanceText), \(next.instruction)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the full instruction and repeats it")
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
    case .arrive: return "flag.checkered"
    }
}
