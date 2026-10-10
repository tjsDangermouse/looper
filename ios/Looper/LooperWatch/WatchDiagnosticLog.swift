import Foundation
import LooperKit

/// The Watch's own diagnostic record, kept on the wrist.
///
/// The phone's navigation log is where diagnostics are read, but it only hears
/// the Watch while the two are talking. A standalone walk — or any stretch out
/// of range — would otherwise leave nothing anywhere. Every event is written
/// here first; the ones the phone didn't hear live are handed over, once, the
/// next time it can be reached, and appear in the phone's export as `watch.*`.
@MainActor
final class WatchDiagnosticLog {
    private struct Entry: Codable {
        var payload: WatchDiagnosticPayload
        var delivered: Bool
    }

    /// Several hours of walking at the Watch's event rate.
    private static let maximumEntries = 4_000
    private static let chunkSize = 100

    private var entries: [Entry]
    private let fileURL: URL
    private var persistTask: Task<Void, Never>?

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = base.appendingPathComponent("watch-diagnostics.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
    }

    /// `delivered` is true when the event was just sent live to a reachable phone.
    func record(_ event: String, details: [String: String] = [:], delivered: Bool) {
        entries.append(Entry(payload: WatchDiagnosticPayload(event: event, details: details), delivered: delivered))
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        schedulePersist()
    }

    var hasUndelivered: Bool { entries.contains { !$0.delivered } }

    /// Undelivered events in wire-sized chunks. Call `markDelivered()` once
    /// they have been handed to the link.
    func undeliveredChunks() -> [[WatchDiagnosticPayload]] {
        let pending = entries.filter { !$0.delivered }.map(\.payload)
        return stride(from: 0, to: pending.count, by: Self.chunkSize).map {
            Array(pending[$0..<min($0 + Self.chunkSize, pending.count)])
        }
    }

    func markDelivered() {
        for index in entries.indices { entries[index].delivered = true }
        schedulePersist()
    }

    /// Writes soon, not on every event — fixes and route batches arrive often.
    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            persistTask = nil
            persistNow()
        }
    }

    func persistNow() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
