import AVFoundation
import SwiftUI

struct VoiceGuidanceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the voice used for spoken turn instructions.")
                    Text("Looper defaults to the highest-quality installed British English voice. Premium and enhanced voices appear after they are downloaded in iOS Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Voice guidance")
                }

                if !model.hasPremiumEnglishVoice {
                    Section {
                        Label("No Premium English voice is installed", systemImage: "arrow.down.circle")
                            .foregroundStyle(.orange)
                        Text("For more natural offline guidance, download one in Settings → Accessibility → Read & Speak → Voices → English. Looper will use it automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Better offline voice")
                    }
                }

                if model.englishVoices.isEmpty {
                    ContentUnavailableView("No English voices available", systemImage: "speaker.slash")
                } else {
                    ForEach(model.englishVoices, id: \.identifier) { voice in
                        HStack(spacing: 12) {
                            Button {
                                model.selectVoice(voice)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(voice.name)
                                        .foregroundStyle(.primary)
                                    Text("\(localeName(for: voice)) · \(model.voiceQualityName(for: voice))")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selectedVoiceIdentifier == voice.identifier {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: "9cc36b"))
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                model.previewVoice(voice)
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Preview \(voice.name)")
                        }
                    }
                }
            }
            .navigationTitle("Voice guidance")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func localeName(for voice: AVSpeechSynthesisVoice) -> String {
        Locale(identifier: voice.language).localizedString(forIdentifier: voice.language) ?? voice.language
    }
}
