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

                    MapReadiness(model: model, plan: plan)

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Whether the maps for the chosen route are on the Watch yet. Said plainly,
/// because the walk is where a missing map would otherwise show up.
private struct MapReadiness: View {
    @ObservedObject var model: WatchModel
    @ObservedObject private var maps: WatchNavigationMapCache
    let plan: LoopPlanPayload

    init(model: WatchModel, plan: LoopPlanPayload) {
        self.model = model
        self.plan = plan
        _maps = ObservedObject(wrappedValue: model.navigationMaps)
    }

    var body: some View {
        if maps.isReady(plan) {
            Label("Route maps saved on this Watch", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if maps.isPreparing {
            Label("Saving route maps — keep a connection until done", systemImage: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Label("Maps not saved yet — without a connection you'll see the route line only", systemImage: "map")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                        } else if maps.hasTurnMaps(route) {
                            Image(systemName: "map.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel("\(route.routeName), \(formatDistance(route.plannedDistanceMeters, unit: route.displayUnit))\(maps.hasTurnMaps(route) ? ", maps saved" : "")")
            }
        }
    }
}
