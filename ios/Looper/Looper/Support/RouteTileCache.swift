import CoreLocation
import Foundation
import MapLibre
import LooperKit

/// Downloads the map tiles covering a single loop into a temporary offline
/// pack for the lifetime of a walk, so the route stays visible even where
/// signal drops out along the way. The pack is created when the walk begins
/// and torn down again as soon as it ends — nothing lingers in offline
/// storage once the loop is no longer active.
final class RouteTileCache {
    private static let minZoomLevel: Double = 12
    private static let maxZoomLevel: Double = 18
    private static let marginDegrees = 0.01

    private let storage: MLNOfflineStorage
    private var pack: MLNOfflinePack?
    private var packsObservation: NSKeyValueObservation?

    init(storage: MLNOfflineStorage = .shared) {
        self.storage = storage
        purgeStaleCaches()
    }

    /// Starts downloading tiles for the bounding box of `route`. Replaces
    /// whatever pack, if any, is already cached for a previous walk.
    func cache(_ route: Route) {
        release()
        guard
            let styleURL = Bundle.main.url(forResource: "OSMStyle", withExtension: "json"),
            let bounds = boundingBox(route)
        else { return }

        let region = MLNTilePyramidOfflineRegion(
            styleURL: styleURL, bounds: bounds,
            fromZoomLevel: Self.minZoomLevel, toZoomLevel: Self.maxZoomLevel
        )
        storage.addPack(for: region, withContext: Data()) { [weak self] pack, error in
            guard let self, let pack, error == nil else { return }
            self.pack = pack
            pack.resume()
        }
    }

    /// Discards the cached tiles once the walk they were downloaded for has ended.
    func release() {
        guard let pack else { return }
        self.pack = nil
        storage.removePack(pack, withCompletionHandler: nil)
    }

    // A pack only ever outlives its walk if the app was killed rather than
    // returning to endWalk() normally — clear anything left over from a
    // previous run so "temporary" holds even across a force-quit.
    private func purgeStaleCaches() {
        if let packs = storage.packs {
            packs.forEach { storage.removePack($0, withCompletionHandler: nil) }
            return
        }
        packsObservation = storage.observe(\.packs, options: [.new]) { [weak self] storage, _ in
            self?.packsObservation = nil
            storage.packs?.forEach { storage.removePack($0, withCompletionHandler: nil) }
        }
    }

    private func boundingBox(_ route: Route) -> MLNCoordinateBounds? {
        var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0
        for point in route.geometry.coordinates {
            minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
            minLng = min(minLng, point.lng); maxLng = max(maxLng, point.lng)
        }
        guard minLat <= maxLat else { return nil }
        return MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: minLat - Self.marginDegrees, longitude: minLng - Self.marginDegrees),
            ne: CLLocationCoordinate2D(latitude: maxLat + Self.marginDegrees, longitude: maxLng + Self.marginDegrees)
        )
    }
}
