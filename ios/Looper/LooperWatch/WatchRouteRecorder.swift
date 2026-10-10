import CoreLocation
import Foundation

/// The Watch's own location feed, batched for the workout's route builder.
///
/// The route saved with the workout is the Watch's, not the phone's. The
/// phone's recorded track is what the Loop Summary draws, and HealthKit
/// offers no supported way for the phone to attach that track to a workout
/// the Watch owns — an iPhone `HKLiveWorkoutBuilder` needs iOS 26, and
/// finishing a route against another device's workout isn't something to
/// build a health record on. Streaming every fix to the wrist instead would
/// mean pushing the whole GPS track over a link meant for a few hundred bytes
/// a second. So the Watch records what the Watch can see.
final class WatchRouteRecorder: NSObject {
    private let manager = CLLocationManager()
    private var pending: [CLLocation] = []
    private var onBatch: (([CLLocation]) -> Void)?
    /// Every usable fix as it arrives, for following the route. Separate from
    /// the batches above, which are only for HealthKit.
    var onFix: ((CLLocation) -> Void)?
    /// Facts for the diagnostic log: authorization, start and stop, errors,
    /// and a periodic count of fixes received against fixes kept.
    var onDiagnostic: ((String, [String: String]) -> Void)?
    private var received = 0
    private var dropped = 0
    private var lastAccuracy: Double?
    private var lastSummaryAt = Date.distantPast
    private static let summaryInterval: TimeInterval = 30
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    /// Fixes are handed over in batches rather than one at a time; HealthKit
    /// would rather have a handful than a steady drip.
    private static let batchSize = 20

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
    }

    /// Resolves only after the location sheet has been answered. The launch
    /// gate awaits this before asking HealthKit anything, so watchOS never
    /// stacks two permission sheets over each other.
    func requestAuthorization() async -> CLAuthorizationStatus {
        let status = manager.authorizationStatus
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    var authorizationName: String { Self.name(manager.authorizationStatus) }

    private static func name(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default: return "unknown"
        }
    }

    func start(onBatch: (([CLLocation]) -> Void)? = nil) {
        self.onBatch = onBatch
        received = 0
        dropped = 0
        lastAccuracy = nil
        lastSummaryAt = Date()
        onDiagnostic?("location.start", [
            "authorization": Self.name(manager.authorizationStatus),
            "accuracyAuthorization": manager.accuracyAuthorization == .fullAccuracy ? "full" : "reduced",
            "locationServicesEnabled": String(CLLocationManager.locationServicesEnabled()),
            "buildsRoute": String(onBatch != nil)
        ])
        // `allowsBackgroundLocationUpdates` was tried here and reliably
        // crashed on a real Watch (`CLClientIsBackgroundable` false) even
        // with Always authorization confirmed granted in Settings. That flag
        // asks CoreLocation for *its own* background grant — the pairing of
        // Always authorization with the `location` background mode, for apps
        // whose only reason to run in the background is tracking location.
        // This app's reason is the workout: `HKWorkoutSession`'s
        // `workout-processing` background mode already keeps the process
        // (and the updates below) running for the life of the workout, a
        // window CoreLocation's own bookkeeping never gets told about. The
        // two mechanisms don't compose, and asking for the one this app
        // doesn't need is what was crashing it.
        manager.startUpdatingLocation()
    }

    func stop() {
        onDiagnostic?("location.stop", [
            "received": String(received), "dropped": String(dropped), "unflushed": String(pending.count)
        ])
        onBatch = nil
        manager.stopUpdatingLocation()
    }

    /// Everything collected but not yet handed over — called once, as the
    /// workout closes, so the last stretch isn't lost.
    func drain() -> [CLLocation] {
        defer { pending = [] }
        return pending
    }
}

extension WatchRouteRecorder: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onDiagnostic?("location.authorization", ["status": Self.name(manager.authorizationStatus)])
        guard manager.authorizationStatus != .notDetermined,
              let continuation = authorizationContinuation else { return }
        authorizationContinuation = nil
        continuation.resume(returning: manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The same standard the phone holds its own track to: a fix
        // CoreLocation couldn't place, or placed to within a hundred metres,
        // is not a point on anybody's route.
        let usable = locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 100 }
        received += locations.count
        dropped += locations.count - usable.count
        lastAccuracy = locations.last?.horizontalAccuracy
        if Date().timeIntervalSince(lastSummaryAt) >= Self.summaryInterval {
            lastSummaryAt = Date()
            onDiagnostic?("location.fixes", [
                "received": String(received), "dropped": String(dropped),
                "lastAccuracyM": lastAccuracy.map { String(format: "%.0f", $0) } ?? "none"
            ])
        }
        usable.forEach { onFix?($0) }
        // With no workout there is no route to build, and fixes are only for
        // following; nothing is held on to.
        guard onBatch != nil else { return }
        pending += usable
        guard pending.count >= Self.batchSize else { return }
        let batch = pending
        pending = []
        onBatch?(batch)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A workout with no map is still a workout; nothing here should
        // interrupt the recording — but it is written down.
        onDiagnostic?("location.failed", ["error": error.localizedDescription])
    }
}
