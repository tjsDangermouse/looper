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
    /// Fixes are handed over in batches rather than one at a time; HealthKit
    /// would rather have a handful than a steady drip.
    private static let batchSize = 20

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
    }

    func start(onBatch: @escaping ([CLLocation]) -> Void) {
        self.onBatch = onBatch
        // Authorization is granted asynchronously — on the very first workout
        // after install, the status is still `.notDetermined` the instant
        // this call returns. Claiming background updates before CoreLocation
        // has actually authorized the app is the same hard exception as
        // claiming them with no background mode declared, so starting is
        // split off and only run once authorization is settled.
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdating()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    private func beginUpdating() {
        #if targetEnvironment(simulator)
        // The watchOS Simulator doesn't grant `CLClientIsBackgroundable`
        // regardless of the background mode declared or the workout
        // session's state — Apple's own daemons refuse it there in a way
        // that doesn't reproduce on a real Watch, and `NSInternalInconsistencyException`
        // from a hard `false` assertion can't be caught. It's also not
        // needed in the Simulator: nothing suspends this process the way a
        // real device would. So background updates are only claimed on
        // an actual Watch.
        #else
        // Claiming background updates without the matching background mode
        // declared is a hard exception, and a crash at the moment a workout
        // starts is the worst failure this app could have. So the bundle is
        // asked what it actually declares rather than assumed.
        let modes = Bundle.main.object(forInfoDictionaryKey: "WKBackgroundModes") as? [String] ?? []
        if modes.contains("location") { manager.allowsBackgroundLocationUpdates = true }
        #endif
        manager.startUpdatingLocation()
    }

    func stop() {
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
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The same standard the phone holds its own track to: a fix
        // CoreLocation couldn't place, or placed to within a hundred metres,
        // is not a point on anybody's route.
        pending += locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= 100 }
        guard pending.count >= Self.batchSize else { return }
        let batch = pending
        pending = []
        onBatch?(batch)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A workout with no map is still a workout; nothing here should
        // interrupt the recording.
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Only fires mid-workout on the very first run, once the walker has
        // answered the permission sheet `start()` triggered.
        guard onBatch != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: beginUpdating()
        default: break
        }
    }
}
