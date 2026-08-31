import LooperKit
import SwiftUI

struct PlannerView: View {
    @ObservedObject var model: AppModel
    @FocusState private var amountFocused: Bool

    var body: some View {
        BottomSheet {
            VStack(alignment: .leading, spacing: 8) {
                // "Use my location" recentres the map, so it lives on the
                // map itself (ContentView's chrome) rather than in here.
                Text("How far shall we Loop?")
                    .font(.system(size: 17, weight: .bold))

                HStack(spacing: 8) {
                    Picker("Activity", selection: $model.activity) {
                        Label("Walk", systemImage: "figure.walk")
                            .labelStyle(.iconOnly)
                            .tag(Activity.walking)
                        Label("Run", systemImage: "figure.run")
                            .labelStyle(.iconOnly)
                            .tag(Activity.running)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)

                    Picker("Plan by", selection: $model.mode) {
                        Label("Distance", systemImage: "ruler")
                            .labelStyle(.iconOnly)
                            .tag(LoopMode.distance)
                        Label("Time", systemImage: "clock")
                            .labelStyle(.iconOnly)
                            .tag(LoopMode.time)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }

                Text(model.mode == .distance ? "Your distance" : "Your time")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField(model.mode == .distance ? "Distance" : "Minutes", text: $model.amount)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .focused($amountFocused)

                    if model.mode == .distance {
                        Picker("Unit", selection: $model.unit) {
                            Text("km").tag(LooperKit.Unit.km)
                            Text("mi").tag(LooperKit.Unit.mi)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 96)
                    } else {
                        Text("minutes").foregroundStyle(.secondary)
                    }
                }

                if !model.error.isEmpty {
                    Text(model.error).font(.footnote).foregroundStyle(.orange)
                } else {
                    Text(model.mode == .distance
                        ? "Enter any distance from 1–20 \(model.unit.rawValue)"
                        : "Enter any time from 15 minutes to 4 hours")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                WaypointHint(model: model)

                Button {
                    amountFocused = false
                    model.findRoutes()
                } label: {
                    Label(model.busy ? model.findingMessage : "Find my loops", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(height: 44, cornerRadius: 12, fontSize: 15))
                .disabled(model.busy)
            }
            .padding(.top, 2)
        }
    }
}

struct WaypointHint: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(.blue)
            Text(model.waypoints.isEmpty
                 ? "Long-press the map to add up to \(AppModel.waypointLimit) waypoints"
                 : "\(model.waypoints.count) of \(AppModel.waypointLimit) waypoints added")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if !model.waypoints.isEmpty {
                Button("Clear", action: model.clearWaypoints)
                    .font(.footnote.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
