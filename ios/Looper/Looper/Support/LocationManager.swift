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
    func positionUpdates() -> AsyncStream<PositionUpdate> {
        AsyncStream { continuation in
            positionContinuation = continuation
            manager.requestAlwaysAuthorization()
            updateBackgroundCapability()
            manager.startUpdatingLocation()
            continuation.onTermination = { [weak self] _ in
                self?.manager.stopUpdatingLocation()
            }
        }
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

    private func updateBackgroundCapability() {
        manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
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
