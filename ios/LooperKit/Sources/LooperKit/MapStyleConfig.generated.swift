// Generated from map-styles.json by the local map style editor. Do not edit by hand.
import Foundation

public struct MapStylePalette: Hashable, Sendable {
    public let background: String
    public let residential: String
    public let commercial: String
    public let industrial: String
    public let education: String
    public let healthcare: String
    public let water: String
    public let waterLine: String
    public let park: String
    public let parkOutline: String
    public let grass: String
    public let farmland: String
    public let woodland: String
    public let wetland: String
    public let sand: String
    public let rock: String
    public let ice: String
    public let sports: String
    public let cemetery: String
    public let military: String
    public let quarry: String
    public let aerodrome: String
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
            commercial: "#eadfcf",
            industrial: "#deddd8",
            education: "#eceecc",
            healthcare: "#ffddee",
            water: "#cae8f1",
            waterLine: "#00c3ff",
            park: "#bddc9e",
            parkOutline: "#172e00",
            grass: "#b8d89a",
            farmland: "#e4ddb0",
            woodland: "#c4e198",
            wetland: "#b8d8c8",
            sand: "#f3e3ad",
            rock: "#d5d0c4",
            ice: "#e0ecec",
            sports: "#cfe3b5",
            cemetery: "#d5dfb8",
            military: "#e6d2d2",
            quarry: "#d6d0c8",
            aerodrome: "#e5e4e0",
            building: "#cccccc",
            casing: "#c4c4c4",
            motorway: "#f05656",
            mainRoad: "#fde753",
            residentialRoad: "#ffffff",
            serviceRoad: "#ffffff",
            footway: "#bfc167",
            trail: "#359c46",
            cycleway: "#ffffff",
            label: "#000000",
            labelHalo: "#e3e3e3"
        )
    ),
    MapStyleDefinition(
        id: "dark-night",
        name: "Dark",
        palette: MapStylePalette(
            background: "#6b6b6b",
            residential: "#2c381e",
            commercial: "#4b4338",
            industrial: "#454545",
            education: "#414631",
            healthcare: "#503b45",
            water: "#30505a",
            waterLine: "#005670",
            park: "#425714",
            parkOutline: "#172e00",
            grass: "#3d522c",
            farmland: "#514d32",
            woodland: "#44670e",
            wetland: "#334e48",
            sand: "#5b533b",
            rock: "#4f4d49",
            ice: "#607070",
            sports: "#3e562f",
            cemetery: "#414b32",
            military: "#503b3b",
            quarry: "#4b4742",
            aerodrome: "#484848",
            building: "#666666",
            casing: "#4a4a4a",
            motorway: "#511a1a",
            mainRoad: "#61581f",
            residentialRoad: "#404040",
            serviceRoad: "#4d4c4c",
            footway: "#444d00",
            trail: "#3cc352",
            cycleway: "#8f8f8f",
            label: "#e8e8e8",
            labelHalo: "#b3b3b3"
        )
    )
]

public let routeColours = ["#ff7438","#00a2ff","#d151e1"]
