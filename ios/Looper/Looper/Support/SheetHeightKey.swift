import SwiftUI

/// Reports a bottom sheet's measured height up to the root view, which hands
/// it to the map as padding — the native equivalent of the web app's
/// ResizeObserver-on-the-sheet trick, so the start marker stays centred in
/// the strip of map the sheet leaves visible.
struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
