import Foundation
import LooperKit

/// Temporary, on-device diagnostics for navigation and voice guidance.
/// Set `includedInThisBuild` to false (or remove this type) before the public
/// release. The export deliberately stays local until the walker chooses to
/// share it from Settings.
@MainActor
final class NavigationLogger: ObservableObject {
    static let shared = NavigationLogger()
    static let includedInThisBuild = true

    struct Entry: Codable {
        let timestamp: Date
        let event: String
        let details: [String: String]
    }

    /// Kept independently of the rolling event list. A long walk may exhaust
    /// the latter before it is exported, but a diagnosis still needs the exact
    /// route the walker was asked to follow.
    private struct RouteSnapshot: Codable {
        struct Coordinate: Codable {
            let longitude: Double
            let latitude: Double
        }

        struct StepSnapshot: Codable {
            let index: Int
            let instruction: String
            let road: String?
            let maneuver: String?
            let distanceMeters: Double
            let cumulativeStartMeters: Double
            let cumulativeEndMeters: Double
            let startCoordinateIndex: Int?
            let endCoordinateIndex: Int?
        }

        let capturedAt: Date
        let sessionID: String
        let routeID: String
        let routeName: String
        let routeWasReversed: Bool
        let activity: String
        let navigationUnit: String
        let advertisedDistanceMeters: Double
        let geometryDistanceMeters: Double
        let coordinates: [Coordinate]
        let steps: [StepSnapshot]
    }

    @Published private(set) var entryCount = 0
    @Published var isRecordingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isRecordingEnabled, forKey: recordingKey)
            if isRecordingEnabled { log("diagnostics.enabled") }
        }
    }

    private static let maximumEntries = 1_500
    private let recordingKey = "navigation-diagnostics-enabled"
    private let fileURL: URL
    private let routeSnapshotURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var entries: [Entry]
    private var routeSnapshot: RouteSnapshot?

    private init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Looper", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("navigation-diagnostics.json")
        routeSnapshotURL = directory.appendingPathComponent("navigation-route-snapshot.json")
        if let data = try? Data(contentsOf: fileURL),
           let savedEntries = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = savedEntries
        } else {
            entries = []
        }
        routeSnapshot = (try? Data(contentsOf: routeSnapshotURL)).flatMap { try? JSONDecoder().decode(RouteSnapshot.self, from: $0) }
        entryCount = entries.count
        isRecordingEnabled = Self.includedInThisBuild && (UserDefaults.standard.object(forKey: recordingKey) as? Bool ?? true)
        if Self.includedInThisBuild { log("diagnostics.launched") }
    }

    func log(_ event: String, details: [String: String] = [:]) {
        guard Self.includedInThisBuild, isRecordingEnabled else { return }
        entries.append(Entry(timestamp: Date(), event: event, details: details))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        entryCount = entries.count
        persist()
    }

    func clear() {
        entries.removeAll()
        entryCount = 0
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: routeSnapshotURL)
        routeSnapshot = nil
        log("diagnostics.cleared")
    }

    /// Saves the selected route as it existed when navigation began: source
    /// geometry, the exact step order and both cumulative step boundaries.
    /// This lets a later export answer whether a call-out named the correct
    /// junction, even if the event ring buffer has rolled over.
    func recordRoute(_ route: Route, sessionID: String, activity: Activity, unit: LooperKit.Unit) {
        guard Self.includedInThisBuild, isRecordingEnabled else { return }
        var cumulative = 0.0
        let steps = route.steps.enumerated().map { index, step in
            defer { cumulative += step.distanceMeters }
            return RouteSnapshot.StepSnapshot(
                index: index,
                instruction: step.instruction,
                road: step.road,
                maneuver: maneuverName(step.maneuver),
                distanceMeters: step.distanceMeters,
                cumulativeStartMeters: cumulative,
                cumulativeEndMeters: cumulative + step.distanceMeters,
                startCoordinateIndex: step.startIndex,
                endCoordinateIndex: step.endIndex
            )
        }
        let coordinates = route.geometry.coordinates.map {
            RouteSnapshot.Coordinate(longitude: $0.lng, latitude: $0.lat)
        }
        routeSnapshot = RouteSnapshot(
            capturedAt: Date(),
            sessionID: sessionID,
            routeID: route.id,
            routeName: route.name,
            routeWasReversed: route.reversed ?? false,
            activity: activity.rawValue,
            navigationUnit: unit.rawValue,
            advertisedDistanceMeters: route.distanceMeters,
            geometryDistanceMeters: geometryDistance(route.geometry.coordinates),
            coordinates: coordinates,
            steps: steps
        )
        persistRouteSnapshot()
        log("route.snapshotSaved", details: [
            "routeID": route.id,
            "coordinates": String(coordinates.count),
            "steps": String(steps.count),
            "geometryDistanceM": String(format: "%.1f", geometryDistance(route.geometry.coordinates))
        ])
    }

    /// Produces a plain-text file suitable for Mail, Files, Messages, or
    /// pasting into a bug report. Values are quoted so spoken text remains
    /// unambiguous even when it contains spaces.
    func makeExport() -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [
            "Looper navigation diagnostics",
            "Generated: \(formatter.string(from: Date()))",
            "Entries: \(entries.count)",
            ""
        ]
        if let routeSnapshot, let routeJSON = formattedRouteSnapshot(routeSnapshot) {
            lines += ["ROUTE SNAPSHOT (JSON)", routeJSON, "END ROUTE SNAPSHOT", ""]
        } else {
            lines += ["ROUTE SNAPSHOT: none captured", ""]
        }
        lines.append("EVENTS")
        lines += entries.map { entry in
            let fields = entry.details.keys.sorted().map { key in
                "\(key)=\(Self.quoted(entry.details[key] ?? ""))"
            }.joined(separator: " ")
            return "\(formatter.string(from: entry.timestamp)) \(entry.event)\(fields.isEmpty ? "" : " \(fields)")"
        }
        let exportURL = fileURL.deletingLastPathComponent().appendingPathComponent("looper-navigation-diagnostics.txt")
        do {
            try lines.joined(separator: "\n").appending("\n").write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            return nil
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func persistRouteSnapshot() {
        guard let routeSnapshot, let data = try? encoder.encode(routeSnapshot) else { return }
        try? data.write(to: routeSnapshotURL, options: .atomic)
    }

    private func formattedRouteSnapshot(_ snapshot: RouteSnapshot) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func geometryDistance(_ coordinates: [Point]) -> Double {
        guard coordinates.count > 1 else { return 0 }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + haversine($1.0, $1.1) }
    }

    private func maneuverName(_ maneuver: Maneuver?) -> String? {
        switch maneuver {
        case .code(let value): return "code:\(value)"
        case .name(let value): return value
        case nil: return nil
        }
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
