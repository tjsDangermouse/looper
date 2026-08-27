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
        paint(style, ids: ["landcover_grass", "landcover_grass_park"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.grass) }
        paint(style, ids: ["landcover_ice"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.ice) }
        paint(style, ids: ["landcover_sand"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.sand) }
        paint(style, ids: ["landuse_pitch", "landuse_track"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.sports) }
        paint(style, ids: ["landuse_cemetery"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.cemetery) }
        paint(style, ids: ["landuse_school"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.education) }
        paint(style, ids: ["landuse_hospital"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.healthcare) }
        paint(style, ids: ["aeroway_fill"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.aerodrome) }
        paint(style, ids: ["water"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.water) }
        paint(style, ids: ["building"], as: MLNFillStyleLayer.self) { $0.fillColor = constant(palette.building) }
        paint(style, ids: ["building-3d"], as: MLNFillExtrusionStyleLayer.self) { $0.fillExtrusionColor = constant(palette.building) }
        paint(style, ids: ["park_outline", "waterway"], as: MLNLineStyleLayer.self) {
            $0.lineColor = constant($0.identifier == "waterway" ? palette.waterLine : palette.parkOutline)
        }

        // Liberty omits several OpenMapTiles land categories. Looper-owned
        // fills make every category in the editor render on iOS as well.
        addFillLayer(style, id: "looper-farmland", sourceLayer: "landcover", colour: palette.farmland,
                     predicate: NSPredicate(format: "%K == %@", "class", "farmland"), below: "park")
        addFillLayer(style, id: "looper-rock", sourceLayer: "landcover", colour: palette.rock,
                     predicate: NSPredicate(format: "%K == %@", "class", "rock"), below: "park")
        addFillLayer(style, id: "looper-wetland-underlay", sourceLayer: "landcover", colour: palette.wetland,
                     predicate: NSPredicate(format: "%K == %@", "class", "wetland"), below: "landcover_wetland")
        addFillLayer(style, id: "looper-parkland", sourceLayer: "landcover", colour: palette.park,
                     predicate: NSPredicate(format: "%K IN %@", "subclass", ["park", "recreation_ground", "village_green", "garden", "golf_course"]), below: "park")
        addFillLayer(style, id: "looper-park-uses", sourceLayer: "landuse", colour: palette.park,
                     predicate: NSPredicate(format: "%K IN %@", "class", ["theme_park", "zoo"]), below: "landuse_pitch")
        addFillLayer(style, id: "looper-commercial", sourceLayer: "landuse", colour: palette.commercial,
                     predicate: NSPredicate(format: "%K IN %@", "class", ["commercial", "retail"]), below: "landuse_pitch")
        addFillLayer(style, id: "looper-industrial", sourceLayer: "landuse", colour: palette.industrial,
                     predicate: NSPredicate(format: "%K IN %@", "class", ["industrial", "garages", "railway"]), below: "landuse_pitch")
        addFillLayer(style, id: "looper-education", sourceLayer: "landuse", colour: palette.education,
                     predicate: NSPredicate(format: "%K IN %@", "class", ["university", "college", "kindergarten", "library"]), below: "landuse_pitch")
        addFillLayer(style, id: "looper-healthcare", sourceLayer: "landuse", colour: palette.healthcare,
                     predicate: NSPredicate(format: "%K == %@", "class", "healthcare"), below: "landuse_pitch")
        addFillLayer(style, id: "looper-recreation", sourceLayer: "landuse", colour: palette.sports,
                     predicate: NSPredicate(format: "%K IN %@", "class", ["stadium", "playground"]), below: "landuse_pitch")
        addFillLayer(style, id: "looper-military", sourceLayer: "landuse", colour: palette.military,
                     predicate: NSPredicate(format: "%K == %@", "class", "military"), below: "landuse_pitch")
        addFillLayer(style, id: "looper-quarry", sourceLayer: "landuse", colour: palette.quarry,
                     predicate: NSPredicate(format: "%K == %@", "class", "quarry"), below: "landuse_pitch")

        let ids = style.layers.map(\.identifier)
        lines(style, ids: ids.filter { $0.hasSuffix("_casing") }, colour: palette.casing, opacity: 0.9)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_motorway(_link)?$"#, options: .regularExpression) != nil }, colour: palette.motorway, opacity: 0.72)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_(trunk_primary|secondary_tertiary|link)$"#, options: .regularExpression) != nil }, colour: palette.mainRoad, opacity: 0.88)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_(minor|street)$"#, options: .regularExpression) != nil }, colour: palette.residentialRoad, opacity: 1)
        lines(style, ids: ids.filter { $0.range(of: #"^(road|bridge|tunnel)_service_track$"#, options: .regularExpression) != nil }, colour: palette.serviceRoad, opacity: 0.9)
        style.layer(withIdentifier: "road_path_pedestrian")?.isVisible = false
        lines(style, ids: ["bridge_path_pedestrian", "tunnel_path_pedestrian"], colour: palette.footway, opacity: 1)

        for id in ["poi_r20", "poi_r7", "poi_r1"] { style.layer(withIdentifier: id)?.isVisible = false }
        paint(style, ids: ["poi_transit"], as: MLNSymbolStyleLayer.self) {
            $0.textOpacity = NSExpression(forConstantValue: 0.5)
            $0.iconOpacity = NSExpression(forConstantValue: 0.5)
        }
        paint(style, ids: ids.filter { $0.range(of: #"(_label|place_|highway-name|water_name)"#, options: .regularExpression) != nil }, as: MLNSymbolStyleLayer.self) {
            $0.textColor = constant(palette.label)
            $0.textHaloColor = constant(palette.labelHalo)
        }

        addWalkingLayer(style, id: "looper-trails", colour: palette.trail, minimumZoom: 13, widths: [1, 1.8, 3.5],
                        predicate: NSPredicate(format: "%K == %@ OR %K IN %@", "class", "track", "subclass", ["path", "track"]), dashed: true)
        addWalkingLayer(style, id: "looper-footways", colour: palette.footway, minimumZoom: 14, widths: [0.8, 1.5, 3.5],
                        predicate: NSPredicate(format: "%K == %@ OR %K IN %@", "class", "pedestrian", "subclass", ["footway", "steps"]))
        addWalkingLayer(style, id: "looper-cycleways", colour: palette.cycleway, minimumZoom: 13, widths: [1, 1.8, 3.8],
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

    private static func addFillLayer(_ style: MLNStyle, id: String, sourceLayer: String, colour: String,
                                     predicate: NSPredicate, below siblingID: String) {
        if let layer = style.layer(withIdentifier: id) as? MLNFillStyleLayer {
            layer.fillColor = constant(colour)
            return
        }
        guard let source = style.source(withIdentifier: "openmaptiles") else { return }
        let layer = MLNFillStyleLayer(identifier: id, source: source)
        layer.sourceLayerIdentifier = sourceLayer
        layer.predicate = predicate
        layer.fillColor = constant(colour)
        layer.fillOpacity = NSExpression(forConstantValue: 1)
        if let sibling = style.layer(withIdentifier: siblingID) {
            style.insertLayer(layer, below: sibling)
        } else {
            style.addLayer(layer)
        }
    }

    private static func addWalkingLayer(_ style: MLNStyle, id: String, colour: String, minimumZoom: Double, widths: [Double],
                                        predicate: NSPredicate, dashed: Bool = false) {
        guard style.layer(withIdentifier: id) == nil,
              let source = style.source(withIdentifier: "openmaptiles") else { return }
        let layer = MLNLineStyleLayer(identifier: id, source: source)
        layer.sourceLayerIdentifier = "transportation"
        let surfaceOnly = NSPredicate(format: "NOT (%K IN %@)", "brunnel", ["bridge", "tunnel"])
        layer.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [surfaceOnly, predicate])
        layer.minimumZoomLevel = Float(minimumZoom)
        layer.lineColor = constant(colour)
        layer.lineWidth = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"], 14, widths[0], 16, widths[1], 19, widths[2]])
        layer.lineOpacity = NSExpression(forConstantValue: 1)
        layer.lineCap = NSExpression(forConstantValue: "round")
        layer.lineJoin = NSExpression(forConstantValue: "round")
        if dashed { layer.lineDashPattern = NSExpression(forConstantValue: [2, 1.4]) }
        if let roads = style.layer(withIdentifier: "road_motorway_link_casing") {
            style.insertLayer(layer, below: roads)
        } else {
            style.addLayer(layer)
        }
    }

    private static func constant(_ hex: String) -> NSExpression {
        NSExpression(forConstantValue: UIColor(hex: hex))
    }
}
