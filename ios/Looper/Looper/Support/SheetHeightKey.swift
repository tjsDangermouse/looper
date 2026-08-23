import SwiftUI

/// Reports a bottom sheet's measured height up to the root view, which hands
/// it to the map as padding — the native equivalent of the web app's
/// ResizeObserver-on-the-sheet trick, so the start marker stays centred in
/// the strip of map the sheet leaves visible.
struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    // The map view sits alongside the sheet in the same ZStack and never
    // sets this preference itself, so it implicitly contributes the default
    // (0). Taking the max — rather than just the latest value — keeps that
    // default from stomping the sheet's real, non-zero height when SwiftUI
    // merges the siblings' preferences.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
