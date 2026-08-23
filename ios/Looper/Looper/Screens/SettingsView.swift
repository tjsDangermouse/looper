import LooperKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        VoiceGuidanceSettingsView(model: model)
                    } label: {
                        Label("Voice guidance", systemImage: "speaker.wave.2")
                    }
                } header: {
                    Text("Preferences")
                }

                Section {
                    NavigationLink {
                        FavoriteRoutesView(model: model)
                    } label: {
                        Label("Saved routes", systemImage: "heart")
                    }
                } footer: {
                    Text("Save a route from your choices to keep it here for later.")
                }

                Section {
                    TextField("Pace", value: $model.walkingPaceMinutes, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    Picker("Unit", selection: Binding(
                        get: { model.walkingPaceUnit },
                        set: { model.setWalkingPaceUnit($0) }
                    )) {
                        Text("minutes per km").tag(LooperKit.Unit.km)
                        Text("minutes per mile").tag(LooperKit.Unit.mi)
                    }
                } header: {
                    Text("Walking pace")
                } footer: {
                    Text("Used to choose the length of time-based loops and estimate time remaining.")
                }

                Section {
                    TextField("Pace", value: $model.runningPaceMinutes, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    Picker("Unit", selection: Binding(
                        get: { model.runningPaceUnit },
                        set: { model.setRunningPaceUnit($0) }
                    )) {
                        Text("minutes per km").tag(LooperKit.Unit.km)
                        Text("minutes per mile").tag(LooperKit.Unit.mi)
                    }
                } header: {
                    Text("Running pace")
                } footer: {
                    Text("Used when you choose Run while planning a route.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FavoriteRoutesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            if model.favoriteRoutes.isEmpty {
                ContentUnavailableView(
                    "No saved routes",
                    systemImage: "heart",
                    description: Text("Tap the heart on a route to save it for later.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(model.favoriteRoutes, id: \.id) { route in
                    Button {
                        model.openFavorite(route)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(route.name).font(.headline)
                            Text("\(formatDistance(route.distanceMeters, unit: model.unit)) · \(formatTime(secondsForDistance(route.distanceMeters, paceMinutesPerKm: model.activePaceMinutesPerKm)))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open this saved route")
                }
                .onDelete { offsets in
                    for index in offsets.reversed() {
                        model.toggleFavorite(model.favoriteRoutes[index])
                    }
                }
            }
        }
        .navigationTitle("Saved routes")
    }
}
