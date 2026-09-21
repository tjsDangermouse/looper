import CoreLocation
import LooperKit

/// Wraps CoreLocation for the app's own progress-tracking and camera-follow
/// needs — the map's camera is driven explicitly by AppModel (mirroring the
/// web app's MapView.tsx), not by MLNMapView's own built-in follow mode,
/// since that mode doesn't give control over zoom.
final class LocationManager: NSObject {
    struct PositionUpdate {
        var point: Point
        var accuracy: Double
        /// The fix as CoreLocation gave it — kept whole so a walk can be
        /// recorded as a real track (altitude, speed, course, timing) for the
        /// Loop Summary and the Apple Health route, not just as a coordinate.
        var location: CLLocation
    }

    static var headingAvailable: Bool { CLLocationManager.headingAvailable() }

    private let manager = CLLocationManager()
    private var oneShotContinuation: CheckedContinuation<Point, Error>?
    private var oneShotTimeout: DispatchWorkItem?
    private var positionContinuation: AsyncStream<PositionUpdate>.Continuation?
    private var headingContinuation: AsyncStream<Double>.Continuation?
    /// The app's own claim on background running time, held for exactly as
    /// long as a walk is being tracked. This is what keeps the phone awake
    /// with the screen off — not the Apple Watch, not a workout session, and
    /// not anything else outside this app.
    private var backgroundSession: CLBackgroundActivitySession?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestOneShotLocation() async throws -> Point {
        // Reuse a recent fix from this manager (for example, after returning
        // from a walk) instead of needlessly spinning the GPS up again.
        if let location = manager.location,
           location.horizontalAccuracy >= 0,
           abs(location.timestamp.timeIntervalSinceNow) <= 60 {
            return Point(location.coordinate.longitude, location.coordinate.latitude)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // A second tap supersedes the first request; never strand its
            // continuation by simply replacing it.
            finishOneShot(.failure(CancellationError()))
            oneShotContinuation = continuation

            switch manager.authorizationStatus {
            case .notDetermined:
                // Wait for the permission decision before requesting a fix.
                // Asking for both together can leave requestLocation pending.
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                startOneShotLocationRequest()
            case .denied, .restricted:
                finishOneShot(.failure(NSError(
                    domain: kCLErrorDomain,
                    code: CLError.Code.denied.rawValue
                )))
            @unknown default:
                finishOneShot(.failure(NSError(
                    domain: kCLErrorDomain,
                    code: CLError.Code.locationUnknown.rawValue
                )))
            }
        }
    }

    private func startOneShotLocationRequest() {
        guard oneShotContinuation != nil else { return }
        oneShotTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishOneShot(.failure(NSError(
                domain: kCLErrorDomain,
                code: CLError.Code.locationUnknown.rawValue
            )))
        }
        oneShotTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
        manager.requestLocation()
    }

    private func finishOneShot(_ result: Result<Point, Error>) {
        guard let continuation = oneShotContinuation else { return }
        oneShotContinuation = nil
        oneShotTimeout?.cancel()
        oneShotTimeout = nil
        continuation.resume(with: result)
    }

    /// Watches position for the duration the stream is being iterated —
    /// terminate iteration (e.g. leave the walk screen) to stop the watch.
    ///
    /// Everything needed to survive a locked screen is claimed here, at the
    /// start of the walk, and given back when the walk ends. A tracked outing
    /// therefore keeps recording on its own terms; nothing about it depends
    /// on whether an Apple Watch is present or what it managed to start.
    func positionUpdates() -> AsyncStream<PositionUpdate> {
        AsyncStream { continuation in
            positionContinuation = continuation
            manager.requestAlwaysAuthorization()
            updateBackgroundCapability()
            beginBackgroundSession()
            manager.startUpdatingLocation()
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.manager.stopUpdatingLocation()
                    self?.endBackgroundSession()
                }
            }
        }
    }

    /// `CLBackgroundActivitySession` is how an app says, in its own right,
    /// that it is doing something that must carry on with the screen off. It
    /// is what makes background location dependable under "While Using" as
    /// well as "Always", and it puts the system's own indicator on screen so
    /// the walker can see the tracking is running.
    private func beginBackgroundSession() {
        guard backgroundSession == nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            backgroundSession = CLBackgroundActivitySession()
        default:
            break
        }
    }

    private func endBackgroundSession() {
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    /// Watches heading for the duration the stream is being iterated — the
    /// map is only read while course-up is being used.
    func headingUpdates() -> AsyncStream<Double> {
        AsyncStream { continuation in
            headingContinuation = continuation
            manager.startUpdatingHeading()
            continuation.onTermination = { [weak self] _ in
                self?.manager.stopUpdatingHeading()
            }
        }
    }

    /// Keeping the track going with the screen off is the whole point of a
    /// walk recording, and "While Using" is enough for it: background updates
    /// are permitted under that grant too, with the system's own indicator
    /// shown while they run. Restricting this to "Always" used to be masked
    /// by the mirrored Watch workout keeping the app awake anyway, which hid
    /// the gap rather than filling it.
    private func updateBackgroundCapability() {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
        default:
            manager.allowsBackgroundLocationUpdates = false
        }
        manager.pausesLocationUpdatesAutomatically = false
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let point = Point(location.coordinate.longitude, location.coordinate.latitude)
        finishOneShot(.success(point))
        positionContinuation?.yield(
            PositionUpdate(point: point, accuracy: location.horizontalAccuracy, location: location)
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishOneShot(.failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateBackgroundCapability()
        // A walk can begin on the same tap that asks for permission, so the
        // grant often lands after tracking has started. Claim the background
        // session at that point rather than leaving the outing without one.
        if positionContinuation != nil { beginBackgroundSession() }
        guard oneShotContinuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            startOneShotLocationRequest()
        case .denied, .restricted:
            finishOneShot(.failure(NSError(
                domain: kCLErrorDomain,
                code: CLError.Code.denied.rawValue
            )))
        case .notDetermined:
            break
        @unknown default:
            finishOneShot(.failure(NSError(
                domain: kCLErrorDomain,
                code: CLError.Code.locationUnknown.rawValue
            )))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingContinuation?.yield(heading)
    }
}
