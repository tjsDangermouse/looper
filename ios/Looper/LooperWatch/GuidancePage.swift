import LooperKit
import SwiftUI

/// The turn the phone says is next. Big arrow, plain words, one distance.
///
/// Everything here is rendered exactly as the phone's navigation engine
/// decided it — no route is recalculated on the wrist, and when the phone
/// stops being heard the screen says so instead of holding a stale turn up as
/// if it were still true.
struct GuidancePage: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.isPhoneLive {
                Disconnected()
            } else if model.state?.offRoute == true {
                OffRoute()
            } else if let next = model.state?.next, next.turnKind != .arrive {
                Turning(next: next, then: model.state?.then, unit: model.plan?.displayUnit ?? .km)
            } else if model.state?.next == nil || model.state?.next?.turnKind == .arrive {
                Arriving()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Turning: View {
    let next: ManeuverPayload
    let then: ManeuverPayload?
    let unit: LooperKit.Unit

    var body: some View {
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
