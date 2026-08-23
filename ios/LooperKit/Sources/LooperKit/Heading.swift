import Foundation

private func mod360(_ x: Double) -> Double {
    let m = x.truncatingRemainder(dividingBy: 360)
    return m < 0 ? m + 360 : m
}

/// Which way the walker is facing, so the map can turn with them. A reading
/// carries either a true compass heading (iOS's `webkitCompassHeading`
/// equivalent from `CLHeading.trueHeading`) or an earth-framed alpha that
/// counts the other way round — both need the screen's own rotation added
/// back on.
public struct HeadingReading {
    public var alpha: Double?
    public var trueHeading: Double?

    public init(alpha: Double? = nil, trueHeading: Double? = nil) {
        self.alpha = alpha
        self.trueHeading = trueHeading
    }
}

public func headingFrom(_ reading: HeadingReading, angle: Double = 0) -> Double? {
    if let compass = reading.trueHeading, compass.isFinite {
        return mod360(compass + angle)
    }
    guard let alpha = reading.alpha, alpha.isFinite else { return nil }
    return mod360(360 - alpha + angle)
}

/// A compass twitches, so each reading is eased toward rather than taken whole,
/// the short way round the circle.
public func smoothHeading(_ previous: Double?, _ next: Double, weight: Double = 0.3) -> Double {
    guard let previous else { return next }
    let diff = (next - previous + 540).truncatingRemainder(dividingBy: 360) - 180
    return mod360(previous + diff * weight + 360)
}

public func headingGap(_ a: Double, _ b: Double) -> Double {
    abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
}
