import Foundation
import SwiftUI
import MapLibre
import LooperKit

/// Close enough to read the next corner and its street, wide enough to hold a
/// couple of hundred metres of the loop around the walker.
private let walkZoom: Double = 16
private let chevronSpacing: NSNumber = 110

struct MapLibreMapView: UIViewRepresentable {
    var mapStyle: MapStyleChoice
    var start: Point
    var waypoints: [Point]
    var routes: [Route]
    var selectedRouteID: String?
    var position: Point?
    var follow: Bool
    var walking: Bool
    var heading: Double?
    var courseUp: Bool
    var padding: (bottom: CGFloat, right: CGFloat)
    var onFollowChange: (Bool) -> Void
    var onUserLocation: (Point) -> Void
    var onPoint: (Point) -> Void
    var onLongPress: (Point) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: MapStyleConfiguration.styleURL(for: mapStyle))
        mapView.setCenter(CLLocationCoordinate2D(latitude: start.lat, longitude: start.lng), zoomLevel: 13, animated: false)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.compassView.isHidden = true
        mapView.showsUserLocation = true
        mapView.showsUserHeadingIndicator = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.55
        mapView.addGestureRecognizer(longPress)
        tap.require(toFail: longPress)

        // A drag or pinch is the walker asking to look elsewhere, so following
        // stops until they ask for it back. These run alongside MLNMapView's
        // own built-in gestures rather than replacing them.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleUserGesture(_:)))
        pan.delegate = context.coordinator
        mapView.addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleUserGesture(_:)))
        pinch.delegate = context.coordinator
        mapView.addGestureRecognizer(pinch)

        context.coordinator.mapView = mapView
        // lastStart is deliberately left unset: this initial placement is a
        // rough, padding-unaware guess (the view has no laid-out size yet to
        // do the padding math against), so the first real sync() still needs
        // to see start as "changed" and correct it once the sheet's height
        // is known.
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapLibreMapView
        weak var mapView: MLNMapView?

        private var routeLayers: [String: (source: MLNShapeSource, line: MLNLineStyleLayer, symbol: MLNSymbolStyleLayer)] = [:]
        private var startAnnotation: MLNPointAnnotation?
        private var waypointAnnotations: [WaypointAnnotation] = []
        private var styleReady = false
        private var lastMapStyle: MapStyleChoice

        // Previous-value trackers, one per camera effect — each effect only
        // acts when its own inputs actually changed, mirroring a set of
        // independent React effects each keyed on their own dependencies.
        var lastStart: Point?
        private var lastFollow = false
        private var lastPosition: Point?
        private var lastCourseUp = false
        private var lastHeading: Double?
        private var lastWalking = false
        private var lastFitRouteIDs: [String] = []
        private var lastFitSelectedRouteID: String?
        private var lastFittedRoutes: [Route] = []
        private var lastPadding: (bottom: CGFloat, right: CGFloat) = (0, 0)
        private var zeroBoundsRetries = 0

        init(parent: MapLibreMapView) {
            self.parent = parent
            self.lastMapStyle = parent.mapStyle
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            parent.onPoint(Point(coordinate.longitude, coordinate.latitude))
        }

        @objc func handleUserGesture(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began && parent.follow {
                parent.onFollowChange(false)
            }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onLongPress(Point(coordinate.longitude, coordinate.latitude))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            routeLayers.removeAll()
            MapStyleConfiguration.apply(parent.mapStyle, to: style)
            style.setImage(chevronImage(), forName: "chevron")
            styleReady = true
            sync()
        }

        func mapView(_ mapView: MLNMapView, didFailToLoadMapWithError error: Error) {
            print("[Looper map] Failed to load \(MapStyleConfiguration.provider) \(MapStyleConfiguration.styleName): \(error.localizedDescription)")
        }

        func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
            guard let coordinate = userLocation?.location?.coordinate else { return }
            parent.onUserLocation(Point(coordinate.longitude, coordinate.latitude))
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let waypoint = annotation as? WaypointAnnotation else { return nil }
            let identifier = "waypoint"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? WaypointAnnotationView
                ?? WaypointAnnotationView(reuseIdentifier: identifier)
            view.configure(number: waypoint.number)
            return view
        }

        func sync() {
            guard let mapView else { return }
            if parent.mapStyle != lastMapStyle {
                lastMapStyle = parent.mapStyle
                styleReady = false
                routeLayers.removeAll()
                mapView.styleURL = MapStyleConfiguration.styleURL(for: parent.mapStyle)
                return
            }
            guard styleReady else { return }
            // Before the view has a real, laid-out size, none of the camera
            // maths below can do anything but guess — and worse, if it ran
            // anyway it would mark whatever changed (start, padding, ...) as
            // already "handled", so the real correction would never happen
            // once a size does arrive. Bail out entirely and wait for the
            // next state change (padding arriving is normally what re-runs
            // this) rather than touch any of the tracked previous values.
            guard mapView.bounds.width > 0, mapView.bounds.height > 0 else {
                // Auto Layout hasn't resolved the view's frame yet — retry
                // next run-loop tick rather than waiting on some other state
                // change to happen to call sync() again. Capped so a view
                // that's stuck at zero size for some other reason doesn't
                // spin forever.
                guard zeroBoundsRetries < 120 else { return }
                zeroBoundsRetries += 1
                DispatchQueue.main.async { [weak self] in self?.sync() }
                return
            }
            zeroBoundsRetries = 0
            syncRoutes(mapView)
            if parent.routes.isEmpty {
                lastFittedRoutes = []
                lastFitRouteIDs = []
                lastFitSelectedRouteID = nil
            }
            updateStartMarker(mapView)
            updateWaypointMarkers(mapView)
            let didFit = syncFit(mapView) || syncWalkingEnd(mapView)
            if didFit {
                // A route fit has just placed the geometry in the visible map
                // area. Do not immediately replace it with the start or GPS
                // camera update that happens to share this SwiftUI pass.
                lastStart = parent.start
                lastPosition = parent.position
                lastFollow = parent.follow
            } else {
                syncPaddingRecenter(mapView)
                syncStartCamera(mapView)
                syncPositionCamera(mapView)
                syncFollowCamera(mapView)
            }
            syncCourseUp(mapView)
        }

        // MARK: Drawing

        private func updateStartMarker(_ mapView: MLNMapView) {
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

        private func updateWaypointMarkers(_ mapView: MLNMapView) {
            let current = waypointAnnotations.map { Point($0.coordinate.longitude, $0.coordinate.latitude) }
            guard current != parent.waypoints else { return }
            if !waypointAnnotations.isEmpty { mapView.removeAnnotations(waypointAnnotations) }
            waypointAnnotations = parent.waypoints.enumerated().map { index, point in
                let annotation = WaypointAnnotation()
                annotation.number = index + 1
                annotation.coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng)
                return annotation
            }
            mapView.addAnnotations(waypointAnnotations)
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
                let selected = parent.selectedRouteID == route.id
                let opacity = parent.selectedRouteID == nil ? 0.9 : (selected ? 1 : 0.28)
                let coordinates = route.geometry.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
                var mutableCoordinates = coordinates
                let feature = MLNPolylineFeature(coordinates: &mutableCoordinates, count: UInt(mutableCoordinates.count))
                if let existing = routeLayers[route.id] {
                    existing.source.shape = feature
                    existing.line.lineColor = NSExpression(forConstantValue: colour)
                    existing.line.lineWidth = routeLineWidth(selected: selected)
                    existing.line.lineOpacity = NSExpression(forConstantValue: opacity)
                    existing.symbol.iconOpacity = existing.line.lineOpacity
                    existing.symbol.iconScale = routeChevronScale()
                } else {
                    let source = MLNShapeSource(identifier: "route-\(route.id)", shape: feature, options: nil)
                    style.addSource(source)

                    let line = MLNLineStyleLayer(identifier: "route-line-\(route.id)", source: source)
                    line.lineColor = NSExpression(forConstantValue: colour)
                    line.lineWidth = routeLineWidth(selected: selected)
                    line.lineOpacity = NSExpression(forConstantValue: opacity)
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
                    symbol.iconScale = routeChevronScale()
                    style.addLayer(symbol)

                    routeLayers[route.id] = (source, line, symbol)
                }
            }
        }

        private func routeLineWidth(selected: Bool) -> NSExpression {
            let widths = selected ? [3, 6, 9, 10] : [2, 4, 6, 7]
            return NSExpression(mglJSONObject: [
                "interpolate", ["linear"], ["zoom"],
                11, widths[0], 14, widths[1], 17, widths[2], 19, widths[3]
            ])
        }

        private func routeChevronScale() -> NSExpression {
            NSExpression(mglJSONObject: [
                "interpolate", ["linear"], ["zoom"],
                11, 0.5, 14, 0.75, 17, 1, 19, 1.1
            ])
        }

        // MARK: Camera

        /// Shifts a target coordinate so that, once centred, it lands in the
        /// middle of the *visible* strip of map left uncovered by the bottom
        /// sheet — rather than the middle of the whole (partly-covered) view.
        private func paddedCenter(_ target: CLLocationCoordinate2D, zoom: Double, mapView: MLNMapView) -> CLLocationCoordinate2D {
            let padding = parent.padding
            guard padding.bottom > 0 || padding.right > 0, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return target }
            // Do not temporarily call setCenter(target) here to use the map's
            // conversion methods. That change is rendered immediately, then
            // the caller animates to the padded centre; each GPS update thus
            // looked like a jump down followed by a slide back up.
            //
            // Work directly in Mercator coordinates instead. `direction` is
            // clockwise from north, so rotate the visible-area offset into
            // map coordinates before shifting the camera centre.
            let worldSize = 512 * pow(2, zoom)
            let angle = mapView.direction * .pi / 180
            let cosine = cos(angle), sine = sin(angle)
            let right = Double(padding.right) / 2 / worldSize
            let bottom = Double(padding.bottom) / 2 / worldSize
            let x = mercatorX(target.longitude) + cosine * right - sine * bottom
            let y = mercatorY(target.latitude) + sine * right + cosine * bottom
            return CLLocationCoordinate2D(latitude: latFromMercatorY(y), longitude: lngFromMercatorX(x))
        }

        /// The start point moving (choosing a new spot, or a fresh GPS fix)
        /// pulls the camera to it, unless the walker's own position is
        /// already driving the camera.
        private func syncStartCamera(_ mapView: MLNMapView) {
            defer { lastStart = parent.start }
            guard lastStart != parent.start, !parent.follow else { return }
            let target = CLLocationCoordinate2D(latitude: parent.start.lat, longitude: parent.start.lng)
            let padded = paddedCenter(target, zoom: mapView.zoomLevel, mapView: mapView)
            mapView.setCenter(padded, zoomLevel: mapView.zoomLevel, animated: true)
        }

        /// The walker's own position, while following, keeps the camera
        /// travelling with them and holds at least a walking zoom level.
        private func syncPositionCamera(_ mapView: MLNMapView) {
            defer { lastPosition = parent.position }
            guard lastPosition != parent.position, parent.follow, let position = parent.position else { return }
            let target = CLLocationCoordinate2D(latitude: position.lat, longitude: position.lng)
            let zoom = max(mapView.zoomLevel, walkZoom)
            let padded = paddedCenter(target, zoom: zoom, mapView: mapView)
            mapView.setCenter(padded, zoomLevel: zoom, animated: true)
        }

        /// Turning following on — starting a walk, or asking to be
        /// re-centred — closes in on the walker without pulling back a zoom
        /// they chose themselves.
        private func syncFollowCamera(_ mapView: MLNMapView) {
            defer { lastFollow = parent.follow }
            guard parent.follow, !lastFollow else { return }
            let anchor = parent.position ?? parent.start
            let target = CLLocationCoordinate2D(latitude: anchor.lat, longitude: anchor.lng)
            let zoom = max(mapView.zoomLevel, walkZoom)
            let padded = paddedCenter(target, zoom: zoom, mapView: mapView)
            mapView.setCenter(padded, zoomLevel: zoom, animated: true)
        }

        /// Course-up: the map turns so the way the walker faces is up the
        /// screen; north-up winds the bearing back to zero.
        private func syncCourseUp(_ mapView: MLNMapView) {
            defer { lastCourseUp = parent.courseUp; lastHeading = parent.heading }
            guard parent.courseUp != lastCourseUp || parent.heading != lastHeading else { return }
            if !parent.courseUp {
                if mapView.direction != 0 { mapView.setDirection(0, animated: true) }
                return
            }
            guard let heading = parent.heading, headingGap(heading, mapView.direction) >= 2 else { return }
            mapView.setDirection(heading, animated: true)
        }

        /// A fresh batch is fitted as a group so every option can be compared.
        /// A card selection then fits that one loop, giving it more useful map
        /// space without hiding the overview until the walker chooses it.
        /// Returns whether it actually performed a fit this call.
        @discardableResult
        private func syncFit(_ mapView: MLNMapView) -> Bool {
            let routeIDs = parent.routes.map(\.id)
            let selectedRouteID = parent.selectedRouteID
            let routesChanged = routeIDs != lastFitRouteIDs
            let selectionChanged = selectedRouteID != lastFitSelectedRouteID
            defer {
                lastFitRouteIDs = routeIDs
                lastFitSelectedRouteID = selectedRouteID
            }
            guard !parent.follow, !parent.routes.isEmpty else { return false }
            let fitRoutes: [Route]
            if routesChanged {
                fitRoutes = parent.routes
            } else if selectionChanged, let selectedRouteID,
                      let selectedRoute = parent.routes.first(where: { $0.id == selectedRouteID }) {
                fitRoutes = [selectedRoute]
            } else {
                return false
            }
            guard fit(fitRoutes, mapView: mapView) else { return false }
            lastFittedRoutes = fitRoutes
            settleFit(fitRoutes, routeIDs: routeIDs, selectedRouteID: selectedRouteID)
            return true
        }

        /// MapLibre can finish laying out its camera just after SwiftUI has
        /// measured the sheet. Repeat the same fit on the settled layout so a
        /// loop's lower edge is never left underneath that sheet.
        private func settleFit(_ routes: [Route], routeIDs: [String], selectedRouteID: String?) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak mapView] in
                guard let self, let mapView,
                      self.parent.routes.map(\.id) == routeIDs,
                      self.parent.selectedRouteID == selectedRouteID,
                      !self.parent.follow else { return }
                self.fit(routes, mapView: mapView)
            }
        }

        /// Leaving the walk screen: pull back out to the whole loop, since
        /// the walker was left zoomed in on wherever they'd got to.
        @discardableResult
        private func syncWalkingEnd(_ mapView: MLNMapView) -> Bool {
            defer { lastWalking = parent.walking }
            guard lastWalking, !parent.walking, let route = parent.routes.first(where: { $0.id == parent.selectedRouteID }) else { return false }
            guard fit([route], mapView: mapView) else { return false }
            lastFittedRoutes = [route]
            return true
        }

        // MLNMapView's own edgePadding-based fit goes badly wrong once one
        // side's padding approaches the container size (as the sheet's does
        // on a phone screen) — it collapses to a much lower zoom than the
        // space actually requires. So the fit is computed by hand, in
        // Mercator space: the tightest zoom that still holds the whole loop
        // within the *visible* area (the screen minus the sheet), plus a
        // small margin, then shifted so the loop sits centred within that
        // visible area rather than the full screen.
        @discardableResult
        private func fit(_ routes: [Route], mapView: MLNMapView) -> Bool {
            var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0
            for route in routes {
                for point in route.geometry.coordinates {
                    minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
                    minLng = min(minLng, point.lng); maxLng = max(maxLng, point.lng)
                }
            }
            guard minLat <= maxLat else { return false }
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLng),
                ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLng)
            )

            let w = Double(mapView.bounds.width), h = Double(mapView.bounds.height)
            guard w > 120, h > 120 else { return false }
            // A generous margin keeps the outer edge of a selected loop clear
            // of the sheet, safe-area edge, and floating map controls.
            let margin = 64.0
            let bottomPad = Double(parent.padding.bottom), rightPad = Double(parent.padding.right)

            let x0 = mercatorX(bounds.sw.longitude), x1 = mercatorX(bounds.ne.longitude)
            let y0 = mercatorY(bounds.ne.latitude), y1 = mercatorY(bounds.sw.latitude) // y increases southward
            let spanX = max(x1 - x0, 1e-9)
            let spanY = max(y1 - y0, 1e-9)

            let availW = max(w - rightPad - 2 * margin, 1)
            let availH = max(h - bottomPad - 2 * margin, 1)
            let zoom = min(log2(availW / (512 * spanX)), log2(availH / (512 * spanY)), walkZoom)

            let worldSize = 512 * pow(2, zoom)
            let x = (x0 + x1) / 2 + rightPad / 2 / worldSize
            let y = (y0 + y1) / 2 + bottomPad / 2 / worldSize
            let shifted = CLLocationCoordinate2D(latitude: latFromMercatorY(y), longitude: lngFromMercatorX(x))
            mapView.setCenter(shifted, zoomLevel: zoom, animated: true)
            return true
        }

        /// Re-centre whenever the sheet's height changes — its real height
        /// often isn't known until just after a fit already ran once against
        /// zero padding, so this redoes that same fit with the padding now
        /// in hand, rather than drifting off to some other anchor.
        private func syncPaddingRecenter(_ mapView: MLNMapView) {
            defer { lastPadding = parent.padding }
            guard parent.padding.bottom != lastPadding.bottom || parent.padding.right != lastPadding.right else { return }
            if !parent.follow, !lastFittedRoutes.isEmpty {
                fit(lastFittedRoutes, mapView: mapView)
                return
            }
            let anchor = parent.follow ? (parent.position ?? parent.start) : parent.start
            let target = CLLocationCoordinate2D(latitude: anchor.lat, longitude: anchor.lng)
            let zoom = parent.follow ? max(mapView.zoomLevel, walkZoom) : mapView.zoomLevel
            let padded = paddedCenter(target, zoom: zoom, mapView: mapView)
            mapView.setCenter(padded, zoomLevel: zoom, animated: true)
        }
    }
}

private final class WaypointAnnotation: MLNPointAnnotation {
    var number = 0
}

private final class WaypointAnnotationView: MLNAnnotationView {
    private let marker = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(origin: .zero, size: CGSize(width: 38, height: 46))
        marker.frame = bounds
        marker.contentMode = .center
        addSubview(marker)
        // The coordinate belongs at the pin's 44 pt tip, not at the 23 pt
        // centre of its image. Move the view centre up by that 21 pt gap so
        // the bottom tip, rather than the top of the marker, lands on the map.
        centerOffset = CGVector(dx: 0, dy: -21)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(number: Int) {
        marker.image = waypointImage(number: number)
        accessibilityLabel = "Waypoint \(number)"
    }
}

private func waypointImage(number: Int) -> UIImage {
    let size = CGSize(width: 38, height: 46)
    return UIGraphicsImageRenderer(size: size).image { _ in
        let circle = CGRect(x: 3, y: 2, width: 32, height: 32)
        let path = UIBezierPath(ovalIn: circle)
        UIColor.systemBlue.setFill()
        path.fill()
        UIColor.white.setStroke()
        path.lineWidth = 3
        path.stroke()

        let pointer = UIBezierPath()
        pointer.move(to: CGPoint(x: 13, y: 30))
        pointer.addLine(to: CGPoint(x: 19, y: 44))
        pointer.addLine(to: CGPoint(x: 25, y: 30))
        pointer.close()
        UIColor.systemBlue.setFill()
        pointer.fill()

        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: 19 - textSize.width / 2, y: 18 - textSize.height / 2), withAttributes: attributes)
    }
}

/// Web Mercator normalised coordinates in [0,1], matching MapLibre GL's own
/// projection — used to shift a fitted centre by a pixel offset that scales
/// correctly with zoom.
private func mercatorX(_ lng: Double) -> Double { (180 + lng) / 360 }
private func mercatorY(_ lat: Double) -> Double {
    (180 - (180 / .pi) * log(tan(.pi / 4 + (lat * .pi / 180) / 2))) / 360
}
private func lngFromMercatorX(_ x: Double) -> Double { x * 360 - 180 }
private func latFromMercatorY(_ y: Double) -> Double {
    (360 / .pi) * atan(exp((180 - y * 360) * .pi / 180)) - 90
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
