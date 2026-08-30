import Foundation
import LooperKit

/// On-device record of routing-engine trials, for field testing the direct
/// closed-walk search against the current engine.
///
/// Deliberately the same shape as `NavigationLogger`: a small JSON file in
/// Application Support, a plain-text export the tester shares from Settings
/// with the standard iOS sheet, and nothing that leaves the device unless they
/// choose to send it. There is no analytics backend here and this is not the
/// place to grow one — the whole question this answers is "which engine drew
/// the walk I have just been on, and was it any good", and that is a handful
/// of numbers per generation plus a word afterwards.
///
/// Set `includedInThisBuild` to false to take the whole feature out of a
/// release build; the Settings section disappears with it.
@MainActor
final class RoutingTrialLog: ObservableObject {
    static let shared = RoutingTrialLog()
    static let includedInThisBuild = true

    /// What a tester thought of a set of walks, afterwards.
    enum Verdict: String, Codable, CaseIterable, Identifiable {
        case good
        case acceptable
        case bad

        var id: String { rawValue }
        var title: String {
            switch self {
            case .good: return "Good"
            case .acceptable: return "Acceptable"
            case .bad: return "Bad"
            }
        }
    }

    /// Why, when it was not good. Multiple may apply.
    enum Issue: String, Codable, CaseIterable, Identifiable {
        case distanceWrong = "distance wrong"
        case poorShape = "poor shape"
        case unpleasantPath = "unpleasant path"
        case retracing = "retracing"
        case navigation = "navigation/instruction issue"
        case notDifferent = "not meaningfully different"
        case other = "other"

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    struct Trial: Codable, Identifiable {
        var id: String
        var timestamp: Date
        var routingEngine: String
        var requestedEngine: String?
        var engineReason: String?
        var fallbackReason: String?
        var requestedMetres: Double
        var mode: String
        var activity: String
        /// Distances of every route offered, in the order they were offered.
        var offeredMetres: [Double]
        var generationMs: Double
        var serviceGenerationMs: Double?
        var searchMs: Double?
        var searchClosedWalks: Int?
        var hadWaypoints: Bool
        /// Rounded to about a hundred metres: enough to tell Peel from Onchan,
        /// not enough to be a record of anyone's front door.
        var startLat: Double
        var startLng: Double
        var selectedRouteIndex: Int?
        var verdict: Verdict?
        var issues: [Issue]?
        var note: String?
    }

    @Published private(set) var trials: [Trial] = []

    private static let maximumTrials = 300
    private let fileURL: URL
    private let encoder = JSONEncoder()

    private init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Looper", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("routing-trials.json")
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL), let saved = try? decoder.decode([Trial].self, from: data) {
            trials = saved
        }
    }

    /// One generation, recorded the moment its answer arrives.
    @discardableResult
    func record(
        engine: RoutingEngineReport?,
        selectedEngine: RoutingEngine,
        requestedMetres: Double,
        mode: LoopMode,
        activity: Activity,
        start: Point,
        hadWaypoints: Bool,
        routes: [Route],
        generationMs: Double
    ) -> Trial? {
        guard Self.includedInThisBuild else { return nil }
        let trial = Trial(
            id: UUID().uuidString,
            timestamp: Date(),
            routingEngine: (engine?.routingEngine ?? selectedEngine).rawValue,
            requestedEngine: (engine?.requestedEngine ?? selectedEngine).rawValue,
            engineReason: engine?.engineReason,
            fallbackReason: engine?.fallbackReason,
            requestedMetres: requestedMetres,
            mode: mode.rawValue,
            activity: activity.rawValue,
            offeredMetres: routes.map(\.distanceMeters),
            generationMs: generationMs,
            serviceGenerationMs: engine?.generationMs,
            searchMs: engine?.searchMs,
            searchClosedWalks: engine?.searchClosedWalks,
            hadWaypoints: hadWaypoints,
            startLat: (start.lat * 1000).rounded() / 1000,
            startLng: (start.lng * 1000).rounded() / 1000,
            selectedRouteIndex: routes.isEmpty ? nil : 0,
            verdict: nil,
            issues: nil,
            note: nil
        )
        trials.append(trial)
        if trials.count > Self.maximumTrials { trials.removeFirst(trials.count - Self.maximumTrials) }
        persist()
        return trial
    }

    /// Which of the offered walks the tester actually chose.
    func recordSelection(trialID: String?, index: Int) {
        guard let trialID, let at = trials.firstIndex(where: { $0.id == trialID }) else { return }
        trials[at].selectedRouteIndex = index
        persist()
    }

    func rate(trialID: String, verdict: Verdict?, issues: [Issue], note: String?) {
        guard let at = trials.firstIndex(where: { $0.id == trialID }) else { return }
        trials[at].verdict = verdict
        trials[at].issues = issues.isEmpty ? nil : issues
        trials[at].note = (note?.isEmpty ?? true) ? nil : note
        persist()
    }

    func clear() {
        trials.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// One row per trial, tab-separated, with a header. Small enough to paste
    /// into a message and regular enough to load into a spreadsheet.
    func makeExport() -> URL? {
        let header = [
            "timestamp", "engine", "requested", "reason", "fallback", "mode", "activity",
            "requestedMetres", "offeredCount", "offeredMetres", "appMs", "serviceMs",
            "searchMs", "closedWalks", "waypoints", "startLat", "startLng",
            "selectedIndex", "verdict", "issues", "note",
        ].joined(separator: "\t")
        let text = ([header] + trials.map(Self.row(for:))).joined(separator: "\n") + "\n"
        let exportURL = fileURL.deletingLastPathComponent().appendingPathComponent("looper-routing-trials.tsv")
        do {
            try text.write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            return nil
        }
    }

    private static func row(for trial: Trial) -> String {
        let formatter = ISO8601DateFormatter()
        var fields: [String] = []
        fields.append(formatter.string(from: trial.timestamp))
        fields.append(trial.routingEngine)
        fields.append(trial.requestedEngine ?? "")
        fields.append(trial.engineReason ?? "")
        fields.append(trial.fallbackReason ?? "")
        fields.append(trial.mode)
        fields.append(trial.activity)
        fields.append(String(format: "%.0f", trial.requestedMetres))
        fields.append(String(trial.offeredMetres.count))
        fields.append(trial.offeredMetres.map { String(format: "%.0f", $0) }.joined(separator: ","))
        fields.append(String(format: "%.0f", trial.generationMs))
        fields.append(trial.serviceGenerationMs.map { String(format: "%.0f", $0) } ?? "")
        fields.append(trial.searchMs.map { String(format: "%.1f", $0) } ?? "")
        fields.append(trial.searchClosedWalks.map(String.init) ?? "")
        fields.append(trial.hadWaypoints ? "yes" : "no")
        fields.append(String(format: "%.3f", trial.startLat))
        fields.append(String(format: "%.3f", trial.startLng))
        fields.append(trial.selectedRouteIndex.map(String.init) ?? "")
        fields.append(trial.verdict?.rawValue ?? "")
        fields.append((trial.issues ?? []).map(\.rawValue).joined(separator: ";"))
        fields.append((trial.note ?? "").replacingOccurrences(of: "\t", with: " "))
        return fields.joined(separator: "\t")
    }

    private func persist() {
        guard let data = try? encoder.encode(trials) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
