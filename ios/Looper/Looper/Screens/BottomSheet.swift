import SwiftUI

/// A drag handle collapses the sheet down to a thin strip — the whole point
/// being to hand the map back the room the sheet was covering, which the map
/// picks up on its own via SheetHeightKey once the sheet's real (now
/// smaller) height is measured.
struct BottomSheet<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var isCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            handle
            if !isCollapsed {
                content
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, isCollapsed ? 4 : 24)
        .frame(maxWidth: .infinity)
        .background(
            Color.looperSheet
                .clipShape(.rect(topLeadingRadius: 20, topTrailingRadius: 20))
                .ignoresSafeArea(edges: .bottom)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
            }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isCollapsed)
    }

    /// A generous full-width strip around the visible capsule, so the drag
    /// and tap targets are comfortable without the gesture reaching into the
    /// content below (route cards, buttons, the distance field) and
    /// swallowing their own taps.
    private var handle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { isCollapsed.toggle() }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        if value.translation.height > 24 {
                            isCollapsed = true
                        } else if value.translation.height < -24 {
                            isCollapsed = false
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isCollapsed ? "Expand panel" : "Collapse panel")
    }
}
