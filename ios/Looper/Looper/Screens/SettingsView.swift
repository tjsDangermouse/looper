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
