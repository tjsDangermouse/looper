import Foundation
import MapLibre
import UIKit

enum MapStyleChoice: String, CaseIterable, Identifiable {
    case `default`
    case looper

    var id: Self { self }
    var label: String { self == .default ? "Default" : "Looper" }
}

enum MapStyleConfiguration {
    static let provider = "OpenFreeMap"
    static let styleName = "liberty"
    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    // The fragment makes MapLibre treat Looper as a new style load while the
    // HTTP request still resolves to the same Liberty JSON.
    static func styleURL(for choice: MapStyleChoice) -> URL {
        choice == .default ? styleURL : URL(string: "https://tiles.openfreemap.org/styles/liberty#looper")!
    }

    static func applyLooperStyle(to style: MLNStyle) {
        paint(style, ids: ["background"], as: MLNBackgroundStyleLayer.self) { $0.backgroundColor = constant("#e4e4d7") }
        paint(style, ids: ["landuse_residential"], as: MLNFillStyleLayer.self) { $0.fillColor = constant("#5c793e") }
        paint(style, ids: ["park"], as: MLNFillStyleLayer.self) { $0.fillColor = constant("#70a300") }
        paint(style, ids: ["landcover_wood"], as: MLNFillStyleLayer.self) { $0.fillColor = constant("#c4e198") }
        paint(style, ids: ["landcover_grass", "landcover_grass_park"], as: MLNFillStyleLayer.self) { $0.fillColor = constant("#70a300") }
        paint(style, ids: ["water"], as: MLNFillStyleLayer.self) { $0.fillColor = constant("#cae8f1") }
        paint(style, ids: ["building"], as: MLNFillStyleLayer.self) { $0.fillColor = constant("#c6c3c3") }
        paint(style, ids: ["building-3d"], as: MLNFillExtrusionStyleLayer.self) { $0.fillExtrusionColor = constant("#c6c3c3") }
        paint(style, ids: ["park_outline", "waterway"], as: MLNLineStyleLayer.self) {
            $0.lineColor = constant($0.identifier == "waterway" ? "#00c3ff" : "#172e00")
        }

        let ids = style.layers.map(\.identifier)
        lines(style, ids: ids.filter { $0.hasSuffix("_casing") }, colour: "#878787", opacity: 0.9)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_motorway(_link)?$"#, options: .regularExpression) != nil }, colour: "#f05656", opacity: 0.72)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_(trunk_primary|secondary_tertiary|link)$"#, options: .regularExpression) != nil }, colour: "#fde753", opacity: 0.88)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_(minor|street)$"#, options: .regularExpression) != nil }, colour: "#ffffff", opacity: 1)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_service_track$"#, options: .regularExpression) != nil }, colour: "#ffffff", opacity: 0.9)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_path_pedestrian$"#, options: .regularExpression) != nil }, colour: "#c9c9c9", opacity: 1)

        for id in ["poi_r20", "poi_r7", "poi_r1"] { style.layer(withIdentifier: id)?.isVisible = false }
        paint(style, ids: ["poi_transit"], as: MLNSymbolStyleLayer.self) {
            $0.textOpacity = NSExpression(forConstantValue: 0.5)
            $0.iconOpacity = NSExpression(forConstantValue: 0.5)
        }
        paint(style, ids: ids.filter { $0.range(of: #"(_label|place_|highway-name|water_name)"#, options: .regularExpression) != nil }, as: MLNSymbolStyleLayer.self) {
            $0.textColor = constant("#000000")
            $0.textHaloColor = constant("#e3e3e3")
        }

        addWalkingLayer(style, id: "looper-trails", colour: "#359c46", width: 3,
                        predicate: NSPredicate(format: "%K == %@ OR %K IN %@", "class", "track", "subclass", ["path", "track"]), dashed: true)
        addWalkingLayer(style, id: "looper-footways", colour: "#c9c9c9", width: 3.4,
                        predicate: NSPredicate(format: "%K == %@ OR %K IN %@", "class", "pedestrian", "subclass", ["footway", "steps"]))
        addWalkingLayer(style, id: "looper-cycleways", colour: "#ffffff", width: 3.8,
                        predicate: NSPredicate(format: "%K == %@ OR %K == %@", "class", "cycleway", "subclass", "cycleway"))
    }

    private static func paint<T: MLNStyleLayer>(_ style: MLNStyle, ids: [String], as type: T.Type, apply: (T) -> Void) {
        for id in ids { if let layer = style.layer(withIdentifier: id) as? T { apply(layer) } }
    }

    private static func lines(_ style: MLNStyle, ids: [String], colour: String, opacity: Double) {
        paint(style, ids: ids, as: MLNLineStyleLayer.self) {
            $0.lineColor = constant(colour)
            $0.lineOpacity = NSExpression(forConstantValue: opacity)
        }
    }

    private static func addWalkingLayer(_ style: MLNStyle, id: String, colour: String, width: Double,
                                        predicate: NSPredicate, dashed: Bool = false) {
        guard style.layer(withIdentifier: id) == nil,
              let source = style.source(withIdentifier: "openmaptiles") else { return }
        let layer = MLNLineStyleLayer(identifier: id, source: source)
        layer.sourceLayerIdentifier = "transportation"
        layer.predicate = predicate
        layer.minimumZoomLevel = 11
        layer.lineColor = constant(colour)
        layer.lineWidth = NSExpression(forConstantValue: width)
        layer.lineOpacity = NSExpression(forConstantValue: 1)
        layer.lineCap = NSExpression(forConstantValue: "round")
        layer.lineJoin = NSExpression(forConstantValue: "round")
        if dashed { layer.lineDashPattern = NSExpression(forConstantValue: [2, 1.4]) }
        if let labels = style.layer(withIdentifier: "road_one_way_arrow") {
            style.insertLayer(layer, below: labels)
        } else {
            style.addLayer(layer)
        }
    }

    private static func constant(_ hex: String) -> NSExpression {
        NSExpression(forConstantValue: UIColor(hex: hex))
    }
}
