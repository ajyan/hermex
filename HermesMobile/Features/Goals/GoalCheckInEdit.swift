import Foundation

/// The optimistic side of a check-in: what a goal's summary looks like once the server takes a
/// tap, and how to put one item back when it doesn't. Shared by the goal screen and the Daily
/// Deck's goal card. `today` and `yesterday` are always the server's dates.
enum GoalCheckInEdit {
    /// Moves one day's commitment status between this week's counts, as the server will.
    static func apply(_ status: GoalStatus, to id: String, on date: String, today: String, yesterday: String,
                      in goal: inout GoalSummary) {
        guard let i = goal.week.commitments.firstIndex(where: { $0.id == id }) else { return }
        var row = goal.week.commitments[i]
        let old = row.effectiveStatus(date, today: today, yesterday: yesterday)
        let week = goal.week
        if date >= week.start, date <= week.end {
            // Skip days this row is known to have: the counted ones, or today and yesterday.
            let shown = [(today, row.today), (yesterday, row.yesterday)]
                .filter { $0.1 == .skip && $0.0 >= week.start && $0.0 <= week.end }.count
            let skipDays = max(row.skipped, shown)
            adjust(&row, old, by: -1, skipDays: skipDays)
            // Clearing a day the source counted puts its done back.
            let counted: GoalStatus? = status == .clear ? (row.sourceDays.contains(date) ? .done : nil) : status
            adjust(&row, counted, by: 1, skipDays: skipDays)
            row.remaining = max(0, row.target - row.done - row.min)
            row.hit = row.done + row.min >= row.target
        }
        let shown: GoalStatus? = status == .clear ? nil : status
        if date == today { row.today = shown } else { row.yesterday = shown }
        goal.week.commitments[i] = row
    }

    /// Adds (`n` > 0, with its `note`) or removes the last (`n` < 0) item of an item commitment,
    /// as the server will. Removing from an empty row does nothing.
    static func addItem(_ n: Int, note: String?, to id: String, on date: String, in goal: inout GoalSummary) {
        guard let i = goal.week.commitments.firstIndex(where: { $0.id == id }) else { return }
        var row = goal.week.commitments[i]
        if n > 0 {
            row.items.append(GoalItem(date: date, note: note))
        } else if n < 0 {
            guard !row.items.isEmpty else { return }
            row.items.removeLast()
        } else {
            return
        }
        row.done = row.items.count
        row.remaining = max(0, row.target - row.done)
        row.hit = row.done >= row.target
        goal.week.commitments[i] = row
    }

    /// Sets one daily check's answer for `date`; `GoalCheckValue.clear` empties it.
    static func setCheck(_ value: String, id: String, on date: String, today: String, yesterday: String,
                         in goal: inout GoalSummary) {
        guard let i = goal.dailyChecks.firstIndex(where: { $0.id == id }) else { return }
        let shown = value == GoalCheckValue.clear ? nil : value
        if date == today { goal.dailyChecks[i].today = shown }
        if date == yesterday { goal.dailyChecks[i].yesterday = shown }
    }

    /// Puts one commitment's or daily check's values from `snapshot` back into `goal`, leaving
    /// every other item (whose check-ins may have landed meanwhile) alone.
    static func restore(_ id: String, from snapshot: GoalSummary, in goal: inout GoalSummary) {
        if let old = snapshot.week.commitments.first(where: { $0.id == id }),
           let i = goal.week.commitments.firstIndex(where: { $0.id == id }) {
            goal.week.commitments[i] = old
        }
        if let old = snapshot.dailyChecks.first(where: { $0.id == id }),
           let i = goal.dailyChecks.firstIndex(where: { $0.id == id }) {
            goal.dailyChecks[i] = old
        }
    }

    /// The server counts a week's skips in day order and any past the budget as misses, so
    /// adding one with the budget spent, or removing one while `skipDays` exceeds it, moves `missed`.
    private static func adjust(_ row: inout GoalCommitmentProgress, _ status: GoalStatus?, by n: Int, skipDays: Int) {
        switch status {
        case .done: row.done += n
        case .min: row.min += n
        case .skip:
            let overBudget = n > 0 ? row.skipped >= row.skips : skipDays > row.skips
            if overBudget { row.missed += n } else { row.skipped += n }
        case .miss: row.missed += n
        default: break
        }
    }
}
