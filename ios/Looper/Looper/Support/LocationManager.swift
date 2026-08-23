import CoreLocation
import LooperKit

/// Wraps CoreLocation for the app's own progress-tracking needs (the map's
/// blue dot and camera-follow use MLNMapView's own built-in location
/// handling instead — see MapLibreMapView).
final class LocationManager: NSObject {
    struct PositionUpdate {
        var point: Point
        var accuracy: Double
    }

    static var headingAvailable: Bool { CLLocationManager.headingAvailable() }

    private let manager = CLLocationManager()
    private var oneShotContinuation: CheckedContinuation<Point, Error>?
    private var positionContinuation: AsyncStream<PositionUpdate>.Continuation?

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
        positionContinuation?.yield(PositionUpdate(point: point, accuracy: location.horizontalAccuracy))
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
}
