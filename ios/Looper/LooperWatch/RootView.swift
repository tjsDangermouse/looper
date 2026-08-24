import LooperKit
import SwiftUI

struct RootView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        Group {
            switch model.screen {
            case .waiting:
                WaitingView()
            case .prepared:
                StartLoopView(model: model)
            case .working:
                WorkoutPages(model: model)
            case .finished:
                ResultView(model: model)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.screen)
    }
}

/// Nothing has been prepared. Said in one plain sentence rather than with an
/// empty dashboard.
private struct WaitingView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "figure.walk.circle")
                .font(.system(.largeTitle))
                .foregroundStyle(Color.looperAccent)
            Text("Pick a loop on your iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("It’ll appear here, ready to start.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}
