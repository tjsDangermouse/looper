import Foundation
import HealthKit
import LooperKit
import UIKit

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
    /// The Watch cannot create a Health workout, but still receives the
    /// phone's route, metrics and turn guidance over WatchConnectivity.
    case guidanceOnly(String)

    var isRunningOnWatch: Bool {
        switch self {
        case .live, .degraded: return true
        case .unavailable, .ready, .starting, .failed, .guidanceOnly: return false
        }
    }

    var canReceiveGuidance: Bool {
        switch self {
        case .starting, .live, .degraded, .guidanceOnly: return true
        case .unavailable, .ready, .failed: return false
        }
    }

    /// For the diagnostics log. The reason carried by the two unhappy cases
    /// is included: "why did the Watch drop out" is the whole question those
    /// entries exist to answer.
    var diagnosticName: String {
        switch self {
        case .unavailable: return "unavailable"
        case .ready: return "ready"
        case .starting: return "starting"
        case .live: return "live"
        case .degraded: return "degraded"
        case .failed(let reason): return "failed(\(reason))"
        case .guidanceOnly(let reason): return "guidanceOnly(\(reason))"
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
    /// Progress reported by the Watch for routes requested for offline use.
    /// A route is not considered downloaded until the Watch says it is ready.
    @Published private(set) var routeTransfers: [String: WatchRouteTransferStatusPayload] = [:]

    /// A pause/resume/end asked for on the wrist.
    var onCommand: ((WatchCommandPayload) -> Void)?
    /// The Watch reporting whether its HealthKit workout took, and what it saved.
    var onWorkoutStatus: ((WatchWorkoutStatusPayload) -> Void)?
    /// Watch-side navigation and map breadcrumbs for the phone's export.
    var onDiagnostic: ((WatchDiagnosticPayload) -> Void)?
    /// A walk the Watch guided and recorded on its own, arriving after the fact.
    var onWalkRecord: ((WatchWalkRecordPayload) -> Void)?
    /// The link has just become able to carry things to the Watch — saved
    /// routes asked for before then were dropped, so they are sent now.
    var onLinkReady: (() -> Void)?

    private let store = HKHealthStore()
    private let link = WatchLinkSession()
    private var mirrored: HKWorkoutSession?
    /// The outing the Watch is currently being asked about. Anything quoting
    /// a different session id is left over from a previous walk.
    private var currentSessionID: String?
    private var mapTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var startTimeout: Task<Void, Never>?
    /// Commands already acted on, so a command arriving down both channels —
    /// or retried by the system's queue — is obeyed exactly once.
    private var handledCommandIDs: Set<String> = []
    private var requestedOfflineRouteIDs: Set<String> = []
    /// Live state is sent at most this often. The mirrored channel allows
    /// 100 KB per 10 seconds and a state payload is a few hundred bytes, so
    /// this is about legibility on the wrist, not about the budget.
    private static let liveInterval: TimeInterval = 1
    /// …and the application-context copy goes out this often. It is the only
    /// channel that survives a locked phone, a sleeping Watch or a dropped
    /// mirrored session, so it is treated as the link that has to work rather
    /// than as a fallback: it runs on this clock for every outing, whether or
    /// not a mirrored session happens to exist. The interval is set by the
    /// Watch's own liveness window — it has to arrive comfortably inside it,
    /// or the wrist declares the phone gone while the phone is walking on.
    private static let resilientInterval: TimeInterval = 5
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

    /// Hands the Watch every saved route as a complete guidance pack, so any
    /// of them can be walked with the phone left at home. Always the whole
    /// list, so a route removed here goes from the wrist too.
    func syncSavedRoutes(_ plans: [LoopPlanPayload]) {
        requestedOfflineRouteIDs = Set(plans.map(\.routeID))
        var next = routeTransfers.filter { requestedOfflineRouteIDs.contains($0.key) }
        for plan in plans {
            if next[plan.routeID] == nil || next[plan.routeID]?.state == .failed {
                next[plan.routeID] = WatchRouteTransferStatusPayload(
                    routeID: plan.routeID,
                    state: .queued,
                    completedItems: 0,
                    totalItems: 0
                )
            }
        }
        routeTransfers = next
        guard link.reach.canPreload else { return }
        link.send(.savedRoutes(SavedRoutesPayload(routes: plans)), delivery: .queued(kind: "saved-routes"))
    }

    func routeTransfer(for routeID: String) -> WatchRouteTransferStatusPayload? {
        routeTransfers[routeID]
    }

    #if DEBUG
    /// Opens the Watch's normal guidance UI without creating a HealthKit
    /// workout. Live simulated fixes then travel over the exact same
    /// WatchConnectivity state channel as a real walk.
    func startSimulation(for plan: LoopPlanPayload) {
        currentSessionID = plan.sessionID
        guard link.reach.canPreload else {
            connection = .unavailable
            return
        }
        connection = .guidanceOnly("Developer route simulation")
        link.send(.plan(plan), delivery: .latest)
    }
    #endif

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
            connection = .guidanceOnly("Apple Health recording is off on your Watch. Guidance is still available.")
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
            connection = .guidanceOnly("Recording on iPhone. Watch guidance remains available when connected.")
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
        guard connection.canReceiveGuidance else { return }
        let now = Date()
        // The fast paths, both of them best-effort: the mirrored channel
        // exists only while the Watch has a workout, and `.live` is discarded
        // the moment the pair stops being reachable — which is exactly what
        // happens when the screen goes off. Neither is allowed to be the only
        // way the wrist hears from the phone.
        if force || now.timeIntervalSince(lastLiveSend) >= Self.liveInterval {
            lastLiveSend = now
            if mirrored != nil {
                sendOverMirroredChannel(.state(state))
            } else {
                link.send(.state(state), delivery: .live)
            }
        }
        // …and the copy that actually has to arrive, on its own slower clock.
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
                connection = .guidanceOnly(
                    status.message ?? "Apple Health recording is off on your Watch. Guidance is still available."
                )
                finishStart(false)
            }
            onWorkoutStatus?(status)
        case .diagnostic(let diagnostic):
            onDiagnostic?(diagnostic)
        case .diagnosticBatch(let diagnostics):
            diagnostics.forEach { onDiagnostic?($0) }
        case .walkRecord(let record):
            onWalkRecord?(record)
        case .routeTransferStatus(let status):
            guard requestedOfflineRouteIDs.contains(status.routeID) else { return }
            if let current = routeTransfers[status.routeID], current.updatedAt > status.updatedAt { return }
            routeTransfers[status.routeID] = status
        case .mapRequest(let request):
            sendMaps(request)
        case .plan, .state, .result, .clearPlan, .savedRoutes:
            // The phone is the source of all four; anything coming back is
            // an echo and is ignored.
            break
        }
    }

    // MARK: Maps for the Watch

    /// Renders the maps the Watch has asked for and sends each as a file, in
    /// the order asked — the order they are walked. The Watch counts them in,
    /// which is what its progress ring shows, and asks again for any that
    /// never arrive, so nothing here needs to remember what was sent.
    private func sendMaps(_ request: WatchMapRequestPayload) {
        mapTask?.cancel()
        // A newer request replaces an older route's; maps already queued for
        // this route are still on their way and aren't made twice.
        link.cancelFiles { $0["routeID"] as? String != request.routeID }
        let queued = Set(link.filesInFlight.compactMap { $0["key"] as? String })
        let items = request.items.filter { !queued.contains($0.key) }
        guard !items.isEmpty else { return }
        onDiagnostic?(WatchDiagnosticPayload(event: "mapUploadStarted", details: ["maps": String(items.count)]))

        let size = CGSize(width: request.widthPoints, height: request.heightPoints)
        // The Watch usually asks while this app is on screen, straight after
        // a route is planned. Asked in the background, this buys the time to
        // send what it can; the Watch fetches the rest itself.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "watch-maps") { [weak self] in
            self?.mapTask?.cancel()
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
        mapTask = Task { [weak self] in
            var sent = 0
            for item in items {
                guard !Task.isCancelled, let self else { break }
                guard let rendered = try? await MapSnapshotRenderer.render(
                    center: item.center, distance: item.distanceMeters, heading: item.headingDegrees,
                    size: size, scale: request.scale
                ), !Task.isCancelled,
                      let image = rendered.image.jpegData(compressionQuality: 0.72),
                      let projection = try? JSONEncoder().encode(rendered.projection) else { continue }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-map-\(UUID().uuidString).jpg")
                guard (try? image.write(to: url, options: .atomic)) != nil else { continue }
                self.link.sendFile(url, details: [
                    "routeID": request.routeID, "key": item.key,
                    "projection": projection, "scale": Double(rendered.image.scale)
                ])
                sent += 1
            }
            self?.onDiagnostic?(WatchDiagnosticPayload(event: "mapUploadQueued", details: [
                "maps": String(sent), "asked": String(items.count)
            ]))
            if background != .invalid {
                UIApplication.shared.endBackgroundTask(background)
                background = .invalid
            }
        }
    }

    private func reachChanged(_ reach: WatchLinkSession.Reach) {
        let becameReady = reach.canPreload && !isPairedWithApp
        isPairedWithApp = reach.canPreload
        if becameReady { onLinkReady?() }
        switch connection {
        case .unavailable, .ready:
            connection = reach.canPreload ? .ready : .unavailable
        case .live, .degraded, .starting, .failed, .guidanceOnly:
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
