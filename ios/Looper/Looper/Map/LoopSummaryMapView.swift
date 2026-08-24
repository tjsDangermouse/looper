import CoreLocation
import LooperKit
import MapLibre
import SwiftUI

/// A small, still map of a finished outing: the track that was actually
/// walked, the planned loop underneath it, and where the walk started and
/// stopped. Deliberately its own thin view rather than a mode bolted onto
/// `MapLibreMapView` — none of that view's camera-follow, course-up or
/// selection machinery means anything once the walk is over.
struct LoopSummaryMapView: UIViewRepresentable {
    var planned: [Point]
    var track: [Point]

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(
            frame: .zero,
            styleURL: Bundle.main.url(forResource: "OSMStyle", withExtension: "json")
        )
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        mapView.compassView.isHidden = true
        // A summary card is something to look at, not to drive.
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.delegate = context.coordinator
        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.draw()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: LoopSummaryMapView
        weak var mapView: MLNMapView?
        private var styleReady = false
        private var drawn = false

        init(parent: LoopSummaryMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleReady = true
            draw()
        }

        func draw() {
            guard let mapView, let style = mapView.style, styleReady, !drawn else { return }
            guard mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
            let line = parent.track.count >= 2 ? parent.track : parent.planned
            guard !line.isEmpty else { return }
            drawn = true

            // The plan sits underneath, dimmed, as context for the track that
            // was actually recorded — never competing with it.
            if parent.planned.count >= 2 {
                addLine(
                    parent.planned, id: "summary-planned", style: style,
                    colour: UIColor(Color.looperLine), width: 5, opacity: 0.9, dashed: true
                )
            }
            if parent.track.count >= 2 {
                addLine(
                    parent.track, id: "summary-track", style: style,
                    colour: UIColor(Color.looperAccent), width: 5, opacity: 1, dashed: false
                )
            }
            addEndpoints(line, mapView: mapView)
            // Fit both, so an outing that stopped part-way still shows how
            // much of the planned loop it got round.
            fit(parent.planned + parent.track, mapView: mapView)
        }

        private func addLine(
            _ points: [Point], id: String, style: MLNStyle,
            colour: UIColor, width: Double, opacity: Double, dashed: Bool
        ) {
            var coordinates = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
            let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            let source = MLNShapeSource(identifier: id, shape: feature, options: nil)
            style.addSource(source)
            let layer = MLNLineStyleLayer(identifier: "\(id)-line", source: source)
            layer.lineColor = NSExpression(forConstantValue: colour)
            layer.lineWidth = NSExpression(forConstantValue: width)
            layer.lineOpacity = NSExpression(forConstantValue: opacity)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            if dashed { layer.lineDashPattern = NSExpression(forConstantValue: [2, 2]) }
            style.addLayer(layer)
        }

        private func addEndpoints(_ line: [Point], mapView: MLNMapView) {
            guard let first = line.first, let last = line.last else { return }
            let start = MLNPointAnnotation()
            start.coordinate = CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng)
            start.title = "Start"
            let finish = MLNPointAnnotation()
            finish.coordinate = CLLocationCoordinate2D(latitude: last.lat, longitude: last.lng)
            finish.title = "Finish"
            // A loop ends where it began; one marker is clearer than two on
            // top of each other.
            if haversine(first, last) < 25 {
                start.title = "Start and finish"
                mapView.addAnnotation(start)
            } else {
                mapView.addAnnotations([start, finish])
            }
        }

        private func fit(_ line: [Point], mapView: MLNMapView) {
            var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0
            for point in line {
                minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
                minLng = min(minLng, point.lng); maxLng = max(maxLng, point.lng)
            }
            guard minLat <= maxLat else { return }
            let bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLng),
                ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLng)
            )
            mapView.setVisibleCoordinateBounds(
                bounds,
                edgePadding: UIEdgeInsets(top: 26, left: 26, bottom: 26, right: 26),
                animated: false,
                completionHandler: nil
            )
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            let isFinish = (annotation.title ?? nil) == "Finish"
            let identifier = isFinish ? "summary-finish" : "summary-start"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? EndpointAnnotationView(reuseIdentifier: identifier, isFinish: isFinish)
            return view
        }
    }
}

/// A filled dot for the start, a ringed dot for the finish — enough to tell
/// the two ends of a track apart at card size.
private final class EndpointAnnotationView: MLNAnnotationView {
    init(reuseIdentifier: String, isFinish: Bool) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        layer.cornerRadius = 8
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.cgColor
        backgroundColor = isFinish ? UIColor(Color.looperAccent) : UIColor(Color.looperSheet)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
