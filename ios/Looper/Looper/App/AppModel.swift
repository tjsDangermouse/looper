import AVFoundation
import CoreLocation
import Foundation
import LooperKit
import UIKit

/// A second "find new loops" tap before the first has answered means two
/// requests can finish out of order. Only the most recently *started* one
/// is allowed to write its result.
@MainActor
final class AppModel: ObservableObject {
    enum Screen { case welcome, planner, choices, walk }

    // Home, Isle of Man — the same fallback the web app opens on.
    private static let defaultStart = Point(-4.517837412123816, 54.15767997688426)

    @Published var screen: Screen = .welcome
    @Published var start: Point = AppModel.defaultStart
    @Published var position: Point?
    @Published var heading: Double?
    @Published var locationState = ""
    @Published var mode: LoopMode = .distance
    @Published var unit: LooperKit.Unit = .km
    @Published var amount = "4"
    @Published var activity: Activity = .walking
    @Published var walkingPaceMinutes = UserDefaults.standard.object(forKey: "walking-pace-minutes") as? Double ?? 12 {
        didSet { UserDefaults.standard.set(walkingPaceMinutes, forKey: "walking-pace-minutes") }
    }
    @Published var walkingPaceUnit = LooperKit.Unit(rawValue: UserDefaults.standard.string(forKey: "walking-pace-unit") ?? "km") ?? .km {
        didSet { UserDefaults.standard.set(walkingPaceUnit.rawValue, forKey: "walking-pace-unit") }
    }
    @Published var runningPaceMinutes = UserDefaults.standard.object(forKey: "running-pace-minutes") as? Double ?? 6 {
        didSet { UserDefaults.standard.set(runningPaceMinutes, forKey: "running-pace-minutes") }
    }
    @Published var runningPaceUnit = LooperKit.Unit(rawValue: UserDefaults.standard.string(forKey: "running-pace-unit") ?? "km") ?? .km {
        didSet { UserDefaults.standard.set(runningPaceUnit.rawValue, forKey: "running-pace-unit") }
    }
    /// What the local engine last reported about how it found the walk.
    /// Developer-facing diagnostics for the most recent on-device search.
    @Published private(set) var localDiagnostics: LocalLoopRouter.Diagnostics?
    /// Set while routing is fetching walking paths for an area it has not seen
    /// before, and nil at every other moment.
    @Published private(set) var dataProgress: LoopDataProgress?
    @Published var routes: [Route] = []
    @Published var selected: Route?
    @Published var showsRouteOverlay = true
    @Published var busy = false
    @Published var error = ""
    @Published var waypoints: [Point] = []
    @Published var expectationMessage: String?
    @Published var muted = false
    @Published private(set) var hasActiveWalk = false
    @Published var offRoute = false
    @Published var progress: Double = 0
    @Published var following = false
    @Published var courseUp = false
    @Published var showingVoiceSettings = false
    @Published private(set) var favoriteRoutes: [Route]
    /// The saved routes kept on the Watch for walking without the phone.
    @Published private(set) var offlineRouteIDs: Set<String>
    @Published private(set) var selectedVoiceIdentifier: String?
    @Published var reversed = false
    @Published var findingStage = 0
    @Published var padding: (bottom: CGFloat, right: CGFloat) = (0, 0)
    /// The outing being recorded, or the last one finished. Persisted, so the
    /// summary and the Health save survive the app being killed behind a walk.
    @Published private(set) var session: LoopSessionRecord?
    /// Non-nil while the Loop Summary is on screen.
    @Published var summary: LoopSummary?
    /// Set while a walk is being started — the Apple Watch is given a few
    /// seconds to bring its workout up before navigation begins. Shown as a
    /// line on the Start button rather than a spinner over the map.
    @Published private(set) var startupNotice = ""
    /// Whether the outing is paused. Paused time is not walked time: no
    /// fixes are recorded, progress doesn't move, nothing is announced, and
    /// the elapsed clock stops.
    @Published private(set) var isPaused = false
    #if DEBUG
    /// When enabled, Start traces the complete chosen geometry at three times
    /// the route's planned pace.
    /// The Watch receives normal plan/state/result messages, but neither
    /// device creates an Apple Health workout.
    @Published var simulatesWalk = UserDefaults.standard.bool(forKey: "developer-simulates-walk") {
        didSet { UserDefaults.standard.set(simulatesWalk, forKey: "developer-simulates-walk") }
    }
    @Published private(set) var isSimulatingWalk = false
    #endif

    let compassAvailable = LocationManager.headingAvailable
    let health: HealthIntegration
    /// Kept on the model so Settings can show and export the same on-device
    /// event stream used by the navigation and speech code.
    let navigationLogger = NavigationLogger.shared
    let routingTrials = RoutingTrialLog.shared
    /// The trial row the routes on screen belong to, so a rating can find it.
    @Published private(set) var currentTrialID: String?
    /// The Apple Watch, if there is one. Always present as an object; it
    /// reports `.unavailable` when there is no Watch to talk to, and every
    /// path through this model works with it in that state.
    let watch = WatchCompanion()

    /// The store is held alongside the engine because Settings reports on it
    /// and can clear it — and because the future Offline Areas feature will
    /// fill this same store, not another one.
    private lazy var routingChunkStore = RoutingChunkStore.applicationDefault()
    private lazy var onDeviceEngine = OnDeviceLoopRoutingEngine(
        store: routingChunkStore,
        source: OverpassRoutingDataSource()
    )
    private let locationManager: LocationManager
    private let speechManager: SpeechManager
    private let routeStore: RouteStore
    private let favoritesStore: FavoritesStore
    private let routeTileCache: RouteTileCache
    private let sessionStore: SessionStore

    private static let variationStride = 3
    private var requestSeq = 0
    private var lastAsk: (key: String, variation: Int) = ("", Int.random(in: 0..<300) * AppModel.variationStride)
    private var spoken = ""
    private var announcementHistory = GuidanceAnnouncementHistory()
    private var endingAfterArrival = false
    private var walked = 0.0
    private var offRouteTracker = OffRouteTracker()
    private var findingStageTask: Task<Void, Never>?
    private var walkWatchTask: Task<Void, Never>?
    private var headingWatchTask: Task<Void, Never>?
    private var watchStateTask: Task<Void, Never>?
    /// A loop preloaded to the Watch but not yet started. Its id becomes the
    /// session record's id, so the plan on the wrist and the record on the
    /// phone are the same outing from the moment Start is tapped.
    private var preparedPlan: LoopPlanPayload?
    private var startingWalk = false
    private var pausedAt: Date?
    private var routeWaypoints: [Point] = []
    private var mapLocationAt: Date?

    static let waypointLimit = 4

    init(
        locationManager: LocationManager = LocationManager(),
        speechManager: SpeechManager? = nil,
        routeStore: RouteStore = RouteStore(),
        favoritesStore: FavoritesStore = FavoritesStore(),
        routeTileCache: RouteTileCache = RouteTileCache(),
        sessionStore: SessionStore = SessionStore(),
        health: HealthIntegration? = nil
    ) {
        self.locationManager = locationManager
        self.speechManager = speechManager ?? SpeechManager()
        self.routeStore = routeStore
        self.favoritesStore = favoritesStore
        self.routeTileCache = routeTileCache
        self.sessionStore = sessionStore
        self.health = health ?? HealthIntegration()
        self.favoriteRoutes = favoritesStore.load()
        self.offlineRouteIDs = favoritesStore.loadOfflineIDs()
        self.selectedVoiceIdentifier = self.speechManager.selectedVoiceIdentifier
        restoreSession()
        connectWatch()
        #if DEBUG
        seedPreviewStateIfRequested()
        #endif
    }

    #if DEBUG
    /// Lets a debug build jump straight to a screen with sample data, without
    /// live location — set LOOPER_PREVIEW to "choices" or "walk" in the
    /// scheme/launch environment. LOOPER_PREVIEW=find exercises on-device
    /// routing and its walking-path download.
    private func seedPreviewStateIfRequested() {
        guard let target = ProcessInfo.processInfo.environment["LOOPER_PREVIEW"] else { return }
        if target == "find" {
            screen = .planner
            findRoutes()
            return
        }
        if target == "locate" {
            requestLocation()
            return
        }
        if target == "settings" {
            showingVoiceSettings = true
            return
        }
        if target == "route-playback" {
            guard let path = ProcessInfo.processInfo.environment["LOOPER_ROUTE_FIXTURE"] else {
                error = "LOOPER_ROUTE_FIXTURE is required for route playback."
                return
            }
            do {
                let route = try JSONDecoder().decode(Route.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                routes = [route]
                selected = route
                Task { await startWalk(route) }
            } catch {
                self.error = "Could not open route playback fixture: \(error.localizedDescription)"
            }
            return
        }
        func sampleRoute(id: String, name: String) -> Route {
            Route(
                id: id, name: name, distanceMeters: 4200, durationSeconds: 3000,
                targetDifferencePercent: 4,
                geometry: LineGeometry(coordinates: [start, Point(start.lng + 0.01, start.lat + 0.005), Point(start.lng + 0.02, start.lat), start]),
                steps: [
                    Step(instruction: "Head along Peel Road", distanceMeters: 1500, durationSeconds: 1100, startIndex: 0, endIndex: 1, road: "Peel Road"),
                    Step(instruction: "Turn left onto Strang Road", distanceMeters: 1700, durationSeconds: 1200, startIndex: 1, endIndex: 2, maneuver: .code(0), road: "Strang Road"),
                    Step(instruction: "Turn right onto Union Road", distanceMeters: 1000, durationSeconds: 700, startIndex: 2, endIndex: 3, maneuver: .code(1), road: "Union Road"),
                    Step(instruction: "Arrive at your starting point", distanceMeters: 0, durationSeconds: 0, startIndex: 3, endIndex: 3, maneuver: .code(10)),
                ]
            )
        }
        let previewRoutes = [
            sampleRoute(id: "preview-1", name: "Riverside loop"),
            sampleRoute(id: "preview-2", name: "Hilltop loop"),
            sampleRoute(id: "preview-3", name: "Harbour loop"),
        ]
        routes = previewRoutes
        selected = previewRoutes.first
        if ProcessInfo.processInfo.environment["LOOPER_PREVIEW_FAVORITES"] == "1" {
            favoriteRoutes = [previewRoutes[0], previewRoutes[2]]
            offlineRouteIDs = Set(favoriteRoutes.map(\.id))
            syncSavedRoutesToWatch()
        }
        switch target {
        case "choices": screen = .choices
        case "walk":
            screen = .walk
            progress = 200
            following = true
        case "summary", "summary-partial":
            seedPreviewSummary(previewRoutes[0], completed: target == "summary")
        default: break
        }
    }

    /// Puts a finished outing in front of the Loop Summary so its states can
    /// be worked through without walking a real loop. Debug builds only, and
    /// only when LOOPER_PREVIEW asks for it.
    private func seedPreviewSummary(_ route: Route, completed: Bool) {
        // Stay on the landing screen: the summary is what's under test here,
        // and the live map behind it would ask for location it doesn't need.
        screen = .welcome
        let walked = completed ? route.distanceMeters : route.distanceMeters * 0.35
        let started = Date().addingTimeInterval(-2_700)
        let steps = 120
        let coordinates = route.geometry.coordinates
        let track = (0...steps).map { index -> TrackPoint in
            let position = Double(index) / Double(steps) * (completed ? 1 : 0.35)
            let along = position * Double(coordinates.count - 1)
            let lower = coordinates[min(Int(along), coordinates.count - 1)]
            let upper = coordinates[min(Int(along) + 1, coordinates.count - 1)]
            let blend = along - along.rounded(.down)
            return TrackPoint(
                lng: lower.lng + (upper.lng - lower.lng) * blend,
                lat: lower.lat + (upper.lat - lower.lat) * blend,
                altitude: 30 + Double(index) * 0.4,
                horizontalAccuracy: 6,
                verticalAccuracy: 4,
                timestamp: started.addingTimeInterval(Double(index) / Double(steps) * 2_700)
            )
        }
        var record = LoopSessionRecord(
            activity: activity, mode: mode, targetAmount: Double(amount) ?? 4,
            targetUnit: unit, displayUnit: unit,
            routeID: route.id, routeName: route.name,
            plannedDistanceMeters: route.distanceMeters,
            plannedDurationSeconds: route.durationSeconds,
            plannedGeometry: coordinates,
            startedAt: started
        )
        record.endedAt = Date()
        record.progressMeters = walked
        if completed { record.arrivedAt = record.endedAt }
        record.track = track
        session = record
        presentSummary(for: record)
    }
    #endif

    var distanceKm: Double {
        let value = Double(amount) ?? 0
        switch mode {
        case .time: return estimateKmFromMinutes(value)
        case .distance: return unit == .mi ? milesToKm(value) : value
        }
    }

    var valid: Bool {
        let value = Double(amount) ?? 0
        switch mode {
        case .time: return value >= 15 && value <= 240
        case .distance: return distanceKm >= 1 && distanceKm <= 20
        }
    }

    // Either way round the loop is the same streets, so a reversal is derived
    // from the fetched routes rather than asked of the router again.
    var shownRoutes: [Route] { reversed ? routes.map(reverseRoute) : routes }
    var mapRoutes: [Route] { showsRouteOverlay ? shownRoutes : [] }
    var walkingPaceMinutesPerKm: Double {
        let pace = walkingPaceUnit == .km ? walkingPaceMinutes : walkingPaceMinutes / 0.621371
        return min(max(pace, 4), 30)
    }
    var runningPaceMinutesPerKm: Double {
        let pace = runningPaceUnit == .km ? runningPaceMinutes : runningPaceMinutes / 0.621371
        return min(max(pace, 2), 30)
    }
    var activePaceMinutes: Double { activity == .walking ? walkingPaceMinutes : runningPaceMinutes }
    var activePaceUnit: LooperKit.Unit { activity == .walking ? walkingPaceUnit : runningPaceUnit }
    var activePaceMinutesPerKm: Double { activity == .walking ? walkingPaceMinutesPerKm : runningPaceMinutesPerKm }

    /// Which of the offered walks the tester picked, for the trial record.
    func recordRouteChoice(_ index: Int) {
        routingTrials.recordSelection(trialID: currentTrialID, index: index)
    }

    var turn: TurnHit? { selected.flatMap { nextTurn($0, progress) } }
    var remaining: Double { selected.map { max(0, $0.distanceMeters - progress) } ?? 0 }
    var waypointsNeedSearch: Bool { waypoints != routeWaypoints }

    func addWaypoint(_ point: Point) {
        guard screen == .planner || screen == .choices else { return }
        guard waypoints.count < Self.waypointLimit else {
            error = "You can add up to \(Self.waypointLimit) waypoints."
            return
        }
        waypoints.append(point)
        error = ""
    }

    func clearWaypoints() {
        waypoints.removeAll()
        error = ""
    }

    func toggleReversed() {
        reversed.toggle()
        selected = selected.map(reverseRoute)
    }

    func isFavorite(_ route: Route) -> Bool {
        favoriteRoutes.contains { $0.id == route.id }
    }

    func toggleFavorite(_ route: Route) {
        if let index = favoriteRoutes.firstIndex(where: { $0.id == route.id }) {
            favoriteRoutes.remove(at: index)
            if offlineRouteIDs.remove(route.id) != nil { favoritesStore.saveOfflineIDs(offlineRouteIDs) }
        } else {
            // Most recently saved first makes the last route someone chose easy
            // to find in Settings.
            favoriteRoutes.insert(route, at: 0)
        }
        favoritesStore.save(favoriteRoutes)
        syncSavedRoutesToWatch()
    }

    func isOffline(_ route: Route) -> Bool {
        offlineRouteIDs.contains(route.id)
    }

    /// Keeps a route on the Watch, or lets it go. Keeping one that isn't saved
    /// yet saves it too: the Watch can only hold what the phone still has.
    func toggleOffline(_ route: Route) {
        if offlineRouteIDs.contains(route.id) {
            offlineRouteIDs.remove(route.id)
        } else {
            if !isFavorite(route) {
                favoriteRoutes.insert(route, at: 0)
                favoritesStore.save(favoriteRoutes)
            }
            offlineRouteIDs.insert(route.id)
        }
        favoritesStore.saveOfflineIDs(offlineRouteIDs)
        syncSavedRoutesToWatch()
    }

    func openFavorite(_ route: Route) {
        waypoints = []
        routeWaypoints = []
        routes = [route]
        selected = route
        reversed = false
        showsRouteOverlay = true
        screen = .choices
        showingVoiceSettings = false
    }

    func setWalkingPaceUnit(_ newUnit: LooperKit.Unit) {
        guard newUnit != walkingPaceUnit else { return }
        let pacePerKm = walkingPaceMinutesPerKm
        walkingPaceUnit = newUnit
        walkingPaceMinutes = newUnit == .km ? pacePerKm : pacePerKm / 0.621371
    }

    func setRunningPaceUnit(_ newUnit: LooperKit.Unit) {
        guard newUnit != runningPaceUnit else { return }
        let pacePerKm = runningPaceMinutesPerKm
        runningPaceUnit = newUnit
        runningPaceMinutes = newUnit == .km ? pacePerKm : pacePerKm / 0.621371
    }

    func requestLocation() {
        // MapLibre receives Core Location updates to draw its user dot. If it
        // already supplied one, use that same known position immediately.
        if let position, let mapLocationAt,
           Date().timeIntervalSince(mapLocationAt) <= 60 {
            start = position
            locationState = ""
            screen = .planner
            return
        }
        locationState = "Finding your location…"
        Task {
            do {
                let point = try await locationManager.requestOneShotLocation()
                start = point
                position = point
                locationState = ""
                screen = .planner
            } catch let error as CLError where error.code == .denied {
                locationState = "Location permission was declined. Choose a start point on the map."
            } catch {
                locationState = "We could not get a location. Choose a start point on the map."
            }
        }
    }

    func updateMapLocation(_ point: Point) {
        position = point
        mapLocationAt = Date()
    }

    // Discovery starts from fresh bearings. Refresh skips the variations the
    // service explored for the displayed routes, and excludes those routes by
    // geometry so it deliberately finds different walks.
    func findRoutes() {
        guard valid else {
            error = mode == .time ? "Choose 15 minutes to 4 hours." : "Choose a loop between 1 and 20 km."
            return
        }
        let waypointKey = waypoints.map { "\(String(format: "%.5f", $0.lng)),\(String(format: "%.5f", $0.lat))" }.joined(separator: ";")
        let planKey = "\(String(format: "%.5f", start.lng)),\(String(format: "%.5f", start.lat))|\(mode.rawValue)|\(amount)|\(unit.rawValue)|\(activity.rawValue)"
        let key = "\(planKey)|\(waypointKey)"
        let sameSpot = lastAsk.key == key
        // Adding or moving a waypoint should refine the loops currently on
        // screen, not silently roll a new random family first. Only an exact
        // repeat (the refresh action) advances the variation.
        let samePlan = lastAsk.key.hasPrefix("\(planKey)|")
        let variation = sameSpot
            ? (lastAsk.variation + AppModel.variationStride) % 900
            : samePlan ? lastAsk.variation : Int.random(in: 0..<300) * AppModel.variationStride
        lastAsk = (key, variation)

        requestSeq += 1
        let seq = requestSeq
        busy = true
        findingStage = 0
        error = ""
        reversed = false
        startFindingStageTimer()
        let requestedWaypoints = waypoints

        let askedAt = Date()
        let loopRequest = LoopRequest(
            start: start,
            mode: mode,
            distanceKm: mode == .distance ? distanceKm : nil,
            durationMinutes: mode == .time ? Double(amount) : nil,
            unit: unit,
            activity: activity,
            walkingPaceMinutes: activePaceMinutes,
            walkingPaceUnit: activePaceUnit,
            variation: variation,
            waypoints: requestedWaypoints,
            excludeRoutes: sameSpot ? routes : [],
            onDataProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, seq == self.requestSeq else { return }
                    self.dataProgress = progress
                }
            }
        )
        Task {
            defer { if seq == requestSeq { dataProgress = nil } }
            do {
                let result = try await onDeviceEngine.generateLoops(loopRequest)
                guard seq == requestSeq else { return } // a later request already started; its result is the one that counts
                if result.expectationExceeded {
                    let message = result.warning ?? "These waypoints need a longer loop. Increase your distance or time, or remove a waypoint."
                    expectationMessage = message
                    error = message
                    busy = false
                    return
                }
                guard !result.routes.isEmpty else {
                    throw LooperAPIError.message(result.warning ?? "We couldn’t find a clean loop of that length from here. Try a different distance or move the start point.")
                }
                routes = result.routes
                selected = result.routes.first
                localDiagnostics = result.localDiagnostics
                // One row per set of walks offered, written the moment they
                // arrive. Local only — see RoutingTrialLog.
                currentTrialID = routingTrials.record(
                    engine: result.engine ?? result.localDiagnostics.map { local in
                        RoutingEngineReport(
                            routingEngine: .onDevice,
                            generationMs: local.totalMs,
                            searchClosedWalks: local.closedWalks,
                            searchStates: local.search.storeSize,
                            searchMs: local.search.searchMs
                        )
                    },
                    selectedEngine: .onDevice,
                    requestedMetres: distanceKm * 1000,
                    mode: mode,
                    activity: activity,
                    start: start,
                    hadWaypoints: !requestedWaypoints.isEmpty,
                    routes: result.routes,
                    generationMs: Date().timeIntervalSince(askedAt) * 1000
                )?.id
                routeWaypoints = requestedWaypoints
                showsRouteOverlay = true
                screen = .choices
                error = result.warning ?? ""
            } catch {
                if seq == requestSeq {
                    // A local failure has its own sentence — "this area isn't
                    // downloaded yet", "no path near that start" — and those
                    // are the ones a walker can act on, so they are shown as
                    // written rather than flattened into the network message.
                    self.error = (error as? LocalizedError)?.errorDescription ?? "Routes are unavailable right now."
                }
            }
            if seq == requestSeq { busy = false }
        }
    }

    /// What the phone is holding, for the Settings screen that reports it.
    struct RoutingDataSummary: Equatable {
        var chunkCount: Int
        var pinnedCount: Int
        var bytes: Int

        var formattedBytes: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    func routingDataSummary() async -> RoutingDataSummary {
        let entries = await routingChunkStore.allMetadata()
        return RoutingDataSummary(
            chunkCount: entries.count,
            pinnedCount: entries.filter { $0.retention == .pinned }.count,
            bytes: entries.reduce(0) { $0 + $1.byteSize }
        )
    }

    func clearRoutingData() async {
        await routingChunkStore.removeAll()
    }

    /// What to say while looking.
    ///
    /// Downloading the walking paths for a new area is a genuinely different
    /// wait from searching one already on the phone — it takes seconds and it
    /// needs the network — so it says so. It says so in a walker's words: the
    /// name of the data format and of the provider serving it are our problem,
    /// not theirs.
    static let findingMessages = ["Building clean loops around you…", "Checking for overlaps and detours…"]

    var findingMessage: String {
        if let progress = dataProgress, progress.totalRequests > 0 {
            return progress.totalRequests > 1
                ? "Downloading walking paths… \(min(progress.completedRequests + 1, progress.totalRequests)) of \(progress.totalRequests)"
                : "Downloading walking paths for this area…"
        }
        return AppModel.findingMessages[min(findingStage, AppModel.findingMessages.count - 1)]
    }

    private func startFindingStageTimer() {
        findingStageTask?.cancel()
        findingStageTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, busy else { return }
            findingStage = 1
        }
    }

    /// Starts the loop. The Apple Watch, when there is one, gets a few
    /// seconds to bring its workout session up first — heart rate and the
    /// canonical Health workout both depend on it — and navigation then
    /// begins either way. A Watch that is missing, uninstalled, refused
    /// permission or simply slow costs the walker those few seconds and
    /// nothing else.
    func beginWalk(_ route: Route) {
        guard !startingWalk, !hasActiveWalk else { return }
        startingWalk = true
        Task { await startWalk(route) }
    }

    /// The Watch has already started its own workout and is asking the phone
    /// to navigate. Skips asking the Watch to start a second time.
    private func beginWalkFromWatch(_ route: Route, sessionID: String, watchOwnsWorkout: Bool) {
        guard !startingWalk, !hasActiveWalk else { return }
        startingWalk = true
        Task { await startWalk(route, watchSessionID: sessionID, watchOwnsWorkout: watchOwnsWorkout) }
    }

    private func startWalk(
        _ proposedRoute: Route,
        watchSessionID: String? = nil,
        watchOwnsWorkout: Bool = true
    ) async {
        defer { startingWalk = false }
        let route = reassessDirections(proposedRoute)
        selected = route
        var plan = preparedLoopPlan(for: route, reassessed: true)
        if let watchSessionID { plan.sessionID = watchSessionID }

        var owner: HealthWorkoutOwner = .phone
        #if DEBUG
        let simulation = simulatesWalk && watchSessionID == nil
        #else
        let simulation = false
        #endif
        if watchSessionID != nil, watchOwnsWorkout {
            // Started on the wrist: the Watch's workout is already running,
            // so it owns the Health record without being asked.
            owner = .watch
        } else {
            #if DEBUG
            if simulation {
                watch.startSimulation(for: plan)
            } else if watch.isPairedWithApp {
                startupNotice = "Starting on your Apple Watch…"
                owner = await watch.startWorkout(for: plan) ? .watch : .phone
            }
            #else
            if watch.isPairedWithApp {
                startupNotice = "Starting on your Apple Watch…"
                owner = await watch.startWorkout(for: plan) ? .watch : .phone
            }
            #endif
        }
        startupNotice = ""
        preparedPlan = nil

        if !muted { speechManager.prime() }
        spoken = ""
        announcementHistory.reset()
        endingAfterArrival = false
        walked = 0
        progress = 0
        isPaused = false
        pausedAt = nil
        offRoute = false
        following = true
        showsRouteOverlay = true
        hasActiveWalk = true
        #if DEBUG
        isSimulatingWalk = simulation
        #endif
        screen = .walk
        routeStore.save(route)
        routeTileCache.cache(route)
        startRecording(
            route,
            id: plan.sessionID,
            owner: owner,
            simulated: simulation
        )
        navigationLogger.resetForNewRoute()
        navigationLogger.log("navigation.started", details: [
            "sessionID": plan.sessionID,
            "routeID": route.id,
            "routeName": route.name,
            "plannedDistanceM": rounded(route.distanceMeters),
            "muted": String(muted),
            "watchOwner": owner == .watch ? "watch" : "phone"
        ])
        // Logged after the reset above rather than where the handshake
        // happens, so it survives into the export the walker sends in.
        navigationLogger.log("watch.handshake", details: [
            "startedFrom": watchSessionID == nil ? "phone" : "watch",
            "paired": String(watch.isPairedWithApp),
            "watchOwnsWorkout": String(owner == .watch),
            "connection": watch.connection.diagnosticName
        ])
        navigationLogger.recordRoute(route, sessionID: plan.sessionID, activity: activity, unit: unit)
        startWalkWatch()
        startWatchStateFeed()
    }

    /// Finishes the outing, once. Both devices can ask for this — a tap on
    /// the phone, a tap on the wrist, or a duplicate of either arriving late
    /// — and every one of them lands here, where the already-finished record
    /// is what makes the second call a no-op.
    func endWalk() {
        guard hasActiveWalk || session?.isFinished == false else { return }
        endingAfterArrival = false
        let finished = finishRecording()
        navigationLogger.log("navigation.ended", details: [
            "progressM": rounded(progress),
            "offRoute": String(offRoute),
            "reason": finished?.arrivedAt == nil ? "manual-or-watch" : "arrived"
        ])
        hasActiveWalk = false
        following = false
        courseUp = false
        showsRouteOverlay = false
        isPaused = false
        #if DEBUG
        isSimulatingWalk = false
        #endif
        pausedAt = nil
        screen = .choices
        stopWalkWatch()
        stopHeadingWatch()
        stopWatchStateFeed()
        speechManager.stop()
        routeTileCache.release()
        if let finished {
            // Tells the Watch to close its own workout, and gives it the
            // phone's verdict on the loop to show. The Watch fills in its own
            // heart-rate average; the phone has none to offer.
            watch.send(command: .end, sessionID: finished.id)
            watch.send(result: makeWorkoutResult(makeLoopSummary(finished)))
            presentSummary(for: finished)
        }
        watch.release()
    }

    // MARK: Pausing

    func pauseWalk() {
        guard hasActiveWalk, !isPaused else { return }
        isPaused = true
        pausedAt = Date()
        navigationLogger.log("navigation.paused", details: ["progressM": rounded(progress)])
        speechManager.stop()
        watch.send(command: .pause, sessionID: session?.id)
        pushWatchState(force: true)
    }

    func resumeWalk() {
        guard hasActiveWalk, isPaused else { return }
        if let pausedAt, var record = session {
            record.pausedSeconds = (record.pausedSeconds ?? 0) + Date().timeIntervalSince(pausedAt)
            session = record
            sessionStore.save(record, immediately: true)
        }
        pausedAt = nil
        isPaused = false
        navigationLogger.log("navigation.resumed", details: ["progressM": rounded(progress)])
        // The next fix decides what to say; nothing is repeated from before
        // the pause just because the walker stood still for a while.
        spoken = ""
        if !muted { speechManager.prime() }
        watch.send(command: .resume, sessionID: session?.id)
        pushWatchState(force: true)
    }

    // MARK: Recording the outing

    /// Opens a fresh record for this walk. Any previous outing's record is
    /// replaced — its summary has been seen, or the walker has moved on
    /// regardless.
    private func startRecording(
        _ route: Route,
        id: String,
        owner: HealthWorkoutOwner,
        simulated: Bool = false
    ) {
        let record = LoopSessionRecord(
            id: id,
            activity: activity,
            mode: mode,
            targetAmount: Double(amount) ?? 0,
            targetUnit: unit,
            displayUnit: unit,
            routeID: route.id,
            routeName: route.name,
            plannedDistanceMeters: route.distanceMeters,
            plannedDurationSeconds: route.durationSeconds,
            plannedGeometry: route.geometry.coordinates,
            startedAt: Date(),
            healthOwner: owner,
            simulated: simulated
        )
        session = record
        sessionStore.save(record, immediately: true)
    }

    /// Records one accepted fix and reports the single transition from walking
    /// to arrived. The location loop uses that transition to close the outing
    /// through `endWalk()`, exactly as either device's End button would.
    @discardableResult
    private func record(_ update: LocationManager.PositionUpdate, on route: Route) -> Bool {
        guard var record = session, !record.isFinished else { return false }
        let location = update.location
        record.track.append(
            TrackPoint(
                lng: location.coordinate.longitude,
                lat: location.coordinate.latitude,
                altitude: location.verticalAccuracy > 0 ? location.altitude : nil,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                speed: location.speed >= 0 ? location.speed : nil,
                course: location.course >= 0 ? location.course : nil,
                timestamp: location.timestamp
            )
        )
        record.progressMeters = progress
        record.endedOffRoute = offRoute
        // Latched here, on the location watch, rather than alongside the
        // spoken "you're back where you started" — that announcement is
        // silenced by mute and by leaving the walk screen, and finishing the
        // loop is a fact about the outing either way.
        var justArrived = false
        if record.arrivedAt == nil,
           hasArrived(route, progressMeters: progress, at: update.point) {
            record.arrivedAt = location.timestamp
            justArrived = true
        }
        session = record
        // Finishing the loop is a one-off fact worth writing straight away,
        // rather than waiting on the track's usual throttled flush.
        sessionStore.save(record, immediately: justArrived)
        return justArrived
    }

    /// Closes the record off. Returns nil if there was nothing being
    /// recorded, and returns the already-finished record unchanged if this
    /// runs twice — the same guard that stops a second Health workout.
    @discardableResult
    private func finishRecording() -> LoopSessionRecord? {
        guard var record = session else { return nil }
        guard !record.isFinished else { return record }
        record.endedAt = Date()
        record.progressMeters = progress
        record.endedOffRoute = offRoute
        if record.arrivedAt == nil,
           let route = selected,
           let position,
           hasArrived(route, progressMeters: progress, at: position) {
            record.arrivedAt = record.endedAt
        }
        session = record
        sessionStore.save(record, immediately: true)
        return record
    }

    /// Brings back a record left behind by a previous run. A walk that was
    /// killed mid-outing is closed off at its last recorded fix rather than
    /// discarded — the walking really happened, and the summary can still be
    /// shown for it.
    private func restoreSession() {
        guard var record = sessionStore.load() else { return }
        if !record.isFinished {
            record.endedAt = record.track.last?.timestamp ?? record.startedAt
            sessionStore.save(record, immediately: true)
        }
        session = record
        guard !record.summaryAcknowledged else { return }
        summary = makeLoopSummary(record)
        // One attempt for an outing that never got as far as trying. A save
        // that already failed waits for the walker to tap Try again, so
        // nothing retries itself over and over in the background.
        if case .notAttempted = record.health {
            Task { await saveToHealth() }
        }
    }

    // MARK: Loop Summary

    private func presentSummary(for record: LoopSessionRecord) {
        summary = makeLoopSummary(record)
        // Deliberately not awaited: the summary appears straight away and the
        // Health row fills itself in behind it.
        //
        // A loop that finishes on arrival finishes with the phone in a pocket
        // and the screen off, and ending the walk has just given up the
        // location updates that were keeping the app awake. The assertion
        // below buys the save the time to finish rather than leaving it to
        // be cut off mid-write by a suspension.
        Task { await withBackgroundTime("health-save") { await self.saveToHealth() } }
    }

    /// Runs `work` under a background task assertion, so it survives the app
    /// being suspended the moment it is no longer on screen. The assertion is
    /// always given back — including when the system calls time on it first.
    private func withBackgroundTime(_ name: String, _ work: () async -> Void) async {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        await work()
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    /// Rebuilds the on-screen summary from the record, so the Health row
    /// tracks the save without any other figure being recalculated elsewhere.
    private func refreshSummary() {
        guard summary != nil, let record = session else { return }
        summary = makeLoopSummary(record)
    }

    func dismissSummary() {
        summary = nil
        guard var record = session else { return }
        record.summaryAcknowledged = true
        session = record
        sessionStore.save(record, immediately: true)
    }

    // MARK: Apple Health

    private func setHealthState(_ state: HealthSaveState) {
        guard var record = session else { return }
        record.health = state
        session = record
        sessionStore.save(record, immediately: true)
        refreshSummary()
    }

    /// The single entry point for writing a loop to Apple Health. Every path
    /// into it — finishing a walk, restoring one, connecting from the
    /// summary, tapping Try again — goes through `canAttemptHealthSave`, and
    /// the check and the move to `.saving` happen together on the main actor,
    /// so two overlapping calls can never both get through.
    func saveToHealth() async {
        guard let record = session, record.isFinished else { return }
        // The one rule that keeps a Watch-recorded outing from becoming two
        // workouts in Apple Health. The Watch's HKWorkoutSession *is* the
        // workout; the phone records the same walk for its own summary and
        // writes nothing. The workout's UUID arrives separately, if the Watch
        // manages to send it.
        if record.workoutOwner == .watch {
            if case .savedOnWatch = record.health {} else { setHealthState(.savedOnWatch(workoutID: nil)) }
            return
        }
        guard health.isEnabled else { return } // the summary offers to connect instead
        await health.refreshAvailability()
        guard let current = session, current.canAttemptHealthSave else { return }

        switch health.availability {
        case .unavailable:
            setHealthState(.skipped(reason: "Apple Health isn’t available on this device."))
            return
        case .denied, .notDetermined:
            setHealthState(.skipped(reason: "Looper doesn’t have permission to add workouts."))
            return
        case .authorized:
            break
        }

        setHealthState(.saving)
        do {
            let workoutID = try await health.saver.save(current)
            setHealthState(.saved(workoutID: workoutID))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "The workout couldn’t be saved."
            setHealthState(.failed(message: message))
        }
    }

    /// Turns the integration on from the summary and saves this loop with it.
    func connectHealthAndSave() async {
        guard await health.enable() else {
            refreshSummary()
            return
        }
        await saveToHealth()
    }

    /// Returns to the first screen without ending an active walk. The location
    /// watcher retains the walk state so it can be resumed from the landing page.
    func returnHome() {
        if hasActiveWalk {
            screen = .welcome
            return
        }

        requestSeq += 1
        busy = false
        findingStageTask?.cancel()
        findingStageTask = nil
        stopWalkWatch()
        stopHeadingWatch()
        speechManager.stop()
        following = false
        courseUp = false
        offRoute = false
        progress = 0
        locationState = ""
        error = ""
        waypoints = []
        routeWaypoints = []
        expectationMessage = nil
        showingVoiceSettings = false
        screen = .welcome
    }

    func continueWalk() {
        guard hasActiveWalk else { return }
        following = true
        screen = .walk
    }

    private func startWalkWatch() {
        offRouteTracker.reset()
        stopWalkWatch()
        walkWatchTask = Task {
            #if DEBUG
            if isSimulatingWalk, let selected {
                await playSimulatedWalk(on: selected)
                return
            }
            #endif
            for await update in locationManager.positionUpdates() {
                if handlePositionUpdate(update) { return }
            }
        }
    }

    /// Runs every real and synthetic fix through one navigation path. This is
    /// the important property of the demo: it tests matching, turns, speech,
    /// recording and Watch payloads rather than directly animating the UI.
    @discardableResult
    private func handlePositionUpdate(_ update: LocationManager.PositionUpdate) -> Bool {
        guard let selected else { return false }
        if isPaused { return false }
        if update.accuracy > 100 {
            locationState = "Waiting for a more accurate location…"
            navigationLogger.log("location.rejected", details: [
                "accuracyM": rounded(update.accuracy),
                "latitude": rounded(update.point.lat, decimals: 5),
                "longitude": rounded(update.point.lng, decimals: 5)
            ])
            return false
        }
        locationState = ""
        position = update.point
        let match = nearestProgress(update.point, selected.geometry.coordinates, from: walked)
        let safeProgress = progressWithoutStartFinishJump(
            previous: walked,
            candidate: match.distanceAlong,
            routeLength: selected.distanceMeters
        )
        walked = safeProgress
        progress = safeProgress
        let wasOffRoute = offRoute
        offRoute = offRouteTracker.record(distanceToRoute: match.distanceToRoute)
        navigationLogger.log("location.accepted", details: [
            "accuracyM": rounded(update.accuracy),
            "latitude": rounded(update.point.lat, decimals: 5),
            "longitude": rounded(update.point.lng, decimals: 5),
            "distanceToRouteM": rounded(match.distanceToRoute),
            "candidateProgressM": rounded(match.distanceAlong),
            "safeProgressM": rounded(safeProgress),
            "badFixes": String(offRouteTracker.badFixes),
            "nextTurnDistanceM": turn.map { rounded($0.distanceAway) } ?? "none"
        ])
        if wasOffRoute != offRoute {
            navigationLogger.log("navigation.offRouteChanged", details: [
                "offRoute": String(offRoute), "distanceToRouteM": rounded(match.distanceToRoute)
            ])
        }
        if record(update, on: selected) {
            announceArrivalThenEnd()
            return true
        }
        announceIfNeeded()
        return false
    }

    #if DEBUG
    private func playSimulatedWalk(on route: Route) async {
        let coordinates = route.geometry.coordinates
        guard coordinates.count > 1 else { return }
        let segmentLengths = zip(coordinates, coordinates.dropFirst()).map { haversine($0, $1) }
        let geometryLength = segmentLengths.reduce(0, +)
        guard geometryLength > 0 else { return }

        // One fix per second at 3x planned pace. Interpolating by distance
        // along every geometry segment makes the puck actually walk the
        // paths between turns instead of treating manoeuvres as keyframes.
        let playbackDuration = max(1, route.durationSeconds / 3)
        let samples = max(1, Int(ceil(playbackDuration)))
        let metresPerSecond = max(0.5, route.distanceMeters / playbackDuration)
        var sample = 0
        while sample <= samples, !Task.isCancelled {
            if isPaused {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continue
            }
            let target = geometryLength * Double(sample) / Double(samples)
            let (point, course) = simulatedPoint(
                distance: target,
                coordinates: coordinates,
                segmentLengths: segmentLengths
            )
            let location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: -1,
                course: course,
                speed: metresPerSecond,
                timestamp: Date()
            )
            let update = LocationManager.PositionUpdate(point: point, accuracy: 5, location: location)
            if handlePositionUpdate(update) { return }
            sample += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // Imported or hand-built routes can have a small discrepancy between
        // their declared distance and their geometry length. Never leave a
        // completed demo sitting indefinitely on its final frame.
        if hasActiveWalk, !Task.isCancelled { endWalk() }
    }

    private func simulatedPoint(
        distance: Double,
        coordinates: [Point],
        segmentLengths: [Double]
    ) -> (Point, Double) {
        var remaining = distance
        for index in segmentLengths.indices {
            let length = segmentLengths[index]
            if remaining <= length || index == segmentLengths.count - 1 {
                let fraction = length > 0 ? min(1, remaining / length) : 0
                let start = coordinates[index]
                let end = coordinates[index + 1]
                let point = Point(
                    start.lng + (end.lng - start.lng) * fraction,
                    start.lat + (end.lat - start.lat) * fraction
                )
                let longitude = (end.lng - start.lng) * cos((start.lat + end.lat) * .pi / 360)
                let latitude = end.lat - start.lat
                let course = (atan2(longitude, latitude) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                return (point, course)
            }
            remaining -= length
        }
        return (coordinates.last!, 0)
    }
    #endif

    private func stopWalkWatch() {
        walkWatchTask?.cancel()
        walkWatchTask = nil
    }

    // Give each turn a preview when it becomes active, an approach reminder,
    // and the instruction at the corner. Also warn once when the walk strays
    // off the loop. Falls silent on mute or on leaving the walk screen.
    private func announceIfNeeded() {
        guard screen == .walk, !muted, !isPaused else {
            navigationLogger.log("guidance.suppressed", details: [
                "screen": String(describing: screen), "muted": String(muted), "paused": String(isPaused)
            ])
            return
        }
        if offRoute {
            if spoken != "off" {
                spoken = "off"
                let text = "You are off the planned loop. Head back to the route."
                navigationLogger.log("guidance.queued", details: ["kind": "offRoute", "text": text, "progressM": rounded(progress)])
                speechManager.speak(text)
            }
            return
        }
        if spoken == "off" { spoken = "" }
        if let turn, let announcement = turnAnnouncement(turn.announcementInput, unit: unit) {
            if announcementHistory.shouldAnnounce(turn.announcementInput) {
                spoken = announcement.key
                navigationLogger.log("guidance.queued", details: [
                    "kind": "turn", "key": announcement.key, "text": announcement.text,
                    "turnDistanceM": rounded(turn.distanceAway), "progressM": rounded(progress)
                ])
                speechManager.speak(announcement.text)
            }
            return
        }
        if turn == nil,
           let selected,
           let position,
           hasArrived(selected, progressMeters: progress, at: position),
           spoken != "home" {
            announceArrivalThenEnd()
        }
    }

    /// Arrival used to end the outing before `announceIfNeeded` could enqueue
    /// its final sentence. Keep the outing alive until that sentence finishes;
    /// manual/watch End remains immediately available and idempotent meanwhile.
    private func announceArrivalThenEnd() {
        guard !endingAfterArrival else { return }
        guard screen == .walk, !muted, !isPaused else {
            endWalk()
            return
        }
        endingAfterArrival = true
        spoken = "home"
        let text = "You are back where you started."
        navigationLogger.log("guidance.queued", details: [
            "kind": "arrival", "text": text, "progressM": rounded(progress)
        ])
        speechManager.speak(text) { [weak self] in
            guard let self, self.endingAfterArrival else { return }
            self.endWalk()
        }
    }

    func toggleMute() {
        muted.toggle()
        navigationLogger.log("navigation.muteChanged", details: ["muted": String(muted), "progressM": rounded(progress)])
        if muted { speechManager.stop() } else { speechManager.prime(); spoken = "" }
    }

    var englishVoices: [AVSpeechSynthesisVoice] { speechManager.englishVoices }
    var hasPremiumEnglishVoice: Bool { speechManager.hasPremiumEnglishVoice }

    func voiceQualityName(for voice: AVSpeechSynthesisVoice) -> String {
        speechManager.qualityName(for: voice)
    }

    func selectVoice(_ voice: AVSpeechSynthesisVoice) {
        speechManager.selectVoice(identifier: voice.identifier)
        selectedVoiceIdentifier = voice.identifier
    }

    func previewVoice(_ voice: AVSpeechSynthesisVoice) {
        speechManager.selectVoice(identifier: voice.identifier)
        selectedVoiceIdentifier = voice.identifier
        speechManager.prime()
        speechManager.speak("In 100 metres, turn left. Your walk is ready.")
    }

    private func rounded(_ value: Double, decimals: Int = 1) -> String {
        String(format: "%.*f", decimals, value)
    }

    // The compass is only read while it is being used.
    func toggleCourseUp() {
        if courseUp { courseUp = false; stopHeadingWatch(); return }
        guard compassAvailable else {
            locationState = "A compass is not available on this device."
            return
        }
        locationState = ""
        courseUp = true
        startHeadingWatch()
    }

    private func startHeadingWatch() {
        stopHeadingWatch()
        headingWatchTask = Task {
            for await value in locationManager.headingUpdates() {
                heading = value
            }
        }
    }

    private func stopHeadingWatch() {
        headingWatchTask?.cancel()
        headingWatchTask = nil
    }

    // MARK: The Apple Watch

    private func connectWatch() {
        watch.onCommand = { [weak self] command in self?.handleWatchCommand(command) }
        watch.onWorkoutStatus = { [weak self] status in self?.handleWatchWorkoutStatus(status) }
        watch.onDiagnostic = { diagnostic in
            var details = diagnostic.details
            details["watchTimestamp"] = ISO8601DateFormatter().string(from: diagnostic.timestamp)
            NavigationLogger.shared.log("watch.\(diagnostic.event)", details: details)
        }
        watch.onWalkRecord = { [weak self] record in self?.adoptWatchWalk(record) }
        watch.onLinkReady = { [weak self] in self?.syncSavedRoutesToWatch() }
        watch.activate()
        syncSavedRoutesToWatch()
    }

    /// The plan for a loop, reusing the one already preloaded to the Watch
    /// when it is for the same route — so the id on the wrist and the id in
    /// the session record are the same outing.
    ///
    /// It is the whole guidance pack, built here from the same reassessed
    /// route the phone speaks from. The Watch follows it; it never plans.
    private func preparedLoopPlan(for route: Route, reassessed: Bool = false) -> LoopPlanPayload {
        if let preparedPlan, preparedPlan.routeID == route.id { return preparedPlan }
        return makeLoopPlan(
            route: route,
            activity: activity,
            mode: mode,
            targetAmount: Double(amount) ?? 0,
            targetUnit: unit,
            displayUnit: unit,
            narration: NarrationSettings(voiceIdentifier: selectedVoiceIdentifier),
            alreadyReassessed: reassessed
        )
    }

    /// The routes kept on the Watch as guidance packs, so any of them can be
    /// walked with the phone left behind. Other routes follow the phone.
    func syncSavedRoutesToWatch() {
        let narration = NarrationSettings(voiceIdentifier: selectedVoiceIdentifier)
        watch.syncSavedRoutes(favoriteRoutes.filter { offlineRouteIDs.contains($0.id) }.map {
            makeSavedRoutePlan(route: $0, activity: activity, displayUnit: unit, narration: narration)
        })
    }

    /// Sends the chosen loop to the Watch ahead of time, so Start on the
    /// wrist knows what it is starting. Called whenever the choice on screen
    /// changes; the Watch keeps only the most recent one.
    func prepareWatch(for route: Route) {
        guard !hasActiveWalk, !startingWalk else { return }
        let plan = preparedLoopPlan(for: route)
        preparedPlan = plan
        watch.prepare(plan)
    }

    /// The loop-choosing screen has gone — dismissed, or left for a walk
    /// already under way — so the Watch should stop offering the loop it was
    /// last shown rather than sit on a Start button for a route no longer on
    /// screen. Left alone while a walk is starting or running: that plan is
    /// still the one in progress.
    func clearWatch() {
        guard !hasActiveWalk, !startingWalk else { return }
        preparedPlan = nil
        watch.clearPrepared()
    }

    private func handleWatchCommand(_ command: WatchCommandPayload) {
        switch command.kind {
        case .start:
            // A start sent while the phone was out of reach is queued and can
            // arrive hours later, back at home. By then the walk is long over
            // and starting one would be a phantom, so only a fresh start counts.
            guard abs(command.issuedAt.timeIntervalSinceNow) < 30 else {
                navigationLogger.log("watch.staleStartIgnored", details: [
                    "ageSeconds": rounded(-command.issuedAt.timeIntervalSinceNow)
                ])
                return
            }
            // Start from the wrist. The Watch names the route it is walking —
            // it may be a saved route the phone isn't showing. With no name,
            // it is the loop chosen on the phone.
            guard let route = routeForWatchStart(command.routeID) else { return }
            guard let sessionID = command.sessionID else { return }
            beginWalkFromWatch(
                route,
                sessionID: sessionID,
                watchOwnsWorkout: command.recordsWorkout ?? true
            )
        case .pause:
            pauseWalk()
        case .resume:
            resumeWalk()
        case .end:
            endWalk()
        case .requestPlan:
            if let plan = preparedPlan ?? selected.map({ preparedLoopPlan(for: $0) }) {
                preparedPlan = plan
                watch.prepare(plan)
            }
            syncSavedRoutesToWatch()
            pushWatchState(force: true)
        }
    }

    private func routeForWatchStart(_ routeID: String?) -> Route? {
        guard let routeID else { return selected ?? routes.first }
        return ([selected].compactMap { $0 } + routes + favoriteRoutes).first { $0.id == routeID }
    }

    /// A walk the Watch guided on its own comes home with it. If the phone
    /// walked the same outing it already has the record; otherwise this one
    /// becomes the last outing, with its summary, as if the phone had been there.
    private func adoptWatchWalk(_ record: WatchWalkRecordPayload) {
        navigationLogger.log("watch.walkRecordReceived", details: [
            "sessionID": record.sessionID, "points": String(record.track.count),
            "alreadyHaveIt": String(session?.id == record.sessionID)
        ])
        guard session?.id != record.sessionID, !hasActiveWalk else { return }
        // The phone only keeps the last outing; a newer one stays.
        if let current = session, current.startedAt > record.startedAt { return }
        let adopted = record.sessionRecord()
        session = adopted
        sessionStore.save(adopted, immediately: true)
        presentSummary(for: adopted)
    }

    private func handleWatchWorkoutStatus(_ status: WatchWorkoutStatusPayload) {
        navigationLogger.log("watch.workoutStatus", details: [
            "state": String(describing: status.state),
            "sessionID": status.sessionID,
            "matchesCurrentSession": String(session?.id == status.sessionID),
            "message": status.message ?? "none",
            "connection": watch.connection.diagnosticName
        ])
        guard var record = session, record.id == status.sessionID else { return }
        switch status.state {
        case .running:
            // Written the moment the Watch confirms it: a phone killed
            // mid-walk must come back knowing the Watch owns the workout.
            guard record.workoutOwner != .watch else { return }
            record.healthOwner = .watch
        case .saved:
            record.healthOwner = .watch
            record.health = .savedOnWatch(workoutID: status.workoutID)
        case .failed:
            // The Watch got nothing into Health, so the phone takes the
            // workout back — one outing still means exactly one workout.
            record.healthOwner = .phone
            if case .savedOnWatch = record.health { record.health = .notAttempted }
        }
        session = record
        sessionStore.save(record, immediately: true)
        refreshSummary()
        if status.state == .failed, record.isFinished {
            Task { await saveToHealth() }
        }
    }

    /// Feeds the Watch the phone's navigation state on a steady clock rather
    /// than on every GPS fix — the wrist wants a readable number, not every
    /// twitch of the track, and the mirrored channel has a byte budget.
    private func startWatchStateFeed() {
        stopWatchStateFeed()
        watchStateTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.pushWatchState() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopWatchStateFeed() {
        watchStateTask?.cancel()
        watchStateTask = nil
    }

    private func pushWatchState(force: Bool = false) {
        guard let record = session, !record.isFinished else { return }
        let phase: WorkoutPhase = isPaused ? .paused : .active
        watch.send(
            makeWorkoutState(record: record, route: selected, phase: phase, offRoute: offRoute),
            force: force
        )
    }

}
