import CoreLocation
import Foundation
import HealthKit
import LooperKit

/// The one HealthKit workout for an outing, on the wrist where it belongs.
///
/// When a Watch is in the picture this is the *canonical* record: an
/// `HKWorkoutSession` with a live builder, collecting heart rate the phone
/// cannot collect, and a route builder fed from the Watch's own location. The
/// phone deliberately writes nothing for the same walk — see `AppModel`'s
/// `saveToHealth`. One outing, one workout.
///
/// It mirrors itself to the phone as soon as it starts running, which both
/// wakes the phone app and opens the low-latency channel the two devices use
/// while walking.
@MainActor
final class WatchWorkout: NSObject, ObservableObject {
    enum Failure: LocalizedError {
        case unavailable
        case notAuthorized
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "This Watch can’t record workouts."
            case .notAuthorized: return "Looper needs permission to save workouts on your Watch."
            case .sessionFailed(let message): return message
            }
        }
    }

    @Published private(set) var phase: WorkoutPhase = .preparing
    /// Beats per minute, straight from the Watch's own sensor. Never
    /// estimated, and absent until the first sample lands.
    @Published private(set) var heartRate: Double?
    @Published private(set) var averageHeartRate: Double?
    /// The Watch's own measure of ground covered. Only shown when the phone
    /// can't be heard from — the phone's recorded track is the app's distance
    /// everywhere else, and two devices quietly disagreeing on a screen is
    /// worse than one number with a warning next to it.
    @Published private(set) var localDistanceMeters: Double = 0
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var failure: String?

    /// Called whenever the workout's standing with HealthKit changes, so the
    /// phone can be told who owns the Health record.
    var onStatus: ((WatchWorkoutStatusPayload) -> Void)?
    /// Data arriving on the mirrored session's own channel.
    var onRemoteMessage: ((WatchMessage) -> Void)?
    /// Each usable GPS fix, for following the route.
    var onFix: ((CLLocation) -> Void)?
    /// Everything worth knowing afterwards about how the workout and its
    /// route went, for the diagnostic log.
    var onDiagnostic: ((String, [String: String]) -> Void)?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    /// Every fix given to the route, kept so the route can be saved again
    /// from scratch if HealthKit lost it. One failed insert ends the builder's
    /// series for good, and nothing else would say so.
    private var routeFixes: [CLLocation] = []
    private let locations = WatchRouteRecorder()
    /// Following the route with no workout — Health recording refused. Only
    /// while the app is in front, since only a workout keeps it running.
    private var followsWithoutWorkout = false
    /// `beginCollection` can return before `HKWorkoutSession` has actually
    /// finished its own async transition to `.running` — and background
    /// location, unlike the workout itself, is only granted to a session the
    /// system considers actually running. Starting the recorder in that gap
    /// is what throws `CLClientIsBackgroundable`, so it waits here instead.
    private var pendingLocationStart: (() -> Void)?
    private var ticker: Task<Void, Never>?
    /// The outing this workout belongs to, as the phone names it.
    private(set) var sessionID: String?
    /// Ending can be asked for by either device, more than once. The workout
    /// is only ever finished, and only ever reported, once.
    private var isFinishing = false

    /// Whether Health will accept a route for the workout. A separate switch
    /// ("Workout Routes") from permission to save the workout itself, so a
    /// workout can save with heart rate and everything else but no map.
    var routeAuthorizationName: String {
        switch store.authorizationStatus(for: HKSeriesType.workoutRoute()) {
        case .notDetermined: return "notDetermined"
        case .sharingDenied: return "denied"
        case .sharingAuthorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    /// Every kind of data this app writes, with what Health says about it now.
    /// HealthKit only ever reveals *write* permission. A switch for reading
    /// something (the Watch's own sensors feeding the workout) can't be seen
    /// from here, so only what is visible is checked.
    var permissionStatuses: [(name: String, status: String)] {
        let checks: [(String, HKObjectType?)] = [
            ("Workouts", HKObjectType.workoutType()),
            ("Workout Routes", HKSeriesType.workoutRoute()),
            ("Distance", HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)),
            ("Heart Rate", HKObjectType.quantityType(forIdentifier: .heartRate)),
            ("Active Energy", HKObjectType.quantityType(forIdentifier: .activeEnergyBurned))
        ]
        return checks.compactMap { name, type in
            guard let type else { return nil }
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized: return (name, "authorized")
            case .sharingDenied: return (name, "denied")
            case .notDetermined: return (name, "notDetermined")
            @unknown default: return (name, "unknown")
            }
        }
    }

    var isAuthorizedToRecordRoute: Bool { routeAuthorizationName == "authorized" }

    var isRunning: Bool { session != nil && (phase == .active || phase == .paused) }

    override init() {
        super.init()
        locations.onFix = { [weak self] location in
            Task { @MainActor in self?.onFix?(location) }
        }
        locations.onDiagnostic = { [weak self] event, details in
            Task { @MainActor in self?.onDiagnostic?(event, details) }
        }
    }

    /// Follows the route on the Watch's GPS without a workout.
    func startFollowingWithoutWorkout() {
        followsWithoutWorkout = true
        locations.start()
    }

    func stopFollowingWithoutWorkout() {
        guard followsWithoutWorkout else { return }
        followsWithoutWorkout = false
        locations.stop()
    }

    /// The launch gate waits for Core Location to settle before it asks for
    /// Health access. Returning the status lets the gate keep the main app
    /// hidden when location access was declined.
    var locationAuthorizationName: String { locations.authorizationName }

    func requestLocationAuthorization() async -> CLAuthorizationStatus {
        await locations.requestAuthorization()
    }

    /// Everything this app writes. No step samples are written.
    ///
    /// Active energy is included so the session's own live builder can save
    /// the active-energy samples watchOS already computes from the wrist's
    /// sensors and the wearer's Health body metrics — Looper never estimates
    /// this itself, only asks to keep what the system worked out.
    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { types.insert(distance) }
        if let heart = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(heart) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
        return types
    }

    /// Metrics the Watch records automatically for this workout configuration.
    /// HealthKit only delivered heart rate when that was the sole requested
    /// read type; without distance Fitness cannot derive pace, and without
    /// active energy it cannot show kilocalories for the workout.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let heart = HKObjectType.quantityType(forIdentifier: .heartRate) { types.insert(heart) }
        if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { types.insert(distance) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
        return types
    }

    /// Whether Health will accept a workout from this Watch right now. Read
    /// after a refusal to tell "declined" apart from a workout that failed
    /// to start for some other reason, and again on later launches, so a
    /// permission granted in Settings is picked up without being re-asked.
    var isAuthorizedToRecord: Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    /// Asked for once at launch, with the other first-run permissions, so the
    /// sheet lands while the walker is setting the app up rather than in
    /// front of the Start button. Calling it again later is harmless: once
    /// the choice is made watchOS answers from the stored decision.
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
        } catch {
            // A thrown request means the sheet never resolved; the status
            // below is still the truth of what we may do.
        }
        return store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    // MARK: Lifecycle

    func start(activity: Activity, sessionID: String) async throws {
        guard !isRunning else { return }
        guard HKHealthStore.isHealthDataAvailable() else { throw Failure.unavailable }
        guard await requestAuthorization() else { throw Failure.notAuthorized }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity == .running ? .running : .walking
        configuration.locationType = .outdoor

        let session: HKWorkoutSession
        do {
            session = try HKWorkoutSession(healthStore: store, configuration: configuration)
        } catch {
            throw Failure.sessionFailed(error.localizedDescription)
        }
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self

        self.sessionID = sessionID
        self.session = session
        self.builder = builder
        self.isFinishing = false
        self.failure = nil
        self.routeFixes = []

        let started = Date()
        session.startActivity(with: started)
        do {
            try await builder.beginCollection(at: started)
        } catch {
            self.session = nil
            self.builder = nil
            throw Failure.sessionFailed(error.localizedDescription)
        }

        // The route rides along with the workout builder, so finishing the
        // workout finishes the route with it — there is no window in which a
        // saved workout is missing its map.
        routeBuilder = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder
        onDiagnostic?("route.builder", [
            "created": String(routeBuilder != nil),
            "workoutAuth": String(describing: store.authorizationStatus(for: HKObjectType.workoutType()).rawValue),
            "routeAuth": routeAuthorizationName,
            "mirrorsToPhone": String(mirrorsToPhone)
        ])
        beginLocationsWhenRunning(session)

        phase = .active
        startTicking()
        report(.running)
        startMirroring()
    }

    /// Starts the route recorder immediately if the session has already
    /// reached `.running`, or defers it to the delegate callback that reports
    /// that transition.
    private func beginLocationsWhenRunning(_ session: HKWorkoutSession) {
        let beginLocations: () -> Void = { [weak self] in
            self?.locations.start { [weak self] batch in
                Task { @MainActor in await self?.appendRoute(batch) }
            }
        }
        // `.paused` also means the session has finished its initial
        // transition and is past the same gate `.running` clears.
        let ready = session.state == .running || session.state == .paused
        onDiagnostic?("route.locationsRequested", [
            "sessionState": String(describing: session.state),
            "startedNow": String(ready),
            "routeBuilderPresent": String(routeBuilder != nil)
        ])
        if ready {
            beginLocations()
        } else {
            pendingLocationStart = beginLocations
        }
    }

    /// Off while the wearer forces standalone mode: the phone is then not told
    /// about the workout at all, as if it were out of range.
    var mirrorsToPhone = true

    /// Mirroring is what wakes the iPhone app and opens the fast channel. A
    /// failure here is not fatal: WatchConnectivity still carries the plan
    /// and the state, just less promptly.
    private func startMirroring() {
        guard mirrorsToPhone else { return }
        session?.startMirroringToCompanionDevice { _, _ in }
    }

    func pause() {
        guard phase == .active else { return }
        session?.pause()
    }

    func resume() {
        guard phase == .paused else { return }
        session?.resume()
    }

    /// Ends and saves. Safe to call twice — from the wrist and from the phone
    /// at the same moment, or from a queued command that arrives late — and
    /// only the first call finishes anything.
    func end() async {
        guard !isFinishing, let session, let builder else { return }
        isFinishing = true
        phase = .ending
        onDiagnostic?("workout.ending", ["routeFixes": String(routeFixes.count), "routeBuilderPresent": String(routeBuilder != nil)])
        let ended = Date()
        session.end()
        pendingLocationStart = nil
        locations.stop()

        // Any fixes still in hand belong to this workout; they are given to
        // the route before collection closes.
        await appendRoute(locations.drain())

        do {
            try await builder.endCollection(at: ended)
            averageHeartRate = averageHeartRate ?? statisticAverage(.heartRate)
            let workout = try await builder.finishWorkout()
            if let workout { await ensureRoute(for: workout) }
            phase = .ended
            onDiagnostic?("workout.saved", ["workoutID": workout?.uuid.uuidString ?? "none"])
            report(.saved, workoutID: workout?.uuid.uuidString)
        } catch {
            onDiagnostic?("workout.saveFailed", ["error": error.localizedDescription])
            phase = .ended
            failure = error.localizedDescription
            // The phone takes the Health record back when this happens, so
            // the outing still gets exactly one workout — just from the other
            // device.
            report(.failed, message: error.localizedDescription)
        }
        stopTicking()
        self.session = nil
        self.builder = nil
        self.routeBuilder = nil
    }

    /// The phone or the Watch app going away mid-workout doesn't end it. On
    /// relaunch, HealthKit hands the running session back so the wrist picks
    /// up where it left off rather than starting a second workout.
    func recoverRunningWorkout() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable(), session == nil else { return false }
        guard let recovered = try? await store.recoverActiveWorkoutSession() else { return false }
        session = recovered
        builder = recovered.associatedWorkoutBuilder()
        builder?.delegate = self
        recovered.delegate = self
        routeBuilder = builder?.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder
        onDiagnostic?("workout.recovered", [
            "state": String(describing: recovered.state), "routeBuilderPresent": String(routeBuilder != nil)
        ])
        phase = recovered.state == .paused ? .paused : .active
        beginLocationsWhenRunning(recovered)
        startTicking()
        startMirroring()
        return true
    }

    // MARK: The mirrored channel

    func sendToPhone(_ message: WatchMessage) {
        guard mirrorsToPhone, let session, let data = try? WatchLinkCodec.encode(message) else { return }
        session.sendToRemoteWorkoutSession(data: data) { _, _ in
            // WatchConnectivity carries the same message as a fallback; a
            // failure here needs no separate handling.
        }
    }

    // MARK: Internals

    private func appendRoute(_ batch: [CLLocation]) async {
        guard let routeBuilder, !batch.isEmpty else { return }
        routeFixes += batch
        do {
            try await routeBuilder.insertRouteData(batch)
            onDiagnostic?("route.inserted", ["batch": String(batch.count), "total": String(routeFixes.count)])
        } catch {
            onDiagnostic?("route.insertFailed", [
                "batch": String(batch.count), "total": String(routeFixes.count),
                "error": error.localizedDescription, "routeAuth": routeAuthorizationName
            ])
        }
    }

    /// After the workout is saved, confirms Health holds a route for it. If
    /// not — the builder's series died, or never attached — the route is
    /// rebuilt from every fix kept and attached explicitly.
    private func ensureRoute(for workout: HKWorkout) async {
        let fixes = routeFixes
        let attached = await hasRoute(for: workout)
        onDiagnostic?("route.check", [
            "fixes": String(fixes.count), "attachedByWorkout": String(attached), "routeAuth": routeAuthorizationName
        ])
        guard !attached, !fixes.isEmpty else { return }
        let rebuilt = HKWorkoutRouteBuilder(healthStore: store, device: nil)
        do {
            try await rebuilt.insertRouteData(fixes)
            _ = try await rebuilt.finishRoute(with: workout, metadata: nil)
            onDiagnostic?("route.rebuilt", ["fixes": String(fixes.count)])
        } catch {
            onDiagnostic?("route.rebuildFailed", [
                "fixes": String(fixes.count), "error": error.localizedDescription, "routeAuth": routeAuthorizationName
            ])
        }
    }

    private func hasRoute(for workout: HKWorkout) async -> Bool {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: !(samples ?? []).isEmpty)
            }
            store.execute(query)
        }
    }

    private func report(_ state: WatchWorkoutStatusPayload.State, workoutID: String? = nil, message: String? = nil) {
        guard let sessionID else { return }
        onStatus?(WatchWorkoutStatusPayload(sessionID: sessionID, state: state, workoutID: workoutID, message: message))
    }

    private func statisticAverage(_ identifier: HKQuantityTypeIdentifier) -> Double? {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier),
              let statistics = builder?.statistics(for: type),
              let average = statistics.averageQuantity() else { return nil }
        return average.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
    }

    /// The elapsed clock is read rather than counted, so a paused workout and
    /// a relaunched app both show the time HealthKit believes in.
    private func startTicking() {
        stopTicking()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self, let builder = self.builder else { return }
                    self.elapsedSeconds = builder.elapsedTime
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }
}

extension WatchWorkout: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            onDiagnostic?("workout.state", [
                "from": String(describing: fromState), "to": String(describing: toState),
                "locationStartDeferred": String(pendingLocationStart != nil)
            ])
            if toState == .running || toState == .paused, let pending = pendingLocationStart {
                pendingLocationStart = nil
                pending()
            }
            switch toState {
            case .running: phase = .active
            case .paused: phase = .paused
            case .stopped: phase = .ending
            case .ended: if phase != .ended { phase = .ending }
            default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            // Most often: the walker started another workout in Apple's own
            // Workout app, which takes the session away from us. Nothing has
            // been saved, so the phone is told to own the record.
            failure = error.localizedDescription
            onDiagnostic?("workout.sessionFailed", ["error": error.localizedDescription])
            phase = .ended
            pendingLocationStart = nil
            locations.stop()
            report(.failed, message: "Your Watch stopped recording this workout.")
            stopTicking()
            session = nil
            builder = nil
            routeBuilder = nil
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        // The phone has gone; the workout on this wrist carries on recording
        // and saving. Nothing to do here but let the UI notice.
        Task { @MainActor in
            onDiagnostic?("workout.mirrorDisconnected", ["error": error?.localizedDescription ?? "none"])
            objectWillChange.send()
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in
            for blob in data {
                guard let message = try? WatchLinkCodec.decode(blob) else { continue }
                onRemoteMessage?(message)
            }
        }
    }
}

extension WatchWorkout: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            for type in collectedTypes {
                guard let quantityType = type as? HKQuantityType,
                      let statistics = workoutBuilder.statistics(for: quantityType) else { continue }
                switch quantityType.identifier {
                case HKQuantityTypeIdentifier.heartRate.rawValue:
                    let bpm = HKUnit.count().unitDivided(by: .minute())
                    heartRate = statistics.mostRecentQuantity()?.doubleValue(for: bpm)
                    averageHeartRate = statistics.averageQuantity()?.doubleValue(for: bpm)
                case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
                    localDistanceMeters = statistics.sumQuantity()?.doubleValue(for: .meter()) ?? localDistanceMeters
                default:
                    break
                }
            }
        }
    }
}
