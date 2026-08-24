import Foundation
import HealthKit
import LooperKit

/// How the iPhone sees the Watch right now. The wording each case turns into
/// lives in the views; this is only the truth of the connection.
enum WatchConnection: Equatable {
    /// No Watch paired, or one paired without the Looper app on it. The app
    /// behaves exactly as it did before the Watch app existed.
    case unavailable
    /// A Watch is there and idle.
    case ready
    /// Asked to start, waiting for the Watch to say the workout is running.
    case starting
    /// A mirrored workout session is connected: the live path is up.
    case live
    /// The Watch owns a running workout, but the live channel is down — out
    /// of range, or the mirrored session dropped. Navigation carries on.
    case degraded
    /// The Watch couldn't take part. Carries the reason for the phone to show.
    case failed(String)

    var isRunningOnWatch: Bool {
        switch self {
        case .live, .degraded: return true
        case .unavailable, .ready, .starting, .failed: return false
        }
    }
}

/// The iPhone's whole view of the Apple Watch: WatchConnectivity for
/// preloading and resilience, and the mirrored `HKWorkoutSession` for
/// low-latency in-workout traffic.
///
/// It never saves a workout and never touches the session record. It reports
/// what the Watch is doing, and `AppModel` decides what that means — which is
/// what keeps the "who owns the Health workout" rule in one place instead of
/// spread across two devices' plumbing.
@MainActor
final class WatchCompanion: NSObject, ObservableObject {
    @Published private(set) var connection: WatchConnection = .unavailable
    /// Whether a Watch with the app is paired at all — the only thing the
    /// Settings screen needs to know.
    @Published private(set) var isPairedWithApp = false

    /// A pause/resume/end asked for on the wrist.
    var onCommand: ((WatchCommandPayload) -> Void)?
    /// The Watch reporting whether its HealthKit workout took, and what it saved.
    var onWorkoutStatus: ((WatchWorkoutStatusPayload) -> Void)?

    private let store = HKHealthStore()
    private let link = WatchLinkSession()
    private var mirrored: HKWorkoutSession?
    /// The outing the Watch is currently being asked about. Anything quoting
    /// a different session id is left over from a previous walk.
    private var currentSessionID: String?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var startTimeout: Task<Void, Never>?
    /// Commands already acted on, so a command arriving down both channels —
    /// or retried by the system's queue — is obeyed exactly once.
    private var handledCommandIDs: Set<String> = []
    /// Live state is sent at most this often. The mirrored channel allows
    /// 100 KB per 10 seconds and a state payload is a few hundred bytes, so
    /// this is about legibility on the wrist, not about the budget.
    private static let liveInterval: TimeInterval = 1
    /// …and the durable copy goes out this often, so a Watch that has been
    /// out of range still finds a recent picture waiting when it comes back.
    private static let resilientInterval: TimeInterval = 20
    private var lastLiveSend = Date.distantPast
    private var lastResilientSend = Date.distantPast
    /// How long the phone waits for the Watch before walking without it.
    static let startTimeoutSeconds: TimeInterval = 8

    override init() {
        super.init()
        link.onMessage = { [weak self] in self?.receive($0) }
        link.onReachChange = { [weak self] in self?.reachChanged($0) }
        link.onVersionMismatch = { [weak self] version in
            self?.connection = .failed("The Looper app on your Watch is a different version (v\(version)). Update both to use them together.")
        }
    }

    /// Called once, as early in launch as possible. The mirroring handler in
    /// particular has to be in place before the app is woken by a Watch
    /// starting a workout, which can happen with no UI on screen at all.
    func activate() {
        link.activate()
        guard HKHealthStore.isHealthDataAvailable() else { return }
        store.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in self?.adopt(session) }
        }
    }

    // MARK: Preparing and starting

    /// Preloads the chosen loop. Cheap, and safe to call whenever the choice
    /// changes — the Watch keeps only the most recent one.
    func prepare(_ plan: LoopPlanPayload) {
        currentSessionID = plan.sessionID
        guard link.reach.canPreload else { return }
        link.send(.plan(plan), delivery: .latest)
    }

    /// The phone has left the loop-choosing screen with nothing started. The
    /// Watch is told to stop offering the loop it was last shown, rather than
    /// sitting on a Start button for a route no longer on screen.
    func clearPrepared() {
        currentSessionID = nil
        guard link.reach.canPreload else { return }
        link.send(.clearPlan(at: Date()), delivery: .latest)
    }

    /// Asks the Watch to start its workout, and waits — briefly — for it to
    /// say it has. Returns whether the Watch owns this outing's workout.
    ///
    /// Everything about this is designed to fall back: no Watch, no app on
    /// it, Health refused on the wrist, or simply too slow to answer, and the
    /// phone walks the loop on its own exactly as it always has.
    func startWorkout(for plan: LoopPlanPayload) async -> Bool {
        guard link.reach.canPreload else {
            connection = .unavailable
            return false
        }
        currentSessionID = plan.sessionID
        connection = .starting
        link.send(.plan(plan), delivery: .latest)
        link.send(.command(WatchCommandPayload(kind: .start, sessionID: plan.sessionID)), delivery: .durable)

        // Launches the Watch app into the foreground and hands it the
        // configuration to start from — the supported way for a phone to
        // begin a workout on the wrist.
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = plan.activity == .running ? .running : .walking
        configuration.locationType = .outdoor
        do {
            try await store.startWatchApp(toHandle: configuration)
        } catch {
            connection = .failed("Your Apple Watch couldn’t start the workout.")
            return false
        }

        let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            startContinuation = continuation
            startTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.startTimeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.finishStart(false) }
            }
        }
        if !started, case .starting = connection {
            connection = .failed("Your Apple Watch didn’t answer in time. Recording on iPhone instead.")
        }
        return started
    }

    private func finishStart(_ started: Bool) {
        startTimeout?.cancel()
        startTimeout = nil
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(returning: started)
    }

    // MARK: Live traffic

    /// Sends the current state to the Watch. Throttled, and quietly dropped
    /// when there is nothing on the other end.
    func send(_ state: WorkoutStatePayload, force: Bool = false) {
        guard connection.isRunningOnWatch || connection == .starting else { return }
        let now = Date()
        if force || now.timeIntervalSince(lastLiveSend) >= Self.liveInterval {
            lastLiveSend = now
            sendOverMirroredChannel(.state(state))
        }
        // The durable copy is what a Watch that has been asleep or out of
        // range wakes up to, so it goes out on its own slower clock.
        if force || now.timeIntervalSince(lastResilientSend) >= Self.resilientInterval {
            lastResilientSend = now
            link.send(.state(state), delivery: .latest)
        }
    }

    /// Tells the Watch what the phone has just done — paused, resumed, or
    /// finished. Always durable: these are the ones that must not be missed.
    func send(command kind: WatchCommandKind, sessionID: String?) {
        let payload = WatchCommandPayload(kind: kind, sessionID: sessionID)
        // Marked as handled before it goes out, so the Watch echoing it back
        // can't bounce the same instruction around the pair.
        handledCommandIDs.insert(payload.id)
        sendOverMirroredChannel(.command(payload))
        link.send(.command(payload), delivery: .durable)
    }

    func send(result: WorkoutResultPayload) {
        sendOverMirroredChannel(.result(result))
        link.send(.result(result), delivery: .durable)
    }

    private func sendOverMirroredChannel(_ message: WatchMessage) {
        guard let mirrored, let data = try? WatchLinkCodec.encode(message) else { return }
        mirrored.sendToRemoteWorkoutSession(data: data) { [weak self] success, _ in
            guard !success else { return }
            Task { @MainActor in
                // The live path is down but the workout is still the Watch's;
                // the WatchConnectivity copy keeps the wrist roughly right.
                if self?.connection == .live { self?.connection = .degraded }
            }
        }
    }

    /// The phone's outing has ended. Lets go of the mirrored session without
    /// ending anything — the Watch ends its own workout, and a phone that
    /// tore the session down here would strand the save.
    func release() {
        currentSessionID = nil
        mirrored?.delegate = nil
        mirrored = nil
        finishStart(false)
        connection = link.reach.canPreload ? .ready : .unavailable
    }

    // MARK: Receiving

    private func adopt(_ session: HKWorkoutSession) {
        mirrored = session
        session.delegate = self
        connection = .live
        finishStart(true)
    }

    private func receive(_ message: WatchMessage) {
        switch message {
        case .command(let command):
            guard handledCommandIDs.insert(command.id).inserted else { return }
            // A command about an outing that is already over — an "end" that
            // took the slow queue home — must not touch the next one.
            if let id = command.sessionID, let current = currentSessionID, id != current { return }
            onCommand?(command)
        case .workoutStatus(let status):
            if status.state == .running {
                currentSessionID = status.sessionID
                if connection != .live { connection = .degraded }
                finishStart(true)
            }
            if status.state == .failed {
                connection = .failed(status.message ?? "Your Apple Watch couldn’t record this workout.")
                finishStart(false)
            }
            onWorkoutStatus?(status)
        case .plan, .state, .result, .clearPlan:
            // The phone is the source of all four; anything coming back is
            // an echo and is ignored.
            break
        }
    }

    private func reachChanged(_ reach: WatchLinkSession.Reach) {
        isPairedWithApp = reach.canPreload
        switch connection {
        case .unavailable, .ready:
            connection = reach.canPreload ? .ready : .unavailable
        case .live, .degraded, .starting, .failed:
            // A running workout's state is decided by the mirrored session,
            // not by whether the two apps can chat.
            break
        }
    }
}

extension WatchCompanion: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .running: connection = .live
            case .ended, .stopped: if connection == .live { connection = .degraded }
            default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            connection = .failed("The workout on your Apple Watch stopped unexpectedly.")
            finishStart(false)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in
            // The mirrored session is dead for good once this fires, but the
            // Watch's workout is not: it keeps recording and keeps the right
            // to save. Navigation on the phone carries on regardless.
            mirrored?.delegate = nil
            mirrored = nil
            if connection.isRunningOnWatch { connection = .degraded }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in
            for blob in data {
                guard let message = try? WatchLinkCodec.decode(blob) else { continue }
                receive(message)
            }
        }
    }
}
