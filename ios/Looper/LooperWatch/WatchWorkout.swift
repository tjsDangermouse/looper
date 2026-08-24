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

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private let locations = WatchRouteRecorder()
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

    var isRunning: Bool { session != nil && (phase == .active || phase == .paused) }

    /// Everything this app writes, and the one thing it reads. Heart rate is
    /// read so it can be shown live on the wrist; no step counts are written,
    /// and nothing else is read.
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

    private var readTypes: Set<HKObjectType> {
        guard let heart = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        return [heart]
    }

    /// Whether the walker has yet been asked. Used to put the reason on
    /// screen *before* the system sheet appears, rather than leaving a
    /// permission prompt to explain itself.
    var needsAuthorization: Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        return store.authorizationStatus(for: HKObjectType.workoutType()) == .notDetermined
    }

    /// Asked for at the moment it is needed — the tap that starts a workout —
    /// so the reason for the sheet is obvious from what the walker just did.
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
        if session.state == .running || session.state == .paused {
            beginLocations()
        } else {
            pendingLocationStart = beginLocations
        }
    }

    /// Mirroring is what wakes the iPhone app and opens the fast channel. A
    /// failure here is not fatal: WatchConnectivity still carries the plan
    /// and the state, just less promptly.
    private func startMirroring() {
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
            phase = .ended
            report(.saved, workoutID: workout?.uuid.uuidString)
        } catch {
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
        phase = recovered.state == .paused ? .paused : .active
        beginLocationsWhenRunning(recovered)
        startTicking()
        startMirroring()
        return true
    }

    // MARK: The mirrored channel

    func sendToPhone(_ message: WatchMessage) {
        guard let session, let data = try? WatchLinkCodec.encode(message) else { return }
        session.sendToRemoteWorkoutSession(data: data) { _, _ in
            // WatchConnectivity carries the same message as a fallback; a
            // failure here needs no separate handling.
        }
    }

    // MARK: Internals

    private func appendRoute(_ batch: [CLLocation]) async {
        guard let routeBuilder, !batch.isEmpty else { return }
        try? await routeBuilder.insertRouteData(batch)
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
        Task { @MainActor in objectWillChange.send() }
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
