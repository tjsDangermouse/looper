import Foundation

/// The three useful moments for walking guidance: introduce the next manoeuvre,
/// remind the walker shortly before it, then call it at the corner itself.
public enum AnnouncementStage: String {
    case preview
    case approach
    case now
}

/// Remembers how far through the announcement stages each manoeuvre has got.
/// GPS can move a matched position backwards for a fix or two; once a turn has
/// reached `now`, that noise must not make it announce `approach` again. Different
/// manoeuvres remain independent, so two close turns can both be announced.
public struct GuidanceAnnouncementHistory {
    private var highestStageByTurn: [Int: Int] = [:]

    public init() {}

    public mutating func shouldAnnounce(_ turn: TurnAnnouncementInput) -> Bool {
        let stage = announcementStage(turn.distanceAway)
        let rank: Int
        switch stage {
        case .preview: rank = 0
        case .approach: rank = 1
        case .now: rank = 2
        }
        guard rank > highestStageByTurn[turn.index, default: -1] else { return false }

        // If a newly active turn is already close, its preview is also its
        // approach warning. Mark both stages consumed rather than queueing a
        // second sentence a few seconds later.
        let recordedRank = stage == .preview && turn.distanceAway <= 50 ? 1 : rank
        highestStageByTurn[turn.index] = recordedRank
        return true
    }

    public mutating func reset() {
        highestStageByTurn.removeAll(keepingCapacity: true)
    }
}

public func announcementStage(_ metresAway: Double) -> AnnouncementStage {
    if metresAway <= 5 { return .now }
    if metresAway <= 25 { return .approach }
    return .preview
}

private func roundTo(_ value: Double, _ step: Double) -> Double {
    (value / step).rounded() * step
}

/// Say the distance that is actually left rather than a nominal trigger distance.
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
    let stage = announcementStage(turn.distanceAway)
    let key = "\(turn.index):\(stage.rawValue)"
    let text = stage == .now
        ? turn.instruction
        : "In \(spokenDistance(turn.distanceAway, unit)), \(joinCase(turn.instruction))"
    return Announcement(key: key, text: text)
}
