import LooperKit
import SwiftUI
import UIKit

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

                if NavigationLogger.includedInThisBuild {
                    Section {
                        NavigationLink {
                            NavigationDiagnosticsView(logger: model.navigationLogger)
                        } label: {
                            Label("Navigation diagnostics", systemImage: "waveform.path.ecg")
                        }
                    } header: {
                        Text("Temporary testing")
                    } footer: {
                        Text("Export a local record of GPS progress and spoken guidance to help investigate navigation issues.")
                    }
                }

                Section {
                    AppleHealthRow(health: model.health)
                    AppleWatchRow(watch: model.watch)
                } header: {
                    Text("Integrations")
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
            .task { await model.health.refreshAvailability() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Intentionally only reachable while the temporary navigation logger is
/// included in the app. Sharing uses the standard iOS sheet, so Mail,
/// Messages, Files, and any installed bug-reporting app can receive the
/// plain-text file without the app needing an account or network access.
private struct NavigationDiagnosticsView: View {
    @ObservedObject var logger: NavigationLogger
    @State private var exportURL: URL?
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Toggle("Record navigation events", isOn: $logger.isRecordingEnabled)
                Text("\(logger.entryCount) event\(logger.entryCount == 1 ? "" : "s") saved on this device")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("The log includes the complete selected-route geometry, its turn steps and positions, location fixes, route-progress calculations, and speech events. It stays on this device until you share it.")
            }

            Section("Export") {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share text file", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        if let text = try? String(contentsOf: exportURL, encoding: .utf8) {
                            UIPasteboard.general.string = text
                            copied = true
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy to clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } else {
                    Text("No log file could be prepared.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Clear saved diagnostics", role: .destructive) {
                    logger.clear()
                    refreshExport()
                }
            }
        }
        .navigationTitle("Navigation diagnostics")
        .onAppear(perform: refreshExport)
        .onChange(of: logger.entryCount) { _, _ in refreshExport() }
    }

    private func refreshExport() {
        exportURL = logger.makeExport()
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


/// The Apple Watch line. Read-only: there is nothing to switch on, because
/// the Watch app is either installed or it isn't, and permission is asked on
/// the wrist at the moment it's needed rather than here.
private struct AppleWatchRow: View {
    @ObservedObject var watch: WatchCompanion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Apple Watch", systemImage: "applewatch")
                    .font(.body.weight(.semibold))
                Spacer()
                Text(watch.isPairedWithApp ? "Ready" : "Not installed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apple Watch. \(subtitle)")
    }

    private var subtitle: String {
        watch.isPairedWithApp
            ? "Start a loop and your Watch records it, with your heart rate. Looper saves one workout, not two."
            : "Install Looper on your Apple Watch to record loops from your wrist."
    }
}

/// Apple Health in the Integrations list. The explanation sits above the
/// switch, so the reason for the system permission sheet is clear before it
/// appears — and the naming stays plain, without dressing the app up as
/// something Apple made.
private struct AppleHealthRow: View {
    @ObservedObject var health: HealthIntegration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Apple Health", systemImage: "heart.text.square")
                    .font(.body.weight(.semibold))
                Spacer()
                control
            }
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Apple Health. \(subtitle)")
    }

    @ViewBuilder
    private var control: some View {
        switch health.availability {
        case .unavailable:
            Text("Unavailable")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .denied:
            Button("Open Settings") { health.openSystemSettings() }
                .buttonStyle(.borderless)
                .font(.footnote.weight(.semibold))
        case .notDetermined, .authorized:
            if health.isRequesting {
                ProgressView()
            } else {
                Toggle("Apple Health", isOn: Binding(
                    get: { health.isEnabled },
                    set: { wanted in
                        if wanted {
                            Task { await health.enable() }
                        } else {
                            health.disable()
                        }
                    }
                ))
                .labelsHidden()
                .tint(Color.looperAccent)
            }
        }
    }

    private var subtitle: String {
        switch health.availability {
        case .unavailable:
            return "Apple Health isn’t available on this device."
        case .denied:
            return "Looper was declined permission to add workouts. You can allow it under Privacy & Security in Settings."
        case .notDetermined, .authorized:
            return health.isEnabled
                ? "Completed loops are saved to Apple Health"
                : "Save completed walks and runs to Apple Health"
        }
    }
}
