import SwiftUI

/// The phone app's palette, as much of it as a Watch screen wants. The Watch
/// is dark because the phone's walk screen is dark, and because a workout
/// screen glanced at in the dark shouldn't be a torch.
extension Color {
    init(hex: String) {
        var value = UInt64(0)
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(
            red: Double((value & 0xFF0000) >> 16) / 255,
            green: Double((value & 0x00FF00) >> 8) / 255,
            blue: Double(value & 0x0000FF) / 255
        )
    }

    static let looperAccent = Color(hex: "9cc36b")
    static let looperRaised = Color(hex: "0d2437")
    static let looperOnAccent = Color(hex: "06180a")
    static let looperHeart = Color(hex: "e0596b")
}
