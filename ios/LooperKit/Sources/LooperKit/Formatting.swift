import Foundation

public func kmToMiles(_ km: Double) -> Double { km * 0.621371 }
public func milesToKm(_ mi: Double) -> Double { mi / 0.621371 }
public func estimateKmFromMinutes(_ minutes: Double) -> Double { minutes / 12 }
public func secondsForDistance(_ meters: Double, paceMinutesPerKm: Double) -> Double {
    meters / 1000 * paceMinutesPerKm * 60
}

public func formatDistance(_ meters: Double, unit: Unit = .km) -> String {
    if unit == .km { return String(format: "%.1f km", meters / 1000) }
    return String(format: "%.1f mi", kmToMiles(meters / 1000))
}

public func formatTime(_ seconds: Double) -> String {
    "\(Int((seconds / 60).rounded())) min"
}

/// Elapsed time read off a stopwatch — `M:SS` under an hour, `H:MM:SS` over
/// it. `formatTime` stays the estimate-shaped "about 24 min" wording used
/// while planning and walking; this is the precise figure a finished outing
/// deserves.
public func formatDuration(_ seconds: Double) -> String {
    let total = Int(max(0, seconds).rounded())
    let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
}

/// Pace in the person's own unit, e.g. `8:24 /km`.
public func formatPace(_ secondsPerKm: Double, unit: Unit = .km) -> String {
    let perUnit = unit == .km ? secondsPerKm : secondsPerKm / 0.621371
    guard perUnit.isFinite, perUnit > 0 else { return "—" }
    let total = Int(perUnit.rounded())
    return String(format: "%d:%02d /%@", total / 60, total % 60, unit == .km ? "km" : "mi")
}

/// Average speed in the person's own unit, e.g. `5.2 km/h`.
public func formatSpeed(_ metersPerSecond: Double, unit: Unit = .km) -> String {
    let kmh = metersPerSecond * 3.6
    if unit == .km { return String(format: "%.1f km/h", kmh) }
    return String(format: "%.1f mph", kmToMiles(kmh))
}

/// Climb, in metres or feet to match the distance unit.
public func formatElevation(_ meters: Double, unit: Unit = .km) -> String {
    if unit == .km { return "\(Int(meters.rounded())) m" }
    return "\(Int((meters * 3.28084).rounded())) ft"
}

/// A signed difference against a target, e.g. `+0.3 km` / `-2 min`.
public func formatDistanceDelta(_ meters: Double, unit: Unit = .km) -> String {
    let sign = meters < 0 ? "-" : "+"
    return sign + formatDistance(abs(meters), unit: unit)
}

public func formatDurationDelta(_ seconds: Double) -> String {
    let sign = seconds < 0 ? "-" : "+"
    return sign + formatDuration(abs(seconds))
}
