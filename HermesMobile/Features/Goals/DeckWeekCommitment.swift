import Foundation

/// One commitment in a weekly coach change (`DeckGoalChange.commitments`), and the shape
/// `POST /api/goals/week` takes back. `was`, `reason` and `drop` are the proposal's notes
/// (last week's target, why it changed, or why to drop it) and never go to the server.
struct DeckWeekCommitment: Codable, Equatable, Hashable, Sendable {
    let id: String
    let action: String
    var target: Int
    let skips: Int
    /// "day" (checked per day) or "item" (counted by +1); anything else reads as "day".
    let unit: String
    let source: String?
    let cue: String?
    let minimum: String?
    let days: [String]?
    let was: Int?
    let reason: String?
    /// The proposal drops this commitment; its row starts removed.
    let drop: Bool

    private enum CodingKeys: String, CodingKey {
        case id, action, target, skips, unit, source, cue, minimum, days, was, reason, drop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        action = (try? c.decodeIfPresent(String.self, forKey: .action)) ?? ""
        target = (try? c.decodeIfPresent(Int.self, forKey: .target)) ?? 1
        skips = (try? c.decodeIfPresent(Int.self, forKey: .skips)) ?? 0
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) == "item" ? "item" : "day"
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        cue = try? c.decodeIfPresent(String.self, forKey: .cue)
        minimum = try? c.decodeIfPresent(String.self, forKey: .minimum)
        days = try? c.decodeIfPresent([String].self, forKey: .days)
        was = try? c.decodeIfPresent(Int.self, forKey: .was)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        drop = (try? c.decodeIfPresent(Bool.self, forKey: .drop)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(action, forKey: .action)
        try c.encode(target, forKey: .target)
        try c.encode(skips, forKey: .skips)
        try c.encode(unit, forKey: .unit)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(cue, forKey: .cue)
        try c.encodeIfPresent(minimum, forKey: .minimum)
        try c.encodeIfPresent(days, forKey: .days)
    }

    var isItem: Bool { unit == "item" }
}
