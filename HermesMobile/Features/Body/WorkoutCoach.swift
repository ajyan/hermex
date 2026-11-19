import Foundation

// The rules and words behind Baki's coaching on the live workout, Body home and the Form page:
// what the body check takes out and says, how an adjustment applies and undoes, which questions
// follow a set, and how his pips read. Everything here is a pure function of the workout
// document, so the view model stays thin and the tests need no screen.

/// What follows the sets on the open lift's card: how many reps the set he just ticked had left,
/// the next set, the focus question after the last set, and a line of praise.
struct WorkoutAfterSet: Equatable {
    /// The lift's name, in a superset card, where two lifts share the foot.
    var name: String?
    /// "Set 2: how many more could you have done?", and the answer so far (3 means 3 or more).
    var question: String?
    var answer: Int?
    /// "Next, set 3: 5 reps, leave 2."
    var next: String?
    /// The coach's question once every work set is done, and the answer so far.
    var focusAsk: String?
    var focusAnswer: BodyFocusAnswer?
    var praise: String?

    var isEmpty: Bool { question == nil && focusAsk == nil && praise == nil }
}

/// One of Baki's adjustments on the workout screen: still a question, or taken and showing its
/// `done` line (with Undo while the app can still put things back).
struct WorkoutAdjustmentRow: Equatable, Identifiable {
    enum State: Equatable { case asking, done(canUndo: Bool) }

    let adjustment: BodyAdjustment
    let state: State

    var id: String { adjustment.id }
}

/// What the body check's line offers once it is answered.
enum WorkoutBodyCheckAction: Equatable {
    case change, putBack

    var label: String { self == .change ? "Change" : "Put them back" }
}

enum WorkoutCoach {
    /// Pain at or above this takes the lifts that load the area out of today's session.
    static let removeAt = 4
    /// Pain at or above this is a rest day.
    static let restAt = 7

    // MARK: The body check

    static func loads(_ lift: BodyExercise, _ area: BodyArea) -> Bool {
        lift.loads?.contains(area.rawValue) ?? false
    }

    /// The server speaks the body check when a prescribed lift carries `loads`.
    static func offersBodyCheck(_ exercises: [BodyExercise]) -> Bool {
        exercises.contains { $0.loads != nil }
    }

    /// The lifts a sore `area` takes out: every lift that loads it and has no ticked set.
    static func removable(_ area: BodyArea, in exercises: [BodyExercise]) -> [BodyExercise] {
        exercises.filter { loads($0, area) && !$0.sets.contains(where: \.done) }
    }

    /// Puts `removed` back into `exercises`, each after the nearest lift that came before it in
    /// `order` (the lift ids before they were taken out) and is in the session now.
    static func restore(_ removed: [BodyExercise], into exercises: [BodyExercise], order: [String]) -> [BodyExercise] {
        var out = exercises
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = removed.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
        for lift in sorted where !out.contains(where: { $0.id == lift.id }) {
            let before = Set(order.prefix(rank[lift.id] ?? order.count))
            let at = out.lastIndex { before.contains($0.id) }.map { $0 + 1 } ?? 0
            out.insert(lift, at: at)
        }
        return out
    }

    /// The line the banner becomes once he has named a sore area: "Lower back at 2. Baki will keep
    /// an eye on it."; at 4 or more the lifts that are out and why; at 7 or more, the rest-day line.
    /// `removed` are the lifts' names; `removedCount` covers a resumed workout, which knows only
    /// how many are out; `loaded` is whether any lift in the session loads the area.
    static func bodyCheckLine(area: BodyArea, score: Int, removed: [String], removedCount: Int = 0,
                              loaded: Bool) -> String {
        var line: String
        if !removed.isEmpty {
            let one = removed.count == 1
            line = "\(area.title) at \(score): \(list(removed)) \(one ? "is" : "are") out today. "
                + "\(one ? "It loads" : "They load") your \(area.phrase)."
        } else if removedCount > 0 {
            line = "\(area.title) at \(score): the lifts that load your \(area.phrase) are out today."
        } else if score >= removeAt, !loaded {
            line = "\(area.title) at \(score). Nothing today loads your \(area.phrase)."
        } else {
            line = "\(area.title) at \(score). Baki will keep an eye on it."
        }
        if score >= restAt {
            line += " At \(score), today is better as a rest day. If it isn't easing in a few days, see a physio."
        }
        return line
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: Adjustments

    /// Whether the app can act on an adjustment in this session: its lift is here (the body check
    /// may have taken it out), and so is what the change needs.
    static func applies(_ adjustment: BodyAdjustment, to exercises: [BodyExercise]) -> Bool {
        guard let lift = exercises.first(where: { $0.id == adjustment.lift }) else { return false }
        switch adjustment.kind {
        case BodyAdjustment.moveUp:
            guard let after = adjustment.after, after != adjustment.lift else { return false }
            return exercises.contains { $0.id == after }
        case BodyAdjustment.capFirst:
            return adjustment.reps != nil && lift.sets.contains { $0.kind == .work }
        default:
            return false
        }
    }

    /// The banners for a session's adjustments, in the server's order: a question for each one not
    /// answered, the `done` line for each one used, nothing for one kept or one that can't apply.
    static func adjustmentRows(_ session: BodySession, canUndo: (BodyAdjustment) -> Bool) -> [WorkoutAdjustmentRow] {
        (session.adjustments ?? []).compactMap { adjustment in
            guard applies(adjustment, to: session.exercises) else { return nil }
            switch session.adjustmentAnswers?[adjustment.id] {
            case nil:
                // Once set 1 is ticked it is too late to cap it.
                if adjustment.kind == BodyAdjustment.capFirst, firstWorkSetDone(adjustment.lift, in: session.exercises) {
                    return nil
                }
                return WorkoutAdjustmentRow(adjustment: adjustment, state: .asking)
            case BodyAdjustment.used: return WorkoutAdjustmentRow(adjustment: adjustment, state: .done(canUndo: canUndo(adjustment)))
            default: return nil
            }
        }
    }

    /// `move_up`: the lift right after `after`. Nil when either is missing.
    static func movedUp(_ adjustment: BodyAdjustment, in exercises: [BodyExercise]) -> [BodyExercise]? {
        guard let after = adjustment.after, after != adjustment.lift,
              let from = exercises.firstIndex(where: { $0.id == adjustment.lift }) else { return nil }
        var out = exercises
        let lift = out.remove(at: from)
        guard let anchor = out.firstIndex(where: { $0.id == after }) else { return nil }
        out.insert(lift, at: anchor + 1)
        return out
    }

    /// Undoes `move_up`: the lift back after `predecessor` (the lift it followed before the move),
    /// or first when it had none.
    static func movedBack(_ lift: String, after predecessor: String?, in exercises: [BodyExercise]) -> [BodyExercise] {
        guard let from = exercises.firstIndex(where: { $0.id == lift }) else { return exercises }
        var out = exercises
        let moved = out.remove(at: from)
        let at = predecessor.flatMap { id in out.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        out.insert(moved, at: min(at, out.count))
        return out
    }

    /// Runs every `move_up` he took again over `exercises`, after another reorder put the lifts
    /// back in an older order.
    static func reapplyingUsedMoves(_ exercises: [BodyExercise], in session: BodySession) -> [BodyExercise] {
        (session.adjustments ?? []).reduce(exercises) { order, adjustment in
            guard adjustment.kind == BodyAdjustment.moveUp,
                  session.adjustmentAnswers?[adjustment.id] == BodyAdjustment.used else { return order }
            return movedUp(adjustment, in: order) ?? order
        }
    }

    /// The first work set's place in a lift's sets.
    static func firstWorkSet(_ lift: BodyExercise) -> Int? {
        lift.sets.firstIndex { $0.kind == .work }
    }

    static func firstWorkSetDone(_ lift: String, in exercises: [BodyExercise]) -> Bool {
        guard let lift = exercises.first(where: { $0.id == lift }), let first = firstWorkSet(lift) else { return false }
        return lift.sets[first].done
    }

    // MARK: The cue

    /// The cue block's kicker: "Baki · focus" under a pace focus, "Baki · your cue" otherwise.
    static func cueKicker(_ coach: BodyCoach) -> String {
        coach.isPace ? "Baki · focus" : "Baki · your cue"
    }

    /// The line under the cue: the plan when there is one, else "Leave 2 in the tank."
    static func cueLine(_ coach: BodyCoach) -> String? {
        if let plan = coach.plan, !plan.isEmpty { return plan }
        return coach.leave.map { "Leave \($0) in the tank." }
    }

    /// A superset card's one line for a lift: "Face pull: Pull the rope to your eyes".
    static func pairedCue(_ lift: BodyExercise) -> String {
        guard let coach = lift.coach, !coach.retired, !coach.cue.isEmpty else { return lift.name }
        return "\(lift.name): \(coach.cue)"
    }

    /// Three pips for a focus: one per earlier check (filled for yes, a glow ring for mostly, an
    /// empty ring for no), then empty rings for the days still to come.
    static func focusPips(_ checks: [String]) -> [LiftPip] {
        let answered = checks.suffix(3).map { BodyFocusAnswer(rawValue: $0)?.pip ?? .notDone }
        return answered + Array(repeating: .notDone, count: 3 - answered.count)
    }

    /// The focus pips for VoiceOver: "Earlier checks: yes, mostly." or "No checks yet."
    static func focusPipsSpoken(_ checks: [String]) -> String {
        let words = checks.suffix(3).compactMap { BodyFocusAnswer(rawValue: $0) }.map { $0.label.lowercased() }
        return words.isEmpty ? "No checks yet." : "Earlier checks: \(words.joined(separator: ", "))."
    }

    // MARK: After a set

    /// A lift asks how many reps were left after each work set when it counts reps and isn't part
    /// of the warm-up; holds and carries never ask.
    static func asksRepsLeft(_ lift: BodyExercise) -> Bool {
        BodyMeasure(lift) == .reps && lift.section != .warmup
    }

    /// A lift asks its focus question after the last set while its coach has one and isn't retired.
    static func asksFocus(_ lift: BodyExercise) -> Bool {
        guard let coach = lift.coach else { return false }
        return !coach.retired && !coach.ask.isEmpty
    }

    static func isComplete(_ lift: BodyExercise) -> Bool {
        let work = lift.workSets
        return !work.isEmpty && work.allSatisfy(\.done)
    }

    /// What the card's foot asks and says. `asked` is the place in `sets` of the work set he just
    /// ticked, or nil when none is waiting; `named` is true in a superset card.
    static func afterSet(_ lift: BodyExercise, asked: Int?, named: Bool = false) -> WorkoutAfterSet {
        var after = WorkoutAfterSet()
        if let asked, lift.sets.indices.contains(asked), lift.sets[asked].kind == .work, lift.sets[asked].done,
           asksRepsLeft(lift) {
            after.question = "Set \(WorkoutCopy.tag(lift, set: asked)): how many more could you have done?"
            after.answer = lift.sets[asked].left
            after.next = nextLine(lift)
        }
        if isComplete(lift) {
            if asksFocus(lift) {
                after.focusAsk = lift.coach?.ask
                after.focusAnswer = lift.focusCheck.flatMap(BodyFocusAnswer.init(rawValue:))
            }
            // Praise rides with a question; a finished lift with nothing to ask folds as before.
            if after.question != nil || after.focusAsk != nil { after.praise = praise(lift) }
        }
        if named, !after.isEmpty { after.name = lift.name }
        return after
    }

    /// "Next, set 3: 5 reps, leave 2." while a work set remains; ", leave 2" only when the coach
    /// says how many. Under a pace focus, set 1 gets the plan line instead.
    static func nextLine(_ lift: BodyExercise) -> String? {
        guard let next = lift.sets.firstIndex(where: { $0.kind == .work && !$0.done }) else { return nil }
        let number = WorkoutCopy.tag(lift, set: next)
        if number == "1", let coach = lift.coach, coach.isPace, !coach.retired, let plan = coach.plan, !plan.isEmpty {
            return plan
        }
        var parts: [String] = []
        if let reps = lift.sets[next].reps { parts.append("\(reps) \(reps == 1 ? "rep" : "reps")") }
        if let leave = lift.coach?.leave { parts.append("leave \(leave)") }
        return parts.isEmpty ? "Next, set \(number)." : "Next, set \(number): \(parts.joined(separator: ", "))."
    }

    /// One line once every work set is done and at least one reached its goal (the lift results'
    /// rule): "Every set hit its target.", "Sets 1 and 2 hit their targets."
    static func praise(_ lift: BodyExercise) -> String? {
        guard isComplete(lift) else { return nil }
        let measure = BodyMeasure(lift)
        let work = lift.workSets
        let hits = work.indices.filter { index in
            guard let goal = LiftResults.goal(lift, set: index) else { return false }
            return LiftResults.pip(done: work[index].done, count: measure.count(work[index]), goal: goal) == .hit
        }
        guard !hits.isEmpty else { return nil }
        if hits.count == work.count { return work.count == 1 ? "That set hit its target." : "Every set hit its target." }
        let numbers = hits.map { "\($0 + 1)" }
        return hits.count == 1 ? "Set \(numbers[0]) hit its target." : "Sets \(list(numbers)) hit their targets."
    }

    // MARK: Watching

    /// A watched pattern's pips: filled when it happened, a glow ring when it didn't, a separator
    /// ring when that day can't tell.
    static func watchingPips(_ item: BodyWatching) -> [LiftPip] {
        item.pips.map { pip in
            switch pip {
            case "yes": .hit
            case "no": .short
            default: .notDone
            }
        }
    }

    /// The note beside "Watching": "Last 4 times", for as many sessions as the pips cover.
    static func watchingCaption(_ items: [BodyWatching]) -> String {
        let most = items.map(\.pips.count).max() ?? 0
        return most > 1 ? "Last \(most) times" : "Last time"
    }

    /// A watched pattern as one sentence, since the pips are drawn: "DB row skipped on pull days:
    /// 3 of the last 4 times. Next Pull asks to move it second." Days that can't tell are named.
    static func watchingSpoken(_ item: BodyWatching) -> String {
        let yes = item.pips.filter { $0 == "yes" }.count
        let unknown = item.pips.filter { $0 != "yes" && $0 != "no" }.count
        let total = item.pips.count
        var parts: [String] = []
        if total > 0 {
            let count = "\(item.name): \(yes) of the last \(total) \(total == 1 ? "time" : "times")"
            parts.append(unknown > 0 ? "\(count), \(unknown) unknown." : "\(count).")
        } else {
            parts.append("\(item.name).")
        }
        if !item.next.isEmpty { parts.append(item.next) }
        return parts.joined(separator: " ")
    }

    // MARK: The Form page

    /// The header over a lift's safety line, from the areas it loads: "Guard your back",
    /// "Guard your shoulders", or "Stay safe" when it loads both or the server didn't say.
    static func safetyHeader(loads: [String]) -> String {
        let back = loads.contains(BodyArea.lowerBack.rawValue)
        let shoulders = loads.contains(BodyArea.shoulders.rawValue) || loads.contains(BodyArea.shoulderBlades.rawValue)
        if back, !shoulders { return "Guard your back" }
        if shoulders, !back { return "Guard your shoulders" }
        return "Stay safe"
    }
}
