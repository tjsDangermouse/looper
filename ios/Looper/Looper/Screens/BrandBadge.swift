import SwiftUI

/// The small "Looper" pill shown over the map on every screen but Welcome
/// and Walk (the walk screen's own header already occupies that corner) —
/// matches the web app's `.brand` badge.
struct BrandBadge: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: "9cc36b"))
            Text("LOOPER")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.white)
        }
        .padding(.leading, 9)
        .padding(.trailing, 13)
        .padding(.vertical, 7)
        .background(Color.looperSheet, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
    }
}
