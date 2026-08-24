import Foundation
import LooperKit
import UIKit

/// The walker's Apple Health preference and the current permission picture,
/// in a form the Settings row and the Loop Summary can both observe. The
/// HealthKit calls themselves stay in `HealthKitService`.
@MainActor
final class HealthIntegration: ObservableObject {
    /// Whether the walker has asked for their loops to go to Apple Health.
    /// Authorisation is only ever requested off the back of this, or of
    /// finishing an outing — never on first launch.
    @Published private(set) var isEnabled: Bool
    @Published private(set) var availability: HealthAvailability = .notDetermined
    /// Set while the system permission sheet is up, so the UI can hold still.
    @Published private(set) var isRequesting = false

    private let service: WorkoutSaving
    private let defaults: UserDefaults
    private static let enabledKey = "health-integration-enabled"

    init(service: WorkoutSaving = HealthKitService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    var saver: WorkoutSaving { service }

    /// True once the walker has turned the integration on and Health will
    /// actually accept a write.
    var canSave: Bool { isEnabled && availability.canSave }

    func refreshAvailability() async {
        availability = await service.availability
        // Permission revoked in Settings shouldn't leave the app claiming to
        // be connected.
        if availability == .unavailable, isEnabled { setEnabled(false) }
    }

    /// Turns the integration on, asking for permission the first time. Returns
    /// whether saving is now possible.
    @discardableResult
    func enable() async -> Bool {
        isRequesting = true
        defer { isRequesting = false }
        availability = await service.requestAuthorization()
        let allowed = availability.canSave
        setEnabled(allowed)
        return allowed
    }

    func disable() {
        setEnabled(false)
    }

    private func setEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: Self.enabledKey)
    }

    /// Health permissions can only be changed from the system Settings app
    /// once they've been declined.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
