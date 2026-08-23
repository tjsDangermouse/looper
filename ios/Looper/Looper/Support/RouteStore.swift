import Foundation
import LooperKit

/// Saves the last-started route so it can be shown again offline — the
/// native equivalent of the web app's `looper-route` localStorage entry.
final class RouteStore {
    private let key = "looper-route"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ route: Route) {
        guard let data = try? JSONEncoder().encode(route) else { return }
        defaults.set(data, forKey: key)
    }

    func load() -> Route? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Route.self, from: data)
    }
}

/// Keeps routes a person explicitly wants to return to. These are separate
/// from the last-started route: beginning a walk should not turn it into a
/// favourite by accident.
final class FavoritesStore {
    private let key = "looper-favorite-routes"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [Route] {
        guard let data = defaults.data(forKey: key),
              let routes = try? JSONDecoder().decode([Route].self, from: data) else { return [] }
        return routes
    }

    func save(_ routes: [Route]) {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        defaults.set(data, forKey: key)
    }
}
