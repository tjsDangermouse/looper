import Foundation

/// Everything the Watch and the iPhone say to each other, in one place.
///
/// The two devices talk over three channels — the mirrored workout session's
/// data channel, WatchConnectivity messages, and WatchConnectivity's
/// application context — and every one of them carries the same envelope, so
/// a payload that arrives by the slow route is indistinguishable from one
/// that arrived by the fast one. Nothing anywhere passes a bare dictionary.
public enum WatchLink {
    /// Bumped whenever a payload changes shape. A build that receives a
    /// version it doesn't know throws rather than decoding half a message —
    /// the two devices can be updated separately, and an old Watch app
    /// guessing at a new phone's payload is worse than a stale screen.
    public static let version = 1
}

/// Where the outing has got to, as both devices understand it. This is the
/// app's own idea of the workout's life, deliberately not `HKWorkoutSession`'s
/// — the phone has to reason about it with no HealthKit session of its own.
public enum WorkoutPhase: String, Codable, Equatable, Sendable {
    /// A loop is chosen and the Watch has been asked, but nothing has started.
    case preparing
    /// Running: recording, navigating, collecting heart rate.
    case active
    case paused
    /// End requested; the workout is being closed off and saved.
    case ending
    case ended
}

/// Which device owns the one Health workout for an outing. Persisted with the
/// session record, because the answer has to survive the app being killed
/// mid-walk: a relaunch that forgot the Watch owns the workout would write a
/// second one.
public enum HealthWorkoutOwner: String, Codable, Equatable, Sendable {
    /// The iPhone builds and saves the workout, exactly as it always has.
    case phone
    /// A Watch `HKWorkoutSession` is the workout. The phone must not save one.
    case watch
}

/// The loop the Watch should be showing before and during an outing. Sent once
/// when a loop is prepared or started, and again whenever the Watch asks for
/// it — never on a timer. It carries no route geometry: the Watch draws no map.
public struct LoopPlanPayload: Codable, Equatable, Sendable {
    /// The session record's id. Every later state update and command quotes
    /// it, so a message left over from the previous outing is ignored rather
    /// than applied to this one.
    public var sessionID: String
    public var routeID: String
    /// What the loop is called, and the area if the name carries one — the
    /// only place the Watch shows where the walk is.
    public var routeName: String
    public var activity: Activity
    public var mode: LoopMode
    public var targetAmount: Double
    public var targetUnit: Unit
    public var displayUnit: Unit
    public var plannedDistanceMeters: Double
    public var plannedDurationSeconds: Double
    /// When the phone prepared this loop. The Watch shows the most recent
    /// plan, and an older one arriving late must not replace a newer one.
    public var preparedAt: Date

    public init(
        sessionID: String,
        routeID: String,
        routeName: String,
        activity: Activity,
        mode: LoopMode,
        targetAmount: Double,
        targetUnit: Unit,
        displayUnit: Unit,
        plannedDistanceMeters: Double,
        plannedDurationSeconds: Double,
        preparedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.routeID = routeID
        self.routeName = routeName
        self.activity = activity
        self.mode = mode
        self.targetAmount = targetAmount
        self.targetUnit = targetUnit
        self.displayUnit = displayUnit
        self.plannedDistanceMeters = plannedDistanceMeters
        self.plannedDurationSeconds = plannedDurationSeconds
        self.preparedAt = preparedAt
    }

    /// The target as a line of text, for the Watch's start screen.
    public var targetDescription: String {
        switch mode {
        case .distance:
            return formatDistance(targetMeters(amount: targetAmount, unit: targetUnit), unit: displayUnit)
        case .time:
            return formatTime(targetAmount * 60)
        }
    }
}

/// One manoeuvre, as the iPhone's navigation engine has already decided it.
/// The Watch renders this and nothing else — it never looks at geometry, and
/// it never works out a turn for itself.
public struct ManeuverPayload: Codable, Equatable, Sendable {
    /// The step's index in the route. Identity for haptics: the same turn
    /// arriving again at a shorter distance is the same turn, and must not
    /// buzz twice for the same reason.
    public var stepIndex: Int
    /// `Turn`'s raw value. Sent as a string so an unknown turn from a newer
    /// phone degrades to a straight-ahead arrow instead of failing to decode.
    public var turn: String
    public var instruction: String
    /// How far until the manoeuvre.
    public var distanceMeters: Double

    public init(stepIndex: Int, turn: Turn, instruction: String, distanceMeters: Double) {
        self.stepIndex = stepIndex
        self.turn = turn.rawValue
        self.instruction = instruction
        self.distanceMeters = distanceMeters
    }

    public var turnKind: Turn { Turn(rawValue: turn) ?? .straight }
}

/// The live state of the outing, sent from the phone to the Watch several
/// times a minute while walking. Everything here is small and scalar on
/// purpose: the mirrored channel allows 100 KB per 10 seconds, and the track
/// itself is never part of it.
public struct WorkoutStatePayload: Codable, Equatable, Sendable {
    public var sessionID: String
    public var phase: WorkoutPhase
    /// Distance actually covered, as the phone's own recording measures it.
    public var distanceMeters: Double
    /// Time spent moving — paused stretches already taken off.
    public var elapsedSeconds: Double
    /// Absent until enough has been covered for a pace to mean anything.
    public var paceSecondsPerKm: Double?
    /// How far round the planned loop, 0…1.
    public var progressFraction: Double
    public var remainingMeters: Double
    public var offRoute: Bool
    public var next: ManeuverPayload?
    /// Only sent when it is close enough behind the next one to be worth
    /// reading — a "then" fifteen minutes away is noise on a small screen.
    public var then: ManeuverPayload?
    public var updatedAt: Date

    public init(
        sessionID: String,
        phase: WorkoutPhase,
        distanceMeters: Double,
        elapsedSeconds: Double,
        paceSecondsPerKm: Double? = nil,
        progressFraction: Double,
        remainingMeters: Double,
        offRoute: Bool,
        next: ManeuverPayload? = nil,
        then: ManeuverPayload? = nil,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.phase = phase
        self.distanceMeters = distanceMeters
        self.elapsedSeconds = elapsedSeconds
        self.paceSecondsPerKm = paceSecondsPerKm
        self.progressFraction = progressFraction
        self.remainingMeters = remainingMeters
        self.offRoute = offRoute
        self.next = next
        self.then = then
        self.updatedAt = updatedAt
    }
}

/// The compact result the Watch shows when the outing finishes. The full Loop
/// Summary stays on the phone; this is the glance you get on your wrist while
/// you catch your breath.
public struct WorkoutResultPayload: Codable, Equatable, Sendable {
    public var sessionID: String
    public var status: LoopCompletionStatus
    public var activity: Activity
    public var displayUnit: Unit
    public var distanceMeters: Double
    public var durationSeconds: Double
    public var paceSecondsPerKm: Double?
    /// Beats per minute, averaged over the workout. Absent when the Watch
    /// collected no heart rate — never estimated.
    public var averageHeartRate: Double?

    public init(
        sessionID: String,
        status: LoopCompletionStatus,
        activity: Activity,
        displayUnit: Unit,
        distanceMeters: Double,
        durationSeconds: Double,
        paceSecondsPerKm: Double? = nil,
        averageHeartRate: Double? = nil
    ) {
        self.sessionID = sessionID
        self.status = status
        self.activity = activity
        self.displayUnit = displayUnit
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.paceSecondsPerKm = paceSecondsPerKm
        self.averageHeartRate = averageHeartRate
    }
}

/// What one device asks the other to do.
public enum WatchCommandKind: String, Codable, Equatable, Sendable {
    /// The Watch asks the phone to begin the prepared loop, or the phone
    /// asks the Watch to begin its workout session.
    case start
    case pause
    case resume
    case end
    /// Sent by the Watch when it has no plan, or a plan it doesn't trust —
    /// after a relaunch, or when connectivity comes back.
    case requestPlan
}

/// A command, with enough identity to be delivered twice safely. Both a
/// dropped connection retrying and the two channels racing can land the same
/// command twice, and "end" arriving twice must not finish two activities.
public struct WatchCommandPayload: Codable, Equatable, Sendable {
    public var id: String
    public var kind: WatchCommandKind
    /// The session the command is about. `nil` for `requestPlan`, and for a
    /// `start` sent from the Watch before the phone has opened a record.
    public var sessionID: String?
    public var issuedAt: Date

    public init(kind: WatchCommandKind, sessionID: String? = nil, id: String = UUID().uuidString, issuedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.issuedAt = issuedAt
    }
}

/// Whether the Watch's HealthKit workout was accepted, and what it produced.
/// The phone needs this to know that the Watch — not it — owns the one Health
/// workout for this outing.
public struct WatchWorkoutStatusPayload: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        /// The Watch has a running `HKWorkoutSession` for this outing.
        case running
        /// Ended and saved. `workoutID` is the saved `HKWorkout`'s UUID.
        case saved
        /// The Watch couldn't start or couldn't save — permission refused,
        /// HealthKit unavailable, or the session failed. The phone owns the
        /// workout after this, and saves it as it always did.
        case failed
    }

    public var sessionID: String
    public var state: State
    public var workoutID: String?
    public var message: String?

    public init(sessionID: String, state: State, workoutID: String? = nil, message: String? = nil) {
        self.sessionID = sessionID
        self.state = state
        self.workoutID = workoutID
        self.message = message
    }
}

/// One message on the wire.
public enum WatchMessage: Codable, Equatable, Sendable {
    case plan(LoopPlanPayload)
    case state(WorkoutStatePayload)
    case result(WorkoutResultPayload)
    case command(WatchCommandPayload)
    case workoutStatus(WatchWorkoutStatusPayload)
}

public enum WatchLinkError: LocalizedError, Equatable {
    /// A payload from a build that speaks a different version of this
    /// protocol. Deliberately fatal to the message, not to the app.
    case unsupportedVersion(Int)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This message was sent by a different version of Looper (v\(version))."
        case .malformed:
            return "The message couldn’t be read."
        }
    }
}

/// The versioned envelope every channel carries.
public struct WatchEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var message: WatchMessage

    public init(message: WatchMessage, version: Int = WatchLink.version) {
        self.version = version
        self.message = message
    }
}

/// Encoding and decoding, in one place so the Watch and the phone cannot
/// drift apart on dates, keys or version handling.
public enum WatchLinkCodec {
    /// Seconds since the reference date — the default. Fixed here explicitly
    /// so a future change to either app's shared encoder can't silently
    /// change the wire format.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public static func encode(_ message: WatchMessage) throws -> Data {
        try encoder.encode(WatchEnvelope(message: message))
    }

    public static func decode(_ data: Data) throws -> WatchMessage {
        guard let envelope = try? decoder.decode(WatchEnvelope.self, from: data) else {
            // A version we don't know is the likeliest reason a decode fails,
            // and it deserves the clearer error — so the version is read on
            // its own before giving up.
            if let probe = try? decoder.decode(VersionProbe.self, from: data), probe.version != WatchLink.version {
                throw WatchLinkError.unsupportedVersion(probe.version)
            }
            throw WatchLinkError.malformed
        }
        guard envelope.version == WatchLink.version else {
            throw WatchLinkError.unsupportedVersion(envelope.version)
        }
        return envelope.message
    }

    /// WatchConnectivity's application context and message payloads are
    /// property-list dictionaries, so the same envelope travels as one blob
    /// under a single key rather than as a spread of loose values.
    public static let payloadKey = "looper.envelope"

    public static func dictionary(for message: WatchMessage) throws -> [String: Any] {
        [payloadKey: try encode(message)]
    }

    public static func message(from dictionary: [String: Any]) throws -> WatchMessage {
        guard let data = dictionary[payloadKey] as? Data else { throw WatchLinkError.malformed }
        return try decode(data)
    }
}

/// Just enough of an envelope to read its version when the rest won't decode.
private struct VersionProbe: Decodable {
    var version: Int
}
