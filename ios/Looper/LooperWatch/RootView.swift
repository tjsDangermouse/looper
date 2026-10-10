import LooperKit
import SwiftUI

enum WatchAppVersion {
    static var displayString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(version) (\(build))"
    }
}

struct RootView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        Group {
            switch model.launchPhase {
            case .permissions:
                PermissionLoadingView()
            case .blocked(let message):
                PermissionBlockedView(message: message, retry: model.retryPermissions)
            case .ready:
                switch model.screen {
                case .waiting:
                    WaitingView(model: model)
                case .prepared:
                    StartLoopView(model: model)
                case .working:
                    WorkoutPages(model: model)
                case .finished:
                    ResultView(model: model)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.screen)
        .animation(.easeInOut(duration: 0.2), value: model.launchPhase)
    }
}

private struct PermissionLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Setting up Looper…")
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionBlockedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield")
                .font(.title2)
                .foregroundStyle(Color.looperAccent)
            Text("Permission needed")
                .font(.headline)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Nothing has been prepared. Said in one plain sentence rather than with an
/// Nothing has been prepared. Either the saved routes to choose from, or one
/// plain sentence saying where routes come from.
private struct WaitingView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        if model.savedRoutes.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title2)
                    .foregroundStyle(Color.looperAccent)
                Text("Pick a loop on your iPhone")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Routes you save there appear here, ready to walk without it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a route")
                        .font(.headline)
                        .padding(.horizontal, 4)
                    SavedRoutesList(model: model)
                    Text(WatchAppVersion.displayString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
