import Foundation
import LooperKit
import MapLibre
import UIKit

struct MapStyleChoice: Hashable, Identifiable {
    let id: String
    let label: String
    let palette: MapStylePalette?

    static let `default` = MapStyleChoice(id: "default", label: "Default", palette: nil)
    static var allCases: [MapStyleChoice] {
        [.default] + customMapStyles.map { MapStyleChoice(id: $0.id, label: $0.name, palette: $0.palette) }
    }
}

enum MapStyleConfiguration {
    static let provider = "OpenFreeMap"
    static let styleName = "liberty"
    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    // The fragment makes MapLibre treat each custom palette as a new style load while the
    // HTTP request still resolves to the same Liberty JSON.
    static func styleURL(for choice: MapStyleChoice) -> URL {
        choice.palette == nil ? styleURL : URL(string: "https://tiles.openfreemap.org/styles/liberty#\(choice.id)")!
    }

    static func apply(_ choice: MapStyleChoice, to style: MLNStyle) {
        guard let palette = choice.palette else { return }
        paint(style, ids: ["background"], as: MLNBackgroundStyleLayer.self) { $0.backgroundColor = constant(palette.background) }
        paint(style, ids: ["landuse_residential"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.residential) }
        paint(style, ids: ["park"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.park) }
        paint(style, ids: ["landcover_wood"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.woodland) }
        paint(style, ids: ["landcover_grass", "landcover_grass_park"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.park) }
        paint(style, ids: ["water"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.water) }
        paint(style, ids: ["building"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.building) }
        paint(style, ids: ["building-3d"], as: MLNFillExtrusionStyleLayer.self) { $0.fillExtrusionColor = constant(palette.building) }
        paint(style, ids: ["park_outline", "waterway"], as: MLNLineStyleLayer.self) {
            $0.lineColor = constant($0.identifier == "waterway" ? palette.waterLine : palette.parkOutline)
        }

        let ids = style.layers.map(\.identifier)
        lines(style, ids: ids.filter { $0.hasSuffix("_casing") }, colour: palette.casing, opacity: 0.9)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_motorway(_link)?$"#, options: .regularExpression) != nil }, colour: palette.motorway, opacity: 0.72)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_(trunk_primary|secondary_tertiary|link)$"#, options: .regularExpression) != nil }, colour: palette.mainRoad, opacity: 0.88)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_(minor|street)$"#, options: .regularExpression) != nil }, colour: palette.residentialRoad, opacity: 1)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_service_track$"#, options: .regularExpression) != nil }, colour: palette.serviceRoad, opacity: 0.9)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_path_pedestrian$"#, options: .regularExpression) != nil }, colour: palette.footway, opacity: 1)

        for id in ["poi_r20", "poi_r7", "poi_r1"] { style.layer(withIdentifier: id)?.isVisible = false }
        paint(style, ids: ["poi_transit"], as: MLNSymbolStyleLayer.self) {
            $0.textOpacity = NSExpression(forConstantValue: 0.5)
            $0.iconOpacity = NSExpression(forConstantValue: 0.5)
        }
        paint(style, ids: ids.filter { $0.range(of: #"(_label|place_|highway-name|water_name)"#, options: .regularExpression) != nil }, as: MLNSymbolStyleLayer.self) {
            $0.textColor = constant(palette.label)
            $0.textHaloColor = constant(palette.labelHalo)
        }

        addWalkingLayer(style, id: "looper-trails", colour: palette.trail, width: 3,
                        predicate: NSPredicate(format: "%K == %@ OR %K IN %@", "class", "track", "subclass", ["path", "track"]), dashed: true)
        addWalkingLayer(style, id: "looper-footways", colour: palette.footway, width: 3.4,
                        predicate: NSPredicate(format: "%K == %@ OR %K IN %@", "class", "pedestrian", "subclass", ["footway", "steps"]))
        addWalkingLayer(style, id: "looper-cycleways", colour: palette.cycleway, width: 3.8,
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
