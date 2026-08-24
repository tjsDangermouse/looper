import Foundation
import LooperKit

/// Persists the outing in progress, and the last one finished, so the Loop
/// Summary and the Apple Health save both work from durable data rather than
/// live app state. A walk can be backgrounded for an hour and the app killed
/// behind it; when it comes back the track, the timings and the Health save
/// state are all still there.
///
/// The record lives in a file rather than UserDefaults because a long outing's
/// track runs to thousands of fixes.
final class SessionStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// A fix arrives roughly once a second; rewriting a growing track that
    /// often would be pointless churn. Anything not yet flushed is at most
    /// this far behind, and ending a walk always flushes immediately.
    private static let flushInterval: TimeInterval = 15

    private var lastFlush = Date.distantPast

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Looper", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("loop-session.json") }

    /// Reads the stored session back. A save that was in flight when the app
    /// went away is reconciled to a retryable failure, since nothing is
    /// running any more to finish it.
    func load() -> LoopSessionRecord? {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? decoder.decode(LoopSessionRecord.self, from: data) else { return nil }
        return record.reconciledAfterRestore()
    }

    /// Writes at most every `flushInterval` seconds unless `immediately` is
    /// set — which it is for anything that must not be lost: starting,
    /// ending, and every change of Health save state.
    func save(_ record: LoopSessionRecord, immediately: Bool = false) {
        guard immediately || Date().timeIntervalSince(lastFlush) >= Self.flushInterval else { return }
        guard let data = try? encoder.encode(record) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            lastFlush = Date()
        } catch {
            // A failed write costs the walker their summary after a crash, but
            // must never interrupt the outing itself.
        }
    }

    func clear() {
        try? fileManager.removeItem(at: fileURL)
        lastFlush = .distantPast
    }
}
