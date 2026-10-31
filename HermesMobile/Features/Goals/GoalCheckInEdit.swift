import Foundation

/// The optimistic side of a check-in: what a goal's summary looks like once the server takes a
/// tap. Shared by the goal screen and the Daily Deck's goal card, which replay these edits through
/// `GoalPendingEdits`. `today` and `yesterday` are always the server's dates.
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
        // The week strip's cell for the day: its best check-in across the day rows, as the server ranks it.
        if let d = goal.week.days.firstIndex(where: { $0.date == date }) {
            let best = goal.week.commitments.filter { !$0.isItem }
                .compactMap { $0.effectiveStatus(date, today: today, yesterday: yesterday) }
                .max { rank($0) < rank($1) }
            goal.week.days[d] = GoalHeatDay(date: date, status: best ?? .none)
        }
    }

    /// The server's order for a day's best check-in: done, then the 2-minute version, skip, miss.
    private static func rank(_ status: GoalStatus) -> Int {
        switch status {
        case .done: 4
        case .min: 3
        case .skip: 2
        case .miss: 1
        case .none, .clear, .unknown: 0
        }
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

/// Which of a goal's rows a check-in touches. Commitments and daily checks keep separate ids, so
/// a commitment and a check that share one never block or roll back each other.
enum GoalRowKey: Hashable, Sendable {
    case commitment(String)
    case check(String)
}

/// The server's latest value with the taps still in flight replayed on top: what a check-in
/// screen shows. A reload or another tap's answer replaces only `base`, so it never wipes a tap
/// that is still in flight, and dropping a tap that failed is its whole rollback.
struct GoalPendingEdits<Value, Key: Hashable> {
    var base: Value
    private var edits: [(key: Key, apply: (inout Value) -> Void)] = []

    init(_ base: Value) { self.base = base }

    var shown: Value { edits.reduce(into: base) { value, edit in edit.apply(&value) } }
    var keys: Set<Key> { Set(edits.map(\.key)) }

    func contains(_ key: Key) -> Bool { edits.contains { $0.key == key } }

    mutating func add(_ key: Key, _ apply: @escaping (inout Value) -> Void) { edits.append((key, apply)) }
    mutating func remove(_ key: Key) { edits.removeAll { $0.key == key } }
}
