import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: String) {
        var value = UInt64(0)
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255
        let g = Double((value & 0x00FF00) >> 8) / 255
        let b = Double(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }

    static let looperBackground = Color(hex: "061523")
    static let looperSheet = Color(hex: "08192b")
    static let looperRaised = Color(hex: "0d2437")
    static let looperLine = Color(hex: "1d3448")
    static let looperAccent = Color(hex: "9cc36b")
    /// Map chrome floats over the map, so it is translucent rather than
    /// solid — plain alpha, because MapLibre draws into a Metal layer that a
    /// material's backdrop cannot sample.
    static let looperGlass = Color.white.opacity(0.32)
    static let looperGlassLine = Color(hex: "b8c1c4").opacity(0.8)
    static let looperOnGlass = Color(hex: "243640")
    static let looperOnAccent = Color(hex: "06180a")
}
