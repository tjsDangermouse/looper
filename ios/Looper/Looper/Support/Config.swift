import Foundation

/// Where Looper's own route service lives — a build-time setting, set per
/// configuration in project.yml, mirroring the web app's build-time
/// VITE_LOOPER_API_BASE.
enum Config {
    static var apiBase: String {
        (Bundle.main.object(forInfoDictionaryKey: "LooperAPIBase") as? String ?? "").trimmingCharacters(in: .whitespaces)
    }
}
