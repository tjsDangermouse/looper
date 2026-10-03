import LooperKit
import MapKit
import SwiftUI
import WatchKit

/// A glanceable navigation map: no scrolling, no zooming, and no whole-loop
/// overview. Its camera follows the Watch's own GPS fix — a live map while
/// there is a connection, the maps saved along the route when there isn't —
/// so it looks the same with or without a phone. The route line alone is the
/// last resort.
struct GuidancePage: View {
    @ObservedObject var model: WatchModel
    @ObservedObject private var navigationMaps: WatchNavigationMapCache

    init(model: WatchModel) {
        self.model = model
        _navigationMaps = ObservedObject(wrappedValue: model.navigationMaps)
    }

    @State private var bannerFrame: CGRect = .zero

    var body: some View {
        ZStack(alignment: .bottom) {
            TurnMapArtwork(
                scene: currentScene,
                route: currentScene?.route ?? fallbackRoute,
                turn: target?.coordinate,
                turnKind: target?.turnKind
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
                bannerFrame: bannerFrame
            )
            .ignoresSafeArea()
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(BannerFrameKey.self) { bannerFrame = $0 }
        .ignoresSafeArea()
        .onAppear(perform: prepareLiveMap)
        .onChange(of: model.state?.updatedAt) { _, _ in prepareLiveMap() }
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
        navigationMaps.prepareLive(position: position, next: target, geometry: geometry)
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
/// when there is one, else by fitting the route line to the screen.
private struct MapProjector {
    let scene: WatchNavigationScene?
    let route: [Point]
    let size: CGSize

    func points(_ coordinates: [Point]) -> [CGPoint] {
        if let scene {
            let imageSize = scene.image.size
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            let xInset = (size.width - imageSize.width * scale) / 2
            let yInset = (size.height - imageSize.height * scale) / 2
            return coordinates.map {
                let point = scene.projection.point(for: $0)
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
    func point(_ coordinate: Point) -> CGPoint? {
        if scene != nil { return points([coordinate]).first }
        guard route.count > 1 else { return nil }
        return points(route + [coordinate]).last
    }
}

/// The walker, drawn above the banner. Where the two overlap the dot turns
/// to a faint ring: still findable, without covering the words.
private struct LocationDot: View {
    let scene: WatchNavigationScene?
    let route: [Point]
    let position: Point?
    let bannerFrame: CGRect

    var body: some View {
        Canvas { context, size in
            guard let position,
                  let point = MapProjector(scene: scene, route: route, size: size).point(position) else { return }
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

private struct TurnMapArtwork: View {
    let scene: WatchNavigationScene?
    let route: [Point]
    let turn: Point?
    let turnKind: Turn?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let scene {
                    Image(uiImage: scene.image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(red: 0.12, green: 0.14, blue: 0.15)
                }

                Canvas { context, size in
                    guard route.count > 1 else { return }
                    let projector = MapProjector(scene: scene, route: route, size: size)
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
