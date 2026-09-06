import LooperKit
import MapKit
import SwiftUI

/// The route and current position stay visible edge-to-edge, with the turn the
/// phone says is next in a compact glass panel at the bottom.
///
/// Everything here is rendered exactly as the phone's navigation engine
/// decided it. The route line is only a visual reference: no route is
/// recalculated on the wrist, and when the phone stops being heard the panel
/// says so instead of holding a stale turn up as if it were still true.
struct GuidancePage: View {
    @ObservedObject var model: WatchModel
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        followsHeading: true,
        fallback: .automatic
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition) {
                if routeCoordinates.count > 1 {
                    MapPolyline(coordinates: routeCoordinates)
                        .stroke(
                            Color.looperAccent,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                        )
                }
                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .flat))
            .ignoresSafeArea()

            guidancePanel
                .padding(.horizontal, 7)
                .padding(.bottom, 8)
        }
        .ignoresSafeArea()
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        (model.plan?.plannedGeometry ?? []).map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
        }
    }

    @ViewBuilder
    private var guidancePanel: some View {
        Group {
            if !model.isPhoneLive {
                Disconnected()
            } else if model.state?.offRoute == true {
                OffRoute()
            } else if let next = model.state?.next, next.turnKind != .arrive {
                Turning(next: next, then: model.state?.then, unit: model.plan?.displayUnit ?? .km)
            } else {
                Arriving()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
    }
}

private struct Turning: View {
    let next: ManeuverPayload
    let then: ManeuverPayload?
    let unit: LooperKit.Unit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: turnSymbolName(next.turnKind))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.looperAccent)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text(distanceText)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)

                    Text(next.instruction)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let then {
                Label(then.instruction, systemImage: turnSymbolName(then.turnKind))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .padding(.leading, 42)
                    .accessibilityLabel("Then, \(then.instruction)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("In \(distanceText), \(next.instruction)")
    }

    /// Metres up close, the walker's own unit further out — the same way the
    /// phone's spoken guidance already says it.
    private var distanceText: String {
        next.distanceMeters < 300
            ? "\(Int((next.distanceMeters / 10).rounded() * 10)) m"
            : formatDistance(next.distanceMeters, unit: unit)
    }
}

private struct OffRoute: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 25))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Off route")
                    .font(.headline)
                Text("Check your iPhone for the route.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Off route. Check your iPhone for the route.")
    }
}

private struct Arriving: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 25))
                .foregroundStyle(Color.looperAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("On route")
                    .font(.headline)
                Text("No turns coming up")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The honest empty state: the workout is still recording, but nothing on
/// this screen can be trusted until the phone is back.
private struct Disconnected: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 25))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("No guidance")
                    .font(.headline)
                Text("iPhone disconnected · Workout recording")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
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
