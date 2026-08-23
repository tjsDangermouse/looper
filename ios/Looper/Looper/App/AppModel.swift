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
    @Published var muted = false
    @Published private(set) var hasActiveWalk = false
    @Published var offRoute = false
    @Published var progress: Double = 0
    @Published var following = false
    @Published var courseUp = false
    @Published var showingVoiceSettings = false
    @Published private(set) var selectedVoiceIdentifier: String?
    @Published var reversed = false
    @Published var findingStage = 0
    @Published var padding: (bottom: CGFloat, right: CGFloat) = (0, 0)

    let compassAvailable = LocationManager.headingAvailable

    private let apiBase: String
    private let httpClient: LoopsHTTPClient
    private let locationManager: LocationManager
    private let speechManager: SpeechManager
    private let routeStore: RouteStore
    private let routeTileCache: RouteTileCache

    private static let variationStride = 3
    private var requestSeq = 0
    private var lastAsk: (key: String, variation: Int) = ("", Int.random(in: 0..<300) * AppModel.variationStride)
    private var spoken = ""
    private var walked = 0.0
    private var badFixes = 0
    private var findingStageTask: Task<Void, Never>?
    private var walkWatchTask: Task<Void, Never>?
    private var headingWatchTask: Task<Void, Never>?

    init(
        apiBase: String,
        locationManager: LocationManager = LocationManager(),
        speechManager: SpeechManager = SpeechManager(),
        httpClient: LoopsHTTPClient = URLSessionLoopsHTTPClient(),
        routeStore: RouteStore = RouteStore(),
        routeTileCache: RouteTileCache = RouteTileCache()
    ) {
        self.apiBase = apiBase
        self.locationManager = locationManager
        self.speechManager = speechManager
        self.httpClient = httpClient
        self.routeStore = routeStore
        self.routeTileCache = routeTileCache
        self.selectedVoiceIdentifier = speechManager.selectedVoiceIdentifier
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
        default: break
        }
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

    func toggleReversed() {
        reversed.toggle()
        selected = selected.map(reverseRoute)
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

    // Discovery starts from fresh bearings. Refresh skips the variations the
    // service explored for the displayed routes, and excludes those routes by
    // geometry so it deliberately finds different walks.
    func findRoutes() {
        guard valid else {
            error = mode == .time ? "Choose 15 minutes to 4 hours." : "Choose a loop between 1 and 20 km."
            return
        }
        let key = "\(String(format: "%.5f", start.lng)),\(String(format: "%.5f", start.lat))|\(mode.rawValue)|\(amount)|\(unit.rawValue)"
        let sameSpot = lastAsk.key == key
        let variation = sameSpot
            ? (lastAsk.variation + AppModel.variationStride) % 900
            : Int.random(in: 0..<300) * AppModel.variationStride
        lastAsk = (key, variation)

        requestSeq += 1
        let seq = requestSeq
        busy = true
        findingStage = 0
        error = ""
        reversed = false
        startFindingStageTimer()

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
                    excludeRoutes: sameSpot ? routes : [],
                    apiBase: apiBase,
                    client: httpClient
                )
                guard seq == requestSeq else { return } // a later request already started; its result is the one that counts
                guard !result.routes.isEmpty else {
                    throw LooperAPIError.message(result.warning ?? "We couldn’t find a clean loop of that length from here. Try a different distance or move the start point.")
                }
                routes = result.routes
                selected = result.routes.first
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

    func beginWalk(_ route: Route) {
        if !muted { speechManager.prime() }
        spoken = ""
        walked = 0
        progress = 0
        following = true
        selected = route
        showsRouteOverlay = true
        hasActiveWalk = true
        screen = .walk
        routeStore.save(route)
        routeTileCache.cache(route)
        startWalkWatch()
    }

    func endWalk() {
        hasActiveWalk = false
        following = false
        courseUp = false
        showsRouteOverlay = false
        screen = .choices
        stopWalkWatch()
        stopHeadingWatch()
        speechManager.stop()
        routeTileCache.release()
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
                if update.accuracy > 100 {
                    locationState = "Waiting for a more accurate location…"
                    continue
                }
                locationState = ""
                position = update.point
                let match = nearestProgress(update.point, selected.geometry.coordinates, from: walked)
                walked = match.distanceAlong
                progress = match.distanceAlong
                badFixes = match.distanceToRoute > 55 ? badFixes + 1 : 0
                offRoute = badFixes >= 3
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
        guard screen == .walk, !muted else { return }
        if offRoute {
            if spoken != "off" { spoken = "off"; speechManager.speak("You are off the planned loop. Head back to the route.") }
            return
        }
        if spoken == "off" { spoken = "" }
        if let turn, let announcement = turnAnnouncement(turn.announcementInput, unit: unit) {
            if spoken != announcement.key { spoken = announcement.key; speechManager.speak(announcement.text) }
            return
        }
        if turn == nil, spoken != "home" { spoken = "home"; speechManager.speak("You are back where you started.") }
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
}
