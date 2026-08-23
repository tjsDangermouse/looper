import Foundation

/// Displayed at the bottom of the welcome screen. The build number
/// (CURRENT_PROJECT_VERSION in project.yml) is bumped on every rebuild.
enum AppVersion {
    static var displayString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "v\(shortVersion) (\(build))"
    }
}
