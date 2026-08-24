import Foundation
import LooperKit
import WatchKit

/// Turn guidance you can feel. What to play is decided by
/// `TurnHapticPlanner` in LooperKit — this is only the wrist end of it, and
/// deliberately holds no distances of its own.
///
/// The system's own haptic settings are respected without any work here:
/// WatchKit silences these when haptic alerts are turned off, and strengthens
/// them when Prominent Haptics is on. Nothing plays while the workout is
/// paused or ended, because the planner never asks for it.
@MainActor
final class WatchHapticPlayer {
    private var planner: TurnHapticPlanner

    init(activity: Activity = .walking) {
        planner = TurnHapticPlanner(activity: activity)
    }

    /// Starts afresh for a new outing — a new plan must never inherit the
    /// "already warned about this turn" memory of the last one.
    func reset(for activity: Activity) {
        planner = TurnHapticPlanner(activity: activity)
    }

    func respond(to state: WorkoutStatePayload) {
        for cue in planner.cues(for: state) {
            switch cue {
            case .prepare:
                // The gentlest of the three: a heads-up, not an instruction.
                WKInterfaceDevice.current().play(.directionUp)
            case .imminent:
                WKInterfaceDevice.current().play(.notification)
            case .offRoute:
                // Distinct from either turn cue, and played exactly once
                // however long the walk stays off the loop.
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }
}
