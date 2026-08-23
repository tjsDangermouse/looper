import Foundation

public func kmToMiles(_ km: Double) -> Double { km * 0.621371 }
public func milesToKm(_ mi: Double) -> Double { mi / 0.621371 }
public func estimateKmFromMinutes(_ minutes: Double) -> Double { minutes / 12 }

public func formatDistance(_ meters: Double, unit: Unit = .km) -> String {
    if unit == .km { return String(format: "%.1f km", meters / 1000) }
    return String(format: "%.1f mi", kmToMiles(meters / 1000))
}

public func formatTime(_ seconds: Double) -> String {
    "\(Int((seconds / 60).rounded())) min"
}
