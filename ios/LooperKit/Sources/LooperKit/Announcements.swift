import Foundation

/// Voice guidance. A turn is announced at most once per band, so walking through
/// 400 m → 100 m → the corner itself gives three prompts and no repetition.
public enum Band: String {
    case soon
    case near
    case now
}

public func turnBand(_ metresAway: Double) -> Band? {
    if metresAway < 30 { return .now }
    if metresAway < 120 { return .near }
    if metresAway < 450 { return .soon }
    return nil
}

private func roundTo(_ value: Double, _ step: Double) -> Double {
    (value / step).rounded() * step
}

/// Say the distance that is actually left. The bands decide *when* to speak;
/// they used to decide what was spoken too, so a turn first picked up part way
/// into a band — right after the turn before it — was called out at the band's
/// nominal distance: "in one hundred metres" with the corner 45 m away.
private func spokenDistance(_ metres: Double, _ unit: Unit) -> String {
    if unit == .mi {
        let yards = metres * 1.09361
        let step = yards < 100 ? 10.0 : 50.0
        return "\(Int(roundTo(yards, step))) yards"
    }
    let step = metres < 100 ? 10.0 : 50.0
    return "\(Int(roundTo(metres, step))) metres"
}

/// Instructions arrive sentence-cased ("Turn left onto…"); lower the first word
/// when it follows a lead-in so the sentence reads as one phrase.
private func joinCase(_ instruction: String) -> String {
    guard let first = instruction.first, first.isUppercase else { return instruction }
    let rest = instruction.dropFirst()
    if let second = rest.first, second.isUppercase { return instruction }
    return first.lowercased() + rest
}

public struct Announcement: Equatable {
    public var key: String
    public var text: String

    public init(key: String, text: String) {
        self.key = key
        self.text = text
    }
}

public struct TurnAnnouncementInput {
    public var index: Int
    public var instruction: String
    public var distanceAway: Double

    public init(index: Int, instruction: String, distanceAway: Double) {
        self.index = index
        self.instruction = instruction
        self.distanceAway = distanceAway
    }
}

extension TurnHit {
    public var announcementInput: TurnAnnouncementInput {
        TurnAnnouncementInput(index: index, instruction: instruction, distanceAway: distanceAway)
    }
}

public func turnAnnouncement(_ turn: TurnAnnouncementInput?, unit: Unit) -> Announcement? {
    guard let turn else { return nil }
    guard let band = turnBand(turn.distanceAway) else { return nil }
    let key = "\(turn.index):\(band.rawValue)"
    let text = band == .now
        ? turn.instruction
        : "In \(spokenDistance(turn.distanceAway, unit)), \(joinCase(turn.instruction))"
    return Announcement(key: key, text: text)
}
