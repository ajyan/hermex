import Foundation

// How a workout's lifts went, set by set, against the time before: the numbers behind
// `LiftResultsCard` on the finish screen and a past workout's page. Everything here reads the
// saved workout document alone (each lift's `sets` and its `last`), so both screens agree.

/// One work set as a pip: done at its goal, done but short of it, or not done.
enum LiftPip: Equatable, Sendable {
    case hit, short, notDone
}

/// A lift against the time before. A heavier or lighter top weight wins; at the same weight the
/// total reps (seconds for a hold, yards for a carry) decide.
enum LiftChange: Equatable, Sendable {
    /// The top done weight moved by this many pounds.
    case heavier(Double), lighter(Double)
    case more(BodyMeasure), less(BodyMeasure)
    case same

    /// True for up, false for down, nil for no change.
    var isUp: Bool? {
        switch self {
        case .heavier, .more: true
        case .lighter, .less: false
        case .same: nil
        }
    }

    /// The words beside the arrow: "10 lb", "reps", "time", "yards"; "Same" stands alone.
    var words: String {
        switch self {
        case .heavier(let pounds), .lighter(let pounds): "\(BodyFormat.number(pounds)) lb"
        case .more(let measure), .less(let measure): Self.noun(measure)
        case .same: "Same"
        }
    }

    private static func noun(_ measure: BodyMeasure) -> String {
        switch measure {
        case .reps: "reps"
        case .hold: "time"
        case .distance: "yards"
        }
    }

    /// What VoiceOver says: "Fewer reps than last time"; `before` is "last time" or "the time before".
    func spoken(before: String) -> String {
        switch self {
        case .heavier(let pounds): "\(BodyFormat.number(pounds)) pounds heavier than \(before)"
        case .lighter(let pounds): "\(BodyFormat.number(pounds)) pounds lighter than \(before)"
        case .more(.reps): "More reps than \(before)"
        case .less(.reps): "Fewer reps than \(before)"
        case .more(.hold): "Held longer than \(before)"
        case .less(.hold): "Held shorter than \(before)"
        case .more(.distance): "Carried farther than \(before)"
        case .less(.distance): "Carried less far than \(before)"
        case .same: "Same as \(before)"
        }
    }
}

/// Whose workout the card describes: the one just finished, or one from an earlier day.
enum LiftResultsFrame: Equatable, Sendable {
    case today, past

    /// The section header's trailing note.
    var caption: String { self == .today ? "Today over last time" : "This day over the time before" }
    /// The label on this workout's row of pips; the row under it is always "Last".
    var rowLabel: String { self == .today ? "Today" : "Then" }
    static let lastLabel = "Last"
    /// How VoiceOver names the earlier workout.
    var before: String { self == .today ? "last time" : "the time before" }
}

/// One lift's row: its pips for this workout and the one before, its weight, and how it compares.
struct LiftResult: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// "90 lb", "42.5s", "BW": the top weight he did, or the planned one when no set was done.
    let weightLabel: String
    /// The same, as VoiceOver says it: "90 pounds", "body weight".
    let spokenWeight: String
    let now: [LiftPip]
    /// Empty when the lift has no earlier session.
    let last: [LiftPip]
    /// Nil when either side has no done set.
    let change: LiftChange?
}

enum LiftResults {
    /// A row for every lift with work sets, warm-up included, in the workout's order.
    static func results(_ session: BodySession) -> [LiftResult] {
        session.exercises.filter { !$0.workSets.isEmpty }.map(result)
    }

    static func result(_ lift: BodyExercise) -> LiftResult {
        let measure = BodyMeasure(lift)
        let work = lift.workSets
        let weight = topWeight(work.filter(\.done).map(\.weight)) ?? work.first?.weight
        return LiftResult(
            id: lift.id, name: lift.name,
            weightLabel: BodyFormat.weightLabel(unit: lift.unit, weight: weight),
            spokenWeight: spokenWeight(unit: lift.unit, weight: weight),
            now: work.enumerated().map { index, set in
                pip(done: set.done, count: measure.count(set), goal: goal(lift, set: index))
            },
            last: lift.last.enumerated().map { index, set in
                pip(done: set.done ?? true, count: measure.count(set), goal: goal(lift, set: index))
            },
            change: change(lift))
    }

    /// What work set `index` has to reach, by the server's rule for its dots: that set's goal reps
    /// when the lift has them, else the top of the rep range, the hold or the distance.
    static func goal(_ lift: BodyExercise, set index: Int) -> Int? {
        if let goals = lift.goalReps, goals.indices.contains(index) { return goals[index] }
        switch BodyMeasure(lift) {
        case .reps: return lift.target.reps?.last
        case .hold: return lift.target.holdS
        case .distance: return lift.target.distanceYd
        }
    }

    /// A done set with nothing to reach counts as a hit.
    static func pip(done: Bool, count: Int?, goal: Int?) -> LiftPip {
        guard done else { return .notDone }
        guard let goal else { return .hit }
        return (count ?? 0) >= goal ? .hit : .short
    }

    static func change(_ lift: BodyExercise) -> LiftChange? {
        let measure = BodyMeasure(lift)
        let now = lift.workSets.filter(\.done)
        let last = lift.last.filter { $0.done ?? true }
        guard !now.isEmpty, !last.isEmpty else { return nil }
        if WorkoutCopy.isWeighted(lift), let weightNow = topWeight(now.map(\.weight)),
           let weightLast = topWeight(last.map(\.weight)), abs(weightNow - weightLast) > 0.001 {
            return weightNow > weightLast ? .heavier(weightNow - weightLast) : .lighter(weightLast - weightNow)
        }
        let countNow = now.reduce(0) { $0 + (measure.count($1) ?? 0) }
        let countLast = last.reduce(0) { $0 + (measure.count($1) ?? 0) }
        if countNow == countLast { return .same }
        return countNow > countLast ? .more(measure) : .less(measure)
    }

    /// The whole row for VoiceOver, since the pips are drawn: "Pull-ups, body weight. Today: 1 of 4
    /// sets hit the goal, 3 short. Last time: 0 of 4. Fewer reps than last time."
    static func spoken(_ result: LiftResult, frame: LiftResultsFrame) -> String {
        var parts = ["\(result.name), \(result.spokenWeight)", "\(frame.rowLabel): \(tally(result.now, full: true))"]
        if !result.last.isEmpty {
            let before = frame.before.prefix(1).uppercased() + frame.before.dropFirst()
            parts.append("\(before): \(tally(result.last, full: false))")
        }
        if let change = result.change { parts.append(change.spoken(before: frame.before)) }
        return parts.joined(separator: ". ") + "."
    }

    /// "1 of 4 sets hit the goal, 2 short, 1 not done"; the short form is "1 of 4" and what was skipped.
    private static func tally(_ pips: [LiftPip], full: Bool) -> String {
        let hit = pips.filter { $0 == .hit }.count
        let short = pips.filter { $0 == .short }.count
        let notDone = pips.filter { $0 == .notDone }.count
        var parts = [full ? "\(hit) of \(pips.count) sets hit the goal" : "\(hit) of \(pips.count)"]
        if full, short > 0 { parts.append("\(short) short") }
        if notDone > 0 { parts.append("\(notDone) not done") }
        return parts.joined(separator: ", ")
    }

    private static func topWeight(_ weights: [Double?]) -> Double? {
        weights.compactMap { $0 }.max()
    }

    private static func spokenWeight(unit: String, weight: Double?) -> String {
        switch unit {
        case "bw": return "body weight"
        case "band": return "band"
        case "cable": return "light cable"
        default: break
        }
        guard let weight else { return "no weight yet" }
        return "\(BodyFormat.number(weight)) pounds" + (unit == "lb_each" ? " each" : "")
    }
}
