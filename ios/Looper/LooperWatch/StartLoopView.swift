import LooperKit
import SwiftUI

/// The loop that is ready to walk, one button, and the phone's saved routes to
/// choose from instead. Every route here was planned on the phone — the Watch
/// offers no way to plan one — and each is complete, so none of it needs the
/// phone to be nearby once it has arrived.
struct StartLoopView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let plan = model.plan {
                    Label(plan.activity == .running ? "Run" : "Walk",
                          systemImage: plan.activity == .running ? "figure.run" : "figure.walk")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.looperAccent)

                    Text(plan.routeName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    Text(plan.targetDescription)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(plan.mode == .distance ? "target distance" : "target time")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    RouteReadiness(model: model, plan: plan)
                        .padding(.vertical, 2)

                    Button(action: model.startFromWatch) {
                        if model.starting {
                            ProgressView()
                        } else {
                            Text("Start")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.looperAccent)
                    .foregroundStyle(Color.looperOnAccent)
                    .disabled(model.starting)
                    .padding(.top, 1)
                    .accessibilityLabel("Start \(plan.activity == .running ? "run" : "walk"), \(plan.routeName), \(plan.targetDescription)")

                    // Said before the walk rather than after it goes wrong:
                    // spoken directions need something to play through.
                    if model.voiceOn {
                        Label("Spoken directions play through headphones.", systemImage: "headphones")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(WatchAppVersion.displayString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    // Permission is settled at launch, so what this screen
                    // owes the walker is not a warning about a sheet to come
                    // but the plain consequence of the answer already given:
                    // start this and nothing lands in Health.
                    if !model.canRecordToHealth {
                        Label(
                            "Guidance only. Allow Health access in Settings to record this \(plan.activity == .running ? "run" : "walk") and show your heart rate.",
                            systemImage: "heart.slash"
                        )
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !model.disabledHealthPermissions.isEmpty {
                    Label(
                        "Health is blocking: \(model.disabledHealthPermissions.joined(separator: ", ")). Turn on in Health on your iPhone → Apps → Looper.",
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let notice = model.notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.savedRoutes.isEmpty {
                    Text("Offline routes")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                SavedRoutesList(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// How much of the chosen route is on the Watch: a ring that fills as its maps
/// arrive from the iPhone, and a plain tick once all of it is here. Shown above
/// Start, because the time to find out a route is only half here is before
/// walking away from the phone, not at the first missing map.
private struct RouteReadiness: View {
    @ObservedObject var model: WatchModel
    @ObservedObject private var maps: WatchNavigationMapCache
    let plan: LoopPlanPayload

    init(model: WatchModel, plan: LoopPlanPayload) {
        self.model = model
        self.plan = plan
        _maps = ObservedObject(wrappedValue: model.navigationMaps)
    }

    private var counts: (saved: Int, total: Int) { maps.progress(plan) ?? (0, 0) }
    private var fraction: Double { counts.total > 0 ? Double(counts.saved) / Double(counts.total) : 0 }
    private var ready: Bool { maps.isReady(plan) }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: ready ? 1 : fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: fraction)
                if ready {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ready ? tint : .primary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }

    /// Maps are only sent for a route made available offline on the phone; any
    /// other follows the phone, which is waiting, not failing.
    private var waiting: Bool { !ready && !maps.isPreparing && !model.isSaved(plan) }

    private var tint: Color {
        if waiting { return .secondary }
        return ready || maps.isPreparing ? Color.looperAccent : .orange
    }

    private var title: String {
        if ready { return "Ready to walk" }
        if maps.isPreparing { return maps.receivingFromPhone ? "Sending from iPhone" : "Downloading maps" }
        return waiting ? "Follows your iPhone" : "Not all here yet"
    }

    private var detail: String {
        let count = "\(counts.saved) of \(counts.total) maps"
        if ready { return "Route and maps are on this Watch" }
        if maps.isPreparing {
            return maps.receivingFromPhone ? "\(count) — keep your iPhone near" : "\(count) — keep a connection"
        }
        if waiting { return "To walk it without your iPhone, make it available offline there" }
        return counts.total > 0
            ? "\(count). Open Looper on your iPhone to finish"
            : "Open Looper on your iPhone to send the maps"
    }
}

/// The phone's saved routes. Choosing one makes it the route to walk.
struct SavedRoutesList: View {
    @ObservedObject var model: WatchModel
    @ObservedObject private var maps: WatchNavigationMapCache

    init(model: WatchModel) {
        self.model = model
        _maps = ObservedObject(wrappedValue: model.navigationMaps)
    }

    var body: some View {
        if !model.savedRoutes.isEmpty {
            VStack(spacing: 6) {
                ForEach(model.savedRoutes, id: \.routeID) { route in
                    Button { model.choose(route) } label: { card(route) }
                        .buttonStyle(RouteCardStyle())
                        .accessibilityLabel("\(route.routeName), \(formatDistance(route.plannedDistanceMeters, unit: route.displayUnit)), \(transferLabel(route))")
                }
            }
        }
    }

    private func card(_ route: LoopPlanPayload) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(route.routeName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Image(systemName: route.activity == .running ? "figure.run" : "figure.walk")
                    Text(formatDistance(route.plannedDistanceMeters, unit: route.displayUnit))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                Text(transferLabel(route))
                    .font(.caption2)
                    .foregroundStyle(transferTint(route))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            status(route)
        }
    }

    @ViewBuilder
    private func status(_ route: LoopPlanPayload) -> some View {
        if maps.isReady(route) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.looperAccent)
        } else if maps.routeTransferStates[route.routeID] == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        } else {
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: maps.savedFractions[route.routeID] ?? 0)
                    .stroke(Color.looperAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
        }
    }

    private func transferLabel(_ route: LoopPlanPayload) -> String {
        let percent = Int((maps.savedFractions[route.routeID] ?? 0) * 100)
        switch maps.routeTransferStates[route.routeID] ?? .queued {
        case .queued: return "Waiting for iPhone"
        case .receiving: return "Receiving… \(percent)%"
        case .ready: return "Ready offline"
        case .failed: return "Download incomplete"
        }
    }

    private func transferTint(_ route: LoopPlanPayload) -> Color {
        switch maps.routeTransferStates[route.routeID] {
        case .ready: return Color.looperAccent
        case .failed: return .orange
        case .queued, .receiving, .none: return .secondary
        }
    }
}

/// A full-width rounded card, not the capsule watchOS gives a bare Button, so
/// two lines of name and a status line sit inside it without clipping.
private struct RouteCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Color.looperRaised.opacity(0.7) : Color.looperRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
