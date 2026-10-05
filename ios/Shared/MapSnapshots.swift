import Foundation
import LooperKit
import MapKit
import UIKit

/// Maps a coordinate onto the pixels of a saved snapshot.
///
/// An `MKMapSnapshotter.Snapshot` can answer "where is this coordinate" but
/// can't be saved. A flat, north-up-then-rotated camera makes the answer an
/// affine map over a snapshot a few hundred metres wide, so three sampled
/// points are enough to rebuild it from disk with no map data at all.
struct SnapshotProjection: Codable, Equatable {
    var origin: Point
    var a: Double, b: Double, c: Double, d: Double
    var tx: Double, ty: Double

    private static let metersPerDegree = 111_320.0
    private static let sampleMeters = 100.0

    init(origin: Point, a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.origin = origin
        self.a = a; self.b = b; self.c = c; self.d = d
        self.tx = tx; self.ty = ty
    }

    /// Fits the map from a live snapshot by sampling its own projection.
    init(snapshot: MKMapSnapshotter.Snapshot, origin: Point) {
        self.init(origin: origin) {
            snapshot.point(for: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng))
        }
    }

    /// Fits the map from any function that places a coordinate on the picture.
    init(origin: Point, pointFor: (Point) -> CGPoint) {
        let east = Self.offset(origin, east: Self.sampleMeters, north: 0)
        let north = Self.offset(origin, east: 0, north: Self.sampleMeters)
        let po = pointFor(origin)
        let pe = pointFor(east)
        let pn = pointFor(north)
        self.init(
            origin: origin,
            a: (pe.x - po.x) / Self.sampleMeters, b: (pe.y - po.y) / Self.sampleMeters,
            c: (pn.x - po.x) / Self.sampleMeters, d: (pn.y - po.y) / Self.sampleMeters,
            tx: po.x, ty: po.y
        )
    }

    private static func offset(_ point: Point, east: Double, north: Double) -> Point {
        let lngScale = metersPerDegree * cos(point.lat * Double.pi / 180)
        return Point(point.lng + east / lngScale, point.lat + north / metersPerDegree)
    }

    /// The compass direction at the top of the picture, in degrees clockwise
    /// from true north: the camera heading it was taken with.
    var heading: Double {
        (atan2(-c, -d) * 180 / Double.pi + 360).truncatingRemainder(dividingBy: 360)
    }

    func point(for coordinate: Point) -> CGPoint {
        let x = (coordinate.lng - origin.lng) * Self.metersPerDegree * cos(origin.lat * Double.pi / 180)
        let y = (coordinate.lat - origin.lat) * Self.metersPerDegree
        return CGPoint(x: a * x + c * y + tx, y: b * x + d * y + ty)
    }
}

/// Renders one map picture. Both apps use it: the Watch for the map that
/// follows the walker and as a fallback, the iPhone to make a route's maps and
/// send them over, so the two produce the same picture for the same camera.
enum MapSnapshotRenderer {
    static func render(
        center: Point,
        distance: CLLocationDistance,
        heading: CLLocationDirection,
        size: CGSize,
        scale: CGFloat
    ) async throws -> (image: UIImage, projection: SnapshotProjection) {
        let options = MKMapSnapshotter.Options()
        options.camera = MKMapCamera(
            lookingAtCenter: CLLocationCoordinate2D(latitude: center.lat, longitude: center.lng),
            fromDistance: distance,
            pitch: 0,
            heading: heading
        )
        options.size = size
        #if os(watchOS)
        options.scale = scale
        #else
        // The Watch draws its maps dark; a picture made here has to match.
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark), UITraitCollection(displayScale: scale)
        ])
        #endif

        let snapshot: MKMapSnapshotter.Snapshot = try await withCheckedThrowingContinuation { continuation in
            MKMapSnapshotter(options: options).start { snapshot, error in
                if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        return (snapshot.image, SnapshotProjection(snapshot: snapshot, origin: center))
    }
}
