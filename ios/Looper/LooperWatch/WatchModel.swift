import Foundation
import HealthKit
import LooperKit
import SwiftUI

/// The Watch app's one piece of state. It owns the workout, the link to the
/// phone and the wrist taps, and everything on screen is derived from it.
///
/// It calculates nothing about the route. Every manoeuvre, every distance to
/// a turn and every off-route verdict arrives from the phone's navigation
/// engine already decided; this only draws them, and says plainly when it has
/// stopped hearing them.
@MainActor
final class WatchModel: ObservableObject {
    enum Screen: Equatable {
        /// Nothing prepared yet — the phone hasn't sent a loop.
        case waiting
        /// A loop is ready to start.
        case prepared
        case working
        case finished
    }

    @Published private(set) var plan: LoopPlanPayload?
    /// The phone's live picture of the walk. Absent until the first update.
    @Published private(set) var state: WorkoutStatePayload?
    @Published private(set) var result: WorkoutResultPayload?
    @Published private(set) var starting = false
    @Published private(set) var notice: String?
    /// Whether the phone's navigation is currently being heard from. False
    /// means the numbers on screen are the Watch's own and the turn guidance
    /// has stopped — said out loud rather than quietly faked.
    @Published private(set) var isPhoneLive = false

    let workout = WatchWorkout()
    private let link = WatchLinkSession()
    private let haptics = WatchHapticPlayer()
    private var freshnessTask: Task<Void, Never>?
    private var lastStateAt: Date?
    private var handledCommandIDs: Set<String> = []
    private let defaults = UserDefaults.standard
    private static let planKey = "watch.last-plan"
    /// How long the wrist waits before admitting the phone has gone quiet.
    /// The phone sends a state update about once a second, so this is many
    /// missed updates rather than one unlucky one.
    private static let livenessSeconds: TimeInterval = 12

    init() {
        plan = loadStoredPlan()
        workout.onStatus = { [weak self] status in self?.send(.workoutStatus(status)) }
        workout.onRemoteMessage = { [weak self] message in self?.receive(message) }
        link.onMessage = { [weak self] message in self?.receive(message) }
        link.onReachChange = { [weak self] _ in self?.objectWillChange.send() }
        link.onVersionMismatch = { [weak self] version in
            self?.notice = "Your iPhone is running a different version of Looper (v\(version))."
        }
    }

    var screen: Screen {
        if result != nil { return .finished }
        if workout.isRunning || starting { return .working }
        return plan == nil ? .waiting : .prepared
    }

    var activity: Activity { plan?.activity ?? .walking }

    func activate() {
        link.activate()
        Task {
            // A Watch app relaunched mid-outing — swiped away, or evicted for
            // memory — picks the running workout back up rather than starting
            // a second one.
            if await workout.recoverRunningWorkout() {
                beginFreshnessWatch()
                requestPlan()
            } else {
                requestPlan()
            }
        }
    }

    /// The phone launched us with a workout configuration: it has tapped
    /// Start and expects a workout on this wrist.
    func handle(_ configuration: HKWorkoutConfiguration) {
        let activity: Activity = configuration.activityType == .running ? .running : .walking
        Task { await start(activity: activity, initiatedHere: false) }
    }

    // MARK: Starting

    /// Start from the wrist. The phone is asked to begin navigating the same
    /// loop; if it can't be reached the workout still records, and the screen
    /// says what is missing rather than pretending to navigate.
    func startFromWatch() {
        Task { await start(activity: activity, initiatedHere: true) }
    }

    private func start(activity: Activity, initiatedHere: Bool) async {
        guard !workout.isRunning, !starting else { return }
        guard let plan else {
            notice = "Choose a loop on your iPhone first."
            return
        }
        starting = true
        defer { starting = false }
        notice = nil
        haptics.reset(for: activity)
        state = nil
        result = nil

        do {
            try await workout.start(activity: activity, sessionID: plan.sessionID)
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "The workout couldn’t start."
            // The phone owns the Health record when the Watch can't take it —
            // it is told so explicitly rather than left to guess.
            send(.workoutStatus(WatchWorkoutStatusPayload(
                sessionID: plan.sessionID, state: .failed, message: notice
            )))
            return
        }

        if initiatedHere {
            // Mirroring has already woken the phone app; this tells it which
            // loop to navigate.
            send(.command(WatchCommandPayload(kind: .start, sessionID: plan.sessionID)))
        }
        beginFreshnessWatch()
    }

    // MARK: Controls

    func pause() {
        workout.pause()
        send(.command(WatchCommandPayload(kind: .pause, sessionID: plan?.sessionID)))
    }

    func resume() {
        workout.resume()
        send(.command(WatchCommandPayload(kind: .resume, sessionID: plan?.sessionID)))
    }

    /// Ends from the wrist. The phone is told, so it closes the same outing
    /// once and shows its Loop Summary; the workout here is saved once.
    func end() {
        let sessionID = plan?.sessionID
        send(.command(WatchCommandPayload(kind: .end, sessionID: sessionID)))
        Task {
            await workout.end()
            finishFreshnessWatch()
            presentResultIfNeeded()
        }
    }

    func dismissResult() {
        result = nil
        state = nil
        notice = nil
    }

    // MARK: Messages

    private func send(_ message: WatchMessage) {
        // The mirrored channel first — it is the fast one, and it exists
        // exactly while a workout does. WatchConnectivity carries the same
        // message either way, which is what makes a dropped mirror survivable.
        workout.sendToPhone(message)
        link.send(message, delivery: .durable)
    }

    private func requestPlan() {
        link.send(.command(WatchCommandPayload(kind: .requestPlan)), delivery: .durable)
    }

    private func receive(_ message: WatchMessage) {
        switch message {
        case .plan(let incoming):
            // A plan that arrives by the slow queue can be older than the one
            // already shown; the newest prepared loop is the one that counts.
            if let plan, plan.preparedAt > incoming.preparedAt { return }
            guard !workout.isRunning else { return }
            plan = incoming
            storePlan(incoming)
            haptics.reset(for: incoming.activity)
        case .state(let incoming):
            // A state for an outing this Watch has never heard of means the
            // plan didn't reach us — most likely the phone chose a different
            // loop while we were out of range. The state is still the truth
            // of what is happening, so it is shown, and the plan is chased.
            if let plan, plan.sessionID != incoming.sessionID {
                requestPlan()
            }
            state = incoming
            lastStateAt = Date()
            isPhoneLive = true
            notice = nil
            haptics.respond(to: incoming)
        case .result(let incoming):
            guard incoming.sessionID == plan?.sessionID || result == nil else { return }
            // The phone decides how the loop went; the Watch adds the one
            // figure only it has.
            var merged = incoming
            merged.averageHeartRate = workout.averageHeartRate ?? incoming.averageHeartRate
            result = merged
            Task { await workout.end() }
            finishFreshnessWatch()
        case .command(let command):
            guard handledCommandIDs.insert(command.id).inserted else { return }
            switch command.kind {
            case .pause: workout.pause()
            case .resume: workout.resume()
            case .end:
                Task {
                    await workout.end()
                    finishFreshnessWatch()
                    presentResultIfNeeded()
                }
            case .start, .requestPlan:
                break
            }
        case .workoutStatus:
            break
        }
    }

    // MARK: Liveness

    private func beginFreshnessWatch() {
        finishFreshnessWatch()
        lastStateAt = nil
        isPhoneLive = false
        freshnessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    let last = self.lastStateAt ?? .distantPast
                    let live = Date().timeIntervalSince(last) < Self.livenessSeconds
                    if self.isPhoneLive != live { self.isPhoneLive = live }
                }
            }
        }
    }

    private func finishFreshnessWatch() {
        freshnessTask?.cancel()
        freshnessTask = nil
        isPhoneLive = false
    }

    /// The Watch's own end screen, for when the phone's verdict never
    /// arrives. Every figure is one this device measured; the status is the
    /// same rule the phone applies to the last progress it managed to send,
    /// and nothing is invented to fill the gaps.
    private func presentResultIfNeeded() {
        guard result == nil, let plan else { return }
        let progress = state?.progressFraction ?? 0
        let distance = state?.distanceMeters ?? workout.localDistanceMeters
        let duration = workout.elapsedSeconds
        let measurable = distance >= 100 && duration >= 60
        result = WorkoutResultPayload(
            sessionID: plan.sessionID,
            status: progress >= loopCompletionFraction ? .complete : .endedEarly,
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

    /// A Watch app opened cold, out of range of the phone, still shows the
    /// last loop it was told about rather than an empty screen.
    private func loadStoredPlan() -> LoopPlanPayload? {
        guard let data = defaults.data(forKey: Self.planKey) else { return nil }
        return try? JSONDecoder().decode(LoopPlanPayload.self, from: data)
    }
}
