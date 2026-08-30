import Foundation

public enum LooperAPIError: Error, LocalizedError, Equatable {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

struct LoopRequestBody: Encodable {
    struct StartPoint: Encodable {
        let lng: Double
        let lat: Double
    }

    let start: StartPoint
    let mode: LoopMode
    let distanceKm: Double?
    let durationMinutes: Double?
    let units: Unit
    let activity: Activity?
    let walkingPaceMinutes: Double?
    let walkingPaceUnit: Unit?
    let variation: Int
    let waypoints: [StartPoint]?
    let exclude: [[Point]]?
    let routingEngine: RoutingEngine?

    enum CodingKeys: String, CodingKey {
        case start, mode, distanceKm, durationMinutes, units, activity, walkingPaceMinutes, walkingPaceUnit, variation, waypoints, exclude, routingEngine
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(distanceKm, forKey: .distanceKm)
        try container.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try container.encode(units, forKey: .units)
        try container.encodeIfPresent(activity, forKey: .activity)
        try container.encodeIfPresent(walkingPaceMinutes, forKey: .walkingPaceMinutes)
        try container.encodeIfPresent(walkingPaceUnit, forKey: .walkingPaceUnit)
        try container.encode(variation, forKey: .variation)
        try container.encodeIfPresent(waypoints, forKey: .waypoints)
        try container.encodeIfPresent(exclude, forKey: .exclude)
        try container.encodeIfPresent(routingEngine, forKey: .routingEngine)
    }
}

private let exclusionPointLimit = 120
private func compactRoute(_ coordinates: [Point]) -> [Point] {
    guard coordinates.count > exclusionPointLimit else { return coordinates }
    return (0..<exclusionPointLimit).map { index in
        coordinates[Int((Double(index) * Double(coordinates.count - 1) / Double(exclusionPointLimit - 1)).rounded())]
    }
}

private struct LoopsResponseBody: Decodable {
    struct RouteDTO: Decodable {
        let id: String
        let label: String
        let distanceMeters: Double
        let durationSeconds: Double
        let targetDifferencePercent: Double
        let geometry: LineGeometry
        let steps: [Step]
        let reversed: Bool?
    }

    /// The service's own account of how the answer was produced. Every field
    /// is optional: a service that predates the engine selector simply does
    /// not send it, and the app must go on working when it doesn't.
    struct EngineDTO: Decodable {
        let routingEngine: String?
        let requestedEngine: String?
        let engineReason: String?
        let generationMs: Double?
        let fallbackReason: String?
        let searchClosedWalks: Int?
        let searchStates: Int?
        let searchMs: Double?
    }

    let routes: [RouteDTO]?
    let warning: String?
    let expectationExceeded: Bool?
    let error: String?
    let engine: EngineDTO?
}

public struct LoopsResult {
    public var routes: [Route]
    public var warning: String?
    public var expectationExceeded: Bool
    /// Absent against a service that does not report one. Developer-facing.
    public var engine: RoutingEngineReport?

    public init(routes: [Route], warning: String? = nil, expectationExceeded: Bool = false, engine: RoutingEngineReport? = nil) {
        self.routes = routes
        self.warning = warning
        self.expectationExceeded = expectationExceeded
        self.engine = engine
    }
}

/// Talks HTTP for `requestLoops` — a seam so tests can stand in for the network
/// exactly as the web tests stand in for `fetch`.
public protocol LoopsHTTPClient {
    func post(url: URL, body: Data) async throws -> (data: Data, statusCode: Int)
}

public struct URLSessionLoopsHTTPClient: LoopsHTTPClient {
    public init() {}

    public func post(url: URL, body: Data) async throws -> (data: Data, statusCode: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LooperAPIError.message("Routes are unavailable right now.")
        }
        return (data, http.statusCode)
    }
}

/// Ask for loops. Errors carry a sentence a walker can act on, nothing more.
public func requestLoops(
    start: Point,
    mode: LoopMode,
    distanceKm: Double? = nil,
    durationMinutes: Double? = nil,
    unit: Unit,
    activity: Activity? = nil,
    walkingPaceMinutes: Double? = nil,
    walkingPaceUnit: Unit? = nil,
    variation: Int,
    waypoints: [Point] = [],
    excludeRoutes: [Route] = [],
    routingEngine: RoutingEngine? = nil,
    apiBase: String,
    client: LoopsHTTPClient
) async throws -> LoopsResult {
    guard let url = URL(string: "\(apiBase)/v1/loops") else {
        throw LooperAPIError.message("Routes are unavailable right now.")
    }
    let body = LoopRequestBody(
        start: .init(lng: start.lng, lat: start.lat),
        mode: mode,
        distanceKm: mode == .distance ? distanceKm : nil,
        durationMinutes: mode == .time ? durationMinutes : nil,
        units: unit,
        activity: activity,
        walkingPaceMinutes: walkingPaceMinutes,
        walkingPaceUnit: walkingPaceUnit,
        variation: variation,
        waypoints: waypoints.isEmpty ? nil : waypoints.map { .init(lng: $0.lng, lat: $0.lat) },
        exclude: excludeRoutes.isEmpty ? nil : excludeRoutes.map { compactRoute($0.geometry.coordinates) },
        routingEngine: routingEngine
    )
    let encoded = try JSONEncoder().encode(body)
    let (data, statusCode) = try await client.post(url: url, body: encoded)
    let decoded = try? JSONDecoder().decode(LoopsResponseBody.self, from: data)
    guard (200..<300).contains(statusCode) else {
        throw LooperAPIError.message(decoded?.error ?? "Routes are unavailable right now.")
    }
    guard let decoded else {
        throw LooperAPIError.message("Routes are unavailable right now.")
    }
    // An answer from a service that does not report an engine is read as
    // coming from the current one, which is what it is.
    let report = decoded.engine.map { dto in
        RoutingEngineReport(
            routingEngine: dto.routingEngine.flatMap(RoutingEngine.init(rawValue:)) ?? .remote,
            requestedEngine: dto.requestedEngine.flatMap(RoutingEngine.init(rawValue:)),
            engineReason: dto.engineReason,
            generationMs: dto.generationMs,
            fallbackReason: dto.fallbackReason,
            searchClosedWalks: dto.searchClosedWalks,
            searchStates: dto.searchStates,
            searchMs: dto.searchMs
        )
    }
    // The service names a loop for the way it heads; the app has always called
    // that a route's name.
    let routes = (decoded.routes ?? []).map { dto in
        Route(
            id: dto.id,
            name: dto.label,
            distanceMeters: dto.distanceMeters,
            durationSeconds: dto.durationSeconds,
            targetDifferencePercent: dto.targetDifferencePercent,
            geometry: dto.geometry,
            steps: dto.steps,
            reversed: dto.reversed,
            routingEngine: report?.routingEngine
        )
    }
    return LoopsResult(routes: routes, warning: decoded.warning, expectationExceeded: decoded.expectationExceeded ?? false, engine: report)
}
