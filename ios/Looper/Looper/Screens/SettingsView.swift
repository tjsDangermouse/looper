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

                if NavigationLogger.includedInThisBuild || RoutingTrialLog.includedInThisBuild {
                    Section {
                        if NavigationLogger.includedInThisBuild {
                            NavigationLink {
                                NavigationDiagnosticsView(logger: model.navigationLogger)
                            } label: {
                                Label("Navigation diagnostics", systemImage: "waveform.path.ecg")
                            }
                        }
                        if RoutingTrialLog.includedInThisBuild {
                            Picker(selection: $model.routingMode) {
                                ForEach(RoutingEngine.allCases, id: \.self) { engine in
                                    Text(engine.title).tag(engine)
                                }
                            } label: {
                                Label("Routing engine", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            }
                            .pickerStyle(.inline)
                            NavigationLink {
                                RoutingTrialsView(log: model.routingTrials)
                            } label: {
                                Label("Routing engine trials", systemImage: "list.clipboard")
                            }
                            NavigationLink {
                                RoutingDataView(model: model)
                            } label: {
                                Label("Downloaded walking paths", systemImage: "arrow.down.circle")
                            }
                        }
                    } header: {
                        Text("Temporary testing")
                    } footer: {
                        Text("On-device finds the walk on this phone, using walking paths it downloads for the area and keeps. Waypoints work on both. A route screen says which engine actually answered.")
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

/// The routing-engine trial list, for field testing. Same shape as the
/// navigation diagnostics above it: everything is on this device until the
/// tester shares it, and the whole section disappears with
/// `RoutingTrialLog.includedInThisBuild`.
private struct RoutingTrialsView: View {
    @ObservedObject var log: RoutingTrialLog
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share results", systemImage: "square.and.arrow.up")
                    }
                }
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("One row per set of loops offered: which engine answered, how long it took, what it offered, and how you rated it.")
            }

            ForEach(log.trials.reversed()) { trial in
                NavigationLink {
                    RoutingTrialRatingView(log: log, trial: trial)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(trial.routingEngine.uppercased())
                                .font(.caption.weight(.bold))
                            Spacer()
                            if let verdict = trial.verdict {
                                Text(verdict.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("\(trial.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(trial.offeredMetres.count) loop\(trial.offeredMetres.count == 1 ? "" : "s") · \(Int(trial.generationMs)) ms")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !log.trials.isEmpty {
                Section {
                    Button("Clear trial results", role: .destructive) {
                        log.clear()
                        refreshExport()
                    }
                }
            }
        }
        .navigationTitle("Routing engine trials")
        .overlay {
            if log.trials.isEmpty {
                ContentUnavailableView("No trials yet", systemImage: "list.clipboard",
                                       description: Text("Find some loops and they will be recorded here."))
            }
        }
        .onAppear(perform: refreshExport)
        .onChange(of: log.trials.count) { _, _ in refreshExport() }
    }

    private var summary: String {
        let local = log.trials.filter { $0.routingEngine == RoutingEngine.onDevice.rawValue }.count
        // Historical "direct" rows were also produced by the remote service.
        let remote = log.trials.count - local
        return "\(log.trials.count) recorded · \(local) on-device · \(remote) remote"
    }

    private func refreshExport() {
        exportURL = log.makeExport()
    }
}

/// A verdict and, optionally, what was wrong with it. Deliberately three taps
/// at most: a rating nobody fills in on a wet hillside measures nothing.
private struct RoutingTrialRatingView: View {
    @ObservedObject var log: RoutingTrialLog
    let trial: RoutingTrialLog.Trial
    @State private var verdict: RoutingTrialLog.Verdict?
    @State private var issues: Set<RoutingTrialLog.Issue> = []
    @State private var note = ""

    var body: some View {
        List {
            Section("Route test") {
                Picker("Verdict", selection: $verdict) {
                    Text("Not rated").tag(RoutingTrialLog.Verdict?.none)
                    ForEach(RoutingTrialLog.Verdict.allCases) { value in
                        Text(value.title).tag(RoutingTrialLog.Verdict?.some(value))
                    }
                }
                .pickerStyle(.inline)
            }

            Section("What was wrong") {
                ForEach(RoutingTrialLog.Issue.allCases) { issue in
                    Button {
                        if issues.contains(issue) { issues.remove(issue) } else { issues.insert(issue) }
                    } label: {
                        HStack {
                            Text(issue.title)
                            Spacer()
                            if issues.contains(issue) { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Note") {
                TextField("Anything else", text: $note, axis: .vertical)
            }

            Section("What was generated") {
                LabeledContent("Engine", value: trial.routingEngine)
                LabeledContent("Asked for", value: "\(Int(trial.requestedMetres)) m")
                LabeledContent("Offered", value: trial.offeredMetres.map { "\(Int($0))" }.joined(separator: ", "))
                LabeledContent("Round trip", value: "\(Int(trial.generationMs)) ms")
                if let searchMs = trial.searchMs { LabeledContent("Search", value: String(format: "%.0f ms", searchMs)) }
                if let closed = trial.searchClosedWalks { LabeledContent("Closed walks", value: String(closed)) }
            }
        }
        .navigationTitle("Rate this test")
        .onAppear {
            verdict = trial.verdict
            issues = Set(trial.issues ?? [])
            note = trial.note ?? ""
        }
        .onDisappear {
            log.rate(trialID: trial.id, verdict: verdict, issues: Array(issues), note: note)
        }
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


/// What routing data the phone is holding, and what the last local search
/// cost. The whole point of the architecture is that these are small numbers,
/// so they are worth being able to read on the device rather than inferring
/// from a log afterwards.
private struct RoutingDataView: View {
    @ObservedObject var model: AppModel
    @State private var summary: AppModel.RoutingDataSummary?
    @State private var clearing = false

    var body: some View {
        List {
            Section {
                if let summary {
                    LabeledContent("Areas stored", value: "\(summary.chunkCount)")
                    LabeledContent("Kept for offline", value: "\(summary.pinnedCount)")
                    LabeledContent("On this phone", value: summary.formattedBytes)
                } else {
                    Text("Reading…").foregroundStyle(.secondary)
                }
            } header: {
                Text("Walking paths")
            } footer: {
                Text("Downloaded automatically for the areas you ask for loops in, and reused afterwards. Clearing them costs nothing but a download the next time you walk there.")
            }

            if let diagnostics = model.localDiagnostics {
                Section("Last on-device search") {
                    LabeledContent("Graph", value: "\(diagnostics.graphNodes) nodes, \(diagnostics.graphEdges) edges")
                    LabeledContent("Explored", value: "\(diagnostics.exploration.nodesReached) nodes, \(diagnostics.exploration.edgesReached) edges")
                    LabeledContent("Snapped", value: String(format: "%.0f m away", diagnostics.exploration.snapDistanceMetres))
                    LabeledContent("Reduced to", value: "\(diagnostics.searchGraph.superEdges) super-edges")
                    LabeledContent("Closed walks", value: "\(diagnostics.closedWalks)")
                    if diagnostics.stemMetres > 0 {
                        LabeledContent("Stem to the circuit", value: String(format: "%.0f m", diagnostics.stemMetres))
                    }
                    LabeledContent("Passed the gate", value: "\(diagnostics.passedGate) of \(diagnostics.passedGate + diagnostics.gateRejected)")
                    if !diagnostics.gateRejectionsByReason.isEmpty {
                        LabeledContent("Refused for", value: diagnostics.gateRejectionsByReason
                            .sorted { $0.value > $1.value }
                            .map { "\($0.key) \($0.value)" }
                            .joined(separator: ", "))
                    }
                    // The number that says whether the shortage is quality or
                    // sameness. A large count here with nothing refused by the
                    // gate means the search found plenty of good walks and
                    // they were all the same walk.
                    LabeledContent("Too alike to offer", value: "\(diagnostics.diversityRejected)")
                    if diagnostics.excludedAsAlreadySeen > 0 || diagnostics.excludeExhausted {
                        LabeledContent(
                            "Already seen",
                            value: diagnostics.excludeExhausted
                                ? "\(diagnostics.excludedAsAlreadySeen) — all of them"
                                : "\(diagnostics.excludedAsAlreadySeen)"
                        )
                    }
                    LabeledContent("Compass spread", value: "\(diagnostics.shortlistOctants) of 8 octants")
                    LabeledContent("Offered", value: "\(diagnostics.offered)")
                    LabeledContent("Search", value: String(format: "%.0f ms", diagnostics.search.searchMs))
                    LabeledContent("Total", value: String(format: "%.0f ms", diagnostics.totalMs))
                    if let failure = diagnostics.failure { LabeledContent("Stopped on", value: failure) }
                }
            }

            Section {
                Button("Clear downloaded paths", role: .destructive) {
                    clearing = true
                    Task {
                        await model.clearRoutingData()
                        summary = await model.routingDataSummary()
                        clearing = false
                    }
                }
                .disabled(clearing)
            }
        }
        .navigationTitle("Downloaded walking paths")
        .task { summary = await model.routingDataSummary() }
    }
}
