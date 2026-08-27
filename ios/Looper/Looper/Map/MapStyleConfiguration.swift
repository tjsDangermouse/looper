import Foundation

/// The basemap provider is kept independent from Looper's route and camera
/// code so a hosted, custom Looper style can replace OpenFreeMap Liberty later.
enum MapStyleConfiguration {
    static let provider = "OpenFreeMap"
    static let styleName = "liberty"
    static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
}
