import LooperKit
import MapKit
import SwiftUI

/// The turn the phone says is next. A street-scale map, plain words and one
/// distance, all from the phone's authoritative navigation state.
///
/// Everything here is rendered exactly as the phone's navigation engine
/// decided it — no route is recalculated on the wrist, and when the phone
/// stops being heard the screen says so instead of holding a stale turn up as
/// if it were still true.
struct GuidancePage: View {
    @ObservedObject var model: WatchModel
    /// `TabView` builds adjacent pages before they are shown. Defer MapKit's
    /// work until the walker actually opens guidance so workout startup stays
    /// lightweight on the Watch.
    let isVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.isPhoneLive {
                Disconnected()
            } else if model.state?.offRoute == true {
                OffRoute()
            } else if let next = model.state?.next, next.turnKind != .arrive {
                Turning(
                    next: next,
                    then: model.state?.then,
                    preview: model.state?.routePreview,
                    showsMap: isVisible,
                    unit: model.plan?.displayUnit ?? .km
                )
            } else if model.state?.next == nil || model.state?.next?.turnKind == .arrive {
                Arriving()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Turning: View {
    let next: ManeuverPayload
    let then: ManeuverPayload?
    let preview: RoutePreviewPayload?
    let showsMap: Bool
    let unit: LooperKit.Unit

    var body: some View {
        Group {
            if showsMap, let preview, preview.coordinates.count >= 2 {
                mapGuidance(preview)
            } else {
                textGuidance
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In \(distanceText), \(next.instruction)")
    }

    private func mapGuidance(_ preview: RoutePreviewPayload) -> some View {
        ZStack(alignment: .bottomLeading) {
            TurnMapSnapshot(preview: preview)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: turnSymbolName(next.turnKind))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.looperAccent)
                    Text(distanceText)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(next.instruction)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)

                if let then {
                    Label(then.instruction, systemImage: turnSymbolName(then.turnKind))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("Then, \(then.instruction)")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var textGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: turnSymbolName(next.turnKind))
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.looperAccent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(distanceText)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("ahead")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(next.instruction)
                .font(.headline)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)

            if let then {
                Label(then.instruction, systemImage: turnSymbolName(then.turnKind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel("Then, \(then.instruction)")
            }
        }
    }

    /// Metres up close, the walker's own unit further out — the same way the
    /// phone's spoken guidance already says it.
    private var distanceText: String {
        next.distanceMeters < 300
            ? "\(Int((next.distanceMeters / 10).rounded() * 10)) m"
            : formatDistance(next.distanceMeters, unit: unit)
    }
}

/// A static map is the right primitive for this non-interactive glance. A
/// live SwiftUI `Map` eagerly starts its renderer even while its `TabView`
/// page is offscreen, competing with HealthKit during workout startup on a
/// resource-constrained Watch. The snapshot is requested only once this page
/// is visible; the Canvas route remains useful even if map tiles are offline.
private struct TurnMapSnapshot: View {
    let preview: RoutePreviewPayload
    @State private var snapshot: Image?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.looperRaised
                if let snapshot {
                    snapshot
                        .resizable()
                        .scaledToFill()
                }
                RouteOverlay(preview: preview, region: region)
            }
            .task(id: snapshotID(size: proxy.size)) {
                await loadSnapshot(size: proxy.size)
            }
        }
        .accessibilityHidden(true)
    }

    private func snapshotID(size: CGSize) -> String {
        "\(preview.maneuver.lng),\(preview.maneuver.lat),\(Int(size.width))x\(Int(size.height))"
    }

    @MainActor
    private func loadSnapshot(size: CGSize) async {
        guard size.width > 0, size.height > 0 else { return }
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        let image = await withCheckedContinuation { continuation in
            let snapshotter = MKMapSnapshotter(options: options)
            snapshotter.start { [snapshotter] result, _ in
                _ = snapshotter
                continuation.resume(returning: result?.image)
            }
        }
        guard !Task.isCancelled, let image else { return }
        snapshot = Image(uiImage: image)
    }

    private var region: MKCoordinateRegion {
        let points = preview.coordinates + [preview.maneuver] + [preview.currentPosition].compactMap { $0 }
        let latitudes = points.map(\.lat)
        let longitudes = points.map(\.lng)
        let minLat = latitudes.min() ?? preview.maneuver.lat
        let maxLat = latitudes.max() ?? preview.maneuver.lat
        let minLng = longitudes.min() ?? preview.maneuver.lng
        let maxLng = longitudes.max() ?? preview.maneuver.lng
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.45, 0.0012),
                longitudeDelta: max((maxLng - minLng) * 1.45, 0.0012)
            )
        )
    }
}

private struct RouteOverlay: View {
    let preview: RoutePreviewPayload
    let region: MKCoordinateRegion

    var body: some View {
        Canvas { context, size in
            let route = path(for: preview.coordinates, size: size)
            let rounded = StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
            context.stroke(route, with: .color(Color.looperRouteCasing), style: rounded)
            context.stroke(
                route,
                with: .color(Color.looperAccent),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
            )

            drawMarker(at: preview.maneuver, color: Color.looperAccent, size: 13, context: &context, canvasSize: size)
            if let current = preview.currentPosition {
                drawMarker(at: current, color: .blue, size: 12, context: &context, canvasSize: size)
            }
        }
    }

    private func path(for points: [Point], size: CGSize) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let position = canvasPoint(point, size: size)
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        return path
    }

    private func drawMarker(
        at point: Point,
        color: Color,
        size markerSize: CGFloat,
        context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        let center = canvasPoint(point, size: canvasSize)
        let outer = CGRect(
            x: center.x - markerSize / 2 - 2,
            y: center.y - markerSize / 2 - 2,
            width: markerSize + 4,
            height: markerSize + 4
        )
        let inner = CGRect(
            x: center.x - markerSize / 2,
            y: center.y - markerSize / 2,
            width: markerSize,
            height: markerSize
        )
        context.fill(Path(ellipseIn: outer), with: .color(.black.opacity(0.8)))
        context.fill(Path(ellipseIn: inner), with: .color(color))
    }

    private func canvasPoint(_ point: Point, size: CGSize) -> CGPoint {
        let latitudeSpan = max(region.span.latitudeDelta, 0.000001)
        let longitudeSpan = max(region.span.longitudeDelta, 0.000001)
        let minLatitude = region.center.latitude - latitudeSpan / 2
        let minLongitude = region.center.longitude - longitudeSpan / 2
        return CGPoint(
            x: (point.lng - minLongitude) / longitudeSpan * size.width,
            y: (1 - (point.lat - minLatitude) / latitudeSpan) * size.height
        )
    }
}

private struct OffRoute: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("Off route")
                .font(.headline)
            Text("Check your phone to get back on the loop.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Off route. Check your phone to get back on the loop.")
    }
}

private struct Arriving: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.looperAccent)
            Text("On route")
                .font(.headline)
            Text("No turns coming up.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The honest empty state: the workout is still recording, but nothing on
/// this screen can be trusted until the phone is back.
private struct Disconnected: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("No guidance")
                .font(.headline)
            Text("Your iPhone isn’t connected. Your workout is still recording.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No guidance. Your iPhone isn’t connected. Your workout is still recording.")
    }
}

/// The same arrows the phone's walk screen uses, so a turn looks the same on
/// both devices.
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
