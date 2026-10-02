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
        return navigationMaps.scene(position: model.state?.position, next: next)
    }

    private func prepareLiveMap() {
        guard let position = model.state?.position,
              let next,
              let geometry = model.plan?.plannedGeometry else { return }
        navigationMaps.prepareLive(position: position, next: next, geometry: geometry)
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
                    Image(uiImage: scene.image)
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
