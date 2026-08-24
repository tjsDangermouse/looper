import HealthKit
import SwiftUI
import WatchKit

@main
struct LooperWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(model: delegate.model)
        }
    }
}

/// The delegate exists for one reason: the phone can start a workout on this
/// wrist, and HealthKit hands the configuration for it to the app delegate.
/// The model is owned here so it is alive before any UI is, which matters
/// when the app is launched into the background by that very handoff.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    @MainActor let model = WatchModel()

    func applicationDidFinishLaunching() {
        Task { @MainActor in model.activate() }
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in model.handle(workoutConfiguration) }
    }
}
