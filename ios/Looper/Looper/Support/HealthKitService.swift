import CoreLocation
import Foundation
import HealthKit
import LooperKit

/// What the app is allowed to do with Apple Health right now.
enum HealthAvailability: Equatable {
    /// No Health data on this device at all.
    case unavailable
    /// Never asked.
    case notDetermined
    /// Asked, and told no.
    case denied
    /// Cleared to write workouts.
    case authorized

    var canSave: Bool { self == .authorized }
}

enum HealthSaveError: LocalizedError {
    case unavailable
    case notAuthorized
    case noWorkoutProduced

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Health isn’t available on this device."
        case .notAuthorized: return "Looper doesn’t have permission to add workouts."
        case .noWorkoutProduced: return "The workout couldn’t be created."
        }
    }
}

/// Saves a finished outing to Apple Health. Kept behind a protocol so the
/// app model can be exercised without a real Health store.
protocol WorkoutSaving: Sendable {
    var availability: HealthAvailability { get async }
    /// Returns the saved workout's identifier.
    func requestAuthorization() async -> HealthAvailability
    func save(_ record: LoopSessionRecord) async throws -> String
}

/// The one place HealthKit is touched. Views and the app model deal in
/// `LoopSessionRecord` and a save state; nothing else imports HealthKit.
///
/// The shape here is deliberately "build a completed workout from a recorded
/// track". A future Apple Watch app would add an `HKWorkoutSession` that
/// feeds live heart-rate samples into the same `HKWorkoutBuilder` before
/// `endCollection` — an extra sample source, not a rewrite of this flow.
final class HealthKitService: WorkoutSaving, @unchecked Sendable {
    private let store = HKHealthStore()

    /// Exactly what this release writes — and nothing it reads. Daily steps
    /// stay Apple Health's own business, so no step samples are written and
    /// no read permission is asked for.
    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(distance)
        }
        return types
    }

    var availability: HealthAvailability {
        get async { currentAvailability() }
    }

    private func currentAvailability() -> HealthAvailability {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        // The workout type is the permission that actually gates a save; the
        // route and distance types ride along with it.
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return .authorized
        case .sharingDenied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorization() async -> HealthAvailability {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: [])
        } catch {
            // A thrown request means the sheet never resolved; the status
            // below is still the truth of what we may do.
        }
        return currentAvailability()
    }

    func save(_ record: LoopSessionRecord) async throws -> String {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthSaveError.unavailable }
        guard currentAvailability() == .authorized else { throw HealthSaveError.notAuthorized }

        let summary = makeLoopSummary(record)
        let start = record.startedAt
        // A zero-length workout is rejected by HealthKit; give a lightning-fast
        // outing a floor of one second.
        let end = max(record.endedAt ?? Date(), start.addingTimeInterval(1))

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = record.activity == .running ? .running : .walking
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: start)

        if summary.distanceMeters > 0,
           let distanceType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            let sample = HKQuantitySample(
                type: distanceType,
                quantity: HKQuantity(unit: .meter(), doubleValue: summary.distanceMeters),
                start: start,
                end: end
            )
            try await builder.addSamples([sample])
        }

        // No active-energy sample: the app has no sound native calculation of
        // it (that would need the reader's body metrics, which this release
        // deliberately doesn't ask to read), and a guessed calorie figure in
        // someone's health record is worse than none.
        var metadata: [String: Any] = [HKMetadataKeyIndoorWorkout: false]
        if let elevation = summary.elevationGainMeters, elevation > 0 {
            metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: elevation)
        }
        try await builder.addMetadata(metadata)

        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { throw HealthSaveError.noWorkoutProduced }

        // The workout itself is already saved at this point. An incomplete or
        // rejected track shouldn't undo that, so route failures are swallowed
        // rather than reported as a failed save — and a track too broken to
        // stand for the outing is left off entirely.
        if summary.hasReliableTrack {
            await attachRoute(record.track, to: workout)
        }
        return workout.uuid.uuidString
    }

    private func attachRoute(_ track: [TrackPoint], to workout: HKWorkout) async {
        // The same track the summary shows — a stale fix from another city
        // must not become a leg of the route in Apple Health either.
        let locations = plausibleTrack(track)
            .map { point in
                CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
                    altitude: point.altitude ?? 0,
                    horizontalAccuracy: point.horizontalAccuracy,
                    verticalAccuracy: point.verticalAccuracy,
                    course: point.course ?? -1,
                    speed: point.speed ?? -1,
                    timestamp: point.timestamp
                )
            }
        // Two points is the least that can draw a line worth showing.
        guard locations.count >= 2 else { return }

        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        do {
            // HealthKit prefers the track fed in batches rather than as one
            // enormous insert; a long run is easily thousands of fixes.
            for chunk in stride(from: 0, to: locations.count, by: 500) {
                let slice = Array(locations[chunk..<min(chunk + 500, locations.count)])
                try await routeBuilder.insertRouteData(slice)
            }
            _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
        } catch {
            // Leaves a workout with no map in Fitness — still a real workout.
        }
    }
}
