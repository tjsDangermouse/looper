import Foundation

/// What the app asks for when it wants loops. Engine-neutral by construction:
/// nothing here names a service, a graph, or a file.
public struct LoopRequest: Sendable {
    public var start: Point
    public var mode: LoopMode
    public var distanceKm: Double?
    public var durationMinutes: Double?
    public var unit: Unit
    public var activity: Activity?
    public var walkingPaceMinutes: Double?
    public var walkingPaceUnit: Unit?
    public var variation: Int
    public var waypoints: [Point]
    public var excludeRoutes: [Route]
    /// Progress while routing data is being acquired. Only an engine that
    /// acquires data calls it; the remote engine never does.
    public var onDataProgress: (@Sendable (LoopDataProgress) -> Void)?

    public init(
        start: Point, mode: LoopMode, distanceKm: Double? = nil, durationMinutes: Double? = nil,
        unit: Unit, activity: Activity? = nil, walkingPaceMinutes: Double? = nil,
        walkingPaceUnit: Unit? = nil, variation: Int = 0, waypoints: [Point] = [],
        excludeRoutes: [Route] = [], onDataProgress: (@Sendable (LoopDataProgress) -> Void)? = nil
    ) {
        self.start = start
        self.mode = mode
        self.distanceKm = distanceKm
        self.durationMinutes = durationMinutes
        self.unit = unit
        self.activity = activity
        self.walkingPaceMinutes = walkingPaceMinutes
        self.walkingPaceUnit = walkingPaceUnit
        self.variation = variation
        self.waypoints = waypoints
        self.excludeRoutes = excludeRoutes
        self.onDataProgress = onDataProgress
    }

    /// The length being asked for, in metres, whichever way it was asked.
    public func targetMetres(paceMinutesPerKm: Double) -> Double {
        switch mode {
        case .distance:
            let amount = distanceKm ?? 0
            return unit == .mi ? amount * 1609.344 : amount * 1000
        case .time:
            let minutes = durationMinutes ?? 0
            return paceMinutesPerKm > 0 ? minutes / paceMinutesPerKm * 1000 : 0
        }
    }
}

public struct LoopDataProgress: Sendable, Equatable {
    public var completedRequests: Int
    public var totalRequests: Int
    public var downloadedBytes: Int

    public var fraction: Double {
        totalRequests > 0 ? Double(completedRequests) / Double(totalRequests) : 0
    }
}

public struct LoopResponse {
    public var routes: [Route]
    public var warning: String?
    public var expectationExceeded: Bool
    /// What the service said, when a service answered. Absent on-device.
    public var engine: RoutingEngineReport?
    /// What the local router did, when it was the one that answered.
    public var localDiagnostics: LocalLoopRouter.Diagnostics?
    /// Which engine actually produced these routes. Never inferred.
    public var routingEngine: RoutingEngine

    public init(
        routes: [Route], warning: String? = nil, expectationExceeded: Bool = false,
        engine: RoutingEngineReport? = nil, localDiagnostics: LocalLoopRouter.Diagnostics? = nil,
        routingEngine: RoutingEngine
    ) {
        self.routes = routes
        self.warning = warning
        self.expectationExceeded = expectationExceeded
        self.engine = engine
        self.localDiagnostics = localDiagnostics
        self.routingEngine = routingEngine
    }
}

/// The seam.
///
/// Two implementations, and the rest of the app consumes the same route model
/// from either. This is what makes the comparison honest: the map, the walk
/// screen, the spoken guidance, the Watch and the saved favourites all behave
/// identically, so the only thing a field test is comparing is the walk.
public protocol LoopRoutingEngine: Sendable {
    func generateLoops(_ request: LoopRequest) async throws -> LoopResponse
}

// MARK: - Remote

/// The existing hosted engine, wrapped and otherwise untouched.
///
/// This calls `requestLoops` exactly as the app has always called it: the same
/// URL, the same body, the same response handling. Nothing about the remote
/// path changes because a second engine exists — it is retained so that the
/// two can be compared on real ground, and a retained baseline that quietly
/// drifted would be worth nothing.
public struct RemoteLoopRoutingEngine: LoopRoutingEngine {
    private let apiBase: String
    private let client: LoopsHTTPClient

    public init(apiBase: String, client: LoopsHTTPClient) {
        self.apiBase = apiBase
        self.client = client
    }

    public func generateLoops(_ request: LoopRequest) async throws -> LoopResponse {
        let result = try await requestLoops(
            start: request.start,
            mode: request.mode,
            distanceKm: request.mode == .distance ? request.distanceKm : nil,
            durationMinutes: request.mode == .time ? request.durationMinutes : nil,
            unit: request.unit,
            activity: request.activity,
            walkingPaceMinutes: request.walkingPaceMinutes,
            walkingPaceUnit: request.walkingPaceUnit,
            variation: request.variation,
            waypoints: request.waypoints,
            excludeRoutes: request.excludeRoutes,
            apiBase: apiBase,
            client: client
        )
        return LoopResponse(
            routes: result.routes.map { route in
                var route = route
                route.routingEngine = .remote
                return route
            },
            warning: result.warning,
            expectationExceeded: result.expectationExceeded,
            engine: RoutingEngineReport(routingEngine: .remote),
            routingEngine: .remote
        )
    }
}

/// Counts every routing call the app makes to Looper's own service.
///
/// A decorator rather than a change to `URLSessionLoopsHTTPClient`, so the
/// remote path's behaviour is identical with it and without it. Its whole
/// purpose is that "the on-device engine made zero Looper routing calls" can
/// be a measurement instead of a claim.
public struct AuditingLoopsHTTPClient: LoopsHTTPClient {
    private let wrapped: LoopsHTTPClient
    private let audit: RoutingAudit

    public init(wrapping wrapped: LoopsHTTPClient = URLSessionLoopsHTTPClient(), audit: RoutingAudit = .shared) {
        self.wrapped = wrapped
        self.audit = audit
    }

    public func post(url: URL, body: Data) async throws -> (data: Data, statusCode: Int) {
        // Logged as well as counted. In On-device mode this line must never
        // appear, and a silence nobody can see is not evidence of anything.
        RoutingLog.remote.info("looper routing request \(url.absoluteString, privacy: .public)")
        await audit.recordLooperRoutingRequest(url: url.absoluteString)
        return try await wrapped.post(url: url, body: body)
    }
}

// MARK: - On device

/// The new engine: raw OSM path data straight from an external provider,
/// cached on the phone, and every routing decision made here.
///
/// Note what this type cannot do, by construction rather than by discipline:
/// it holds no `LoopsHTTPClient`, no API base, and no reference to
/// `RemoteLoopRoutingEngine`. There is no code path from here to Looper's
/// routing service, which is why the "did it secretly fall back" question has
/// a structural answer and not just a test.
public actor OnDeviceLoopRoutingEngine: LoopRoutingEngine {
    private let data: RoutingDataManager
    private let store: RoutingChunkStore
    private let router: LocalLoopRouter
    private let policy: PedestrianAccessPolicy

    /// One built graph, kept between requests. Asking for a second set of
    /// loops from the same doorstep is the common case, and rebuilding a
    /// town's graph to answer it is the single largest avoidable cost.
    private var cachedKey: String?
    private var cachedGraph: LocalWalkingGraph?
    private var cachedIndex: LocalEdgeIndex?

    public init(
        store: RoutingChunkStore,
        source: RoutingDataSource,
        grid: RoutingChunkGrid = .standard,
        audit: RoutingAudit? = .shared,
        policy: PedestrianAccessPolicy = .standard
    ) {
        self.store = store
        self.data = RoutingDataManager(store: store, source: source, grid: grid, audit: audit)
        self.router = LocalLoopRouter()
        self.policy = policy
    }

    /// The app's ordinary configuration: the on-device store, and the public
    /// Overpass endpoint as the OSM data source.
    public static func standard(
        endpoint: URL = OverpassRoutingDataSource.Configuration.publicOverpass
    ) -> OnDeviceLoopRoutingEngine {
        OnDeviceLoopRoutingEngine(
            store: .applicationDefault(),
            source: OverpassRoutingDataSource(configuration: .init(endpoint: endpoint))
        )
    }

    public func generateLoops(_ request: LoopRequest) async throws -> LoopResponse {
        let pace = request.walkingPaceMinutes ?? 12
        let paceMinutesPerKm = request.walkingPaceUnit == .mi ? pace / 1.609344 : pace
        let targetMetres = request.targetMetres(paceMinutesPerKm: paceMinutesPerKm)
        guard targetMetres > 0 else { throw LocalLoopRouter.Failure.noLoopFound }

        let progress = request.onDataProgress
        do {
            _ = try await data.ensureCoverage(
                lat: request.start.lat, lon: request.start.lng, targetMetres: targetMetres,
                // The pins widen the area that has to be on the phone. A walk
                // through a place two kilometres away needs that place.
                waypoints: request.waypoints,
                onProgress: progress.map { handler in
                    { @Sendable update in
                        handler(LoopDataProgress(
                            completedRequests: update.completedRequests,
                            totalRequests: update.totalRequests,
                            downloadedBytes: update.downloadedBytes
                        ))
                    }
                }
            )
        } catch RoutingDataManager.AcquisitionError.source(.offline) {
            // The device has no network and the data is not here. Say so; do
            // not reach for the remote router, which would make a comparison
            // test meaningless.
            //
            // Note what is *not* caught: `providerUnavailable`. A walker with
            // a working connection whose OSM provider is down has a different
            // problem, and telling them to connect would send them looking for
            // a fault they do not have.
            throw RoutingDataManager.AcquisitionError.dataUnavailableOffline
        }

        let (graph, index) = try await graphFor(
            lat: request.start.lat, lon: request.start.lng,
            targetMetres: targetMetres, waypoints: request.waypoints
        )

        // Ordered pins are a different question from a ring, and they get a
        // different search — but the same graph, the same gate and the same
        // guarantee: no routing call leaves this device either way.
        if !request.waypoints.isEmpty {
            return try waypointLoops(request, targetMetres: targetMetres, graph: graph, index: index)
        }

        // The generator the service itself answers walkers with, ported. The
        // closed-walk search it replaces is still here and still tested —
        // `LocalLoopRouter.findLoops` — because the two want measuring against
        // each other on the same ground, and because a walker's answer should
        // not depend on which of them was easier to reach for.
        let result = try router.findRingLoops(
            .init(
                lat: request.start.lat, lon: request.start.lng, targetMetres: targetMetres,
                wanted: 3, variation: request.variation,
                exclude: request.excludeRoutes.map(\.geometry.coordinates)
            ),
            in: graph, index: index
        )
        let d = result.diagnostics
        let pavement = d.offeredPavement.isEmpty ? 0 : d.offeredPavement.reduce(0) { $0 + $1.share } / Double(d.offeredPavement.count)
        RoutingLog.search.info("local ring graph=\(d.graphNodes)n/\(d.graphEdges)e built=\(d.candidatesBuilt) abandoned=\(d.candidatesAbandoned) judged=\(d.closedWalks) gate-]=\(d.gateRejected) passed=\(d.passedGate) batches=\(d.batchesRun) seen-]=\(d.excludedAsAlreadySeen)\(d.excludeExhausted ? "!" : "") alike-]=\(d.diversityRejected) offered=\(d.offered) pave=\(Int(pavement * 100))% sweepMs=\(Int(d.sweepMs)) totalMs=\(Int(d.totalMs)) failure=\(d.failure ?? "-", privacy: .public)")
        guard !result.routes.isEmpty else {
            throw LocalLoopRouter.Failure.noLoopFound
        }
        // Nothing to filter here: a walk already offered from this doorstep was
        // taken out of the pool before the selector saw it, which is the only
        // place removing it can actually produce a different walk.
        return LoopResponse(
            routes: result.routes,
            localDiagnostics: result.diagnostics,
            routingEngine: .onDevice
        )
    }

    /// Walks through ordered pins.
    ///
    /// Separated from the ring case only so that each reads as the one thing
    /// it is. Note what this does *not* do: reach for the remote engine. A
    /// waypoint walk the device cannot build is reported as such, in the same
    /// words the service would use, because an engine that quietly changes
    /// under a comparison is not a comparison.
    private func waypointLoops(
        _ request: LoopRequest, targetMetres: Double,
        graph: LocalWalkingGraph, index: LocalEdgeIndex
    ) throws -> LoopResponse {
        let result = try router.findWaypointLoops(
            .init(
                start: request.start, waypoints: request.waypoints, targetMetres: targetMetres,
                variation: request.variation,
                exclude: request.excludeRoutes.map(\.geometry.coordinates)
            ),
            in: graph, index: index
        )
        let d = result.diagnostics
        RoutingLog.search.info("local waypoints pins=\(d.waypointCount) stage=\(d.waypointStage ?? "backbone", privacy: .public) backbone=\(Int(d.waypointBackboneMetres))m options=\(d.waypointOptions) allocations=\(d.waypointAllocations) enclosing=\(d.waypointEnclosing) passedGate=\(d.passedGate) offered=\(d.offered) totalMs=\(Int(d.totalMs)) failure=\(d.failure ?? "-", privacy: .public)")

        // The pins alone need more ground than the plan allows. Say how much
        // more: a walker can act on "at least 8.2 km" and cannot act on "no".
        if let minimum = result.minimumMetres {
            return LoopResponse(
                routes: [],
                warning: Self.tooFarForPlan(minimum, request: request, targetMetres: targetMetres),
                expectationExceeded: true,
                localDiagnostics: result.diagnostics,
                routingEngine: .onDevice
            )
        }
        guard !result.routes.isEmpty else {
            // The router reports rather than throws, so the diagnostics that
            // say *which* gate refused every walk survive to the log line
            // above. Turning that into an error is this layer's job.
            throw LooperAPIError.message(result.warning
                ?? "We couldn’t find a clean loop of that length through those waypoints. Try a different distance, or move a waypoint.")
        }
        return LoopResponse(
            routes: result.routes,
            warning: result.warning,
            localDiagnostics: result.diagnostics,
            routingEngine: .onDevice
        )
    }

    /// The service's own refusal, worded the same way and in the walker's own
    /// units. Parity here is not cosmetic: the two engines refusing the same
    /// request differently is exactly the kind of difference a field test
    /// would misread as a routing difference.
    static func tooFarForPlan(_ minimumMetres: Double, request: LoopRequest, targetMetres: Double) -> String {
        let overBy = Int((LocalLoopRouter.waypointDistanceTolerance * 100).rounded())
        let needed: String
        let asked: String
        switch request.mode {
        case .distance where request.unit == .mi:
            needed = String(format: "%.1f miles", minimumMetres / 1609.344)
            asked = String(format: "%.1f miles", (request.distanceKm ?? 0))
        case .distance:
            needed = String(format: "%.1f km", minimumMetres / 1000)
            asked = String(format: "%.1f km", request.distanceKm ?? 0)
        case .time:
            let pace = targetMetres > 0 ? (request.durationMinutes ?? 0) / targetMetres : 0
            needed = "\(Int((minimumMetres * pace).rounded(.up))) minutes"
            asked = "\(Int((request.durationMinutes ?? 0).rounded())) minutes"
        }
        return "These waypoints need at least \(needed), which is more than \(overBy)% over your \(asked) plan. Increase your plan or remove a waypoint."
    }

    /// Build the graph, or reuse the one already built for this ground.
    private func graphFor(
        lat: Double, lon: Double, targetMetres: Double, waypoints: [Point] = []
    ) async throws -> (LocalWalkingGraph, LocalEdgeIndex) {
        let chunks = RoutingCoverage.requiredChunks(
            start: Point(lon, lat), waypoints: waypoints, targetMetres: targetMetres
        )
        let key = chunks.map(\.key).joined(separator: ",")
        if key == cachedKey, let graph = cachedGraph, let index = cachedIndex { return (graph, index) }
        let merged = await store.merged(chunks)
        let (graph, _) = LocalWalkingGraphBuilder.build(from: merged, policy: policy)
        let index = LocalEdgeIndex(graph: graph)
        cachedKey = key
        cachedGraph = graph
        cachedIndex = index
        return (graph, index)
    }

    /// Fill and pin an area, for the Offline Areas feature this store already
    /// supports. Exposed here so the app has one door to the routing data.
    @discardableResult
    public func downloadOfflineArea(
        _ bounds: GeographicBounds,
        onProgress: (@Sendable (LoopDataProgress) -> Void)? = nil
    ) async throws -> RoutingDataManager.AcquisitionReport {
        try await data.downloadOfflineArea(bounds, onProgress: onProgress.map { handler in
            { @Sendable update in
                handler(LoopDataProgress(
                    completedRequests: update.completedRequests,
                    totalRequests: update.totalRequests,
                    downloadedBytes: update.downloadedBytes
                ))
            }
        })
    }

    /// What the phone already holds for this walk, without fetching anything.
    public func coverage(lat: Double, lon: Double, targetMetres: Double) async -> RoutingDataManager.Coverage {
        await data.coverage(lat: lat, lon: lon, targetMetres: targetMetres)
    }
}
