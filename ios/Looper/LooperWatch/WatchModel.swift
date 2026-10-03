import CoreLocation
import Foundation
import HealthKit
import LooperKit
import SwiftUI

/// The Watch app's one piece of state. It owns the workout, the link to the
/// phone and the wrist taps, and everything on screen is derived from it.
///
/// The phone's engine plans the route and decides everything the walker is
/// told; that arrives as a guidance pack. This follows the pack with the
/// Watch's own GPS — how far along the route, which turn is next, whether the
/// walker has strayed — and plays the phone's haptics and spoken script. It
/// never plans, rewords or re-routes, and it looks and behaves the same with
/// the phone beside it or left at home.
@MainActor
final class WatchModel: ObservableObject {
    enum LaunchPhase: Equatable {
        case permissions
        case ready
        case blocked(String)
    }

    enum Screen: Equatable {
        /// Nothing prepared yet — no loop chosen, none saved.
        case waiting
        /// A loop is ready to start.
        case prepared
        case working
        case finished
    }

    @Published private(set) var plan: LoopPlanPayload?
    /// The Watch's own picture of the walk, from its own fixes. Absent until
    /// the first one.
    @Published private(set) var state: WorkoutStatePayload?
    @Published private(set) var result: WorkoutResultPayload?
    @Published private(set) var starting = false
    /// When Health recording is unavailable the walk is still guided, from the
    /// Watch's location while the app is in front, and the phone owns the
    /// Health record.
    @Published private(set) var guidanceOnly = false
    @Published private(set) var notice: String?
    /// The normal app stays behind this gate until the first-run sheets have
    /// been presented, in a deliberate order. Location is required to get
    /// past it; Health is asked for there too but is not required.
    @Published private(set) var launchPhase: LaunchPhase = .permissions
    /// Whether Health will accept a workout from this Watch. Settled at
    /// launch, alongside the other permissions, so that by the time a loop is
    /// on screen the app already knows whether it can record — and can say
    /// so, rather than finding out on the Start tap.
    @Published private(set) var canRecordToHealth = true
    /// The phone's saved routes, each a complete guidance pack.
    @Published private(set) var savedRoutes: [LoopPlanPayload] = []
    /// Spoken directions on or off. The wearer's choice, kept on the Watch.
    @Published var voiceOn: Bool {
        didSet {
            defaults.set(voiceOn, forKey: Self.voiceKey)
            if !voiceOn { speech.stop() }
        }
    }

    /// A testing switch: behave as if the phone were out of range, whether or
    /// not it is. Nothing is sent to it and nothing from it is acted on.
    @Published var standaloneForced: Bool {
        didSet {
            defaults.set(standaloneForced, forKey: Self.standaloneKey)
            workout.mirrorsToPhone = !standaloneForced
        }
    }

    let workout = WatchWorkout()
    let navigationMaps = WatchNavigationMapCache()
    private let link = WatchLinkSession()
    private let haptics = WatchHapticPlayer()
    private let speech = WatchSpeechPlayer()
    private var tracker: RouteTracker?
    private var cueSpeaker: CueSpeaker?
    private var walk = WalkLog()
    private var guidancePaused = false
    private var arrivalHandled = false
    /// The last time the phone's own navigation was heard from. Not shown
    /// anywhere: it only matters when the phone owns the walk's recording.
    private var lastPhoneStateAt: Date?
    private var savedWorkoutID: String?
    private var lastSnapshotAt = Date.distantPast
    private var plannedOnWatch = false
    private var savedRoutesSentAt = Date.distantPast
    private var handledCommandIDs: Set<String> = []
    private var permissionGate: Task<Bool, Never>?
    private let defaults = UserDefaults.standard
    private static let planKey = "watch.last-plan"
    private static let voiceKey = "watch.voice"
    private static let standaloneKey = "watch.force-standalone"
    /// How long since the phone last reported before the Watch speaks for it.
    private static let phoneSpeaksWithin: TimeInterval = 12
    private static let snapshotInterval: TimeInterval = 15

    init() {
        voiceOn = (defaults.object(forKey: Self.voiceKey) as? Bool) ?? true
        standaloneForced = defaults.bool(forKey: Self.standaloneKey)
        plan = loadStoredPlan()
        savedRoutes = WatchFiles.load(SavedRoutesPayload.self, named: "saved-routes")?.routes ?? []
        workout.mirrorsToPhone = !standaloneForced
        workout.onStatus = { [weak self] status in
            if status.state == .saved { self?.savedWorkoutID = status.workoutID }
            self?.send(.workoutStatus(status))
        }
        workout.onRemoteMessage = { [weak self] message in self?.receive(message) }
        workout.onFix = { [weak self] location in self?.ingest(location) }
        link.onMessage = { [weak self] message in self?.receive(message) }
        link.onReachChange = { [weak self] reach in
            guard let self else { return }
            objectWillChange.send()
            send(.diagnostic(WatchDiagnosticPayload(event: "connectionChanged", details: [
                "activated": String(reach.activated),
                "counterpartInstalled": String(reach.counterpartInstalled),
                "reachable": String(reach.reachable)
            ])))
        }
        link.onVersionMismatch = { [weak self] version in
            self?.notice = "Your iPhone is running a different version of Looper (v\(version))."
        }
        navigationMaps.onDiagnostic = { [weak self] event, details in
            self?.send(.diagnostic(WatchDiagnosticPayload(event: event, details: details)))
        }
        speech.onDiagnostic = { [weak self] event, details in
            self?.send(.diagnostic(WatchDiagnosticPayload(event: event, details: details)))
        }
        if let plan {
            speech.configure(plan.narration)
            navigationMaps.prepare(plan)
        }
        if !savedRoutes.isEmpty { navigationMaps.prefetch(savedRoutes) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_SKIP_GATE"] == "1" { launchPhase = .ready }
        seedDemoRoutesIfRequested()
        seedGuidancePreviewIfRequested()
        #endif
    }

    #if DEBUG
    /// Simulator-only: gives the Watch a prepared route and two saved ones, as
    /// the phone would have sent, so the Watch can be exercised on its own.
    /// Set LOOPER_WATCH_SEED=demo.
    private func seedDemoRoutesIfRequested() {
        guard ProcessInfo.processInfo.environment["LOOPER_WATCH_SEED"] == "demo" else { return }
        func loop(_ id: String, _ name: String, east: Double, north: Double) -> LoopPlanPayload {
            let originLat = 54.1500, originLng = -4.4800
            func point(_ e: Double, _ n: Double) -> Point {
                Point(originLng + e / (111_320 * cos(originLat * Double.pi / 180)), originLat + n / 111_320)
            }
            var geometry: [Point] = []
            func side(_ a: (Double, Double), _ b: (Double, Double)) {
                let count = max(1, Int(hypot(b.0 - a.0, b.1 - a.1) / 20))
                for i in 0..<count {
                    let t = Double(i) / Double(count)
                    geometry.append(point(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t))
                }
            }
            side((0, 0), (east, 0)); side((east, 0), (east, north))
            side((east, north), (0, north)); side((0, north), (0, 0))
            geometry.append(point(0, 0))
            let quarter = geometry.count / 4
            let starts = [0, quarter, quarter * 2, quarter * 3, geometry.count - 1]
            let names = ["Set off along Quay Road", "Turn left onto Harbour Road", "Turn left onto Mill Lane",
                         "Turn left onto Station Road", "You’re back where you started"]
            let kinds: [Maneuver] = [.name("continue"), .name("turn-left"), .name("turn-left"), .name("turn-left"), .name("finish")]
            var steps: [Step] = []
            for (i, start) in starts.enumerated() {
                let end = i + 1 < starts.count ? starts[i + 1] : start
                let length = end > start ? (start..<end).reduce(0.0) { $0 + haversine(geometry[$1], geometry[$1 + 1]) } : 0
                steps.append(Step(instruction: names[i], distanceMeters: length, durationSeconds: length / 1.4,
                                  startIndex: start, endIndex: end, maneuver: kinds[i]))
            }
            let route = Route(
                id: id, name: name, distanceMeters: steps.reduce(0) { $0 + $1.distanceMeters },
                durationSeconds: 1_200, targetDifferencePercent: 0,
                geometry: LineGeometry(coordinates: geometry), steps: steps
            )
            return makeSavedRoutePlan(route: route, activity: .walking, displayUnit: .km)
        }
        let prepared = loop("demo-1", "Harbour loop", east: 500, north: 300)
        let saved = [prepared, loop("demo-2", "Mill Lane circuit", east: 700, north: 400)]
        savedRoutes = saved
        WatchFiles.save(SavedRoutesPayload(routes: saved), named: "saved-routes")
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_SEED_PLAN"] != "0",
           plan == nil || ProcessInfo.processInfo.environment["LOOPER_WATCH_SEED_PLAN"] == "1" {
            choose(prepared)
        }
        navigationMaps.prefetch(saved)
        launchPhase = .ready
    }

    /// A simulator-only route into the live guidance page for visual QA.
    /// It deliberately reuses the last real plan stored on this Watch.
    private func seedGuidancePreviewIfRequested() {
        guard ProcessInfo.processInfo.environment["LOOPER_WATCH_PREVIEW"] == "guidance",
              let plan,
              var maneuver = plan.plannedManeuvers?.first else { return }
        maneuver.distanceMeters = 240
        let previewPosition = maneuver.coordinate.map {
            WatchNavigationMapCache.pointBeforeTurn(
                maneuver.distanceMeters,
                turn: $0,
                route: plan.plannedGeometry ?? []
            )
        }
        state = WorkoutStatePayload(
            sessionID: plan.sessionID,
            phase: .active,
            distanceMeters: 500,
            elapsedSeconds: 360,
            progressFraction: 0.15,
            remainingMeters: max(0, plan.plannedDistanceMeters - 500),
            offRoute: false,
            position: previewPosition,
            courseDegrees: previewPosition.flatMap { position in
                maneuver.coordinate.map { WatchNavigationMapCache.bearing(from: position, to: $0) }
            },
            next: maneuver
        )
        launchPhase = .ready
        guidanceOnly = true
    }

    /// Simulator-only: walks the chosen route with synthetic fixes through the
    /// real tracking, haptics and speech path, so the whole Watch pipeline can
    /// be exercised with no phone and no GPS. Set LOOPER_WATCH_SIMULATE=walk.
    private var simulation: Task<Void, Never>?
    private static var simulatedWalkRequested: Bool {
        ProcessInfo.processInfo.environment["LOOPER_WATCH_SIMULATE"] == "walk"
    }

    private func startSimulatedWalkIfRequested() {
        guard Self.simulatedWalkRequested, simulation == nil, screen == .prepared else { return }
        startFromWatch()
        simulation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while !Task.isCancelled {
                guard let self, let geometry = self.plan?.plannedGeometry, geometry.count > 1 else { return }
                let metersPerFix = Double(ProcessInfo.processInfo.environment["LOOPER_WATCH_SIM_SPEED"] ?? "") ?? 12
                var carried = 0.0
                for (a, b) in zip(geometry, geometry.dropFirst()) {
                    let length = haversine(a, b)
                    var at = metersPerFix - carried
                    while at <= length {
                        if Task.isCancelled { return }
                        let t = at / length
                        let location = CLLocation(
                            coordinate: CLLocationCoordinate2D(
                                latitude: a.lat + (b.lat - a.lat) * t, longitude: a.lng + (b.lng - a.lng) * t
                            ),
                            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1,
                            course: WatchNavigationMapCache.bearing(from: a, to: b), speed: 1.4, timestamp: Date()
                        )
                        await MainActor.run { self.ingest(location, simulated: true) }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        at += metersPerFix
                    }
                    carried = length - (at - metersPerFix)
                }
                return
            }
        }
    }
    #endif

    var screen: Screen {
        if result != nil { return .finished }
        if workout.isRunning || guidanceOnly || starting { return .working }
        return plan == nil ? .waiting : .prepared
    }

    var activity: Activity { plan?.activity ?? .walking }
    var isPaused: Bool {
        workout.isRunning ? workout.phase == .paused : guidancePaused
    }

    /// The Watch does the talking whenever it is guiding, so the walk sounds
    /// the same with or without a phone. The one exception is a walk the phone
    /// owns because Health recording is off here: the phone is speaking then.
    private var watchSpeaks: Bool {
        guard voiceOn else { return false }
        if guidanceOnly, let last = lastPhoneStateAt { return Date().timeIntervalSince(last) >= Self.phoneSpeaksWithin }
        return true
    }

    func activate() {
        link.activate()
        Task {
            #if DEBUG
            if Self.simulatedWalkRequested {
                requestPlan()
                startSimulatedWalkIfRequested()
                return
            }
            #endif
            guard await completePermissionGate() else { return }
            // A Watch app relaunched mid-outing — swiped away, or evicted for
            // memory — picks the running workout back up rather than starting
            // a second one.
            if await workout.recoverRunningWorkout() {
                restoreWalk()
            }
            requestPlan()
        }
    }

    /// Both first-run questions are asked here, at launch, in a deliberate
    /// order. A shared task also makes a phone-initiated launch wait on the
    /// exact same gate instead of starting a competing authorization request.
    ///
    /// The two are not equally important. Location must resolve: without it
    /// there is no route and nothing to record. Health is asked for in the
    /// same breath — permission sheets belong with the rest of setting up,
    /// not in front of someone who has just tapped Start and wants to walk —
    /// but a refusal only costs the Health recording, so it is noted and the
    /// launch carries on.
    private func completePermissionGate() async -> Bool {
        if launchPhase == .ready { return true }
        if let permissionGate { return await permissionGate.value }

        launchPhase = .permissions
        let gate = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let location = await workout.requestLocationAuthorization()
            guard location == .authorizedAlways || location == .authorizedWhenInUse else {
                launchPhase = .blocked("Allow location access in Settings so Looper can record your route, then try again.")
                return false
            }

            // The delegate callback records the choice before watchOS has
            // necessarily finished dismissing its sheet. Leave that short
            // transition clear before presenting HealthKit's larger sheet.
            try? await Task.sleep(nanoseconds: 350_000_000)
            canRecordToHealth = await workout.requestAuthorization()

            launchPhase = .ready
            return true
        }
        permissionGate = gate
        let ready = await gate.value
        permissionGate = nil
        return ready
    }

    func retryPermissions() {
        Task {
            guard await completePermissionGate() else { return }
            if await workout.recoverRunningWorkout() { restoreWalk() }
            requestPlan()
        }
    }

    /// The phone launched us with a workout configuration: it has tapped
    /// Start and expects a workout on this wrist.
    func handle(_ configuration: HKWorkoutConfiguration) {
        let activity: Activity = configuration.activityType == .running ? .running : .walking
        Task {
            guard await completePermissionGate() else { return }
            await start(activity: activity, initiatedHere: false)
        }
    }

    // MARK: Choosing a route

    /// Picks one of the phone's saved routes to walk. Nothing is worked out:
    /// the pack is already complete, and only gets a fresh outing id.
    func choose(_ route: LoopPlanPayload) {
        guard !workout.isRunning, !guidanceOnly, !starting else { return }
        var chosen = route
        chosen.sessionID = UUID().uuidString
        chosen.preparedAt = Date()
        plan = chosen
        plannedOnWatch = true
        storePlan(chosen)
        result = nil
        notice = nil
        speech.configure(chosen.narration)
        haptics.reset(config: chosen.guidance?.haptics ?? .forActivity(chosen.activity))
        navigationMaps.prepare(chosen)
    }

    // MARK: Starting

    /// Start from the wrist. Everything needed is already on the Watch, so
    /// this works with the phone out of reach; if it is in reach it is told,
    /// and walks the same route alongside.
    func startFromWatch() {
        Task { await start(activity: activity, initiatedHere: true) }
    }

    private func start(activity: Activity, initiatedHere: Bool) async {
        guard !workout.isRunning, !starting else { return }
        guard let plan else {
            notice = "Choose a route first — on the Watch from your saved routes, or on your iPhone."
            return
        }
        starting = true
        defer { starting = false }
        notice = nil
        haptics.reset(config: plan.guidance?.haptics ?? .forActivity(activity))
        navigationMaps.pausePrefetch()
        navigationMaps.prepare(plan)
        speech.configure(plan.narration)
        if voiceOn { speech.prime() }
        state = nil
        result = nil
        guidanceOnly = false
        guidancePaused = false
        arrivalHandled = false
        savedWorkoutID = nil
        tracker = RouteTracker(plan: plan)
        cueSpeaker = plan.script.map { CueSpeaker(script: $0) }
        walk = WalkLog(startedAt: Date())
        if tracker == nil {
            notice = "This route has no map data. Choose it again on your iPhone."
        }

        var recordsWorkout = false
        do {
            #if DEBUG
            // A simulated walk exercises the Watch's guidance without a
            // HealthKit workout, which the simulator may not be allowed to run.
            if Self.simulatedWalkRequested { throw WatchWorkout.Failure.unavailable }
            #endif
            try await workout.start(activity: activity, sessionID: plan.sessionID)
            recordsWorkout = true
            canRecordToHealth = true
            guidanceOnly = false
        } catch {
            guidanceOnly = true
            canRecordToHealth = workout.isAuthorizedToRecord
            notice = "Guidance only · Apple Health recording is off"
            // Without a workout nothing keeps the app running, so guidance
            // follows the Watch's location while the app is in front.
            workout.startFollowingWithoutWorkout()
            // The phone owns the Health record when the Watch can't take it —
            // it is told so explicitly rather than left to guess.
            send(.workoutStatus(WatchWorkoutStatusPayload(
                sessionID: plan.sessionID,
                state: .failed,
                message: (error as? LocalizedError)?.errorDescription ?? "The workout couldn’t start."
            )))
        }

        if initiatedHere {
            send(.command(WatchCommandPayload(
                kind: .start,
                sessionID: plan.sessionID,
                recordsWorkout: recordsWorkout,
                routeID: plan.routeID
            )))
        }
    }

    // MARK: Controls

    func pause() {
        if workout.isRunning { workout.pause() } else { guidancePaused = true }
        walk.pause()
        state?.phase = .paused
        send(.command(WatchCommandPayload(kind: .pause, sessionID: plan?.sessionID)))
    }

    func resume() {
        if workout.isRunning { workout.resume() } else { guidancePaused = false }
        walk.resume()
        state?.phase = .active
        send(.command(WatchCommandPayload(kind: .resume, sessionID: plan?.sessionID)))
    }

    /// Ends from the wrist. The phone is told, so it closes the same outing
    /// once and shows its Loop Summary; the workout here is saved once.
    func end() {
        send(.command(WatchCommandPayload(kind: .end, sessionID: plan?.sessionID)))
        Task { await finishWalk() }
    }

    func dismissResult() {
        result = nil
        state = nil
        guidanceOnly = false
        notice = nil
        tracker = nil
        cueSpeaker = nil
        if !savedRoutes.isEmpty { navigationMaps.prefetch(savedRoutes) }
    }

    private func finishWalk() async {
        speech.stop()
        await workout.end()
        workout.stopFollowingWithoutWorkout()
        #if DEBUG
        simulation?.cancel()
        simulation = nil
        #endif
        sendWalkRecord()
        WatchFiles.remove(named: "walk")
        guidancePaused = false
        presentResultIfNeeded()
    }

    // MARK: Following the route

    /// One GPS fix, followed along the pack's route. Position matching,
    /// a lookup of the next turn and the off-route test — nothing else.
    private func ingest(_ location: CLLocation, simulated: Bool = false) {
        guard tracker != nil, plan != nil, result == nil, !isPaused else { return }
        guard workout.isRunning || guidanceOnly || simulated else { return }
        let point = Point(location.coordinate.longitude, location.coordinate.latitude)
        guard let update = tracker?.update(fix: point, accuracy: location.horizontalAccuracy),
              let plan, let tracker else { return }

        walk.record(location, progress: update, now: Date())
        let elapsed = workout.elapsedSeconds > 0 ? workout.elapsedSeconds : walk.movingSeconds()
        let tracked = makeTrackedState(
            plan: plan,
            update: update,
            position: point,
            courseDegrees: location.course,
            phase: .active,
            distanceMeters: walk.trackDistance,
            elapsedSeconds: elapsed
        )
        let previousStep = state?.next?.stepIndex
        state = tracked
        if previousStep != tracked.next?.stepIndex {
            send(.diagnostic(WatchDiagnosticPayload(event: "stepDisplayed", details: [
                "previousStep": previousStep.map(String.init) ?? "none",
                "step": tracked.next.map { String($0.stepIndex) } ?? "none",
                "distanceM": tracked.next.map { String(format: "%.1f", $0.distanceMeters) } ?? "none"
            ])))
        }
        haptics.respond(to: tracked)
        narrate(update)

        if Date().timeIntervalSince(lastSnapshotAt) >= Self.snapshotInterval {
            lastSnapshotAt = Date()
            WatchFiles.save(walk.snapshot(sessionID: plan.sessionID, progress: tracker.progressMeters,
                                          hasArrived: tracker.hasArrived), named: "walk")
        }
        if update.arrived { handleArrival() }
    }

    private func narrate(_ update: TrackerUpdate) {
        guard var speaker = cueSpeaker else { return }
        let text = speaker.due(progressMeters: update.progressMeters, offRoute: update.offRoute)
        cueSpeaker = speaker
        // The cue is always consumed, so a phone that drops out mid-walk
        // doesn't leave the Watch with a backlog to read out.
        guard let text, watchSpeaks else { return }
        speech.speak(text)
    }

    /// Says the current instruction again, at the distance it is now, for a
    /// wearer who tapped the banner. Spoken on the Watch even when the phone
    /// is doing the talking: the tap was on the wrist. A tap during speech
    /// doesn't queue another sentence behind it.
    func repeatGuidance() {
        guard voiceOn, result == nil, !arrivalHandled, let state, !speech.isSpeaking else { return }
        let unit = plan?.displayUnit ?? .km
        let text: String?
        if state.offRoute {
            text = plan?.script?.offRouteText ?? guidanceOffRouteText
        } else if let next = state.next {
            text = turnAnnouncement(TurnAnnouncementInput(
                index: next.stepIndex, instruction: next.instruction, distanceAway: next.distanceMeters
            ), unit: unit)?.text
        } else if state.remainingMeters > 0 {
            text = turnAnnouncement(TurnAnnouncementInput(
                index: finishStepIndex, instruction: "You'll be back at the start", distanceAway: state.remainingMeters
            ), unit: unit)?.text
        } else {
            text = nil
        }
        guard let text else { return }
        speech.prime()
        speech.speak(text)
    }

    /// Back at the start: the Watch says so and ends the walk, which tells the
    /// phone to close its own.
    private func handleArrival() {
        guard !arrivalHandled else { return }
        arrivalHandled = true
        walk.arrivedAt = Date()
        var speaker = cueSpeaker
        let text = speaker?.arrival()
        cueSpeaker = speaker
        if watchSpeaks, let text {
            speech.speak(text) { [weak self] in self?.end() }
        } else {
            end()
        }
    }

    /// Picks up a walk after the app was relaunched mid-outing.
    private func restoreWalk() {
        guard let plan else { return }
        tracker = RouteTracker(plan: plan)
        cueSpeaker = plan.script.map { CueSpeaker(script: $0) }
        arrivalHandled = false
        if let snapshot = WatchFiles.load(WalkSnapshot.self, named: "walk"), snapshot.sessionID == plan.sessionID {
            walk = WalkLog(restoring: snapshot)
            tracker?.restore(progressMeters: snapshot.progressMeters, hasArrived: snapshot.hasArrived)
            arrivalHandled = snapshot.hasArrived
        } else {
            walk = WalkLog(startedAt: Date())
        }
        haptics.reset(config: plan.guidance?.haptics ?? .forActivity(plan.activity))
        navigationMaps.prepare(plan)
        speech.configure(plan.narration)
        if voiceOn { speech.prime() }
    }

    /// Hands the phone the walk, for when the two next meet. Queued as a file,
    /// so it arrives whenever the phone is next in reach — and is simply
    /// ignored if the phone walked it too.
    private func sendWalkRecord() {
        guard let plan, let tracker, !walk.track.isEmpty else { return }
        let record = walk.record(
            plan: plan,
            progressMeters: tracker.progressMeters,
            endedOffRoute: state?.offRoute ?? false,
            workoutID: savedWorkoutID
        )
        link.send(.walkRecord(record), delivery: .queued(kind: "walk-\(plan.sessionID)"))
    }

    // MARK: Messages

    private func send(_ message: WatchMessage) {
        guard !standaloneForced else { return }
        // Diagnostics are only worth having now. Queued durably they would
        // pile up while the phone is at home and arrive as a flood.
        if case .diagnostic = message {
            workout.sendToPhone(message)
            link.send(message, delivery: .live)
            return
        }
        // The mirrored channel first — it is the fast one, and it exists
        // exactly while a workout does. WatchConnectivity carries the same
        // message either way, which is what makes a dropped mirror survivable.
        workout.sendToPhone(message)
        link.send(message, delivery: .durable)
    }

    private func requestPlan() {
        guard !standaloneForced else { return }
        link.send(.command(WatchCommandPayload(kind: .requestPlan)), delivery: .durable)
    }

    private func receive(_ message: WatchMessage) {
        guard !standaloneForced else { return }
        switch message {
        case .plan(let incoming):
            // A plan that arrives by the slow queue can be older than the one
            // already shown; the newest prepared loop is the one that counts.
            if let plan, plan.preparedAt > incoming.preparedAt { return }
            // Starting the mirrored workout can beat the plan across the
            // radio. Accept that late plan when it belongs to this workout,
            // but never let another outing replace the route in progress.
            if workout.isRunning || guidanceOnly {
                guard incoming.sessionID == workout.sessionID || incoming.sessionID == plan?.sessionID else { return }
            }
            plan = incoming
            plannedOnWatch = false
            storePlan(incoming)
            speech.configure(incoming.narration)
            navigationMaps.prepare(incoming)
            haptics.reset(config: incoming.guidance?.haptics ?? .forActivity(incoming.activity))
        case .clearPlan(let clearedAt):
            // The phone left the loop-choosing screen with nothing started.
            // A clear that predates the plan on screen is stale and ignored,
            // the same way an old plan would be. A route the wearer picked on
            // the Watch is theirs, and the phone doesn't take it away.
            guard !workout.isRunning, !guidanceOnly, !plannedOnWatch else { return }
            guard let plan, plan.preparedAt <= clearedAt else { return }
            self.plan = nil
            clearStoredPlan()
            navigationMaps.release()
        case .savedRoutes(let incoming):
            guard incoming.sentAt >= savedRoutesSentAt else { return }
            savedRoutesSentAt = incoming.sentAt
            savedRoutes = incoming.routes
            WatchFiles.save(incoming, named: "saved-routes")
            if !workout.isRunning, !guidanceOnly, !starting {
                navigationMaps.prefetch(incoming.routes)
            }
        case .state(let incoming):
            // The phone's own picture of the walk is not drawn — the Watch
            // follows the route itself, so it looks the same without a phone.
            // It only says the phone is out walking too, and so will speak.
            lastPhoneStateAt = Date()
            // A state for an outing this Watch has never heard of means the
            // plan didn't reach us; chase it.
            if plan?.sessionID != incoming.sessionID, !workout.isRunning {
                requestPlan()
            }
        case .result(let incoming):
            guard incoming.sessionID == plan?.sessionID || result == nil else { return }
            // The phone decides how the loop went; the Watch adds the one
            // figure only it has.
            var merged = incoming
            merged.averageHeartRate = workout.averageHeartRate ?? incoming.averageHeartRate
            result = merged
            Task { await finishWalk() }
        case .command(let command):
            guard handledCommandIDs.insert(command.id).inserted else { return }
            switch command.kind {
            case .pause:
                if workout.isRunning { workout.pause() } else { guidancePaused = true }
                walk.pause()
                state?.phase = .paused
            case .resume:
                if workout.isRunning { workout.resume() } else { guidancePaused = false }
                walk.resume()
                state?.phase = .active
            case .end:
                Task { await finishWalk() }
            case .start, .requestPlan:
                break
            }
        case .workoutStatus, .diagnostic, .walkRecord:
            break
        }
    }

    /// The Watch's own end screen. Every figure is one this device measured,
    /// and nothing is invented to fill the gaps. The phone's verdict replaces
    /// it if the phone walked too.
    private func presentResultIfNeeded() {
        guard result == nil, let plan else { return }
        let progress = state?.progressFraction ?? 0
        let distance = max(state?.distanceMeters ?? 0, workout.localDistanceMeters)
        let duration = workout.elapsedSeconds > 0 ? workout.elapsedSeconds : walk.movingSeconds()
        let measurable = distance >= 100 && duration >= 60
        result = WorkoutResultPayload(
            sessionID: plan.sessionID,
            status: progress >= (plan.guidance?.completionFraction ?? loopCompletionFraction) ? .complete : .endedEarly,
            activity: plan.activity,
            displayUnit: plan.displayUnit,
            distanceMeters: distance,
            durationSeconds: duration,
            paceSecondsPerKm: measurable ? duration / (distance / 1000) : nil,
            averageHeartRate: workout.averageHeartRate
        )
    }

    // MARK: The last plan

    private func storePlan(_ plan: LoopPlanPayload) {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        defaults.set(data, forKey: Self.planKey)
    }

    private func clearStoredPlan() {
        defaults.removeObject(forKey: Self.planKey)
    }

    /// A Watch app opened cold, out of range of the phone, still shows the
    /// last loop it was told about rather than an empty screen.
    private func loadStoredPlan() -> LoopPlanPayload? {
        guard let data = defaults.data(forKey: Self.planKey) else { return nil }
        return try? JSONDecoder().decode(LoopPlanPayload.self, from: data)
    }
}

// MARK: - The walk's own record

/// What the Watch keeps of a walk as it happens: a thinned track for the phone,
/// the distance covered and the time spent paused.
private struct WalkLog {
    var startedAt = Date()
    var track: [TrackPoint] = []
    var trackDistance = 0.0
    var arrivedAt: Date?
    private(set) var pausedSeconds = 0.0
    private var pausedAt: Date?
    private var lastFix: CLLocation?

    /// A fix is kept when the walker has moved or a few seconds have passed,
    /// which keeps an hour's walk small enough to hand to the phone.
    private static let keepEveryMeters = 8.0
    private static let keepEverySeconds = 6.0

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    init(restoring snapshot: WalkSnapshot) {
        startedAt = snapshot.startedAt
        track = snapshot.track
        trackDistance = snapshot.trackDistance
        arrivedAt = snapshot.arrivedAt
        pausedSeconds = snapshot.pausedSeconds
    }

    mutating func record(_ location: CLLocation, progress: TrackerUpdate, now: Date) {
        if let lastFix {
            let hop = location.distance(from: lastFix)
            // Under a metre is jitter; over a hundred is a jump, not a step.
            if hop >= 1, hop <= 100 { trackDistance += hop }
        }
        lastFix = location

        let keep: Bool
        if let last = track.last {
            let moved = haversine(last.point, Point(location.coordinate.longitude, location.coordinate.latitude))
            keep = moved >= Self.keepEveryMeters || location.timestamp.timeIntervalSince(last.timestamp) >= Self.keepEverySeconds
        } else {
            keep = true
        }
        guard keep else { return }
        track.append(TrackPoint(
            lng: location.coordinate.longitude,
            lat: location.coordinate.latitude,
            altitude: location.verticalAccuracy > 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil,
            timestamp: location.timestamp
        ))
    }

    mutating func pause(now: Date = Date()) {
        if pausedAt == nil { pausedAt = now }
    }

    mutating func resume(now: Date = Date()) {
        guard let pausedAt else { return }
        pausedSeconds += now.timeIntervalSince(pausedAt)
        self.pausedAt = nil
        lastFix = nil
    }

    func movingSeconds(now: Date = Date()) -> Double {
        let paused = pausedSeconds + (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        return max(0, now.timeIntervalSince(startedAt) - paused)
    }

    func snapshot(sessionID: String, progress: Double, hasArrived: Bool) -> WalkSnapshot {
        WalkSnapshot(
            sessionID: sessionID, startedAt: startedAt, progressMeters: progress, hasArrived: hasArrived,
            arrivedAt: arrivedAt, pausedSeconds: pausedSeconds, trackDistance: trackDistance, track: track
        )
    }

    func record(plan: LoopPlanPayload, progressMeters: Double, endedOffRoute: Bool, workoutID: String?) -> WatchWalkRecordPayload {
        WatchWalkRecordPayload(
            sessionID: plan.sessionID,
            routeID: plan.routeID,
            routeName: plan.routeName,
            activity: plan.activity,
            mode: plan.mode,
            targetAmount: plan.targetAmount,
            targetUnit: plan.targetUnit,
            displayUnit: plan.displayUnit,
            plannedDistanceMeters: plan.plannedDistanceMeters,
            plannedDurationSeconds: plan.plannedDurationSeconds,
            plannedGeometry: plan.plannedGeometry ?? [],
            startedAt: startedAt,
            endedAt: Date(),
            progressMeters: progressMeters,
            arrivedAt: arrivedAt,
            endedOffRoute: endedOffRoute,
            pausedSeconds: pausedSeconds > 0 ? pausedSeconds : nil,
            track: track,
            workoutID: workoutID
        )
    }
}

/// A walk's state on disk, so a relaunched app picks up where it was.
private struct WalkSnapshot: Codable {
    var sessionID: String
    var startedAt: Date
    var progressMeters: Double
    var hasArrived: Bool
    var arrivedAt: Date?
    var pausedSeconds: Double
    var trackDistance: Double
    var track: [TrackPoint]
}

/// Small JSON files in Application Support — saved routes, the walk in
/// progress. Too big for UserDefaults, and they need to survive a relaunch.
private enum WatchFiles {
    private static func url(_ name: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let folder = base.appendingPathComponent("Looper", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(name).json")
    }

    static func save<T: Encodable>(_ value: T, named name: String) {
        guard let url = url(name) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, named name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    static func remove(named name: String) {
        guard let url = url(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
