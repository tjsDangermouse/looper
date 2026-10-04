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

                if let notice = model.notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SavedRoutesList(model: model)

                // For testing: act as if the phone were out of range.
                Toggle(isOn: $model.standaloneForced) {
                    Label("Standalone", systemImage: "iphone.slash")
                        .font(.caption2)
                }
                .tint(Color.looperAccent)
                .padding(.top, 8)
                if model.standaloneForced {
                    Text("Ignoring the iPhone. Routes already on this Watch still work.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// Maps are only sent for a saved route or once a walk starts; a route
    /// just being looked at on the phone is waiting, not failing.
    private var waiting: Bool { !ready && !maps.isPreparing && !model.isSaved(plan) }

    private var tint: Color {
        if waiting { return .secondary }
        return ready || maps.isPreparing ? Color.looperAccent : .orange
    }

    private var title: String {
        if ready { return "Ready to walk" }
        if maps.isPreparing { return maps.receivingFromPhone ? "Sending from iPhone" : "Downloading maps" }
        return waiting ? "Maps not sent yet" : "Not all here yet"
    }

    private var detail: String {
        let count = "\(counts.saved) of \(counts.total) maps"
        if ready { return "Route and maps are on this Watch" }
        if maps.isPreparing {
            return maps.receivingFromPhone ? "\(count) — keep your iPhone near" : "\(count) — keep a connection"
        }
        if waiting { return "Sent when you start, or save the route on your iPhone" }
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
            Text("Saved routes")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            ForEach(model.savedRoutes, id: \.routeID) { route in
                Button { model.choose(route) } label: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(route.routeName)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            Text(formatDistance(route.plannedDistanceMeters, unit: route.displayUnit))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if model.plan?.routeID == route.routeID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.looperAccent)
                        } else if maps.isReady(route) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(Color.looperAccent)
                        } else {
                            // Filling in from the iPhone behind the chosen route.
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.18), lineWidth: 2.5)
                                Circle()
                                    .trim(from: 0, to: maps.savedFractions[route.routeID] ?? 0)
                                    .stroke(Color.looperAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 14, height: 14)
                        }
                    }
                }
                .accessibilityLabel("\(route.routeName), \(formatDistance(route.plannedDistanceMeters, unit: route.displayUnit)), \(maps.isReady(route) ? "ready on this Watch" : "\(Int((maps.savedFractions[route.routeID] ?? 0) * 100)) percent sent")")
            }
        }
    }
}
