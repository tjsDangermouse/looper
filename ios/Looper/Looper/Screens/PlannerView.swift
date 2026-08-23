import LooperKit
import SwiftUI

private let findingMessages = ["Building clean loops around you…", "Checking for overlaps and detours…"]

struct PlannerView: View {
    @ObservedObject var model: AppModel
    @FocusState private var amountFocused: Bool

    var body: some View {
        BottomSheet {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Text("How far shall we Loop?")
                        .font(.title2.bold())
                    Spacer()
                    Button(action: model.requestLocation) {
                        Image(systemName: "location.fill")
                    }
                    .buttonStyle(IconButtonStyle(background: .looperRaised, bordered: true))
                    .accessibilityLabel("Use my location")
                }

                HStack(spacing: 12) {
                    Picker("Activity", selection: $model.activity) {
                        Label("Walk", systemImage: "figure.walk")
                            .labelStyle(.iconOnly)
                            .tag(Activity.walking)
                        Label("Run", systemImage: "figure.run")
                            .labelStyle(.iconOnly)
                            .tag(Activity.running)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)

                    Picker("Plan by", selection: $model.mode) {
                        Label("Distance", systemImage: "ruler")
                            .labelStyle(.iconOnly)
                            .tag(LoopMode.distance)
                        Label("Time", systemImage: "clock")
                            .labelStyle(.iconOnly)
                            .tag(LoopMode.time)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                }

                Text(model.mode == .distance ? "Your distance" : "Your time")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
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
                        .frame(width: 120)
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

                Button {
                    amountFocused = false
                    model.findRoutes()
                } label: {
                    Label(model.busy ? findingMessages[model.findingStage] : "Find my loops", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.busy)
            }
            .padding(.top, 4)
        }
    }
}
