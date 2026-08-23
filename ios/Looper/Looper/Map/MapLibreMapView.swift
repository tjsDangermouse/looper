import SwiftUI
import MapLibre
import LooperKit

/// Close enough to read the next corner and its street, wide enough to hold a
/// couple of hundred metres of the loop around the walker.
private let walkZoom: Double = 17
private let chevronSpacing: NSNumber = 110

struct MapLibreMapView: UIViewRepresentable {
    var start: Point
    var routes: [Route]
    var selectedRouteID: String?
    var follow: Bool
    var courseUp: Bool
    var padding: (bottom: CGFloat, right: CGFloat)
    var onFollowChange: (Bool) -> Void
    var onPoint: (Point) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = Bundle.main.url(forResource: "OSMStyle", withExtension: "json")
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.setCenter(CLLocationCoordinate2D(latitude: start.lat, longitude: start.lng), zoomLevel: 13, animated: false)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.compassView.isHidden = true
        mapView.showsUserLocation = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)

        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapLibreMapView
        weak var mapView: MLNMapView?

        private var routeLayers: [String: (source: MLNShapeSource, line: MLNLineStyleLayer, symbol: MLNSymbolStyleLayer)] = [:]
        private var startAnnotation: MLNPointAnnotation?
        private var lastFitRouteIDs: [String] = []
        private var lastFitPadding: (bottom: CGFloat, right: CGFloat) = (0, 0)
        private var styleReady = false

        init(parent: MapLibreMapView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            parent.onPoint(Point(coordinate.longitude, coordinate.latitude))
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            style.setImage(chevronImage(), forName: "chevron")
            styleReady = true
            sync()
        }

        /// A drag or pinch is the walker asking to look elsewhere, so following
        /// stops until they ask for it back — MLNMapView resets tracking mode to
        /// `.none` on its own the moment a gesture moves the camera; this just
        /// reports that back to the app.
        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            if mode == .none && parent.follow {
                parent.onFollowChange(false)
            }
        }

        func sync() {
            guard let mapView, styleReady else { return }
            syncStartMarker(mapView)
            syncRoutes(mapView)
            syncTracking(mapView)
            syncFit(mapView)
        }

        private func syncStartMarker(_ mapView: MLNMapView) {
            let coordinate = CLLocationCoordinate2D(latitude: parent.start.lat, longitude: parent.start.lng)
            if let startAnnotation {
                startAnnotation.coordinate = coordinate
            } else {
                let annotation = MLNPointAnnotation()
                annotation.coordinate = coordinate
                mapView.addAnnotation(annotation)
                startAnnotation = annotation
            }
        }

        private func syncRoutes(_ mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            let current = Set(parent.routes.map(\.id))
            for (id, layers) in routeLayers where !current.contains(id) {
                style.removeLayer(layers.symbol)
                style.removeLayer(layers.line)
                style.removeSource(layers.source)
                routeLayers.removeValue(forKey: id)
            }
            for (index, route) in parent.routes.enumerated() {
                let colour = UIColor(hex: routeColours[index % routeColours.count])
                let selected = parent.selectedRouteID == nil || parent.selectedRouteID == route.id
                let coordinates = route.geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                if let existing = routeLayers[route.id] {
                    var mutableCoordinates = coordinates
                    let feature = MLNPolylineFeature(coordinates: &mutableCoordinates, count: UInt(mutableCoordinates.count))
                    existing.source.shape = feature
                    existing.line.lineColor = NSExpression(forConstantValue: colour)
                    existing.line.lineWidth = NSExpression(forConstantValue: selected ? 9 : 6)
                    existing.line.lineOpacity = NSExpression(forConstantValue: parent.selectedRouteID == nil ? 0.9 : (selected ? 1 : 0.28))
                    existing.symbol.iconOpacity = existing.line.lineOpacity
                } else {
                    var mutableCoordinates = coordinates
                    let feature = MLNPolylineFeature(coordinates: &mutableCoordinates, count: UInt(mutableCoordinates.count))
                    let source = MLNShapeSource(identifier: "route-\(route.id)", shape: feature, options: nil)
                    style.addSource(source)

                    let line = MLNLineStyleLayer(identifier: "route-line-\(route.id)", source: source)
                    line.lineColor = NSExpression(forConstantValue: colour)
                    line.lineWidth = NSExpression(forConstantValue: selected ? 9 : 6)
                    line.lineOpacity = NSExpression(forConstantValue: parent.selectedRouteID == nil ? 0.9 : (selected ? 1 : 0.28))
                    line.lineCap = NSExpression(forConstantValue: "round")
                    line.lineJoin = NSExpression(forConstantValue: "round")
                    style.addLayer(line)

                    let symbol = MLNSymbolStyleLayer(identifier: "route-arrows-\(route.id)", source: source)
                    symbol.iconImageName = NSExpression(forConstantValue: "chevron")
                    symbol.symbolPlacement = NSExpression(forConstantValue: "line")
                    symbol.symbolSpacing = NSExpression(forConstantValue: chevronSpacing)
                    symbol.iconRotationAlignment = NSExpression(forConstantValue: "map")
                    symbol.iconAllowsOverlap = NSExpression(forConstantValue: true)
                    symbol.iconIgnoresPlacement = NSExpression(forConstantValue: true)
                    symbol.iconOpacity = line.lineOpacity
                    style.addLayer(symbol)

                    routeLayers[route.id] = (source, line, symbol)
                }
            }
        }

        private func syncTracking(_ mapView: MLNMapView) {
            let desired: MLNUserTrackingMode = parent.follow ? (parent.courseUp ? .followWithHeading : .follow) : .none
            if mapView.userTrackingMode != desired {
                mapView.userTrackingMode = desired
            }
        }

        /// When a fresh batch of routes comes in (or the sheet's padding
        /// changes), pull back so every loop is on screen at once, rather than
        /// leaving the camera wherever it was. Skipped while following, since
        /// the walker's own position is driving the camera then.
        private func syncFit(_ mapView: MLNMapView) {
            guard !parent.follow, !parent.routes.isEmpty else { return }
            let routeIDs = parent.routes.map(\.id)
            if routeIDs == lastFitRouteIDs && parent.padding.bottom == lastFitPadding.bottom && parent.padding.right == lastFitPadding.right {
                return
            }
            lastFitRouteIDs = routeIDs
            lastFitPadding = parent.padding

            var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0
            for route in parent.routes {
                for point in route.geometry.coordinates {
                    minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
                    minLng = min(minLng, point.lng); maxLng = max(maxLng, point.lng)
                }
            }
            guard minLat <= maxLat else { return }
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLng),
                ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLng)
            )
            let insets = UIEdgeInsets(top: 60, left: 60, bottom: 60 + parent.padding.bottom, right: 60 + parent.padding.right)
            mapView.setVisibleCoordinateBounds(bounds, edgePadding: insets, animated: true, completionHandler: nil)
        }
    }
}

/// A simple white chevron, matching the web's hand-drawn SVG arrow —
/// MapLibre repeats and rotates this along each route's line automatically.
private func chevronImage() -> UIImage {
    let size = CGSize(width: 12, height: 12)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 2, y: 2))
        path.addLine(to: CGPoint(x: 9, y: 6))
        path.addLine(to: CGPoint(x: 2, y: 10))
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        UIColor.white.setStroke()
        path.stroke()
    }
}
