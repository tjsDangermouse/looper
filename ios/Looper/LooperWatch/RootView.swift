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
                    WaitingView()
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
/// empty dashboard.
private struct WaitingView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("LooperIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Pick a loop on your iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(WatchAppVersion.displayString)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}
