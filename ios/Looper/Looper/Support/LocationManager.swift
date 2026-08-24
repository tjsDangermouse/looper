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
    private var positionContinuation: AsyncStream<PositionUpdate>.Continuation?
    private var headingContinuation: AsyncStream<Double>.Continuation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestOneShotLocation() async throws -> Point {
        try await withCheckedThrowingContinuation { continuation in
            oneShotContinuation = continuation
            manager.requestWhenInUseAuthorization()
            manager.requestLocation()
        }
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
        if let continuation = oneShotContinuation {
            oneShotContinuation = nil
            continuation.resume(returning: point)
        }
        positionContinuation?.yield(
            PositionUpdate(point: point, accuracy: location.horizontalAccuracy, location: location)
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let continuation = oneShotContinuation {
            oneShotContinuation = nil
            continuation.resume(throwing: error)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateBackgroundCapability()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingContinuation?.yield(heading)
    }
}
