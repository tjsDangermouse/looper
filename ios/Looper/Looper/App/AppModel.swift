import AVFoundation
import CoreLocation
import Foundation
import LooperKit

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

    let compassAvailable = LocationManager.headingAvailable
    let health: HealthIntegration
    /// The Apple Watch, if there is one. Always present as an object; it
    /// reports `.unavailable` when there is no Watch to talk to, and every
    /// path through this model works with it in that state.
    let watch = WatchCompanion()

    private let apiBase: String
    private let httpClient: LoopsHTTPClient
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
    private var walked = 0.0
    private var badFixes = 0
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
        apiBase: String,
        locationManager: LocationManager = LocationManager(),
        speechManager: SpeechManager = SpeechManager(),
        httpClient: LoopsHTTPClient = URLSessionLoopsHTTPClient(),
        routeStore: RouteStore = RouteStore(),
        favoritesStore: FavoritesStore = FavoritesStore(),
        routeTileCache: RouteTileCache = RouteTileCache(),
        sessionStore: SessionStore = SessionStore(),
        health: HealthIntegration? = nil
    ) {
        self.apiBase = apiBase
        self.locationManager = locationManager
        self.speechManager = speechManager
        self.httpClient = httpClient
        self.routeStore = routeStore
        self.favoritesStore = favoritesStore
        self.routeTileCache = routeTileCache
        self.sessionStore = sessionStore
        self.health = health ?? HealthIntegration()
        self.favoriteRoutes = favoritesStore.load()
        self.selectedVoiceIdentifier = speechManager.selectedVoiceIdentifier
        restoreSession()
        connectWatch()
        #if DEBUG
        seedPreviewStateIfRequested()
        #endif
    }

    #if DEBUG
    /// Lets a debug build jump straight to a screen with sample data, without
    /// a live route service — set LOOPER_PREVIEW to "choices" or "walk" in
    /// the scheme/launch environment. LOOPER_PREVIEW=find instead exercises
    /// the real network path against the configured apiBase.
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
        func sampleRoute(id: String, name: String) -> Route {
            Route(
                id: id, name: name, distanceMeters: 4200, durationSeconds: 3000,
                targetDifferencePercent: 4,
                geometry: LineGeometry(coordinates: [start, Point(start.lng + 0.01, start.lat + 0.005), Point(start.lng + 0.02, start.lat), start]),
                steps: [
                    Step(instruction: "Head along Peel Road", distanceMeters: 1500, durationSeconds: 1100, road: "Peel Road"),
                    Step(instruction: "Turn left onto Strang Road", distanceMeters: 1700, durationSeconds: 1200, maneuver: .code(0), road: "Strang Road"),
                    Step(instruction: "Turn right onto Union Road", distanceMeters: 1000, durationSeconds: 700, maneuver: .code(1), road: "Union Road"),
                    Step(instruction: "Arrive at your starting point", distanceMeters: 0, durationSeconds: 0, maneuver: .code(10)),
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
        } else {
            // Most recently saved first makes the last route someone chose easy
            // to find in Settings.
            favoriteRoutes.insert(route, at: 0)
        }
        favoritesStore.save(favoriteRoutes)
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

        Task {
            do {
                let result = try await requestLoops(
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
                    apiBase: apiBase,
                    client: httpClient
                )
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
                routeWaypoints = requestedWaypoints
                showsRouteOverlay = true
                screen = .choices
                error = result.warning ?? ""
            } catch {
                if seq == requestSeq {
                    self.error = (error as? LooperAPIError)?.errorDescription ?? "Routes are unavailable right now."
                }
            }
            if seq == requestSeq { busy = false }
        }
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
    private func beginWalkFromWatch(_ route: Route, sessionID: String) {
        guard !startingWalk, !hasActiveWalk else { return }
        startingWalk = true
        Task { await startWalk(route, watchSessionID: sessionID) }
    }

    private func startWalk(_ route: Route, watchSessionID: String? = nil) async {
        defer { startingWalk = false }
        selected = route
        var plan = preparedLoopPlan(for: route)
        if let watchSessionID { plan.sessionID = watchSessionID }

        var owner: HealthWorkoutOwner = .phone
        if watchSessionID != nil {
            // Started on the wrist: the Watch's workout is already running,
            // so it owns the Health record without being asked.
            owner = .watch
        } else if watch.isPairedWithApp {
            startupNotice = "Starting on your Apple Watch…"
            owner = await watch.startWorkout(for: plan) ? .watch : .phone
        }
        startupNotice = ""
        preparedPlan = nil

        if !muted { speechManager.prime() }
        spoken = ""
        walked = 0
        progress = 0
        isPaused = false
        pausedAt = nil
        offRoute = false
        following = true
        showsRouteOverlay = true
        hasActiveWalk = true
        screen = .walk
        routeStore.save(route)
        routeTileCache.cache(route)
        startRecording(route, id: plan.sessionID, owner: owner)
        startWalkWatch()
        startWatchStateFeed()
    }

    /// Finishes the outing, once. Both devices can ask for this — a tap on
    /// the phone, a tap on the wrist, or a duplicate of either arriving late
    /// — and every one of them lands here, where the already-finished record
    /// is what makes the second call a no-op.
    func endWalk() {
        guard hasActiveWalk || session?.isFinished == false else { return }
        let finished = finishRecording()
        hasActiveWalk = false
        following = false
        courseUp = false
        showsRouteOverlay = false
        isPaused = false
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
    private func startRecording(_ route: Route, id: String, owner: HealthWorkoutOwner) {
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
            healthOwner: owner
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
        if record.arrivedAt == nil, hasArrived(route, progressMeters: progress) {
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
        if record.arrivedAt == nil, let route = selected, hasArrived(route, progressMeters: progress) {
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
        Task { await saveToHealth() }
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
        badFixes = 0
        stopWalkWatch()
        walkWatchTask = Task {
            for await update in locationManager.positionUpdates() {
                guard let selected else { continue }
                // A paused outing isn't being walked: the fix is neither
                // recorded nor allowed to move progress, so standing still
                // with the phone in a pocket can't drift the loop along.
                if isPaused { continue }
                if update.accuracy > 100 {
                    locationState = "Waiting for a more accurate location…"
                    continue
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
                badFixes = match.distanceToRoute > 55 ? badFixes + 1 : 0
                offRoute = badFixes >= 3
                if record(update, on: selected) {
                    // This is the same idempotent path used by both End
                    // buttons. It presents the summary and tells the Watch to
                    // finish its one canonical HealthKit workout.
                    endWalk()
                    return
                }
                announceIfNeeded()
            }
        }
    }

    private func stopWalkWatch() {
        walkWatchTask?.cancel()
        walkWatchTask = nil
    }

    // Speak each turn once per distance band, plus one warning when the walk
    // strays off the loop. Falls silent on mute or on leaving the walk screen.
    private func announceIfNeeded() {
        guard screen == .walk, !muted, !isPaused else { return }
        if offRoute {
            if spoken != "off" { spoken = "off"; speechManager.speak("You are off the planned loop. Head back to the route.") }
            return
        }
        if spoken == "off" { spoken = "" }
        if let turn, let announcement = turnAnnouncement(turn.announcementInput, unit: unit) {
            if spoken != announcement.key { spoken = announcement.key; speechManager.speak(announcement.text) }
            return
        }
        if turn == nil,
           let selected,
           hasArrived(selected, progressMeters: progress),
           spoken != "home" {
            spoken = "home"
            speechManager.speak("You are back where you started.")
        }
    }

    func toggleMute() {
        muted.toggle()
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
        watch.activate()
    }

    /// The plan for a loop, reusing the one already preloaded to the Watch
    /// when it is for the same route — so the id on the wrist and the id in
    /// the session record are the same outing.
    private func preparedLoopPlan(for route: Route) -> LoopPlanPayload {
        if let preparedPlan, preparedPlan.routeID == route.id { return preparedPlan }
        return LoopPlanPayload(
            sessionID: UUID().uuidString,
            routeID: route.id,
            routeName: route.name,
            activity: activity,
            mode: mode,
            targetAmount: Double(amount) ?? 0,
            targetUnit: unit,
            displayUnit: unit,
            plannedDistanceMeters: route.distanceMeters,
            plannedDurationSeconds: route.durationSeconds
        )
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
            // Start from the wrist. The route is whichever loop is chosen on
            // the phone — the Watch was shown that same plan, and it has no
            // route of its own to offer.
            guard let route = selected ?? routes.first else { return }
            guard let sessionID = command.sessionID else { return }
            beginWalkFromWatch(route, sessionID: sessionID)
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
            pushWatchState(force: true)
        }
    }

    private func handleWatchWorkoutStatus(_ status: WatchWorkoutStatusPayload) {
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
