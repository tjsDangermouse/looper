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
