// Generated from map-styles.json by the local map style editor. Do not edit by hand.
import Foundation

public struct MapStylePalette: Hashable, Sendable {
    public let background: String
    public let residential: String
    public let water: String
    public let park: String
    public let parkOutline: String
    public let woodland: String
    public let waterLine: String
    public let building: String
    public let casing: String
    public let motorway: String
    public let mainRoad: String
    public let residentialRoad: String
    public let serviceRoad: String
    public let footway: String
    public let trail: String
    public let cycleway: String
    public let label: String
    public let labelHalo: String
}

public struct MapStyleDefinition: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let palette: MapStylePalette
}

public let customMapStyles: [MapStyleDefinition] = [
    MapStyleDefinition(
        id: "looper",
        name: "Looper",
        palette: MapStylePalette(
            background: "#e4e4d7",
            residential: "#5c793e",
            water: "#cae8f1",
            park: "#70a300",
            parkOutline: "#172e00",
            woodland: "#c4e198",
            waterLine: "#00c3ff",
            building: "#c6c3c3",
            casing: "#878787",
            motorway: "#f05656",
            mainRoad: "#fde753",
            residentialRoad: "#ffffff",
            serviceRoad: "#ffffff",
            footway: "#c9c9c9",
            trail: "#359c46",
            cycleway: "#ffffff",
            label: "#000000",
            labelHalo: "#e3e3e3"
        )
    )
]

public let routeColours = ["#9cc36b","#5fa8d3","#e0a35c"]
